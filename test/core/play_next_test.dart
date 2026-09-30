import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/playback_controller.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/playback_engine.dart';

import 'fakes.dart';

const _tracks = [
  Track(id: 'a', title: 'A'),
  Track(id: 'b', title: 'B'),
  Track(id: 'c', title: 'C'),
  Track(id: 'd', title: 'D'),
];
const _extra = Track(id: 'extra', title: 'Outside the collection');

void main() {
  late FakeEngine engine;
  late PlaybackController player;

  setUp(() {
    engine = FakeEngine();
    player = PlaybackController(
      engine: engine,
      random: Random(42),
      enableSystemControls: false,
      resolveSource: (track, _) async => AudioSource('/cache/${track.id}'),
    );
  });
  tearDown(() async {
    await player.shutdown();
    player.dispose();
  });

  Future<void> completeTrack() async {
    engine.emit(const EngineState(completed: true));
    await player.flushSettings();
  }

  test(
    'manual occurrences are FIFO, including duplicates and external tracks',
    () async {
      await player.playQueue(_tracks);
      final original = player.queue;
      await player.queueNext(_extra);
      await player.queueNext(_tracks[1]);
      await player.queueNext(_extra);
      expect(player.currentTrack, _tracks.first);
      expect(player.effectiveQueue.map((e) => e.track), [
        _tracks.first,
        _extra,
        _tracks[1],
        _extra,
        ..._tracks.skip(1),
      ]);
      expect(player.effectiveQueue[1], isNot(same(player.effectiveQueue[3])));
      expect(player.effectiveQueue[2], isNot(same(player.effectiveQueue[4])));
      for (final track in [_extra, _tracks[1], _extra]) {
        await completeTrack();
        expect(player.currentTrack, track);
        expect(player.index, 0);
        expect(identical(player.queue, original), isTrue);
        expect(
          player.effectiveQueue[player.effectiveIndex].isManuallyQueued,
          isTrue,
        );
      }
      await completeTrack();
      expect(player.currentTrack, _tracks[1]);
      expect(player.effectiveQueue.every((e) => !e.isManuallyQueued), isTrue);
    },
  );

  test('shuffle resumes exactly the original remaining order', () async {
    player.setShuffle(true);
    await player.playQueue(_tracks, index: 0);
    final continuation = player.effectiveQueue
        .skip(1)
        .map((e) => e.track)
        .toList();
    await player.queueNextTracks([_extra, _tracks[2], _extra]);
    for (final track in [_extra, _tracks[2], _extra, ...continuation]) {
      await player.next();
      expect(player.currentTrack, track);
    }
    await player.next();
    expect(player.currentTrack, isNull);
  });

  for (final repeat in RepeatMode.values) {
    test(
      'queued tracks override $repeat and finish before original continuation',
      () async {
        await player.playQueue(_tracks);
        player.setRepeat(repeat);
        await player.queueNextTracks([_extra, _extra]);
        await completeTrack();
        expect(player.currentTrack, _extra);
        await completeTrack();
        expect(player.currentTrack, _extra);
        await completeTrack();
        expect(player.currentTrack, _tracks[1]);
        expect(player.repeatMode, repeat);
        if (repeat == RepeatMode.one) {
          await completeTrack();
          expect(player.currentTrack, _tracks[1]);
        }
      },
    );
  }

  for (final shuffle in [false, true]) {
    test(
      'previous retraces manual history and preserves continuation (shuffle=$shuffle)',
      () async {
        player.setShuffle(shuffle);
        await player.playQueue(_tracks, index: 0);
        final next = player.effectiveQueue[1].track;
        await player.queueNextTracks([_extra, _tracks[2]]);
        await player.next();
        await player.next();
        expect(player.currentTrack, _tracks[2]);
        await player.previous();
        expect(player.currentTrack, _extra);
        await player.previous();
        expect(player.currentTrack, _tracks.first);
        for (final track in [_extra, _tracks[2], next]) {
          await player.next();
          expect(player.currentTrack, track);
        }
      },
    );
  }

  test('previous after three seconds restarts a manual track', () async {
    await player.playQueue(_tracks);
    await player.queueNextTracks([_extra, _tracks[2]]);
    await player.next();
    await player.seek(const Duration(seconds: 12));
    await player.previous();
    expect(player.currentTrack, _extra);
    expect(player.position, Duration.zero);
    await player.next();
    expect(player.currentTrack, _tracks[2]);
  });

  test(
    'queue at collection end plays before stopping or repeat-all wrap',
    () async {
      for (final repeat in [RepeatMode.off, RepeatMode.one, RepeatMode.all]) {
        player.setRepeat(repeat);
        await player.playQueue(_tracks, index: _tracks.length - 1);
        await player.queueNext(_extra);
        await completeTrack();
        expect(player.currentTrack, _extra);
        await completeTrack();
        expect(
          player.currentTrack,
          repeat == RepeatMode.all ? _tracks.first : null,
        );
      }
    },
  );

  test(
    'idle queues start playback, keep duplicates, and finish even on repeat',
    () async {
      player.setRepeat(RepeatMode.all);
      player.setShuffle(true);
      await player.queueNextTracks([_extra, _extra]);
      expect(player.currentTrack, _extra);
      expect(player.queue, isEmpty);
      expect(player.effectiveIndex, 0);
      await player.previous();
      expect(player.effectiveIndex, 0);
      await completeTrack();
      expect(player.effectiveIndex, 1);
      await completeTrack();
      expect(player.currentTrack, isNull);
      expect(player.effectiveQueue, isEmpty);
    },
  );

  test(
    'singleton shuffle repeat does not duplicate the current occurrence',
    () async {
      player.setShuffle(true);
      player.setRepeat(RepeatMode.all);
      await player.playQueue([_tracks.first]);
      for (var i = 0; i < 3; i++) {
        await completeTrack();
        expect(player.effectiveQueue, hasLength(1));
        expect(player.effectiveIndex, 0);
      }
    },
  );

  test('shuffle previous crosses repeat-all boundaries without duplicate queue entries', () async {
    player.setShuffle(true);
    player.setRepeat(RepeatMode.all);
    await player.playQueue(_tracks.take(3).toList(), index: 0);
    final firstCycle = player.effectiveQueue.toList();
    await player.next();
    await player.next();
    await player.next();
    final nextCycleStart = player.currentTrack;

    void expectUniqueQueue() {
      expect(player.effectiveQueue, hasLength(3));
      expect(player.effectiveQueue.toSet(), hasLength(3));
      expect(
        player.effectiveQueue[player.effectiveIndex].track,
        player.currentTrack,
      );
    }

    expectUniqueQueue();
    expect(player.effectiveQueue.first, same(firstCycle.last));
    await player.previous();
    expect(player.currentTrack, firstCycle.last.track);
    expectUniqueQueue();
    await player.previous();
    expect(player.currentTrack, firstCycle[1].track);
    expectUniqueQueue();
    await player.next();
    expect(player.currentTrack, firstCycle.last.track);
    await player.next();
    expect(player.currentTrack, nextCycleStart);
    expectUniqueQueue();
  });

  test(
    'shuffle selection after repeat-all uses the displayed occurrence',
    () async {
      player.setShuffle(true);
      player.setRepeat(RepeatMode.all);
      await player.playQueue(_tracks.take(3).toList(), index: 0);
      final firstCycle = player.effectiveQueue.toList();
      await player.next();
      await player.next();
      await player.next();
      final current = player.effectiveQueue[player.effectiveIndex];
      final upcoming = player.effectiveQueue.last;
      final displayed = player.effectiveQueue.toList();

      // The current source index also occurs in the previous cycle's history.
      await player.selectQueueEntry(current);
      expect(player.effectiveQueue, orderedEquals(displayed));
      expect(player.effectiveQueue[player.effectiveIndex], same(current));
      await player.previous();
      expect(player.currentTrack, firstCycle.last.track);
      await player.previous();
      expect(player.currentTrack, firstCycle[1].track);
      await player.next();
      await player.next();

      // Select the upcoming copy, not its older appearance in history.
      await player.selectQueueEntry(upcoming);
      expect(player.effectiveQueue, orderedEquals(displayed));
      expect(player.effectiveQueue[player.effectiveIndex], same(upcoming));
      await player.previous();
      expect(player.effectiveQueue[player.effectiveIndex], same(current));
      await player.previous();
      expect(player.currentTrack, firstCycle.last.track);
      await player.previous();
      expect(player.currentTrack, firstCycle[1].track);
    },
  );

  test(
    'effective snapshots stay immutable and stable across playback ticks',
    () async {
      await player.playQueue(_tracks);
      await player.queueNext(_extra);
      final snapshot = player.effectiveQueue;
      expect(() => snapshot.clear(), throwsUnsupportedError);
      for (var i = 0; i < 100; i++) {
        engine.emit(
          EngineState(playing: true, position: Duration(milliseconds: i)),
        );
        expect(identical(player.effectiveQueue, snapshot), isTrue);
      }
      await player.next();
      expect(player.effectiveQueue, orderedEquals(snapshot));
      expect(player.effectiveIndex, 1);
      expect(snapshot[0].track, _tracks.first);
    },
  );

  test('selecting a manual duplicate selects its exact occurrence', () async {
    player.setShuffle(true);
    await player.playQueue(_tracks, index: 0);
    final continuation = player.effectiveQueue[1].track;
    await player.queueNextTracks([_extra, _tracks[1], _extra]);
    final lastCopy = player.effectiveQueue[3];
    await player.selectQueueEntry(lastCopy);
    expect(player.currentTrack, _extra);
    expect(player.effectiveQueue[player.effectiveIndex], same(lastCopy));
    await player.previous();
    expect(player.currentTrack, _tracks[1]);
    await player.next();
    expect(player.effectiveQueue[player.effectiveIndex], same(lastCopy));
    await player.next();
    expect(player.currentTrack, continuation);
  });

  test('selecting an original occurrence preserves shuffled order and pending tracks', () async {
    player.setShuffle(true);
    await player.playQueue([
      _tracks.first,
      _tracks.first,
      ..._tracks.skip(1),
    ], index: 0);
    final originalOrder = player.effectiveQueue.toList();
    final duplicate = originalOrder.singleWhere((e) => e.sourceIndex == 1);
    await player.queueNext(_extra);
    await player.selectQueueEntry(duplicate);
    expect(player.index, 1);
    expect(player.effectiveQueue[player.effectiveIndex], same(duplicate));
    expect(
      player.effectiveQueue.where((e) => !e.isManuallyQueued),
      originalOrder,
    );
    await player.next();
    expect(player.currentTrack, _extra);
    await player.next();
    final targetPosition = originalOrder.indexOf(duplicate);
    expect(
      player.currentTrack,
      targetPosition == originalOrder.length - 1
          ? null
          : originalOrder[targetPosition + 1].track,
    );
  });

  test(
    'failed manual source can be skipped without losing following tracks',
    () async {
      await player.shutdown();
      player.dispose();
      engine = FakeEngine();
      player = PlaybackController(
        engine: engine,
        enableSystemControls: false,
        resolveSource: (track, _) async {
          if (track.id == _extra.id) throw StateError('Missing queued track');
          return AudioSource('/cache/${track.id}');
        },
      );
      await player.playQueue(_tracks);
      await player.queueNextTracks([_extra, _tracks[2]]);
      await expectLater(player.next(), throwsStateError);
      expect(player.currentTrack, _extra);
      await player.next();
      expect(player.currentTrack, _tracks[2]);
      expect(player.error, isNull);
      await player.next();
      expect(player.currentTrack, _tracks[1]);
    },
  );

  test(
    'stop or a new collection clears manual entries and stale selections',
    () async {
      await player.playQueue(_tracks);
      await player.queueNext(_extra);
      final stale = player.effectiveQueue[1];
      await player.playQueue(_tracks, index: 2);
      expect(player.effectiveQueue.every((e) => !e.isManuallyQueued), isTrue);
      await player.selectQueueEntry(stale);
      expect(player.currentTrack, _tracks[2]);
      await player.queueNext(_extra);
      await player.next();
      await player.stop();
      expect(player.effectiveQueue, isEmpty);
      expect(player.effectiveIndex, -1);
      await player.playQueue(_tracks);
      await player.next();
      expect(player.currentTrack, _tracks[1]);
    },
  );
}
