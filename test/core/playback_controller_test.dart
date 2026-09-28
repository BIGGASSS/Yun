import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/playback_controller.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/playback_engine.dart';

import 'fakes.dart';

void main() {
  late FakeEngine engine;
  late PlaybackController player;
  const tracks = [
    Track(id: 'a', title: 'A'),
    Track(id: 'b', title: 'B'),
    Track(id: 'c', title: 'C'),
  ];
  setUp(() {
    engine = FakeEngine();
    player = PlaybackController(
      engine: engine,
      enableSystemControls: false,
      resolveSource: (track, local) async =>
          AudioSource('/cache/${track.id}', local: true),
    );
    player.configureRecording('device', (_) async {});
  });
  tearDown(() async {
    await player.shutdown();
    player.dispose();
  });
  test(
    'local sources and transport controls do not require native plugins',
    () async {
      await player.playQueue(tracks, index: 1);
      expect(player.currentTrack!.id, 'b');
      expect(engine.opened, '/cache/b');
      expect(player.isPlaying, isTrue);
      await player.seek(const Duration(seconds: 42));
      expect(player.position.inSeconds, 42);
      await player.pause();
      expect(player.isPlaying, isFalse);
      await player.play();
      expect(player.isPlaying, isTrue);
      await player.next();
      expect(player.currentTrack!.id, 'c');
      await player.next();
      expect(player.currentTrack, isNull);
    },
  );
  test(
    'repeated system shuffle command does not reset the remaining bag',
    () async {
      await player.playQueue(tracks.take(2).toList());
      player.setShuffle(true);
      await player.next();
      player.setShuffle(true);
      await player.next();
      expect(player.currentTrack, isNull);
    },
  );

  test('shuffle visits every index exactly once before stopping', () async {
    await player.playQueue(tracks);
    player.setShuffle(true);
    final visited = {player.currentTrack!.id};
    await player.next();
    visited.add(player.currentTrack!.id);
    await player.next();
    visited.add(player.currentTrack!.id);
    expect(visited, {'a', 'b', 'c'});
    await player.next();
    expect(player.currentTrack, isNull);
  });
  test('repeat-one applies to completion, not explicit next', () async {
    await player.playQueue(tracks);
    player.setRepeat(RepeatMode.one);
    engine.emit(const EngineState(completed: true));
    await Future<void>.delayed(Duration.zero);
    expect(player.currentTrack!.id, 'a');
    expect(engine.opens, 2);
    await player.next();
    expect(player.currentTrack!.id, 'b');
  });
  test(
    'repeat-all wraps, previous restarts a track after three seconds',
    () async {
      await player.playQueue(tracks, index: 2);
      player.setRepeat(RepeatMode.all);
      await player.next();
      expect(player.currentTrack!.id, 'a');
      await player.previous();
      expect(player.currentTrack!.id, 'c');
      await player.seek(const Duration(seconds: 20));
      await player.previous();
      expect(player.currentTrack!.id, 'c');
      expect(player.position, Duration.zero);
    },
  );
  test(
    'invalid queue index is rejected without corrupting current queue',
    () async {
      await player.playQueue(tracks);
      await expectLater(player.playQueue(tracks, index: 10), throwsRangeError);
      expect(player.currentTrack!.id, 'a');
      await player.pause(); // Failed commands do not poison the serial queue.
      expect(player.isPlaying, isFalse);
    },
  );
  test('stale completion cannot skip a newly selected queue', () async {
    await player.playQueue(tracks);
    final replacement = player.playQueue(tracks, index: 1);
    engine.emit(const EngineState(completed: true));
    await replacement;
    await player.pause(); // Drain the operation queue after completion.
    expect(player.currentTrack!.id, 'b');
    expect(engine.opens, 2);
  });

  test(
    'decoder error plus completion recovers without advancing queue',
    () async {
      await player.playQueue(tracks);
      engine.emit(const EngineState(error: 'bad decoder', completed: true));
      await Future<void>.delayed(Duration.zero);
      await player.pause();
      expect(player.currentTrack!.id, 'a');
      expect(engine.opens, 2);
    },
  );

  test(
    'shutdown still disposes native resources when event persistence fails',
    () async {
      final localEngine = FakeEngine();
      final local =
          PlaybackController(
            engine: localEngine,
            enableSystemControls: false,
            resolveSource: (_, _) async => const AudioSource('/test'),
          )..configureRecording('device', (_) async {
            throw StateError('Disk full');
          });
      await local.playQueue(tracks);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await expectLater(local.shutdown(), throwsStateError);
      expect(localEngine.controller.isClosed, isTrue);
      expect(local.currentTrack, isNull);
      local.dispose();
    },
  );

  test('stale recovery cannot reopen a newly selected queue', () async {
    await player.playQueue(tracks);
    final replacement = player.playQueue(tracks, index: 1);
    engine.emit(const EngineState(error: 'old decoder failed'));
    await replacement;
    await player.pause();
    expect(player.currentTrack!.id, 'b');
    expect(engine.opens, 2);
  });

  test('shutdown rejects commands queued after closing begins', () async {
    await player.playQueue(tracks);
    final closing = player.shutdown();
    final reopening = player.playQueue(tracks);
    await closing;
    await reopening;
    expect(engine.opens, 1);
    expect(player.currentTrack, isNull);
    expect(player.isPlaying, isFalse);
  });

  test(
    'failed event persistence cannot prevent stop and pending events retry',
    () async {
      var fail = true;
      final saved = <ListeningEvent>[];
      player.configureRecording('device', (event) async {
        if (fail) throw StateError('Disk full');
        saved.add(event);
      });
      await player.playQueue(tracks);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await expectLater(player.stop(), throwsStateError);
      expect(engine.state.playing, isFalse);
      expect(player.currentTrack, isNull);
      expect(player.duration, Duration.zero);
      fail = false;
      await player.checkpoint();
      expect(saved, isNotEmpty);
      await player.checkpoint();
      expect(saved.map((e) => e.id).toSet().length, saved.length);
    },
  );

  test(
    'shuffle previous retraces history and next returns to same entry',
    () async {
      await player.playQueue(tracks);
      player.setShuffle(true);
      await player.next();
      final second = player.index;
      await player.previous();
      expect(player.index, 0);
      await player.next();
      expect(player.index, second);
    },
  );

  test('controller can retry a failed engine initialization', () async {
    await player.shutdown();
    player.dispose();
    final flaky = FlakyEngine();
    engine = flaky;
    player = PlaybackController(
      engine: engine,
      enableSystemControls: false,
      resolveSource: (_, _) async => const AudioSource('/test'),
    );
    await expectLater(player.playQueue(tracks), throwsStateError);
    await player.playQueue(tracks);
    expect(flaky.initializations, 2);
    expect(player.isPlaying, isTrue);
  });

  test(
    'asynchronous local decoder failures fall back to authenticated streaming',
    () async {
      await player.shutdown();
      player.dispose();
      engine = FakeEngine();
      player = PlaybackController(
        engine: engine,
        enableSystemControls: false,
        resolveSource: (track, local) async => local
            ? const AudioSource('/cache/a', local: true)
            : const AudioSource(
                'https://yun.test/audio',
                headers: {'Authorization': 'Bearer token'},
              ),
      );
      await player.playQueue(tracks);
      engine.emit(
        const EngineState(
          error: 'local file became unreadable',
          position: Duration(seconds: 12),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(engine.opened, 'https://yun.test/audio');
      expect(player.position, const Duration(seconds: 12));
      expect(player.currentTrack!.id, 'a');
    },
  );
}

class FlakyEngine extends FakeEngine {
  int initializations = 0;
  @override
  Future<void> initialize() async {
    if (++initializations == 1) throw StateError('Native init failed');
  }
}
