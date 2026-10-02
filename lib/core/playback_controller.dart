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

/// A completed download is unavailable locally. Playback must not silently
/// substitute a network source; the user can retry or explicitly repair it.
class LocalAudioUnavailable implements Exception {
  const LocalAudioUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
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
    final controls = _controls;
    if (controls is RecoverableSystemMediaControls) {
      _controlsStatusSubscription = (controls as RecoverableSystemMediaControls)
          .statusChanges
          .listen((status) {
            if (_closing || _disposed) return;
            _controlsHealthy = status.available;
            _systemControlsUpdateError = status.error;
            if (!_notifierDisposed) notifyListeners();
          });
    }
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
  /// Repeat-cycle history is collapsed so each source occurrence appears once,
  /// prioritizing the current entry, then its nearest upcoming appearance.
  List<PlaybackQueueEntry> get effectiveQueue => _effectiveQueue;
  int effectiveIndex = -1;
  int index = -1;
  Track? get currentTrack =>
      _manualCurrent?.track ??
      (index >= 0 && index < _queue.length ? _queue[index] : null);
  bool isPlaying = false,
      isBuffering = false,
      isWaitingForAudio = false,
      shuffle = false;
  RepeatMode repeatMode = RepeatMode.off;
  double _volume = 100, _lastPositiveVolume = 100;
  bool _volumeOverridden = false;
  double get volume => _volume;
  bool get isMuted => _volume == 0;
  Duration position = Duration.zero, duration = Duration.zero;
  String? _error, _systemControlsError, _systemControlsUpdateError;
  String? get error => _error ?? systemMediaControlsError;
  set error(String? value) => _error = value;

  /// A service failure does not imply that the selected audio is damaged.
  /// Foreground playback remains available; background controls may not work.
  String? get systemMediaControlsError =>
      _systemControlsError ?? _systemControlsUpdateError;
  bool get systemMediaControlsAvailable =>
      _controlsInitialized && _controlsHealthy && !_closing && !_disposed;
  String? _playbackError;
  bool _audioFocusFailure = false;

  /// The first local failure for the selected track, retained until retry/stop.
  /// Audio-focus failures describe the session, not the downloaded bytes.
  String? get localPlaybackError =>
      _sourceLocal && !_audioFocusFailure ? _playbackError : null;
  String? get audioFocusError => _audioFocusFailure ? _playbackError : null;
  _Recording? _recording;
  ListeningTracker? get _tracker => _recording?.tracker;
  final _recordingBuffers = <Object, _RecordingBuffer>{};
  final int Function()? _monotonicMs;
  Future<void>? _shutdownFuture, _controlsUpdate;
  final Stopwatch _clock = Stopwatch()..start();
  StreamSubscription<EngineState>? _subscription;
  StreamSubscription<SystemMediaControlsStatus>? _controlsStatusSubscription;
  Timer? _timer;
  int _ticks = 0;
  Future<void>? _initialization;
  int _initializationCancellation = 0, _controlsAttempt = 0;
  bool _engineInitialized = false,
      _controlsInitialized = false,
      _controlsHealthy = true,
      _opening = false,
      _seeking = false,
      _completedSeen = false,
      _disposed = false,
      _closing = false,
      _notifierDisposed = false;
  EngineState _lastState = const EngineState();
  bool _sourceLocal = false, _failedOver = false, _wantsPlayback = false;
  // Native stop retires media before focus release/checkpoint can fail. A later
  // Play must reload the selection even when that failure was not a file error.
  bool _needsReload = false;
  // stop/checkpoint/source lookup can receive events from the retired source.
  // Accept events only once the next native open has actually been requested.
  bool _acceptSourceState = false;
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

  /// A failed service gets one attempt per explicit playback command. Native
  /// state ticks, automatic track advancement and settings never retry it.
  Future<bool> _initialize(int requestedAttempt) async {
    final cancellation = _initializationCancellation;
    await (_initialization ??= _initializePlayback(requestedAttempt)
        .whenComplete(() {
          _initialization = null;
        }));
    // Only explicit playback commands enter this method. Passive state ticks
    // and automatic EOF advancement never retry failed foreground promotion.
    // Recover before acquiring focus: a background request may depend on this
    // native acknowledgement, rather than a future successful decoder event.
    final controls = _controls;
    if (!_closing &&
        !_disposed &&
        cancellation == _initializationCancellation &&
        _controlsInitialized &&
        !_controlsHealthy &&
        requestedAttempt == _controlsAttempt &&
        controls is RecoverableSystemMediaControls) {
      try {
        await (controls as RecoverableSystemMediaControls).retryPlaybackState();
      } catch (_) {
        // The status stream carries a sanitized, persistent service warning.
        // A service failure must not prevent permitted foreground playback.
      } finally {
        _controlsAttempt++;
      }
    }
    return !_closing &&
        !_disposed &&
        cancellation == _initializationCancellation;
  }

