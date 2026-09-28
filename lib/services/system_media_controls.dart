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
    required Duration position,
    required bool shuffle,
    required int repeat,
  });
  Future<void> dispose();
}

class NativeSystemMediaControls implements SystemMediaControls {
  NativeSystemMediaControls({@visibleForTesting this._handler});

  BaseAudioHandler? _handler;
  win.SMTCWindows? _windows;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Track? _lastTrack;
  List<Track> _lastQueue = [];
  Future<void> _updates = Future.value();
  bool _disposed = false;
  @override
  Future<void> initialize(MediaCommands commands) async {
    if (Platform.isWindows) {
      await win.SMTCWindows.initialize();
      final windows = win.SMTCWindows();
      _windows = windows;
      _subscriptions.add(
        windows.buttonPressStream.listen((button) {
          switch (button) {
            case win.PressedButton.play:
              unawaited(commands.play());
            case win.PressedButton.pause:
              unawaited(commands.pause());
            case win.PressedButton.next:
              unawaited(commands.next());
            case win.PressedButton.previous:
              unawaited(commands.previous());
            case win.PressedButton.stop:
              unawaited(commands.stop());
            default:
              break;
          }
        }),
      );
      _subscriptions.add(windows.shuffleChangeStream.listen(commands.shuffle));
      _subscriptions.add(
        windows.repeatModeChangeStream.listen(
          (mode) => commands.repeat(
            mode == win.RepeatMode.none
                ? 0
                : mode == win.RepeatMode.list
                ? 1
                : 2,
          ),
        ),
      );
    } else {
      if (Platform.isLinux) AudioServiceMpris.registerWith();
      _handler = await AudioService.init<_YunAudioHandler>(
        builder: () => _YunAudioHandler(commands),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'org.yun.audio',
          androidNotificationChannelName: '韵 playback',
          androidNotificationOngoing: false,
          // Keep the service foreground while paused so headset/lock-screen
          // resume does not illegally restart a background FGS on Android 12+.
          // Explicit Stop releases the service/notification.
          androidStopForegroundOnPause: false,
        ),
      );
    }
  }

  @override
  Future<void> update({
    required Track? track,
    required List<Track> queue,
    required int index,
    required bool playing,
    required bool buffering,
    required Duration position,
    required bool shuffle,
    required int repeat,
  }) {
    // Windows calls cross an asynchronous native bridge. Serialize snapshots so
    // a slow metadata update cannot overwrite a subsequent stop/new track.
    final next = _updates.then((_) async {
      if (_disposed) return;
      await _update(
        track: track,
        queue: queue,
        index: index,
        playing: playing,
        buffering: buffering,
        position: position,
        shuffle: shuffle,
        repeat: repeat,
      );
    });
    _updates = next.catchError((Object _) {});
    return next;
  }

  Future<void> _update({
    required Track? track,
    required List<Track> queue,
    required int index,
    required bool playing,
    required bool buffering,
    required Duration position,
    required bool shuffle,
    required int repeat,
  }) async {
    final handler = _handler;
    final metadataChanged = !mapEquals(_lastTrack?.toJson(), track?.toJson());
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
      if (!listEquals(_lastQueue, queue)) {
        handler.queue.add(queue.map(item).toList());
      }
      handler.playbackState.add(
        PlaybackState(
          controls: [
            MediaControl.skipToPrevious,
            playing ? MediaControl.pause : MediaControl.play,
            MediaControl.skipToNext,
            MediaControl.stop,
          ],
          systemActions: const {MediaAction.seek},
          androidCompactActionIndices: const [0, 1, 2],
          processingState: track == null
              ? AudioProcessingState.idle
              : buffering
              ? AudioProcessingState.buffering
              : AudioProcessingState.ready,
          playing: playing,
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
        await windows.clearMetadata();
        await windows.disableSmtc();
      } else {
        await windows.enableSmtc();
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
        await windows.setPlaybackStatus(
          playing ? win.PlaybackStatus.playing : win.PlaybackStatus.paused,
        );
        await windows.updateTimeline(
          win.PlaybackTimeline(
            startTimeMs: 0,
            endTimeMs: track.durationMs,
            positionMs: position.inMilliseconds,
            minSeekTimeMs: 0,
            maxSeekTimeMs: track.durationMs,
          ),
        );
        await windows.setShuffleEnabled(shuffle);
        await windows.setRepeatMode(
          repeat == 0
              ? win.RepeatMode.none
              : repeat == 1
              ? win.RepeatMode.list
              : win.RepeatMode.track,
        );
      }
    }
    _lastTrack = track;
    _lastQueue = List.of(queue);
  }

  @override
  Future<void> dispose() async {
    await _updates;
    _disposed = true;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _handler?.playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
    _handler?.mediaItem.add(null);
    _handler?.queue.add([]);
    await _windows?.dispose();
  }
}

class _YunAudioHandler extends BaseAudioHandler {
  _YunAudioHandler(this.commands);
  final MediaCommands commands;
  @override
  Future<void> play() => commands.play();
  @override
  Future<void> pause() => commands.pause();
  @override
  Future<void> stop() => commands.stop();
  @override
  Future<void> skipToNext() => commands.next();
  @override
  Future<void> skipToPrevious() => commands.previous();
  @override
  Future<void> seek(Duration position) => commands.seek(position);
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode mode) async =>
      commands.shuffle(mode != AudioServiceShuffleMode.none);
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode mode) async =>
      commands.repeat(
        mode == AudioServiceRepeatMode.none
            ? 0
            : mode == AudioServiceRepeatMode.one
            ? 2
            : 1,
      );
}
