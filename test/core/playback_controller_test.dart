import 'dart:async';
import 'dart:math';

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
      random: Random(42),
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
  group('volume', () {
    test(
      'defaults do not override native volume even across track changes',
      () async {
        expect(player.volume, 100);
        expect(player.isMuted, isFalse);
        await player.playQueue(tracks);
        await player.next();
        await player.stop();
        await player.playQueue(tracks);
        expect(engine.volumeCalls, isEmpty);
      },
    );

    test(
      'idle changes clamp, mute and restore without initializing audio',
      () async {
        await player.toggleMute();
        expect(player.volume, 0);
        expect(player.isMuted, isTrue);
        await player.toggleMute();
        expect(player.volume, 100);
        await player.setVolume(37.5);
        await player.toggleMute();
        expect(player.volume, 0);
        await player.toggleMute();
        expect(player.volume, 37.5);
        await player.setVolume(-20);
        expect(player.isMuted, isTrue);
        await player.toggleMute();
        expect(player.volume, 37.5);
        await player.setVolume(120);
        expect(player.volume, 100);
        await player.setVolume(0);
        await player.toggleMute();
        expect(player.volume, 100);
        expect(engine.initializations, 0);
        expect(engine.volumeCalls, isEmpty);
      },
    );

    test(
      'nonfinite values fail without changing volume or poisoning commands',
      () async {
        await player.setVolume(42);
        for (final value in [
          double.nan,
          double.infinity,
          double.negativeInfinity,
        ]) {
          await expectLater(player.setVolume(value), throwsArgumentError);
          expect(player.volume, 42);
        }
        await player.toggleMute();
        await player.toggleMute();
        expect(player.volume, 42);
        expect(engine.initializations, 0);
      },
    );

    test(
      'latest idle volume is applied before the first open, including mute',
      () async {
        await player.setVolume(42);
        await player.setVolume(0);
        await player.playQueue(tracks);
        expect(engine.calls.take(4), ['initialize', 'volume', 'stop', 'open']);
        expect(engine.volumeCalls, [0]);
        expect(engine.volume, 0);
        await player.toggleMute();
        expect(engine.volume, 42);
        expect(player.volume, 42);
      },
    );

    test('rapid commands compute mute and restore in serial order', () async {
      await player.playQueue(tracks);
      await Future.wait([
        player.setVolume(25),
        player.toggleMute(),
        player.toggleMute(),
        player.setVolume(60),
        player.setVolume(0),
        player.toggleMute(),
        player.toggleMute(),
        player.toggleMute(),
      ]);
      expect(engine.volumeCalls, [25, 0, 25, 60, 0, 60, 0, 60]);
      expect(player.volume, 60);
      expect(player.isMuted, isFalse);
    });

    test('native commands publish state only after success', () async {
      await player.playQueue(tracks);
      final pending = Completer<void>();
      final started = Completer<void>();
      engine.onSetVolume = (_) {
        started.complete();
        return pending.future;
      };
      final observed = <double>[];
      player.addListener(() => observed.add(player.volume));
      final change = player.setVolume(25);
      await started.future;
      expect(player.volume, 100);
      expect(observed, isEmpty);
      pending.complete();
      await change;
      expect(player.volume, 25);
      expect(observed, [25]);
    });

    test(
      'failed native volume and mute commands preserve state and restore level',
      () async {
        await player.playQueue(tracks);
        await player.setVolume(35);
        engine.onSetVolume = (_) async => throw StateError('Volume failed');
        await expectLater(player.setVolume(75), throwsStateError);
        expect(player.volume, 35);
        expect(player.error, contains('Volume failed'));
        await expectLater(player.toggleMute(), throwsStateError);
        expect(player.isMuted, isFalse);
        engine.onSetVolume = null;
        await player.toggleMute();
        expect(player.volume, 0);
        engine.onSetVolume = (_) async => throw StateError('Volume failed');
        await expectLater(player.toggleMute(), throwsStateError);
        expect(player.isMuted, isTrue);
        await expectLater(player.setVolume(90), throwsStateError);
        engine.onSetVolume = null;
        await player.toggleMute();
        expect(player.volume, 35);
        expect(engine.volume, 35);
        await player.pause();
        expect(player.isPlaying, isFalse);
      },
    );

    test(
      'failed preplay volume application can retry initialization',
      () async {
        await player.setVolume(23);
        engine.onSetVolume = (_) async => throw StateError('Volume failed');
        await expectLater(player.playQueue(tracks), throwsStateError);
        expect(engine.opens, 0);
        expect(player.currentTrack, isNull);
        expect(player.volume, 23);
        expect(engine.controller.hasListener, isFalse);
        engine.onSetVolume = null;
        await player.playQueue(tracks);
        expect(engine.initializations, 2);
        expect(engine.volumeCalls, [23, 23]);
        expect(engine.controller.hasListener, isTrue);
        expect(player.isPlaying, isTrue);
      },
    );

    test('volume and mute restore survive track switches, stop and recording changes', () async {
      await player.playQueue(tracks);
      await player.setVolume(48);
      await player.next();
      expect(player.volume, 48);
      await player.toggleMute();
      await player.previous();
      expect(player.isMuted, isTrue);
      await player.stop();
      player.configureRecording('new-account-device', (_) async {});
      expect(player.isMuted, isTrue);
      await player.playQueue(tracks, index: 2);
      expect(player.isMuted, isTrue);
      await player.toggleMute();
      expect(player.volume, 48);
      expect(engine.volumeCalls, [48, 0, 48]);
      await player.stop();
      await player.setVolume(27);
      expect(engine.volume, 27);
      await player.playQueue(tracks);
      expect(player.volume, 27);
    });

    test('closing skips queued and subsequent volume commands', () async {
      await player.playQueue(tracks);
      await player.setVolume(40);
      final queued = player.setVolume(20);
      final closing = player.shutdown();
      await Future.wait([
        queued,
        closing,
        player.toggleMute(),
        player.setVolume(10),
      ]);
      await player.setVolume(90);
      await player.toggleMute();
      expect(engine.volumeCalls, [40]);
      expect(player.volume, 40);
    });

    test(
      'shutdown waits for an in-flight volume command before disposal',
      () async {
        await player.playQueue(tracks);
        final pending = Completer<void>();
        final started = Completer<void>();
        engine.onSetVolume = (_) {
          started.complete();
          return pending.future;
        };
        final change = player.setVolume(18);
        await started.future;
        final closing = player.shutdown();
        final ignored = player.toggleMute();
        pending.complete();
        await Future.wait([change, closing, ignored]);
        expect(player.volume, 18);
        expect(engine.volumeCalls, [18]);
        expect(engine.controller.isClosed, isTrue);
      },
    );
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

  test(
    'shuffled collection starts randomly and visits each entry once',
    () async {
      player.setShuffle(true);
      await player.playQueue(tracks);
      expect(player.index, Random(42).nextInt(tracks.length));
      expect(player.queue, tracks);
      final first = player.index;
      await player.next();
      final second = player.index;
      expect(second, isNot(first));
      await player.previous();
      expect(player.index, first);
      final visited = {player.index};
      for (var i = 1; i < tracks.length; i++) {
        await player.next();
        expect(visited.add(player.index), isTrue);
      }
      await player.next();
      expect(player.currentTrack, isNull);
    },
  );

  test(
    'explicit indices override shuffle, including the first entry',
    () async {
      player.setShuffle(true);
      for (final index in [0, 2]) {
        await player.playQueue(tracks, index: index);
        expect(player.index, index);
        expect(player.queue, tracks);
        expect(player.shuffle, isTrue);
      }
    },
  );

  test(
    'collection starts handle sequential, single and empty queues',
    () async {
      await player.playQueue(tracks);
      expect(player.index, 0);
      player.setShuffle(true);
      player.setRepeat(RepeatMode.all);
      await player.setVolume(35);
      await player.playQueue([tracks.first]);
      expect(player.index, 0);
      await player.next();
      expect(player.index, 0);
      await player.playQueue([]);
      expect(player.currentTrack, isNull);
      expect(player.queue, isEmpty);
      expect(player.shuffle, isTrue);
      expect(player.repeatMode, RepeatMode.all);
      expect(player.volume, 35);
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
  @override
  Future<void> initialize() async {
    if (++initializations == 1) throw StateError('Native init failed');
  }
}