  Future<void> _initializePlayback(int requestedAttempt) async {
    if (!_engineInitialized) {
      await _engine.initialize();
      if (_closing || _disposed) return;
      // Leave native defaults untouched unless volume was adjusted or restored.
      // Apply before opening audio; a failure leaves initialization retryable.
      if (_volumeOverridden) await _engine.setVolume(_volume);
      if (_closing || _disposed) return;
      _subscription = _engine.states.listen(_onState);
      _engineInitialized = true;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        _tracker?.tick();
        if (++_ticks % 10 == 0) unawaited(_safe(checkpoint));
      });
    }
    if (_controlsInitialized ||
        _controls == null ||
        _closing ||
        _disposed ||
        requestedAttempt != _controlsAttempt) {
      return;
    }
    try {
      await _controls.initialize(
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
      _controlsInitialized = true;
      _systemControlsError = null;
    } catch (e) {
      _systemControlsError ??=
          'Background playback and system media controls unavailable: $e. '
          'Try Play again to reconnect.';
    } finally {
      _controlsAttempt++;
    }
    // Also replay the current snapshot when reconnecting a paused selection.
    if (!_closing && !_disposed) _notify();
  }

  Future<void> _safe(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      error = _playbackError ?? e.toString();
      _notify();
    }
  }

  Future<void> _enqueuePlayback(
    Future<void> Function(int) action, {
    bool replacesPendingInitialization = false,
  }) {
    if (replacesPendingInitialization && _initialization != null) {
      _initializationCancellation++;
    }
    final requestedAttempt = _controlsAttempt;
    final cancellation = _initializationCancellation;
    return _enqueue(() async {
      if (cancellation != _initializationCancellation) return;
      await action(requestedAttempt);
    });
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
      error = _playbackError ?? e.toString();
      _notify();
    });
    return next;
  }

  void _notify() {
    if (_disposed || _notifierDisposed) return;
    notifyListeners();
    if (_controlsInitialized) {
      final update = _controls?.update(
        track: currentTrack,
        queue: _effectiveTracks,
        index: effectiveIndex,
        playing: isPlaying,
        buffering: isBuffering,
        waitingForAudio: isWaitingForAudio,
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
              if (!identical(_controlsUpdate, update)) return;
              _controlsUpdate = null;
              if (_systemControlsUpdateError != null &&
                  _controls is! RecoverableSystemMediaControls) {
                _systemControlsUpdateError = null;
                if (!_disposed && !_notifierDisposed) notifyListeners();
              }
            },
            onError: (Object e) {
              if (!identical(_controlsUpdate, update) || _disposed) return;
              _controlsUpdate = null;
              if (_controls is! RecoverableSystemMediaControls) {
                _systemControlsUpdateError = 'System media controls: $e';
              }
              if (!_notifierDisposed) notifyListeners();
            },
          ),
        );
      }
    }
  }

  void _onState(EngineState state) {
    if (_disposed || !_acceptSourceState) return;
    _lastState = state;
    if (state.error != null) {
      _recordPlaybackFailure(state.error!, audioFocus: state.audioFocusFailure);
    }
    // Error/end states may already report playing=false. Preserve the last
    // intent through recovery, while honoring native interruptions and pauses.
    if (!_opening && _playbackError == null && !state.completed) {
      _wantsPlayback = state.playing || state.waitingForAudio;
    }
    final wasActive = isPlaying && !isBuffering;
    isWaitingForAudio = state.waitingForAudio && _playbackError == null;
    isPlaying = state.playing && !isWaitingForAudio && _playbackError == null;
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
      unawaited(_safe(checkpoint));
      // A download stays local even when its decoder fails. Preserve the first
      // cause and let explicit Play/Redownload retry, rather than contacting a
      // server that may be unreachable (or concealing the local failure).
      if (!_opening && !_failedOver && currentTrack != null) {
        _failedOver = true;
        final generation = _generation;
        final cancellation = _initializationCancellation;
        unawaited(
          _safe(
            () => _enqueue(() async {
              if (generation != _generation ||
                  cancellation != _initializationCancellation) {
                return;
              }
              if (_sourceLocal || _audioFocusFailure) {
                await _haltFailedSource();
              } else {
                await _recoverPlayback();
              }
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
      final cancellation = _initializationCancellation;
      unawaited(
        _safe(
          () => _enqueue(() async {
            if (generation == _generation &&
                cancellation == _initializationCancellation) {
              await _advance(completed: true);
            }
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
      _enqueuePlayback((attempt) async {
        if (tracks.isEmpty) {
          await _stop();
          return;
        }
        if (index != null && (index < 0 || index >= tracks.length)) {
          throw RangeError.index(index, tracks);
        }
        if (!await _initialize(attempt)) return;
        if (!await _haltForTransition()) return;
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
      }, replacesPendingInitialization: true);

  /// Append an occurrence to the FIFO next-up queue without changing the
  /// collection cursor or consuming/rebuilding its shuffled continuation.
  /// When idle, begin playing the first requested track immediately.
  Future<void> queueNext(Track track) => queueNextTracks([track]);

  Future<void> queueNextTracks(List<Track> tracks) {
    final entries = [for (final track in tracks) PlaybackQueueEntry._(track)];
    return _enqueuePlayback((attempt) async {
      if (entries.isEmpty) return;
      if (currentTrack == null) {
        if (!await _initialize(attempt)) return;
        if (!await _haltForTransition()) return;
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
  Future<void> selectQueueEntry(PlaybackQueueEntry entry) => _enqueuePlayback((
    attempt,
  ) async {
    if (!_effectiveQueue.contains(entry)) return;
    if (!await _initialize(attempt)) return;
    if (!await _haltForTransition()) return;
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
        final sourceIndex = entry.sourceIndex!;
        final upcoming = _shuffleRemaining.lastIndexOf(sourceIndex);
        // Match the occurrence shown by _refreshEffectiveQueue, not an older
        // appearance of the same source index in repeat-all history.
        final target = sourceIndex == index
            ? _shuffleHistory.length
            : upcoming >= 0
            ? order.length - 1 - upcoming
            : _shuffleHistory.lastIndexOf(sourceIndex);
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
  }, replacesPendingInitialization: _effectiveQueue.contains(entry));

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
        // Navigation retains the full repeat timeline, but source identities
        // must be unique in the displayed queue (including after Previous).
        final seen = {index};
        after.addAll(
          _shuffleRemaining.reversed
              .where(seen.add)
              .map((i) => _sourceEntries[i]),
        );
        before.addAll(
          _shuffleHistory.reversed
              .where(seen.add)
              .toList()
              .reversed
              .map((i) => _sourceEntries[i]),
        );
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

  Future<bool> _haltForTransition({bool preserveFocus = false}) async {
    final cancellation = _initializationCancellation;
    _generation++;
    _opening = true;
    _acceptSourceState = false;
    _tracker?.setActive(false);
    isPlaying = isBuffering = isWaitingForAudio = false;
    _needsReload = true;
    try {
      final engine = _engine;
      if (preserveFocus && engine is TransitionPlaybackEngine) {
        await (engine as TransitionPlaybackEngine).stopForTransition();
      } else {
        await engine.stop();
      }
      await checkpoint();
      if (_closing ||
          _disposed ||
          cancellation != _initializationCancellation) {
        _opening = false;
        await _engine.stop();
        return false;
      }
      return true;
    } catch (failure) {
      _opening = false;
      if (failure is AudioFocusUnavailable) _recordPlaybackFailure(failure);
      // Retaining focus is valid only while the next track can still load.
      // Cleanup must not replace the original transition failure.
      if (preserveFocus) {
        try {
          await _engine.stop();
        } catch (_) {}
      }
      rethrow;
    }
  }

  String _describePlaybackError(Object failure, {bool audioFocus = false}) {
    if (audioFocus || failure is AudioFocusUnavailable) {
      return failure.toString();
    }
    if (failure is LocalAudioUnavailable) return failure.message;
    return _sourceLocal
        ? 'Could not play the downloaded audio: $failure'
        : failure.toString();
  }

  void _recordPlaybackFailure(Object failure, {bool audioFocus = false}) {
    if (_playbackError == null) {
      _audioFocusFailure = audioFocus || failure is AudioFocusUnavailable;
      _playbackError = _describePlaybackError(
        failure,
        audioFocus: _audioFocusFailure,
      );
    }
    error = _playbackError;
  }

  Future<void> _openCurrent({Duration start = Duration.zero}) async {
    final track = currentTrack;
    if (track == null) return;
    final cancellation = _initializationCancellation;
    _opening = true;
    _acceptSourceState = false;
    _sourceLocal = false;
    _lastState = const EngineState();
    _completedSeen = false;
    _failedOver = false;
    _wantsPlayback = true;
    _tracker?.start(track.id);
    isPlaying = isBuffering = isWaitingForAudio = false;
    position = start;
    duration = track.duration;
    _playbackError = error = null;
    _audioFocusFailure = false;
    try {
      final source = await resolveSource(track, true);
      if (_closing ||
          _disposed ||
          cancellation != _initializationCancellation) {
        await _engine.stop();
        return;
      }
      _sourceLocal = source.local;
      _acceptSourceState = true;
      await _engine.open(source.uri, headers: source.headers, start: start);
      if (_closing ||
          _disposed ||
          cancellation != _initializationCancellation) {
        _acceptSourceState = false;
        await _engine.stop();
        return;
      }
      if (_playbackError != null) {
        if (_audioFocusFailure) throw AudioFocusUnavailable(_playbackError!);
        throw StateError(_playbackError!);
      }
      _needsReload = false;
    } catch (e) {
      if (e is LocalAudioUnavailable) _sourceLocal = true;
      _tracker?.setActive(false);
      _recordPlaybackFailure(e);
      // A failed next-track lookup/open also owns a possibly retained focus
      // grant. Always retire it, including failures before source resolution.
      await _haltFailedSource();
      _acceptSourceState = false;
      isPlaying = isBuffering = isWaitingForAudio = false;
      rethrow;
    } finally {
      _opening = false;
      _tracker?.setActive(
        _lastState.playing &&
            !_lastState.buffering &&
            !_lastState.completed &&
            cancellation == _initializationCancellation &&
            _playbackError == null,
      );
      _notify();
    }
  }

  Future<void> _haltFailedSource({bool throwOnFailure = false}) async {
    // Keep queue, position and diagnosis available for explicit retry/repair,
    // but retire native events before stopping a failed decoder.
    _acceptSourceState = false;
    _tracker?.setActive(false);
    isPlaying = isBuffering = isWaitingForAudio = false;
    _needsReload = true;
    try {
      try {
        await _engine.stop();
      } finally {
        await checkpoint();
      }
    } catch (_) {
      // Cleanup must not replace the file/decoder failure that triggered it.
      // An explicit repair needs successful cleanup before replacing its file.
      if (throwOnFailure) rethrow;
    }
    _notify();
  }

  /// Release a failed/downloaded file before explicit repair, preserving queue.
  /// The guard runs in the audio operation queue, so it cannot stop a newer track.
  Future<void> prepareLocalRepair(String trackId) => _enqueue(() async {
    if (!_sourceLocal || currentTrack?.id != trackId) return;
    _generation++;
    _wantsPlayback = false;
    if (_playbackError == null || _audioFocusFailure) {
      _audioFocusFailure = false;
      _playbackError = 'Downloaded audio is being replaced. Try Play after redownload finishes.';
    }
    error = _playbackError;
    await _haltFailedSource(throwOnFailure: true);
  });

  Future<void> _recoverPlayback() async {
    final track = currentTrack;
    if (track == null || _sourceLocal) return;
    final cancellation = _initializationCancellation;
    final firstError = _playbackError;
    final resumeAt = position;
    final resumePlaying = _wantsPlayback;
    _generation++;
    _opening = true;
    _acceptSourceState = false;
    _needsReload = true;
    _tracker?.setActive(false);
    isPlaying = isBuffering = isWaitingForAudio = false;
    try {
      await _engine.stop();
      await checkpoint();
      if (_closing ||
          _disposed ||
          cancellation != _initializationCancellation) {
        return;
      }
      // A failed stream can use audio downloaded meanwhile; otherwise refresh
      // its auth headers. Resolution itself enforces completed-download intent.
      final source = await resolveSource(track, true);
      if (_closing ||
          _disposed ||
          cancellation != _initializationCancellation) {
        return;
      }
      _sourceLocal = source.local;
      _playbackError = error = null;
      _audioFocusFailure = false;
      _acceptSourceState = true;
      await _engine.open(
        source.uri,
        headers: source.headers,
        play: resumePlaying,
        start: resumeAt,
      );
      if (_closing ||
          _disposed ||
          cancellation != _initializationCancellation) {
        _acceptSourceState = false;
        await _engine.stop();
        return;
      }
      if (_playbackError != null) {
        if (_audioFocusFailure) throw AudioFocusUnavailable(_playbackError!);
        throw StateError(_playbackError!);
      }
      _needsReload = false;
    } catch (e) {
      if (e is LocalAudioUnavailable) {
        _sourceLocal = true;
        _playbackError = e.message;
        _audioFocusFailure = false;
      }
      _recordPlaybackFailure(e);
      // If even recovery fails, retain the triggering cause rather than just
      // the secondary relay/auth error. A newly selected local failure gets its
      // own actionable diagnosis.
      if (!_sourceLocal && !_audioFocusFailure && firstError != null) {
        _playbackError = firstError;
      }
      error = _playbackError;
      if (_sourceLocal || _audioFocusFailure) await _haltFailedSource();
      _acceptSourceState = false;
      isPlaying = isBuffering = isWaitingForAudio = false;
      rethrow;
    } finally {
      _opening = false;
      _tracker?.setActive(
        isPlaying &&
            !isBuffering &&
            !_lastState.completed &&
            cancellation == _initializationCancellation &&
            _playbackError == null,
      );
      _notify();
    }
  }

  Future<void> play() => _enqueuePlayback((attempt) async {
    if (currentTrack == null) return;
    if (!await _initialize(attempt)) return;
    if (_playbackError != null || _needsReload) {
      // A selected track can have no loaded media after resolution/open fails.
      // Retry local-first resolution, not play on an empty mpv. A focus denial
      // doesn't invalidate the audio or the position where it was paused.
      final start =
          !_completedSeen && (_audioFocusFailure || _playbackError == null)
          ? position
          : Duration.zero;
      if (!await _haltForTransition()) return;
      await _openCurrent(start: start);
    } else {
      _wantsPlayback = true;
      try {
        await _engine.play();
      } on AudioFocusUnavailable catch (e) {
        _recordPlaybackFailure(e);
        await _haltFailedSource();
        rethrow;
      }
    }
  });
  Future<void> pause() {
    _initializationCancellation++;
    _cancelPendingOpen();
    return _enqueue(() async {
      _wantsPlayback = false;
      _tracker?.setActive(false);
      await _engine.pause();
      await checkpoint();
    });
  }

  Future<void> toggle() => isPlaying || isWaitingForAudio ? pause() : play();

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
    if (_engineInitialized) await _engine.setVolume(value);
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
  Future<void> next() => _enqueuePlayback((attempt) async {
    if (currentTrack == null || !await _initialize(attempt)) return;
    await _advance(completed: false);
  });
  Future<void> _advance({required bool completed}) async {
    if (currentTrack == null) return;
    if (!await _haltForTransition(preserveFocus: completed)) return;
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

  Future<void> previous() => _enqueuePlayback((attempt) async {
    if (currentTrack == null || !await _initialize(attempt)) return;
    final restart = position > const Duration(seconds: 3);
    if (!await _haltForTransition()) return;
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
    _wantsPlayback = false;
    _generation++;
    _opening = true;
    _acceptSourceState = false;
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
      if (error == _playbackError) error = null;
      _playbackError = null;
      _audioFocusFailure = false;
      _sourceLocal = false;
      _needsReload = false;
      isPlaying = false;
      isBuffering = false;
      isWaitingForAudio = false;
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

  Future<void> stop() {
    _initializationCancellation++;
    _cancelPendingOpen();
    return _enqueue(_stop);
  }

  void _cancelPendingOpen() {
    if ((!_opening && !_completedSeen) || !_engineInitialized) return;
    _wantsPlayback = false;
    _acceptSourceState = false;
    _needsReload = true;
    isPlaying = isBuffering = isWaitingForAudio = false;
    _tracker?.setActive(false);
    // A source lookup/open can be waiting ahead of the queued user command.
    // Invalidate native playback now, so a late load cannot briefly play before
    // that command runs. The queued command repeats and reports any failed
    // cleanup; cancellation must not replace the original playback diagnosis.
    unawaited(_engine.stop().catchError((Object _) {}));
  }

  /// Await before closing the account cache/application to durably flush events.
  Future<void> shutdown() => _shutdownFuture ??= _shutdown();
  Future<void> _shutdown() async {
    if (_disposed) return;
    _closing = true;
    _initializationCancellation++;
    _cancelPendingOpen();
    try {
      await _enqueue(_stop, allowClosing: true);
    } finally {
      await _settingsWrites;
      _disposed = true;
      _timer?.cancel();
      await _subscription?.cancel();
      await _controlsStatusSubscription?.cancel();
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
