import 'dart:async';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:media_kit/media_kit.dart';

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
  Future<void> open(String uri, {Map<String, String>? headers});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> stop();
  Future<void> dispose();
}

/// Thin native adapter: tests inject an in-memory PlaybackEngine instead.
class MediaKitEngine implements PlaybackEngine {
  MediaKitEngine({
    Future<Player> Function()? createPlayer,
    Future<AudioSession?> Function()? loadSession,
  }) : _createPlayer = createPlayer ?? _nativePlayer,
       _loadSession = loadSession ?? _nativeSession,
       _sessionOptional = loadSession == null && Platform.isMacOS;

  final Future<Player> Function() _createPlayer;
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
        player.stream.error.listen(emit),
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
                player.pause().catchError((Object e) => emit(e.toString())),
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
      // Publish only a fully configured player. A failed AudioSession setup
      // must dispose the partial player and allow a later initialize to retry.
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
  Future<void> open(String uri, {Map<String, String>? headers}) async {
    final intent = ++_intent;
    _wantsPlayback = true;
    _resumeAfterInterruption = false;
    await initialize();
    if (intent != _intent || _disposed) return;
    if (!await _activate(intent) || intent != _intent || _disposed) return;
    await _player!.open(Media(uri, httpHeaders: headers));
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

  @override
  Future<void> pause() async {
    _wantsPlayback = false;
    _intent++;
    _resumeAfterInterruption = false;
    await _player?.pause();
    await _session?.setActive(false);
  }

  @override
  Future<void> seek(Duration position) async {
    await _player?.seek(position);
  }

  @override
  Future<void> stop() async {
    _wantsPlayback = false;
    _intent++;
    _resumeAfterInterruption = false;
    await _player?.stop();
    await _session?.setActive(false);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _wantsPlayback = false;
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
      await _player?.dispose();
      await _session?.setActive(false);
    } finally {
      _player = null;
      _session = null;
      await _states.close();
    }
  }
}
