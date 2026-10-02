import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:smtc_windows/smtc_windows.dart' as win;
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/system_media_controls.dart';

class _Windows implements win.SMTCWindows {
  final calls = <String>[];
  final positions = <int>[];
  final titles = <String?>[];
  Future<void> Function()? onMetadata;

  @override
  Future<void> enableSmtc() async => calls.add('enable');
  @override
  Future<void> disableSmtc() async => calls.add('disable');
  @override
  Future<void> clearMetadata() async => calls.add('clear');
  @override
  Future<void> updateMetadata(win.MusicMetadata metadata) async {
    calls.add('metadata');
    titles.add(metadata.title);
    await onMetadata?.call();
  }

  @override
  Future<void> updateTimeline(win.PlaybackTimeline timeline) async {
    calls.add('timeline');
    positions.add(timeline.positionMs);
  }

  @override
  Future<void> setPlaybackStatus(win.PlaybackStatus status) async =>
      calls.add('status');
  @override
  Future<void> setShuffleEnabled(bool value) async => calls.add('shuffle');
  @override
  Future<void> setRepeatMode(win.RepeatMode value) async => calls.add('repeat');
  @override
  Future<void> dispose() async => calls.add('dispose');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _update(
  NativeSystemMediaControls controls,
  List<Track> queue,
  int position,
) => controls.update(
  track: queue.firstOrNull,
  queue: queue,
  index: queue.isEmpty ? -1 : 0,
  playing: queue.isNotEmpty,
  buffering: false,
  position: Duration(milliseconds: position),
  shuffle: false,
  repeat: 0,
);

void main() {
  test(
    'waiting publishes play-when-ready and buffering with frozen position',
    () async {
      final handler = BaseAudioHandler();
      final controls = NativeSystemMediaControls(handler: handler);
      const track = Track(id: 'a', title: 'A');
      Future<void> update(bool waiting, {bool playing = false}) =>
          controls.update(
            track: track,
            queue: const [track],
            index: 0,
            playing: playing,
            buffering: false,
            waitingForAudio: waiting,
            position: const Duration(seconds: 12),
            shuffle: false,
            repeat: 0,
          );
      await update(true);
      expect(handler.playbackState.value.playing, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.buffering,
      );
      expect(handler.playbackState.value.position, const Duration(seconds: 12));
      expect(
        handler.playbackState.value.controls,
        contains(MediaControl.pause),
      );
      expect(handler.playbackState.value.controls, contains(MediaControl.stop));
      expect(
        handler.playbackState.value.controls,
        isNot(contains(MediaControl.play)),
      );
      expect(
        handler.playbackState.value.updatePosition,
        const Duration(seconds: 12),
      );
      await update(false);
      expect(handler.playbackState.value.playing, isFalse);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.ready,
      );
      expect(handler.playbackState.value.controls, contains(MediaControl.play));
      expect(
        handler.playbackState.value.controls,
        isNot(contains(MediaControl.pause)),
      );
      await update(true);
      await update(false, playing: true);
      expect(handler.playbackState.value.playing, isTrue);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.ready,
      );
      expect(
        handler.playbackState.value.controls,
        contains(MediaControl.pause),
      );
      await controls.dispose();
    },
  );

  test('slow native updates retain only latest pending snapshot', () async {
    final windows = _Windows();
    final handler = BaseAudioHandler();
    final controls = NativeSystemMediaControls(
      handler: handler,
      windows: windows,
    );
    final started = Completer<void>();
    final gate = Completer<void>();
    windows.onMetadata = () {
      if (!started.isCompleted) started.complete();
      return gate.future;
    };
    const queue = [Track(id: 'a', title: 'A')];
    final first = _update(controls, queue, 0);
    await started.future;
    for (var i = 1; i <= 1000; i++) {
      expect(identical(_update(controls, queue, i), first), isTrue);
    }
    gate.complete();
    await first;
    expect(windows.positions, [0, 1000]);
    expect(windows.calls.where((c) => c == 'metadata').length, 1);
    expect(windows.calls.where((c) => c == 'enable').length, 1);
    expect(windows.calls.where((c) => c == 'status').length, 1);
    expect(windows.calls.where((c) => c == 'shuffle').length, 1);
    expect(windows.calls.where((c) => c == 'repeat').length, 1);
    expect(handler.playbackState.value.updatePosition.inMilliseconds, 1000);
    final queueSnapshot = handler.queue.value;
    await _update(controls, queue, 1001);
    expect(identical(handler.queue.value, queueSnapshot), isTrue);
    expect(windows.calls.last, 'timeline');
    final callCount = windows.calls.length;
    await _update(controls, queue, 1001);
    expect(windows.calls.length, callCount);
    await controls.dispose();
  });

  test(
    'latest stop survives bridge failure and disposal rejects new updates',
    () async {
      final windows = _Windows();
      final handler = BaseAudioHandler();
      final controls = NativeSystemMediaControls(
        handler: handler,
        windows: windows,
      );
      final started = Completer<void>();
      final gate = Completer<void>();
      windows.onMetadata = () async {
        started.complete();
        await gate.future;
        throw StateError('bridge failure');
      };
      final first = _update(controls, const [Track(id: 'a', title: 'A')], 0);
      final error = expectLater(first, throwsStateError);
      await started.future;
      expect(identical(_update(controls, const [], 0), first), isTrue);
      final disposing = controls.dispose();
      await _update(controls, const [
        Track(id: 'ignored', title: 'Ignored'),
      ], 1);
      gate.complete();
      await error;
      await disposing;
      expect(windows.calls, [
        'enable',
        'metadata',
        'clear',
        'disable',
        'dispose',
      ]);
      expect(handler.mediaItem.value, isNull);
      expect(handler.queue.value, isEmpty);
      expect(identical(controls.dispose(), disposing), isTrue);
    },
  );

  test(
    'coalescing preserves the newest replacement queue and metadata',
    () async {
      final windows = _Windows();
      final handler = BaseAudioHandler();
      final controls = NativeSystemMediaControls(
        handler: handler,
        windows: windows,
      );
      final started = Completer<void>();
      final gate = Completer<void>();
      windows.onMetadata = () {
        if (!started.isCompleted) started.complete();
        return gate.future;
      };
      final first = _update(controls, const [Track(id: 'a', title: 'A')], 0);
      await started.future;
      _update(controls, const [], 0);
      _update(controls, const [Track(id: 'b', title: 'B')], 7);
      gate.complete();
      await first;
      expect(windows.titles, ['A', 'B']);
      expect(windows.positions, [0, 7]);
      expect(handler.queue.value.single.id, 'b');
      expect(handler.mediaItem.value!.title, 'B');
      await controls.dispose();
    },
  );
  test('failed partial native updates are fully replayed on retry', () async {
    final windows = _Windows();
    final handler = BaseAudioHandler();
    final controls = NativeSystemMediaControls(
      handler: handler,
      windows: windows,
    );
    final statuses = <SystemMediaControlsStatus>[];
    final subscription = controls.statusChanges.listen(statuses.add);
    const a = [Track(id: 'a', title: 'A')];
    const b = [Track(id: 'b', title: 'B')];
    await _update(controls, a, 0);
    windows.onMetadata = () async => throw StateError('partial bridge write');
    await expectLater(_update(controls, b, 0), throwsStateError);
    expect(statuses.last.available, isFalse);
    expect(statuses.last.errorCode, 'native_state_failed');
    expect(statuses.last.error, isNot(contains('partial bridge write')));
    windows.onMetadata = null;
    await _update(controls, a, 0);
    expect(statuses.last.available, isTrue);
    expect(statuses.last.error, isNull);
    expect(windows.titles, ['A', 'B', 'A']);
    expect(handler.mediaItem.value!.title, 'A');
    expect(handler.queue.value.single.id, 'a');
    await subscription.cancel();
    await controls.dispose();
  });

  test('queue changes independently of current ID, supports duplicates and revisions', () async {
    final handler = BaseAudioHandler();
    final controls = NativeSystemMediaControls(handler: handler);
    const a = Track(id: 'a', title: 'A');
    const b = Track(id: 'b', title: 'B');
    const c = Track(id: 'c', title: 'C');
    Future<void> update(List<Track> queue, {int index = 0, int position = 0}) =>
        controls.update(
          track: queue.isEmpty ? null : queue[index],
          queue: queue,
          index: queue.isEmpty ? -1 : index,
          playing: queue.isNotEmpty,
          buffering: false,
          position: Duration(milliseconds: position),
          shuffle: false,
          repeat: 0,
        );
    await update([a, b]);
    await update([a, c]);
    expect(handler.queue.value.map((item) => item.id), ['a', 'c']);
    await update([a, a, c], index: 1);
    expect(handler.queue.value.map((item) => item.id), ['a', 'a', 'c']);
    expect(handler.playbackState.value.queueIndex, 1);
    const revised = Track(
      id: 'a',
      title: 'Corrected title',
      durationMs: 1234,
      revision: 2,
    );
    await update([revised, a, c]);
    expect(handler.mediaItem.value!.title, 'Corrected title');
    expect(handler.mediaItem.value!.duration!.inMilliseconds, 1234);
    expect(handler.queue.value.first.title, 'Corrected title');
    final queueSnapshot = handler.queue.value;
    final itemSnapshot = handler.mediaItem.value;
    for (var i = 0; i < 10; i++) {
      await update([revised, a, c], position: i * 100);
    }
    // Position updates publish playback state, not repeated metadata/queues.
    expect(identical(handler.queue.value, queueSnapshot), isTrue);
    expect(identical(handler.mediaItem.value, itemSnapshot), isTrue);
    await update([]);
    expect(handler.queue.value, isEmpty);
    expect(handler.mediaItem.value, isNull);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );
    await controls.dispose();
  });
}
