import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as path;

import 'playback_relay.dart';

class EngineState {
  const EngineState({
    this.playing = false,
    this.buffering = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.completed = false,
    this.error,
  });
  final bool playing, buffering, completed;
  final Duration position, duration;
  final String? error;
}

abstract interface class PlaybackEngine {
  Stream<EngineState> get states;
  Future<void> initialize();

  /// [start] is applied during loading, not by seeking before media is ready.
  Future<void> open(
    String uri, {
    Map<String, String>? headers,
    bool play = true,
    Duration start = Duration.zero,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// App-local perceived loudness percentage (0–100), not native mixer gain.
  Future<void> setVolume(double volume);
  Future<void> stop();
  Future<void> dispose();
}

/// Thin native adapter: tests inject an in-memory PlaybackEngine instead.
class MediaKitEngine implements PlaybackEngine {
  MediaKitEngine({
    Future<Player> Function()? createPlayer,
    Future<AudioSession?> Function()? loadSession,
    this._createHttpClient,
  }) : _createPlayer = createPlayer ?? _nativePlayer,
       _loadSession = loadSession ?? _nativeSession,
       _sessionOptional = loadSession == null && Platform.isMacOS;

  final Future<Player> Function() _createPlayer;
  final HttpClient Function()? _createHttpClient;
  _EngineRelay? _relay;
  final _relays = <_EngineRelay>{};
  final Future<AudioSession?> Function() _loadSession;
  final bool _sessionOptional;
  Player? _player;
  AudioSession? _session;
  Future<void>? _initializing;
  final _states = StreamController<EngineState>.broadcast(sync: true);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _resumeAfterInterruption = false,
      _interrupted = false,
      _disposed = false;
  int _intent = 0;
  bool _wantsPlayback = false;
  _NativeSource? _nativeSource;
  String? _retiredLocalUri;

  // Only our relay capability URLs have this shape. Native log events have no
  // source ID, but a failed-open message naming a different capability cannot
  // describe the current source. Do not discard unidentifiable decoder errors.
  static final _relayUriPattern = RegExp(
    r'http://127\.0\.0\.1:[0-9]+/[a-f0-9]{64}(?=[^a-zA-Z0-9/_?%#-]|$)',
  );
  static final _failedOpenPattern = RegExp(
    r'^Failed to open (.+)\.$',
    dotAll: true,
  );
  static final _cannotOpenFilePattern = RegExp(
    r"^Cannot open file '(.+)': [^\r\n]+$",
    dotAll: true,
  );

  static Future<Player> _nativePlayer() async {
    MediaKit.ensureInitialized();
    return Player();
  }

  static Future<AudioSession?> _nativeSession() async {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      return AudioSession.instance;
    }
    return null;
  }

  @override
  Stream<EngineState> get states => _states.stream;

  @override
  Future<void> initialize() async {
    if (_disposed) throw StateError('Playback engine is disposed');
    if (_player != null) return;
    final pending = _initializing ??= _initialize();
    try {
      await pending;
    } finally {
      if (identical(_initializing, pending)) _initializing = null;
    }
  }

  Future<void> _initialize() async {
    final player = await _createPlayer();
    void emit([String? error]) {
      if (_disposed) return;
      final s = player.state;
      _states.add(
        EngineState(
          playing: s.playing,
          buffering: s.buffering,
          position: s.position,
          duration: s.duration,
          completed: s.completed,
          error: error,
        ),
      );
    }

    try {
      // Defense in depth: native playback receives only loopback relay URLs,
      // never authenticated upstream URLs. Dart's HttpClient verifies upstream
      // TLS. Read back because setProperty ignores mpv's return code.
      final native = player.platform as NativePlayer;
      await native.setProperty('tls-verify', 'yes');
      if (await native.getProperty('tls-verify') != 'yes') {
        throw StateError('Native TLS certificate verification unavailable');
      }
      AudioSession? session;
      try {
        session = await _loadSession();
        await session?.configure(const AudioSessionConfiguration.music());
      } catch (_) {
        // Some macOS versions lack audio_session, but can still play via mpv.
        if (!_sessionOptional) rethrow;
        session = null;
      }
      _subscriptions.addAll([
        player.stream.playing.listen((_) => emit()),
        player.stream.buffering.listen((_) => emit()),
        player.stream.position.listen((_) => emit()),
        player.stream.duration.listen((_) => emit()),
        player.stream.completed.listen((_) => emit()),
        player.stream.error.listen((message) {
          if (_isStaleNativeError(message)) return;
          emit(message);
        }),
      ]);
      if (session != null) {
        _subscriptions.add(
          session.interruptionEventStream.listen((event) {
            if (event.begin) {
              if (!_interrupted) {
                _resumeAfterInterruption = player.state.playing;
              }
              _interrupted = true;
              _wantsPlayback = false;
              _intent++; // Invalidate any activation already in flight.
              unawaited(
                _pausePlayer().catchError((Object e) => emit(e.toString())),
              );
            } else {
              final resume =
                  _interrupted &&
                  _resumeAfterInterruption &&
                  event.type != AudioInterruptionType.unknown;
              _interrupted = false;
              _resumeAfterInterruption = false;
              if (resume) {
                unawaited(play().catchError((Object e) => emit(e.toString())));
              }
            }
          }),
        );
        _subscriptions.add(
          session.becomingNoisyEventStream.listen((_) {
            unawaited(pause().catchError((Object e) => emit(e.toString())));
          }),
        );
      }
      // Publish only a fully configured player. TLS/session failures below
      // dispose the partial player and propagate, allowing a later retry.
      _session = session;
      _player = player;
    } catch (_) {
      for (final subscription in _subscriptions) {
        await subscription.cancel();
      }
      _subscriptions.clear();
      await player.dispose();
      rethrow;
    }
  }

  bool _isStaleNativeError(String message) {
    final source = _nativeSource;
    // stop/replacement invalidates the old source before closing its relay.
    // A new source owns errors only once it is submitted to native open, not
    // while binding a relay or waiting for audio focus.
    if (source == null) return true;
    // media_kit also forwards ffmpeg TCP logs through its error stream. A
    // local file cannot produce a relay connection error; its own file/decoder
    // failures must still be reported, including before the first audio tick.
    if (source.local && message.startsWith('tcp:')) return true;
    if (message.contains('Failed to open')) {
      final relays = _relayUriPattern.allMatches(message).map((m) => m[0]!);
      if (relays.isNotEmpty && !relays.contains(source.uri)) return true;
    }
    // media_kit forwards mpv's trimmed text verbatim. These two formats name
    // the exact path passed to native open (including spaces and apostrophes).
    // Match only the known retired file, never every path unlike the current
    // file: an unknown path can be a genuine current-source dependency error.
    final failedUri =
        _failedOpenPattern.firstMatch(message.trim())?[1] ??
        _cannotOpenFilePattern.firstMatch(message.trim())?[1];
    final retired = _retiredLocalUri;
    if (failedUri != null &&
        retired != null &&
        !_sameNativeFilePath(failedUri, source.uri) &&
        _sameNativeFilePath(failedUri, retired)) {
      return true;
    }
    return false;
  }

  static bool _sameNativeFilePath(String reported, String expected) {
    if (reported == expected) return true;
    // media_kit normalizes file paths before loading and adds the Windows
    // long-path prefix. Do not normalize network/content URIs as file paths.
    if (!path.isAbsolute(reported) || !path.isAbsolute(expected)) return false;
    String normalize(String value) {
      if (Platform.isWindows && value.startsWith('\\\\?\\')) {
        value = value.substring(4);
      }
      return path.normalize(value);
    }

    return normalize(reported) == normalize(expected);
  }

  void _retireNativeSource() {
    final source = _nativeSource;
    if (source != null) _retiredLocalUri = source.local ? source.uri : null;
    _nativeSource = null;
  }

  Future<bool> _activate(int intent) async {
    final session = _session;
    final accepted = session == null || await session.setActive(true);
    if (intent != _intent || _disposed) {
      // Focus may have arrived after stop already deactivated the session.
      if (!_wantsPlayback) await session?.setActive(false);
      return false;
    }
    if (!accepted) throw StateError('Audio focus was denied');
    return true;
  }

  @override
  Future<void> open(
    String uri, {
    Map<String, String>? headers,
    bool play = true,
    Duration start = Duration.zero,
  }) async {
    final intent = ++_intent;
    _wantsPlayback = play;
    _resumeAfterInterruption = false;
    _retireNativeSource();
    final scheme = Uri.tryParse(uri)?.scheme.toLowerCase();
    final local =
        scheme == '' ||
        scheme == 'file' ||
        scheme == 'content' ||
        scheme == 'fd' ||
        scheme == 'asset' ||
        File(uri).isAbsolute;
    await _closeRelay();
    if (intent != _intent || _disposed) return;
    await initialize();
    if (intent != _intent || _disposed) return;
    _EngineRelay? source;
    _NativeSource? nativeSource;
    var opened = false, nativeOpenCompleted = false;
    try {
      var nativeUri = uri;
      final network = scheme == 'http' || scheme == 'https';
      if (network) {
        final relay = source = _EngineRelay();
        _relay = relay;
        _relays.add(relay);
        relay.binding = PlaybackRelay.start(
          Uri.parse(uri),
          headers: headers,
          createClient: _createHttpClient,
          onError: (_, _) {
            // A closing relay can finish a failed request after replacement.
            // Never expose upstream exceptions, URLs or credentials to the UI.
            if (_disposed || !identical(_relay, relay)) return;
            final s = _player!.state;
            _states.add(
              EngineState(
                playing: s.playing,
                buffering: s.buffering,
                position: s.position,
                duration: s.duration,
                completed: s.completed,
                error: 'Unable to load audio from the server.',
              ),
            );
          },
        );
        nativeUri = (await relay.binding).uri.toString();
        if (intent != _intent || _disposed) return;
      }
      if (play) {
        if (!await _activate(intent) || intent != _intent || _disposed) return;
      } else {
        await _session?.setActive(false);
        if (intent != _intent || _disposed) return;
      }
      // Media.start is applied by mpv's load hook. An immediate seek after
      // open can run before the file is ready; zero resets a previous start.
      final media = Media(
        nativeUri,
        httpHeaders: network ? null : headers,
        start: start,
      );
      _nativeSource = nativeSource = _NativeSource(media.uri, local, source);
      await _player!.open(media, play: play);
      nativeOpenCompleted = true;
      if (intent != _intent || _disposed) return;
      opened = true;
      source?.opening = false;
    } finally {
      if (!opened) {
        // A pause can invalidate intent while a local open finishes. The file
        // remains loaded and must still report its own errors on resume.
        if (!nativeOpenCompleted && identical(_nativeSource, nativeSource)) {
          _retireNativeSource();
        }
        if (source != null) await _retireRelay(source);
      }
    }
  }

  @override
  Future<void> play() async {
    final intent = ++_intent;
    _wantsPlayback = true;
    await initialize();
    if (intent != _intent || _disposed) return;
    // A stop/pause during focus acquisition must win over automatic resume.
    if (!await _activate(intent) || intent != _intent || _disposed) return;
    await _player!.play();
  }

  Future<void> _retireRelay(_EngineRelay relay) async {
    // Detach before awaiting so cancellation errors cannot affect a new source.
    if (identical(_relay, relay)) _relay = null;
    if (identical(_nativeSource?.relay, relay)) _retireNativeSource();
    try {
      await relay.close();
    } finally {
      _relays.remove(relay);
    }
  }

  Future<void> _closeRelay({bool onlyOpening = false}) async {
    // Include retired relays still binding/closing, even when another command
    // has already detached them. stop/dispose must await their cleanup too.
    await Future.wait([
      for (final relay in _relays.toList())
        if (!onlyOpening || relay.opening) _retireRelay(relay),
    ]);
  }

  Future<void> _pausePlayer() async {
    await Future.wait([
      _closeRelay(onlyOpening: true),
      if (_player != null) _player!.pause(),
    ]);
    await _session?.setActive(false);
  }

  @override
  Future<void> pause() async {
    _wantsPlayback = false;
    _intent++;
    _resumeAfterInterruption = false;
    await _pausePlayer();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player?.seek(position);
  }

  @override
  Future<void> setVolume(double volume) async {
    if (!volume.isFinite) {
      throw ArgumentError.value(volume, 'volume', 'Must be finite');
    }
    // Approximate half perceived loudness with a 10 dB reduction each time
    // the UI percentage halves. mpv applies (nativeVolume / 100)^3 to the
    // signal, so compensate for that cubic curve here, not in saved/UI values.
    // 60 * log10(nativeVolume / 100) = 10 * log2(volume / 100).
    // Zero stays exact silence; 100 stays unity gain.
    final fraction = volume.clamp(0.0, 100.0) / 100.0;
    final nativeVolume =
        100.0 * math.pow(fraction, math.ln10 / (6 * math.ln2)).toDouble();
    await _player?.setVolume(nativeVolume);
  }

  @override
  Future<void> stop() async {
    _wantsPlayback = false;
    _retireNativeSource();
    _intent++;
    _resumeAfterInterruption = false;
    await _closeRelay();
    await _player?.stop();
    await _session?.setActive(false);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _wantsPlayback = false;
    _nativeSource = null;
    _retiredLocalUri = null;
    _intent++;
    _resumeAfterInterruption = false;
    try {
      await _initializing;
    } catch (_) {
      // Initialization already cleaned up its partial player.
    }
    for (final s in _subscriptions) {
      await s.cancel();
    }
    _subscriptions.clear();
    try {
      await _closeRelay();
      await _player?.dispose();
      await _session?.setActive(false);
    } finally {
      _player = null;
      _session = null;
      await _states.close();
    }
  }
}

class _NativeSource {
  const _NativeSource(this.uri, this.local, this.relay);

  final String uri;
  final bool local;
  final _EngineRelay? relay;
}

/// Owns both an in-flight loopback bind and the established relay. Closing while
/// binding waits for the result and immediately closes it; repeated closes are
/// safe when cancellation races the open operation's cleanup.
class _EngineRelay {
  late final Future<PlaybackRelay> binding;
  bool opening = true;
  Future<void>? _closing;

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    final relay = await binding;
    await relay.close();
  }
}
