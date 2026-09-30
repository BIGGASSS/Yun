import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import '../models/playback_settings.dart';
import '../services/playback_engine.dart';
import '../services/system_media_controls.dart';
import 'listening_tracker.dart';

export '../models/playback_settings.dart' show PlaybackSettings, RepeatMode;

class AudioSource {
  const AudioSource(this.uri, {this.headers, this.local = false});
  final String uri;
  final Map<String, String>? headers;
  final bool local;
}

/// One occurrence in the effective play queue. Identity distinguishes duplicate
/// tracks, including a queued copy of a track already in the collection.
class PlaybackQueueEntry {
  PlaybackQueueEntry._(this.track, {this.sourceIndex});

  final Track track;
  final int? sourceIndex;
  bool get isManuallyQueued => sourceIndex == null;
}

class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.resolveSource,
    PlaybackEngine? engine,
    SystemMediaControls? controls,
    bool enableSystemControls = true,
    Random? random,
    PlaybackSettings initialSettings = const PlaybackSettings(),
    this._saveSettings,
    this._monotonicMs,
  }) : _engine = engine ?? MediaKitEngine(),
       _controls = enableSystemControls
           ? (controls ?? NativeSystemMediaControls())
           : null,
       _random = random ?? Random() {
    final settings = PlaybackSettings.fromJson(initialSettings.toJson());
    _volume = settings.volume ?? 100;
    _volumeOverridden = settings.volume != null;
    _lastPositiveVolume = settings.lastPositiveVolume;
    shuffle = settings.shuffle;
    repeatMode = settings.repeatMode;
  }
  final Future<AudioSource> Function(Track track, bool localFirst)
  resolveSource;
  final PlaybackEngine _engine;
  final SystemMediaControls? _controls;
  final Random _random;
  final Future<void> Function(PlaybackSettings)? _saveSettings;
  Future<void>? _settingsWrites;
  String? _settingsError;
  List<Track> _queue = const [];

  /// Immutable snapshot, replaced only when queue membership/order changes.
  List<Track> get queue => _queue;
  List<PlaybackQueueEntry> _sourceEntries = const [];
  final _manualPending = ListQueue<PlaybackQueueEntry>();
  final _manualHistory = <PlaybackQueueEntry>[];
  PlaybackQueueEntry? _manualCurrent;
  List<PlaybackQueueEntry> _effectiveQueue = const [];
  List<Track> _effectiveTracks = const [];

  /// Immutable, cached snapshot in actual playback order, including manual
  /// occurrences. Unlike [queue], this reflects shuffle and queued-next tracks.
  List<PlaybackQueueEntry> get effectiveQueue => _effectiveQueue;
  int effectiveIndex = -1;
  int index = -1;
  Track? get currentTrack =>
      _manualCurrent?.track ??
      (index >= 0 && index < _queue.length ? _queue[index] : null);
  bool isPlaying = false, isBuffering = false, shuffle = false;
  RepeatMode repeatMode = RepeatMode.off;
  double _volume = 100, _lastPositiveVolume = 100;
  bool _volumeOverridden = false;
  double get volume => _volume;
  bool get isMuted => _volume == 0;
  Duration position = Duration.zero, duration = Duration.zero;
  String? error;
  String? _playbackError;
  _Recording? _recording;
  ListeningTracker? get _tracker => _recording?.tracker;
  final _recordingBuffers = <Object, _RecordingBuffer>{};
  final int Function()? _monotonicMs;
  Future<void>? _shutdownFuture, _controlsUpdate;
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

  /// Bind recording to a normalized server/user scope, not a device or track.
  /// Without [accountKey], only the identical callback can reclaim its buffer.
  /// Reconfiguration detaches immediately; checkpoints wait for earlier writes
  /// in the same scope before retrying with the new callback.
  void configureRecording(
    String deviceId,
    Future<void> Function(ListeningEvent) saveEvent, {
    String? accountKey,
  }) {
    _detachRecording();
    final key = accountKey ?? saveEvent;
    final buffer = _recordingBuffers.putIfAbsent(
      key,
      () => _RecordingBuffer(key),
    );
    _recording = _Recording(
      buffer,
      saveEvent,
      ListeningTracker(
        deviceId: deviceId,
        newId: () => const Uuid().v4(),
        monotonicMs: _monotonicMs ?? () => _clock.elapsedMilliseconds,
        wallNow: DateTime.now,
      ),
    );
  }

  /// Stop recording/retries synchronously, then await any accepted DB write.
  /// Call after stop, and await even on failure BEFORE closing the account DB.
  /// Failed segments remain quarantined in memory until that account returns.
  /// Unlike the durable database outbox, these cannot survive process exit.
  Future<void> detachRecording() {
    final buffer = _detachRecording();
    return buffer?.persisting ?? Future<void>.value();
  }

  _RecordingBuffer? _detachRecording() {
    final recording = _recording;
    if (recording == null) return null;
    _recording = null;
    recording.tracker.setActive(false);
    recording.buffer.pending.addAll(recording.tracker.flush());
    recording.tracker.clear();
    // Release the database closure; a running save holds its own snapshot.
    recording.saveEvent = null;
    _discardEmptyBuffer(recording.buffer);
    return recording.buffer;
  }

  void _discardEmptyBuffer(_RecordingBuffer buffer) {
    if (!identical(buffer, _recording?.buffer) &&
        buffer.pending.isEmpty &&
        buffer.persisting == null) {
      _recordingBuffers.remove(buffer.key);
    }
  }

  Future<void> _initialize() async {
    if (_initialized) return;
    await _engine.initialize();
    // Leave native defaults untouched unless volume was adjusted or restored.
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
      final update = _controls?.update(
        track: currentTrack,
        queue: _effectiveTracks,
        index: effectiveIndex,
        playing: isPlaying,
        buffering: isBuffering,
        position: position,
        shuffle: shuffle,
        repeat: repeatMode.index,
      );
      // Native controls return one shared future for a coalesced burst. Avoid
      // attaching an unbounded number of error handlers to that same drain.
      if (update != null && !identical(update, _controlsUpdate)) {
        _controlsUpdate = update;
        unawaited(
          update.then(
            (_) {
              if (identical(_controlsUpdate, update)) _controlsUpdate = null;
            },
            onError: (Object e) {
              if (identical(_controlsUpdate, update)) _controlsUpdate = null;
              error = 'System media controls: $e';
            },
          ),
        );
      }
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

  Future<void> checkpoint() {
    final recording = _recording;
    if (recording == null) return Future<void>.value();
    recording.buffer.pending.addAll(recording.tracker.flush());
    return recording.persisting ??= _persist(recording).whenComplete(() {
      recording.persisting = null;
    });
  }

  Future<void> _persist(_Recording recording) {
    final buffer = recording.buffer;
    final previous = buffer.persisting;
    late final Future<void> operation;
    operation =
        () async {
          // Only a previous recording can reach this branch: checkpoints within
          // one recording share its future and preserve its persistence errors.
          try {
            await previous;
          } catch (_) {
            // Its caller receives the error; this recording may retry the same
            // scope once that write settles, never concurrently or under a new ID.
          }
          while (buffer.pending.isNotEmpty && recording.saveEvent != null) {
            final save = recording.saveEvent!;
            await save(buffer.pending.first);
            buffer.pending.removeFirst();
          }
        }().whenComplete(() {
          if (identical(buffer.persisting, operation)) buffer.persisting = null;
          _discardEmptyBuffer(buffer);
        });
    buffer.persisting = operation;
    return operation;
  }

  /// Start a collection using shuffle unless a specific [index] is requested.
  /// Keep queue order and playback preferences unchanged.
  Future<void> playQueue(List<Track> tracks, {int? index}) =>
      _enqueue(() async {
        if (tracks.isEmpty) {
          await _stop();
          return;
        }
        if (index != null && (index < 0 || index >= tracks.length)) {
          throw RangeError.index(index, tracks);
        }
        await _initialize();
        await _haltForTransition();
        if (!listEquals(_queue, tracks)) {
          _queue = List.unmodifiable(tracks);
          _sourceEntries = List.unmodifiable([
            for (var i = 0; i < _queue.length; i++)
              PlaybackQueueEntry._(_queue[i], sourceIndex: i),
          ]);
        }
        _clearManualQueue();
        this.index = index ?? (shuffle ? _random.nextInt(tracks.length) : 0);
        _resetShuffle();
        _refreshEffectiveQueue();
        await _openCurrent();
      });

  /// Append an occurrence to the FIFO next-up queue without changing the
  /// collection cursor or consuming/rebuilding its shuffled continuation.
  /// When idle, begin playing the first requested track immediately.
  Future<void> queueNext(Track track) => queueNextTracks([track]);

  Future<void> queueNextTracks(List<Track> tracks) {
    final entries = [for (final track in tracks) PlaybackQueueEntry._(track)];
    return _enqueue(() async {
      if (entries.isEmpty) return;
      if (currentTrack == null) {
        await _initialize();
        await _haltForTransition();
        _manualCurrent = entries.first;
        _manualPending.addAll(entries.skip(1));
        _refreshEffectiveQueue();
        await _openCurrent();
      } else {
        _manualPending.addAll(entries);
        _refreshEffectiveQueue();
        _notify();
      }
    });
  }

  /// Select the exact displayed occurrence without rebuilding the shuffle bag.
  /// Stale occurrences removed by a transition are ignored.
  Future<void> selectQueueEntry(PlaybackQueueEntry entry) => _enqueue(() async {
    if (!_effectiveQueue.contains(entry)) return;
    await _haltForTransition();
    if (entry.isManuallyQueued) {
      final manual = [..._manualHistory, ?_manualCurrent, ..._manualPending];
      final target = manual.indexOf(entry);
      _manualHistory
        ..clear()
        ..addAll(manual.take(target));
      _manualCurrent = entry;
      _manualPending
        ..clear()
        ..addAll(manual.skip(target + 1));
    } else {
      if (shuffle) {
        final order = [
          ..._shuffleHistory,
          index,
          ..._shuffleRemaining.reversed,
        ];
        final target = order.indexOf(entry.sourceIndex!);
        _shuffleHistory
          ..clear()
          ..addAll(order.take(target));
        _shuffleRemaining
          ..clear()
          ..addAll(order.skip(target + 1).toList().reversed);
      }
      index = entry.sourceIndex!;
      _manualCurrent = null;
      _manualHistory.clear();
    }
    _refreshEffectiveQueue();
    await _openCurrent();
  });

  void _clearManualQueue() {
    _manualCurrent = null;
    _manualHistory.clear();
    _manualPending.clear();
  }

  void _refreshEffectiveQueue() {
    final before = <PlaybackQueueEntry>[];
    final after = <PlaybackQueueEntry>[];
    if (index >= 0 && index < _queue.length) {
      if (shuffle) {
        before.addAll(_shuffleHistory.map((i) => _sourceEntries[i]));
        after.addAll(_shuffleRemaining.reversed.map((i) => _sourceEntries[i]));
      } else {
        before.addAll(_sourceEntries.take(index));
        after.addAll(_sourceEntries.skip(index + 1));
      }
      before.add(_sourceEntries[index]);
    }
    before.addAll(_manualHistory);
    if (_manualCurrent != null) before.add(_manualCurrent!);
    effectiveIndex = currentTrack == null ? -1 : before.length - 1;
    _effectiveQueue = List.unmodifiable([
      ...before,
      ..._manualPending,
      ...after,
    ]);
    _effectiveTracks = List.unmodifiable(
      _effectiveQueue.map((entry) => entry.track),
    );
  }

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
    unawaited(_persistSettings());
    _notify();
  }

  // Capture only preferences, never account/queue/listening state. Serialize
  // complete snapshots separately from audio commands so slow storage cannot
  // make slider dragging lag or allow an older write to replace a newer one.
  Future<void> _persistSettings() {
    final save = _saveSettings;
    if (save == null) return Future.value();
    final settings = PlaybackSettings(
      volume: _volumeOverridden ? _volume : null,
      lastPositiveVolume: _lastPositiveVolume,
      shuffle: shuffle,
      repeatMode: repeatMode,
    );
    return _settingsWrites = (_settingsWrites ?? Future<void>.value()).then((
      _,
    ) async {
      try {
        await save(settings);
        if (_settingsError != null) {
          if (error == _settingsError) error = null;
          _settingsError = null;
          _notify();
        }
      } catch (e) {
        error = _settingsError = 'Could not save playback settings: $e';
        _notify();
      }
    });
  }

  /// Wait for accepted audio commands and their preference writes. Writes are
  /// eager; this is a drain, not a save-on-exit requirement. Failures are exposed
  /// in [error] and a subsequent settings command can retry.
  Future<void> flushSettings() async {
    await _operations;
    await _settingsWrites;
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
    if (currentTrack == null) return;
    await _haltForTransition();
    if (_manualPending.isNotEmpty) {
      if (_manualCurrent != null) _manualHistory.add(_manualCurrent!);
      _manualCurrent = _manualPending.removeFirst();
      _refreshEffectiveQueue();
      await _openCurrent();
      return;
    }
    final wasManual = _manualCurrent != null;
    _manualCurrent = null;
    _manualHistory.clear();
    if (_queue.isEmpty) {
      await _stop();
      return;
    }
    if (!wasManual && completed && repeatMode == RepeatMode.one) {
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
        _shuffleHistory.clear();
      }
      target = _shuffleRemaining.isEmpty
          ? index
          : _shuffleRemaining.removeLast();
      if (target != index) _shuffleHistory.add(index);
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
    _refreshEffectiveQueue();
    await _openCurrent();
  }

  Future<void> previous() => _enqueue(() async {
    if (currentTrack == null) return;
    final restart = position > const Duration(seconds: 3);
    await _haltForTransition();
    if (!restart) {
      if (_manualCurrent != null) {
        if (_manualHistory.isNotEmpty || _queue.isNotEmpty) {
          _manualPending.addFirst(_manualCurrent!);
          _manualCurrent = _manualHistory.isEmpty
              ? null
              : _manualHistory.removeLast();
        }
      } else if (shuffle && _shuffleHistory.isNotEmpty) {
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
    _refreshEffectiveQueue();
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
    if (_closing || _disposed) return;
    if (shuffle == value) {
      if (_settingsError != null) unawaited(_persistSettings());
      return;
    }
    shuffle = value;
    _resetShuffle();
    _refreshEffectiveQueue();
    unawaited(_persistSettings());
    _notify();
  }

  void setRepeat(RepeatMode value) {
    if (_closing || _disposed) return;
    if (repeatMode == value) {
      if (_settingsError != null) unawaited(_persistSettings());
      return;
    }
    repeatMode = value;
    unawaited(_persistSettings());
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
      _queue = const [];
      _sourceEntries = const [];
      _clearManualQueue();
      _shuffleHistory.clear();
      _shuffleRemaining.clear();
      index = -1;
      _refreshEffectiveQueue();
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
      await _settingsWrites;
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

class _RecordingBuffer {
  _RecordingBuffer(this.key);
  final Object key;
  final pending = ListQueue<ListeningEvent>();
  Future<void>? persisting;
}

class _Recording {
  _Recording(this.buffer, this.saveEvent, this.tracker);
  final _RecordingBuffer buffer;
  final ListeningTracker tracker;
  Future<void> Function(ListeningEvent)? saveEvent;
  Future<void>? persisting;
}
