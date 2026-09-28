import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import '../services/playback_engine.dart';
import '../services/system_media_controls.dart';
import 'listening_tracker.dart';

enum RepeatMode { off, all, one }

class AudioSource {
  const AudioSource(this.uri, {this.headers, this.local = false});
  final String uri;
  final Map<String, String>? headers;
  final bool local;
}

class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.resolveSource,
    PlaybackEngine? engine,
    SystemMediaControls? controls,
    bool enableSystemControls = true,
    Random? random,
  }) : _engine = engine ?? MediaKitEngine(),
       _controls = enableSystemControls
           ? (controls ?? NativeSystemMediaControls())
           : null,
       _random = random ?? Random();
  final Future<AudioSource> Function(Track track, bool localFirst)
  resolveSource;
  final PlaybackEngine _engine;
  final SystemMediaControls? _controls;
  final Random _random;
  List<Track> _queue = [];
  List<Track> get queue => List.unmodifiable(_queue);
  int index = -1;
  Track? get currentTrack =>
      index >= 0 && index < _queue.length ? _queue[index] : null;
  bool isPlaying = false, isBuffering = false, shuffle = false;
  RepeatMode repeatMode = RepeatMode.off;
  double _volume = 100, _lastPositiveVolume = 100;
  bool _volumeOverridden = false;
  double get volume => _volume;
  bool get isMuted => _volume == 0;
  Duration position = Duration.zero, duration = Duration.zero;
  String? error;
  String? _playbackError;
  ListeningTracker? _tracker;
  Future<void> Function(ListeningEvent)? _saveEvent;
  final _pending = <ListeningEvent>[];
  Future<void>? _persisting, _shutdownFuture;
  final Stopwatch _clock = Stopwatch()..start();
  StreamSubscription<EngineState>? _subscription;
  Timer? _timer;
  int _ticks = 0;
  bool _initialized = false,
      _opening = false,
      _seeking = false,
      _completedSeen = false,
      _disposed = false,
      _closing = false,
      _notifierDisposed = false;
  EngineState _lastState = const EngineState();
  bool _sourceLocal = false, _failedOver = false;
  int _generation = 0;
  Future<void> _operations = Future.value();
  final List<int> _shuffleHistory = [];
  final List<int> _shuffleRemaining = [];
  void configureRecording(
    String deviceId,
    Future<void> Function(ListeningEvent) saveEvent,
  ) {
    _saveEvent = saveEvent;
    _tracker = ListeningTracker(
      deviceId: deviceId,
      newId: () => const Uuid().v4(),
      monotonicMs: () => _clock.elapsedMilliseconds,
      wallNow: DateTime.now,
    );
  }

  Future<void> _initialize() async {
    if (_initialized) return;
    await _engine.initialize();
    // Leave native defaults untouched until volume is explicitly adjusted.
    // Apply before opening audio; a failure leaves initialization retryable.
    if (_volumeOverridden) await _engine.setVolume(_volume);
    _subscription = _engine.states.listen(_onState);
    _initialized = true;
    try {
      await _controls?.initialize(
        MediaCommands(
          play: () => _safe(play),
          pause: () => _safe(pause),
          stop: () => _safe(stop),
          next: () => _safe(next),
          previous: () => _safe(previous),
          seek: (p) => _safe(() => seek(p)),
          shuffle: setShuffle,
          repeat: (v) => setRepeat(RepeatMode.values[v]),
        ),
      );
    } catch (e) {
      error = 'System media controls unavailable: $e';
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _tracker?.tick();
      if (++_ticks % 10 == 0) unawaited(_safe(checkpoint));
    });
  }

  Future<void> _safe(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      error = e.toString();
      _notify();
    }
  }

  Future<void> _enqueue(
    Future<void> Function() action, {
    bool allowClosing = false,
  }) {
    final next = _operations.then((_) async {
      if (_disposed || (_closing && !allowClosing)) return;
      await action();
    });
    _operations = next.catchError((Object e) {
      error = e.toString();
      _notify();
    });
    return next;
  }

  void _notify() {
    if (_disposed || _notifierDisposed) return;
    notifyListeners();
    if (_initialized) {
      unawaited(
        _controls
                ?.update(
                  track: currentTrack,
                  queue: queue,
                  index: index,
                  playing: isPlaying,
                  buffering: isBuffering,
                  position: position,
                  shuffle: shuffle,
                  repeat: repeatMode.index,
                )
                .catchError((Object e) {
                  error = 'System media controls: $e';
                }) ??
            Future.value(),
      );
    }
  }

  void _onState(EngineState state) {
    if (_disposed) return;
    _lastState = state;
    if (state.error != null) _playbackError = error = state.error;
    final wasActive = isPlaying && !isBuffering;
    isPlaying = state.playing;
    isBuffering = state.buffering;
    position = state.position;
    duration = state.duration > Duration.zero
        ? state.duration
        : currentTrack?.duration ?? Duration.zero;
    _tracker?.setActive(
      isPlaying &&
          !isBuffering &&
          !_opening &&
          !_seeking &&
          !state.completed &&
          !_completedSeen &&
          _playbackError == null,
    );
    if (wasActive && (!isPlaying || isBuffering)) unawaited(_safe(checkpoint));
    if (state.error != null) {
      error = state.error;
      unawaited(_safe(checkpoint));
      if (!_opening && !_failedOver && currentTrack != null) {
        _failedOver = true;
        final generation = _generation;
        unawaited(
          _safe(
            () => _enqueue(() async {
              if (generation == _generation) await _recoverPlayback();
            }),
          ),
        );
      }
    }
    if (state.completed &&
        !_completedSeen &&
        !_opening &&
        _playbackError == null) {
      _completedSeen = true;
      final generation = _generation;
      unawaited(
        _safe(
          () => _enqueue(() async {
            if (generation == _generation) await _advance(completed: true);
          }),
        ),
      );
    }
    _notify();
  }

  Future<void> checkpoint() async {
    _pending.addAll(_tracker?.flush() ?? []);
    if (_persisting != null) {
      await _persisting;
      return;
    }
    _persisting = _persist();
    try {
      await _persisting;
    } finally {
      _persisting = null;
    }
  }

  Future<void> _persist() async {
    while (_pending.isNotEmpty && _saveEvent != null) {
      await _saveEvent!(_pending.first);
      _pending.removeAt(0);
    }
  }

  Future<void> playQueue(List<Track> tracks, {int index = 0}) =>
      _enqueue(() async {
        if (tracks.isEmpty) {
          await _stop();
          return;
        }
        if (index < 0 || index >= tracks.length) {
          throw RangeError.index(index, tracks);
        }
        await _initialize();
        await _haltForTransition();
        _queue = List.of(tracks);
        this.index = index;
        _resetShuffle();
        await _openCurrent();
      });
  Future<void> _haltForTransition() async {
    _generation++;
    _opening = true;
    _tracker?.setActive(false);
    try {
      await _engine.stop();
      await checkpoint();
    } catch (_) {
      _opening = false;
      rethrow;
    }
  }

  Future<void> _openCurrent() async {
    final track = currentTrack;
    if (track == null) return;
    _opening = true;
    _completedSeen = false;
    _failedOver = false;
    _tracker?.start(track.id);
    position = Duration.zero;
    duration = track.duration;
    _playbackError = error = null;
    try {
      final source = await resolveSource(track, true);
      _sourceLocal = source.local;
      try {
        await _engine.open(source.uri, headers: source.headers);
        if (_playbackError != null) throw StateError(_playbackError!);
      } catch (_) {
        if (!source.local) rethrow;
        _failedOver = true;
        final fallback = await resolveSource(track, false);
        _sourceLocal = fallback.local;
        _playbackError = error = null;
        await _engine.open(fallback.uri, headers: fallback.headers);
        if (_playbackError != null) throw StateError(_playbackError!);
      }
    } catch (e) {
      _tracker?.setActive(false);
      _playbackError = error = e.toString();
      rethrow;
    } finally {
      _opening = false;
      _tracker?.setActive(
        _lastState.playing &&
            !_lastState.buffering &&
            !_lastState.completed &&
            _playbackError == null,
      );
      _notify();
    }
  }

  Future<void> _recoverPlayback() async {
    final track = currentTrack;
    if (track == null) return;
    final resumeAt = position;
    _generation++;
    _opening = true;
    _tracker?.setActive(false);
    try {
      await _engine.stop();
      await checkpoint();
      // A failed local file falls back to the server; a failed stream can use
      // an audio file downloaded meanwhile, otherwise refresh its auth headers.
      final source = await resolveSource(track, !_sourceLocal);
      _sourceLocal = source.local;
      _playbackError = error = null;
      await _engine.open(source.uri, headers: source.headers);
      if (_playbackError != null) throw StateError(_playbackError!);
      await _engine.seek(resumeAt);
    } catch (e) {
      _playbackError = error = e.toString();
      rethrow;
    } finally {
      _opening = false;
      _tracker?.setActive(
        isPlaying &&
            !isBuffering &&
            !_lastState.completed &&
            _playbackError == null,
      );
      _notify();
    }
  }

  Future<void> play() => _enqueue(() async {
    if (currentTrack == null) return;
    await _initialize();
    await _engine.play();
  });
  Future<void> pause() => _enqueue(() async {
    _tracker?.setActive(false);
    await _engine.pause();
    await checkpoint();
  });
  Future<void> toggle() => isPlaying ? pause() : play();

  Future<void> setVolume(double value) => _enqueue(() async {
    if (!value.isFinite) {
      throw ArgumentError.value(value, 'volume', 'Must be finite');
    }
    await _setVolume(value.clamp(0.0, 100.0));
  });

  Future<void> toggleMute() =>
      _enqueue(() => _setVolume(isMuted ? _lastPositiveVolume : 0));

  Future<void> _setVolume(double value) async {
    // Idle changes must not load native audio. Once initialized, publish only
    // after the native command succeeds, including the remembered restore level.
    if (_initialized) await _engine.setVolume(value);
    _volumeOverridden = true;
    _volume = value;
    if (value > 0) _lastPositiveVolume = value;
    _notify();
  }

  Future<void> seek(Duration value) => _enqueue(() async {
    if (currentTrack == null) return;
    _seeking = true;
    _tracker?.setActive(false);
    try {
      await checkpoint();
      await _engine.seek(
        Duration(
          milliseconds: value.inMilliseconds.clamp(0, duration.inMilliseconds),
        ),
      );
    } finally {
      _seeking = false;
      _tracker?.setActive(
        isPlaying &&
            !isBuffering &&
            !_lastState.completed &&
            _playbackError == null,
      );
    }
  });
  Future<void> next() => _enqueue(() => _advance(completed: false));
  Future<void> _advance({required bool completed}) async {
    if (_queue.isEmpty) return;
    await _haltForTransition();
    if (completed && repeatMode == RepeatMode.one) {
      await _openCurrent();
      return;
    }
    int target;
    if (shuffle) {
      if (_shuffleRemaining.isEmpty) {
        if (repeatMode != RepeatMode.all) {
          await _stop();
          return;
        }
        _shuffleRemaining.addAll(
          List.generate(_queue.length, (i) => i).where((i) => i != index),
        );
        _shuffleRemaining.shuffle(_random);
      }
      _shuffleHistory.add(index);
      target = _shuffleRemaining.isEmpty
          ? index
          : _shuffleRemaining.removeLast();
    } else {
      target = index + 1;
      if (target >= _queue.length) {
        if (repeatMode != RepeatMode.all) {
          await _stop();
          return;
        }
        target = 0;
      }
    }
    index = target;
    await _openCurrent();
  }

  Future<void> previous() => _enqueue(() async {
    if (currentTrack == null) return;
    final restart = position > const Duration(seconds: 3);
    await _haltForTransition();
    if (!restart) {
      if (shuffle && _shuffleHistory.isNotEmpty) {
        _shuffleRemaining.add(index);
        index = _shuffleHistory.removeLast();
      } else if (!shuffle) {
        index = index > 0
            ? index - 1
            : repeatMode == RepeatMode.all
            ? _queue.length - 1
            : 0;
      }
    }
    await _openCurrent();
  });
  void _resetShuffle() {
    _shuffleHistory.clear();
    _shuffleRemaining
      ..clear()
      ..addAll(List.generate(_queue.length, (i) => i).where((i) => i != index))
      ..shuffle(_random);
  }

  void setShuffle(bool value) {
    if (shuffle == value) return;
    shuffle = value;
    _resetShuffle();
    _notify();
  }

  void setRepeat(RepeatMode value) {
    if (repeatMode == value) return;
    repeatMode = value;
    _notify();
  }

  Future<void> _stop() async {
    _generation++;
    _opening = true;
    _tracker?.setActive(false);
    try {
      // Stop audio even when saving listening events fails (e.g. sign-out).
      try {
        await _engine.stop();
      } finally {
        await checkpoint();
      }
    } finally {
      _tracker?.clear();
      _opening = false;
      _lastState = const EngineState();
      _playbackError = null;
      isPlaying = false;
      isBuffering = false;
      position = duration = Duration.zero;
      _queue = [];
      index = -1;
      _notify();
    }
  }

  Future<void> stop() => _enqueue(_stop);

  /// Await before closing the account cache/application to durably flush events.
  Future<void> shutdown() => _shutdownFuture ??= _shutdown();
  Future<void> _shutdown() async {
    if (_disposed) return;
    _closing = true;
    try {
      await _enqueue(_stop, allowClosing: true);
    } finally {
      _disposed = true;
      _timer?.cancel();
      await _subscription?.cancel();
      try {
        await _controls?.dispose();
      } finally {
        await _engine.dispose();
      }
    }
  }

  @override
  void dispose() {
    _notifierDisposed = true;
    unawaited(
      shutdown().catchError((Object e) {
        error = e.toString();
      }),
    );
    super.dispose();
  }
}
