import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_mpris/audio_service_mpris.dart';
import 'package:flutter/foundation.dart';
import 'package:smtc_windows/smtc_windows.dart' as win;

import '../models/models.dart';

class MediaCommands {
  const MediaCommands({
    required this.play,
    required this.pause,
    required this.stop,
    required this.next,
    required this.previous,
    required this.seek,
    required this.shuffle,
    required this.repeat,
  });
  final Future<void> Function() play, pause, stop, next, previous;
  final Future<void> Function(Duration) seek;
  final void Function(bool) shuffle;
  final void Function(int) repeat;
}

abstract interface class SystemMediaControls {
  Future<void> initialize(MediaCommands commands);
  Future<void> update({
    required Track? track,
    required List<Track> queue,
    required int index,
    required bool playing,
    required bool buffering,
    bool waitingForAudio = false,
    required Duration position,
    required bool shuffle,
    required int repeat,
  });
  Future<void> dispose();
}

class NativeSystemMediaControls implements SystemMediaControls {
  NativeSystemMediaControls({
    @visibleForTesting this._handler,
    @visibleForTesting this._windows,
    @visibleForTesting this._initializeHandler,
    @visibleForTesting this._initializeWindows,
  }) : _initialized = _handler != null || _windows != null {
    final handler = _handler;
    if (handler != null) _handlerOwners[handler] = this;
  }

  static final _handlerOwners = Expando<NativeSystemMediaControls>();

  final Future<BaseAudioHandler> Function()? _initializeHandler;
  final Future<win.SMTCWindows> Function()? _initializeWindows;
  static Future<_YunAudioHandler>? _sharedHandler;
  static bool _mprisRegistered = false;
  Future<void>? _initialization;
  bool _initialized;

  static Future<_YunAudioHandler> _audioHandler() => _sharedHandler ??=
      _createAudioHandler().onError((Object error, StackTrace stack) {
        _sharedHandler = null;
        Error.throwWithStackTrace(error, stack);
      });

  static Future<_YunAudioHandler> _createAudioHandler() {
    if (Platform.isLinux && !_mprisRegistered) {
      AudioServiceMpris.registerWith();
      _mprisRegistered = true;
    }
    return AudioService.init<_YunAudioHandler>(
      builder: () => _YunAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'org.yun.audio',
        androidNotificationChannelName: '韵 playback',
        androidNotificationOngoing: false,
        // Keep paused sessions eligible for headset/lock-screen resume on
        // Android 12+. Stop still releases foreground service/notification.
        androidStopForegroundOnPause: false,
      ),
    );
  }

  BaseAudioHandler? _handler;
  win.SMTCWindows? _windows;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Track? _lastTrack;
  List<Track> _lastQueue = [];
  Future<void> _updates = Future.value();
  Future<void> Function()? _pendingUpdate;
  Completer<void>? _drain;
  Future<void>? _disposal;
  bool _disposed = false, _forceUpdate = false;
  bool? _lastEnabled, _lastPlaying, _lastShuffle;
  int? _lastRepeat;
  Duration? _lastPosition;
  @override
  Future<void> initialize(MediaCommands commands) {
    if (_disposed) return Future.value();
    if (_initialized) return Future.value();
    return _initialization ??= _initialize(commands).whenComplete(() {
      _initialization = null;
    });
  }

  Future<void> _initialize(MediaCommands commands) async {
    // Native callbacks may arrive while disposing. Never retain authority to
    // call a retired controller, even if native initialization completes late.
    final guarded = MediaCommands(
      play: () async {
        if (!_disposed) await commands.play();
      },
      pause: () async {
        if (!_disposed) await commands.pause();
      },
      stop: () async {
        if (!_disposed) await commands.stop();
      },
      next: () async {
        if (!_disposed) await commands.next();
      },
      previous: () async {
        if (!_disposed) await commands.previous();
      },
      seek: (position) async {
        if (!_disposed) await commands.seek(position);
      },
      shuffle: (value) {
        if (!_disposed) commands.shuffle(value);
      },
      repeat: (value) {
        if (!_disposed) commands.repeat(value);
      },
    );
    if (_initializeWindows != null ||
        (Platform.isWindows && _initializeHandler == null)) {
      win.SMTCWindows? windows;
      final subscriptions = <StreamSubscription<dynamic>>[];
      try {
        if (_initializeWindows != null) {
          windows = await _initializeWindows();
        } else {
          await win.SMTCWindows.initialize();
          windows = win.SMTCWindows();
        }
        if (_disposed) {
          final retired = windows;
          windows = null;
          await retired.dispose();
          return;
        }
        subscriptions.add(
          windows.buttonPressStream.listen((button) {
            switch (button) {
              case win.PressedButton.play:
                unawaited(guarded.play());
              case win.PressedButton.pause:
                unawaited(guarded.pause());
              case win.PressedButton.next:
                unawaited(guarded.next());
              case win.PressedButton.previous:
                unawaited(guarded.previous());
              case win.PressedButton.stop:
                unawaited(guarded.stop());
              default:
                break;
            }
          }),
        );
        subscriptions.add(windows.shuffleChangeStream.listen(guarded.shuffle));
        subscriptions.add(
          windows.repeatModeChangeStream.listen(
            (mode) => guarded.repeat(
              mode == win.RepeatMode.none
                  ? 0
                  : mode == win.RepeatMode.list
                  ? 1
                  : 2,
            ),
          ),
        );
        _windows = windows;
        _subscriptions.addAll(subscriptions);
      } catch (_) {
        // A subscription getter/listen can fail after native allocation.
        // Preserve the original failure while releasing every partial owner.
        for (final subscription in subscriptions) {
          try {
            await subscription.cancel();
          } catch (_) {}
        }
        try {
          await windows?.dispose();
        } catch (_) {}
        rethrow;
      }
    } else {
      final handler = await (_initializeHandler?.call() ?? _audioHandler());
      _handler = handler;
      if (!_disposed) {
        _handlerOwners[handler] = this;
        if (handler is _YunAudioHandler) handler.commands = guarded;
      }
    }
    if (_disposed) return;
    _forceUpdate = true;
    _initialized = true;
  }

  @override
  Future<void> update({
    required Track? track,
    required List<Track> queue,
    required int index,
    required bool playing,
    required bool buffering,
    bool waitingForAudio = false,
    required Duration position,
    required bool shuffle,
    required int repeat,
  }) {
    if (_disposed || !_initialized) return Future.value();
    // At most one bridge call and one latest snapshot are retained. All callers
    // in a burst wait for the same drain, including its final/latest state.
    // PlaybackController supplies an immutable, stable queue snapshot.
    _pendingUpdate = () => _update(
      track: track,
      queue: queue,
      index: index,
      playing: playing,
      buffering: buffering,
      waitingForAudio: waitingForAudio,
      position: position,
      shuffle: shuffle,
      repeat: repeat,
    );
    if (_drain == null) {
      final drain = _drain = Completer<void>();
      _updates = drain.future.catchError((Object _) {});
      scheduleMicrotask(() => _drainUpdates(drain));
    }
    return _drain!.future;
  }

  Future<void> _drainUpdates(Completer<void> drain) async {
    Object? failure;
    StackTrace? failureStack;
    while (_pendingUpdate != null) {
      final update = _pendingUpdate!;
      _pendingUpdate = null;
      try {
        await update();
      } catch (error, stack) {
        failure ??= error;
        failureStack ??= stack;
        // A failed call may already have changed some native properties.
        // Replay all fields of the next snapshot instead of trusting old diffs.
        _forceUpdate = true;
        _lastEnabled = null;
      }
    }
    _drain = null;
    if (failure == null) {
      drain.complete();
    } else {
      drain.completeError(failure, failureStack);
    }
  }

  Future<void> _update({
    required Track? track,
    required List<Track> queue,
    required int index,
    required bool playing,
    required bool buffering,
    bool waitingForAudio = false,
    required Duration position,
    required bool shuffle,
    required int repeat,
  }) async {
    final handler = _handler;
    if (handler != null && !identical(_handlerOwners[handler], this)) return;
    final metadataChanged =
        _forceUpdate ||
        (!identical(_lastTrack, track) &&
            !mapEquals(_lastTrack?.toJson(), track?.toJson()));
    MediaItem item(Track t) => MediaItem(
      id: t.id,
      title: t.title,
      artist: t.artist,
      album: t.album,
      duration: t.duration,
    );
    if (handler != null) {
      if (metadataChanged) {
        handler.mediaItem.add(track == null ? null : item(track));
      }
      // Queue identity is independent of the current song: replacing [A, B]
      // with [A, C], or visiting duplicate A entries, must not leave stale data.
      // Tracks are immutable; position-only updates reuse these same objects.
      if (_forceUpdate || !listEquals(_lastQueue, queue)) {
        handler.queue.add(queue.map(item).toList());
      }
      handler.playbackState.add(
        PlaybackState(
          controls: [
            MediaControl.skipToPrevious,
            playing || waitingForAudio ? MediaControl.pause : MediaControl.play,
            MediaControl.skipToNext,
            MediaControl.stop,
          ],
          systemActions: const {MediaAction.seek},
          androidCompactActionIndices: const [0, 1, 2],
          processingState: track == null
              ? AudioProcessingState.idle
              : buffering || waitingForAudio
              ? AudioProcessingState.buffering
              : AudioProcessingState.ready,
          // audio_service defines this as play-when-ready, not audible output.
          // An eligible user-started wait must enter foreground before screen
          // lock; promoting only on a later GAIN may be disallowed in background.
          // Buffering keeps the system position frozen while waiting.
          playing: playing || waitingForAudio,
          updatePosition: position,
          queueIndex: index < 0 ? null : index,
          shuffleMode: shuffle
              ? AudioServiceShuffleMode.all
              : AudioServiceShuffleMode.none,
          repeatMode: repeat == 0
              ? AudioServiceRepeatMode.none
              : repeat == 1
              ? AudioServiceRepeatMode.all
              : AudioServiceRepeatMode.one,
        ),
      );
    }
    final windows = _windows;
    if (windows != null) {
      if (track == null) {
        if (_lastEnabled != false) {
          await windows.clearMetadata();
          await windows.disableSmtc();
        }
      } else {
        if (_lastEnabled != true) await windows.enableSmtc();
        if (metadataChanged) {
          await windows.updateMetadata(
            win.MusicMetadata(
              title: track.title,
              artist: track.artist,
              album: track.album,
              albumArtist: track.albumArtist,
            ),
          );
        }
        if (_lastEnabled != true || _lastPlaying != playing) {
          await windows.setPlaybackStatus(
            playing ? win.PlaybackStatus.playing : win.PlaybackStatus.paused,
          );
        }
        if (metadataChanged || _lastPosition != position) {
          await windows.updateTimeline(
            win.PlaybackTimeline(
              startTimeMs: 0,
              endTimeMs: track.durationMs,
              positionMs: position.inMilliseconds,
              minSeekTimeMs: 0,
              maxSeekTimeMs: track.durationMs,
            ),
          );
        }
        if (_lastEnabled != true || _lastShuffle != shuffle) {
          await windows.setShuffleEnabled(shuffle);
        }
        if (_lastEnabled != true || _lastRepeat != repeat) {
          await windows.setRepeatMode(
            repeat == 0
                ? win.RepeatMode.none
                : repeat == 1
                ? win.RepeatMode.list
                : win.RepeatMode.track,
          );
        }
      }
    }
    _forceUpdate = false;
    _lastTrack = track;
    _lastQueue = queue;
    _lastEnabled = track != null;
    _lastPlaying = playing;
    _lastPosition = position;
    _lastShuffle = shuffle;
    _lastRepeat = repeat;
  }

  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    // Refuse new snapshots immediately, but drain the accepted latest state.
    _disposed = true;
    try {
      await _initialization;
    } catch (_) {}
    await _updates;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    final handler = _handler;
    // A process-wide audio_service handler can be reused by a later app
    // controller. An older disposer must not detach or clear its new owner.
    if (handler != null &&
        (_handlerOwners[handler] == null ||
            identical(_handlerOwners[handler], this))) {
      _handlerOwners[handler] = null;
      if (handler is _YunAudioHandler) handler.commands = null;
      handler.playbackState.add(
        PlaybackState(processingState: AudioProcessingState.idle),
      );
      handler.mediaItem.add(null);
      handler.queue.add([]);
    }
    await _windows?.dispose();
  }
}

class _YunAudioHandler extends BaseAudioHandler {
  MediaCommands? commands;
  @override
  Future<void> play() => commands?.play() ?? Future.value();
  @override
  Future<void> pause() => commands?.pause() ?? Future.value();
  @override
  Future<void> stop() => commands?.stop() ?? Future.value();
  @override
  Future<void> skipToNext() => commands?.next() ?? Future.value();
  @override
  Future<void> skipToPrevious() => commands?.previous() ?? Future.value();
  @override
  Future<void> seek(Duration position) =>
      commands?.seek(position) ?? Future.value();
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode mode) async =>
      commands?.shuffle(mode != AudioServiceShuffleMode.none);
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode mode) async =>
      commands?.repeat(
        mode == AudioServiceRepeatMode.none
            ? 0
            : mode == AudioServiceRepeatMode.one
            ? 2
            : 1,
      );
}
