import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/playback_controller.dart';
import 'package:yun/core/app_controller.dart' show AppController;
import 'package:yun/models/models.dart';
import 'package:yun/services/playback_engine.dart';

import 'fakes.dart';

void main() {
  late FakeEngine engine;
  late PlaybackController player;
  var monotonicMs = 0;
  const tracks = [
    Track(id: 'a', title: 'A'),
    Track(id: 'b', title: 'B'),
    Track(id: 'c', title: 'C'),
  ];
  setUp(() {
    monotonicMs = 0;
    engine = FakeEngine();
    player = PlaybackController(
      engine: engine,
      random: Random(42),
      monotonicMs: () => monotonicMs,
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

  Future<void> usePlayer({
    required Future<AudioSource> Function(Track, bool) resolveSource,
    FakeEngine? playbackEngine,
  }) async {
    await player.shutdown();
    player.dispose();
    engine = playbackEngine ?? FakeEngine();
    player = PlaybackController(
      engine: engine,
      enableSystemControls: false,
      resolveSource: resolveSource,
    );
  }

  test('playback preferences do not notify the general app channel', () async {
    final app = AppController(
      playbackEngine: FakeEngine(),
      enableSystemControls: false,
      automaticRefresh: false,
    );
    var appChanges = 0, playbackChanges = 0;
    app.addListener(() => appChanges++);
    app.playback.addListener(() => playbackChanges++);
    await app.playback.setVolume(42);
    app.playback.setShuffle(true);
    app.playback.setRepeat(RepeatMode.all);
    expect(playbackChanges, 3);
    expect(appChanges, 0);
    await app.shutdown();
    app.dispose();
  });

  test(
    'queue snapshots are immutable and stable across playback ticks',
    () async {
      final input = tracks.toList();
      await player.playQueue(input);
      final snapshot = player.queue;
      input.clear();
      expect(snapshot, tracks);
      expect(() => snapshot.clear(), throwsUnsupportedError);
      for (var i = 0; i < 100; i++) {
        engine.emit(
          EngineState(playing: true, position: Duration(milliseconds: i)),
        );
        expect(identical(player.queue, snapshot), isTrue);
      }
      await player.next();
      expect(identical(player.queue, snapshot), isTrue);
      await player.playQueue(tracks, index: 2);
      expect(identical(player.queue, snapshot), isTrue);
      await player.playQueue([tracks.last, tracks.first]);
      expect(identical(player.queue, snapshot), isFalse);
      expect(snapshot, tracks);
      await player.stop();
      expect(player.queue, isEmpty);
      expect(identical(player.queue, player.queue), isTrue);
    },
  );

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

  for (final paused in [false, true]) {
    test(
      'stream recovery preserves position and paused=$paused at load time',
      () async {
        await usePlayer(
          resolveSource: (_, localFirst) async {
            expect(localFirst, isTrue);
            return const AudioSource('https://yun.test/audio');
          },
        );
        await player.playQueue(tracks);
        if (paused) await player.pause();
        engine.emit(
          EngineState(
            playing: !paused,
            position: const Duration(seconds: 42),
            duration: const Duration(seconds: 120),
          ),
        );
        engine.emit(
          const EngineState(
            error: 'decoder failed',
            position: Duration(seconds: 42),
          ),
        );
        await player.flushSettings();
        expect(engine.opens, 2);
        expect(player.isPlaying, !paused);
        expect(player.position, const Duration(seconds: 42));
        expect(engine.calls, isNot(contains('seek')));
        expect(player.error, isNull);
      },
    );
  }

  test(
    'Play retries failed source resolution and restarts accounting',
    () async {
      await player.shutdown();
      player.dispose();
      engine = FakeEngine();
      var attempts = 0;
      final events = <ListeningEvent>[];
      player = PlaybackController(
        engine: engine,
        monotonicMs: () => monotonicMs,
        enableSystemControls: false,
        resolveSource: (track, localFirst) async {
          expect(localFirst, isTrue);
          if (++attempts <= 2) throw StateError('Offline');
          return AudioSource('/cache/${track.id}', local: true);
        },
      )..configureRecording('device', (event) async => events.add(event));
      await expectLater(player.playQueue(tracks), throwsStateError);
      expect(player.currentTrack, tracks.first);
      expect(engine.opens, 0);
      await expectLater(player.play(), throwsStateError);
      expect(player.error, contains('Offline'));
      monotonicMs += 5000;
      await player.play();
      expect(attempts, 3);
      expect(engine.opens, 1);
      expect(player.error, isNull);
      expect(player.isPlaying, isTrue);
      monotonicMs += 1000;
      await player.pause();
      expect(events.single.listenedMs, 1000);
    },
  );

  test(
    'local decoder error plus completion stays failed without advancing queue',
    () async {
      await player.playQueue(tracks);
      engine.emit(const EngineState(error: 'bad decoder', completed: true));
      await Future<void>.delayed(Duration.zero);
      await player.pause();
      expect(player.currentTrack!.id, 'a');
      expect(engine.opens, 1);
      expect(player.localPlaybackError, contains('bad decoder'));
    },
  );

  test(
    'shutdown still disposes native resources when event persistence fails',
    () async {
      final localEngine = FakeEngine();
      final local =
          PlaybackController(
            engine: localEngine,
            monotonicMs: () => monotonicMs,
            enableSystemControls: false,
            resolveSource: (_, _) async => const AudioSource('/test'),
          )..configureRecording('device', (_) async {
            throw StateError('Disk full');
          });
      await local.playQueue(tracks);
      monotonicMs += 1000;
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
      monotonicMs += 1000;
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

  testWidgets('detached failures do not retry on ticks or other accounts', (
    tester,
  ) async {
    final player = PlaybackController(
      engine: FakeEngine(),
      enableSystemControls: false,
      monotonicMs: () => monotonicMs,
      resolveSource: (_, _) async => const AudioSource('/test'),
    );
    addTearDown(() async {
      await tester.runAsync(player.shutdown);
      player.dispose();
    });
    final failed = <ListeningEvent>[];
    player.configureRecording('device', (event) async {
      failed.add(event);
      throw StateError('Disk full');
    }, accountKey: 'server/user');
    await player.playQueue(tracks);
    monotonicMs += 1000;
    await expectLater(player.stop(), throwsStateError);
    expect(player.error, contains('Disk full'));
    final original = failed.first;
    await player.detachRecording();
    final attempts = failed.length;
    await tester.pump(const Duration(seconds: 30));
    await player.checkpoint();
    expect(failed, hasLength(attempts));

    final other = <ListeningEvent>[];
    player.configureRecording('device', (event) async {
      other.add(event);
    }, accountKey: 'server/other-user');
    await player.checkpoint();
    await tester.pump(const Duration(seconds: 30));
    expect(other, isEmpty);
    expect(failed, hasLength(attempts));

    final recovered = <ListeningEvent>[];
    player.configureRecording('device', (event) async {
      recovered.add(event);
    }, accountKey: 'server/user');
    await player.checkpoint();
    await player.checkpoint();
    expect(recovered, [same(original)]);
    expect(recovered.single.listenedMs, 1000);
    await tester.runAsync(player.shutdown);
  });

  test(
    'detaching drains only the accepted callback, not its pending tail',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final oldWrites = <ListeningEvent>[];
      player.configureRecording('device', (event) async {
        oldWrites.add(event);
        entered.complete();
        await release.future;
      }, accountKey: 'a');
      await player.playQueue(tracks);
      monotonicMs += 1000;
      final first = player.checkpoint();
      await entered.future;
      monotonicMs += 1000;
      final second = player.checkpoint();
      var detached = false;
      final drain = player.detachRecording().then((_) => detached = true);
      final otherWrites = <ListeningEvent>[];
      player.configureRecording('device', (event) async {
        otherWrites.add(event);
      }, accountKey: 'b');
      await player.checkpoint();
      expect(detached, isFalse);
      expect(otherWrites, isEmpty);
      release.complete();
      await Future.wait([first, second, drain]);
      expect(detached, isTrue);
      expect(oldWrites, hasLength(1));

      final recovered = <ListeningEvent>[];
      player.configureRecording('device', (event) async {
        recovered.add(event);
      }, accountKey: 'a');
      await player.checkpoint();
      expect(recovered, hasLength(1));
      expect(recovered.single.id, isNot(oldWrites.single.id));
      expect(recovered.single.listenedMs, 1000);
      expect(otherWrites, isEmpty);
    },
  );

  for (final fails in [false, true]) {
    test(
      'same-account reconfiguration serializes in-flight save (failure=$fails)',
      () async {
        final entered = Completer<void>(), release = Completer<void>();
        final oldWrites = <ListeningEvent>[];
        player.configureRecording('device', (event) async {
          oldWrites.add(event);
          entered.complete();
          await release.future;
          if (fails) throw StateError('Disk full');
        }, accountKey: 'a');
        await player.playQueue(tracks);
        monotonicMs += 1000;
        final first = player.checkpoint();
        final observed = fails ? expectLater(first, throwsStateError) : first;
        await entered.future;
        monotonicMs += 1000;
        final recovered = <ListeningEvent>[];
        player.configureRecording('device', (event) async {
          recovered.add(event);
        }, accountKey: 'a');
        final retry = player.checkpoint();
        await Future<void>.delayed(Duration.zero);
        expect(recovered, isEmpty);
        release.complete();
        await observed;
        await retry;
        expect(oldWrites, hasLength(1));
        expect(recovered, hasLength(fails ? 2 : 1));
        if (fails) expect(recovered.first, same(oldWrites.single));
        expect(
          recovered.map((event) => event.id).toSet(),
          hasLength(recovered.length),
        );
        expect(recovered.every((event) => event.listenedMs == 1000), isTrue);
        await player.checkpoint();
        expect(recovered, hasLength(fails ? 2 : 1));
      },
    );
  }

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

  for (final local in [true, false]) {
    test(
      'focus-denied ${local ? 'download' : 'stream'} waits for explicit retry',
      () async {
        final resolutions = <bool>[];
        final focused = FocusHookEngine()
          ..openFailure = const AudioFocusUnavailable();
        await usePlayer(
          playbackEngine: focused,
          resolveSource: (_, localFirst) async {
            resolutions.add(localFirst);
            return AudioSource(
              local ? '/cache/a' : 'https://yun.test/audio',
              local: local,
            );
          },
        );
        await expectLater(
          player.playQueue(tracks),
          throwsA(isA<AudioFocusUnavailable>()),
        );
        expect(focused.opens, 0);
        expect(player.localPlaybackError, isNull);
        expect(player.audioFocusError, isNotNull);
        expect(player.error, player.audioFocusError);
        expect(player.error, isNot(contains('Bad state')));
        expect(player.error, isNot(contains('downloaded audio')));
        expect(player.isPlaying, isFalse);
        expect(resolutions, [true]);
        await player.flushSettings();
        expect(resolutions, [
          true,
        ], reason: 'Focus denial must not trigger an automatic retry');
        focused.openFailure = null;
        await player.play();
        expect(resolutions, [true, true]);
        expect(focused.opens, 1);
        expect(player.error, isNull);
        expect(player.audioFocusError, isNull);
        expect(player.isPlaying, isTrue);
      },
    );
  }

  test(
    'focus-denied resume and repeated retries preserve local position',
    () async {
      final focused = FocusHookEngine();
      final resolutions = <bool>[];
      await usePlayer(
        playbackEngine: focused,
        resolveSource: (_, localFirst) async {
          resolutions.add(localFirst);
          return const AudioSource('/cache/a', local: true);
        },
      );
      await player.playQueue(tracks);
      focused.emit(
        const EngineState(playing: true, position: Duration(seconds: 12)),
      );
      await player.pause();
      focused.playFailure = const AudioFocusUnavailable();
      await expectLater(player.play(), throwsA(isA<AudioFocusUnavailable>()));
      expect(player.position, const Duration(seconds: 12));
      expect(player.audioFocusError, isNotNull);
      expect(player.localPlaybackError, isNull);
      expect(player.isPlaying, isFalse);
      focused.openFailure = const AudioFocusUnavailable();
      await expectLater(player.play(), throwsA(isA<AudioFocusUnavailable>()));
      expect(player.position, const Duration(seconds: 12));
      focused.openFailure = focused.playFailure = null;
      await player.play();
      expect(focused.starts, [
        Duration.zero,
        const Duration(seconds: 12),
        const Duration(seconds: 12),
      ]);
      expect(focused.calls, isNot(contains('seek')));
      expect(resolutions, [true, true, true]);
      expect(player.position, const Duration(seconds: 12));
      expect(player.error, isNull);
      expect(player.isPlaying, isTrue);
    },
  );

  test(
    'focus state emitted during open preserves typed error for the UI action',
    () async {
      final focused = OpenHookEngine();
      focused.onOpen = () async => focused.emit(
        const EngineState(
          error: 'Audio is unavailable. Try Play again.',
          audioFocusFailure: true,
        ),
      );
      await usePlayer(
        playbackEngine: focused,
        resolveSource: (_, _) async =>
            const AudioSource('/cache/a', local: true),
      );
      await expectLater(
        player.playQueue(tracks),
        throwsA(isA<AudioFocusUnavailable>()),
      );
      expect(player.audioFocusError, 'Audio is unavailable. Try Play again.');
      expect(player.localPlaybackError, isNull);
      expect(player.error, isNot(contains('Bad state')));
      focused.onOpen = null;
      await player.play();
      expect(player.audioFocusError, isNull);
      expect(player.isPlaying, isTrue);
    },
  );

  test('asynchronous focus error stays retryable without local repair or network recovery', () async {
    final focused = FocusHookEngine();
    var resolutions = 0;
    await usePlayer(
      playbackEngine: focused,
      resolveSource: (_, _) async {
        resolutions++;
        return const AudioSource('/cache/a', local: true);
      },
    );
    await player.playQueue(tracks);
    focused.emit(
      const EngineState(
        error: 'Audio is unavailable. Try Play again.',
        audioFocusFailure: true,
        position: Duration(seconds: 9),
      ),
    );
    await player.flushSettings();
    expect(resolutions, 1);
    expect(player.localPlaybackError, isNull);
    expect(player.audioFocusError, 'Audio is unavailable. Try Play again.');
    expect(player.isPlaying, isFalse);
    await player.play();
    expect(resolutions, 2);
    expect(focused.starts.last, const Duration(seconds: 9));
    expect(player.audioFocusError, isNull);
    expect(player.isPlaying, isTrue);
  });

  test(
    'focus denial during stream recovery keeps the actionable focus cause',
    () async {
      final focused = FocusHookEngine();
      await usePlayer(
        playbackEngine: focused,
        resolveSource: (_, _) async =>
            const AudioSource('https://yun.test/audio'),
      );
      await player.playQueue(tracks);
      focused.openFailure = const AudioFocusUnavailable();
      focused.emit(
        const EngineState(
          error: 'stream interrupted',
          position: Duration(seconds: 11),
        ),
      );
      await player.flushSettings();
      expect(player.audioFocusError, isNotNull);
      expect(player.error, player.audioFocusError);
      expect(player.error, isNot(contains('stream interrupted')));
      expect(focused.starts, [Duration.zero, const Duration(seconds: 11)]);
      focused.openFailure = null;
      await player.play();
      expect(focused.starts.last, const Duration(seconds: 11));
      expect(player.error, isNull);
    },
  );

  test(
    'Next and Stop clear focus error without marking the next download',
    () async {
      final focused = FocusHookEngine()
        ..openFailure = const AudioFocusUnavailable();
      await usePlayer(
        playbackEngine: focused,
        resolveSource: (track, _) async =>
            AudioSource('/cache/${track.id}', local: true),
      );
      await expectLater(
        player.playQueue(tracks),
        throwsA(isA<AudioFocusUnavailable>()),
      );
      focused.openFailure = null;
      await player.next();
      expect(player.currentTrack?.id, 'b');
      expect(player.audioFocusError, isNull);
      expect(player.localPlaybackError, isNull);
      focused.emit(
        const EngineState(error: 'Focus lost', audioFocusFailure: true),
      );
      await player.flushSettings();
      await player.stop();
      expect(player.audioFocusError, isNull);
      expect(player.localPlaybackError, isNull);
      expect(player.error, isNull);
    },
  );

  test(
    'asynchronous local failures stay local and preserve their first cause',
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
      await player.flushSettings();
      expect(engine.opened, '/cache/a');
      expect(engine.opens, 1);
      expect(player.position, const Duration(seconds: 12));
      expect(player.currentTrack!.id, 'a');
      final firstError = player.localPlaybackError;
      expect(firstError, contains('local file became unreadable'));
      engine.emit(const EngineState(error: 'secondary decoder diagnostic'));
      await player.flushSettings();
      expect(player.localPlaybackError, firstError);
      expect(player.error, firstError);
      await player.play();
      expect(engine.opens, 2);
      expect(engine.opened, '/cache/a');
      expect(player.localPlaybackError, isNull);
    },
  );

  test(
    'repeated local open failures never resolve a network fallback',
    () async {
      final resolutions = <bool>[];
      final failing = OpenHookEngine()
        ..onOpen = () async => throw StateError('file permission denied');
      await usePlayer(
        playbackEngine: failing,
        resolveSource: (_, localFirst) async {
          resolutions.add(localFirst);
          return const AudioSource('/cache/a', local: true);
        },
      );
      await expectLater(player.playQueue(tracks), throwsStateError);
      expect(player.localPlaybackError, contains('file permission denied'));
      await expectLater(player.play(), throwsStateError);
      expect(resolutions, [true, true]);
      expect(failing.attempts, 2);
      expect(player.error, player.localPlaybackError);
      failing.onOpen = null;
      await player.play();
      expect(failing.attempts, 3);
      expect(player.localPlaybackError, isNull);
      expect(player.isPlaying, isTrue);
    },
  );

  test('local resolution failures retain local intent through retry', () async {
    var resolves = 0;
    await usePlayer(
      resolveSource: (_, localFirst) async {
        expect(localFirst, isTrue);
        resolves++;
        throw const LocalAudioUnavailable('Downloaded audio is missing');
      },
    );
    await expectLater(
      player.playQueue(tracks),
      throwsA(isA<LocalAudioUnavailable>()),
    );
    await expectLater(player.play(), throwsA(isA<LocalAudioUnavailable>()));
    expect(resolves, 2);
    expect(engine.opens, 0);
    expect(player.localPlaybackError, 'Downloaded audio is missing');
    await player.stop();
    expect(player.localPlaybackError, isNull);
  });

  test('retired source events during async local lookup are ignored', () async {
    final lookup = Completer<AudioSource>();
    final started = Completer<void>();
    await usePlayer(
      resolveSource: (track, localFirst) async {
        expect(localFirst, isTrue);
        if (track.id == 'a') return const AudioSource('https://yun.test/audio');
        started.complete();
        return lookup.future;
      },
    );
    await player.playQueue(tracks);
    final next = player.next();
    await started.future;
    engine.emit(
      const EngineState(
        playing: true,
        completed: true,
        position: Duration(seconds: 99),
        error: 'Failed to open http://127.0.0.1:123/retired',
      ),
    );
    expect(player.error, isNull);
    lookup.complete(const AudioSource('/cache/b', local: true));
    await next;
    await player.flushSettings();
    expect(player.currentTrack!.id, 'b');
    expect(engine.opened, '/cache/b');
    expect(engine.opens, 2);
    expect(player.position, Duration.zero);
    expect(player.error, isNull);
    expect(player.isPlaying, isTrue);
  });

  test('genuine local errors emitted during open are not discarded', () async {
    final failing = OpenHookEngine();
    failing.onOpen = () async {
      failing.emit(const EngineState(error: 'unsupported local audio format'));
      throw StateError('secondary open failure');
    };
    await usePlayer(
      playbackEngine: failing,
      resolveSource: (_, _) async => const AudioSource('/cache/a', local: true),
    );
    await expectLater(player.playQueue(tracks), throwsStateError);
    expect(
      player.localPlaybackError,
      contains('unsupported local audio format'),
    );
    expect(player.error, isNot(contains('secondary')));
    expect(failing.attempts, 1);
  });

  test('stopped playback ignores late errors and completion', () async {
    await player.playQueue(tracks);
    await player.stop();
    engine.emit(const EngineState(error: 'retired source', completed: true));
    await player.flushSettings();
    expect(player.error, isNull);
    expect(player.currentTrack, isNull);
    expect(engine.opens, 1);
  });

  test(
    'failed stream recovery preserves the original cause and stays bounded',
    () async {
      final failing = OpenHookEngine();
      await usePlayer(
        playbackEngine: failing,
        resolveSource: (_, localFirst) async {
          expect(localFirst, isTrue);
          return const AudioSource('https://yun.test/audio');
        },
      );
      await player.playQueue(tracks);
      failing.onOpen = () async =>
          throw StateError('secondary relay open failure');
      engine.emit(const EngineState(error: 'original stream interruption'));
      await player.flushSettings();
      expect(failing.attempts, 2);
      expect(player.error, 'original stream interruption');
      expect(player.localPlaybackError, isNull);
      engine.emit(const EngineState(error: 'later diagnostic'));
      await player.flushSettings();
      expect(failing.attempts, 2);
      expect(player.error, 'original stream interruption');
    },
  );

  test(
    'transition is stopped while its listening checkpoint is pending',
    () async {
      final saving = Completer<void>();
      final saved = Completer<void>();
      final events = <ListeningEvent>[];
      player.configureRecording('device', (event) async {
        events.add(event);
        saving.complete();
        await saved.future;
      });
      await player.playQueue(tracks);
      expect(player.isPlaying, isTrue);
      monotonicMs += 1000;
      final next = player.next();
      await saving.future;
      try {
        expect(player.isPlaying, isFalse);
        expect(player.isBuffering, isFalse);
        engine.emit(
          const EngineState(
            playing: true,
            buffering: true,
            error: 'retired source during checkpoint',
          ),
        );
        expect(player.isPlaying, isFalse);
        expect(player.isBuffering, isFalse);
        expect(player.error, isNull);
      } finally {
        saved.complete();
        await next;
      }
      expect(events.single.trackId, 'a');
      expect(events.single.listenedMs, 1000);
      expect(player.currentTrack!.id, 'b');
      expect(player.isPlaying, isTrue);
      expect(player.error, isNull);
    },
  );

  test(
    'local cleanup failure preserves cause and retries listening checkpoint',
    () async {
      await player.shutdown();
      player.dispose();
      final failing = StopHookEngine();
      engine = failing;
      var saveAttempts = 0;
      final events = <ListeningEvent>[];
      player =
          PlaybackController(
            engine: engine,
            monotonicMs: () => monotonicMs,
            enableSystemControls: false,
            resolveSource: (_, _) async =>
                const AudioSource('/cache/a', local: true),
          )..configureRecording('device', (event) async {
            if (++saveAttempts == 1) throw StateError('checkpoint unavailable');
            events.add(event);
          });
      await player.playQueue(tracks);
      monotonicMs += 1000;
      failing.onStop = () async {
        // Let the first eager checkpoint fail before stop fails. Cleanup must
        // still retry the buffered listening event in its finally block.
        await Future<void>.delayed(Duration.zero);
        failing.emit(const EngineState(error: 'secondary shutdown diagnostic'));
        throw StateError('native stop failed');
      };
      try {
        failing.emit(
          const EngineState(
            playing: true,
            buffering: true,
            position: Duration(seconds: 1),
            error: 'original local decoder failure',
          ),
        );
        await player.flushSettings();
        expect(saveAttempts, 2);
        expect(events.single.listenedMs, 1000);
        expect(
          player.localPlaybackError,
          contains('original local decoder failure'),
        );
        expect(player.error, player.localPlaybackError);
        expect(player.error, isNot(contains('secondary')));
        expect(player.error, isNot(contains('checkpoint unavailable')));
        expect(player.error, isNot(contains('native stop failed')));
        expect(player.currentTrack!.id, 'a');
        expect(player.isPlaying, isFalse);
        expect(player.isBuffering, isFalse);
        expect(engine.opens, 1);
      } finally {
        failing.onStop = null;
      }
    },
  );

  test(
    'failed remote open clears native playing and buffering flags',
    () async {
      final failing = OpenHookEngine();
      failing.onOpen = () async {
        failing.emit(const EngineState(playing: true, buffering: true));
        throw StateError('remote open failed');
      };
      await usePlayer(
        playbackEngine: failing,
        resolveSource: (_, _) async =>
            const AudioSource('https://yun.test/audio'),
      );
      await expectLater(player.playQueue(tracks), throwsStateError);
      expect(player.isPlaying, isFalse);
      expect(player.isBuffering, isFalse);
      expect(player.error, contains('remote open failed'));
    },
  );
  test(
    'explicit repair releases local source and preserves queue for Play',
    () async {
      await player.playQueue(tracks);
      await player.prepareLocalRepair('a');
      expect(player.currentTrack, tracks.first);
      expect(player.queue, tracks);
      expect(player.isPlaying, isFalse);
      expect(player.localPlaybackError, contains('being replaced'));
      expect(engine.calls.last, 'stop');
      expect(engine.opens, 1);
      await player.play();
      expect(engine.opens, 2);
      expect(player.isPlaying, isTrue);
      expect(player.localPlaybackError, isNull);
    },
  );

  test('queued local repair never stops a newer selected track', () async {
    await player.playQueue(tracks);
    final next = player.next();
    final repair = player.prepareLocalRepair('a');
    await Future.wait([next, repair]);
    expect(player.currentTrack, tracks[1]);
    expect(player.isPlaying, isTrue);
    expect(engine.calls.last, 'open');
    expect(player.localPlaybackError, isNull);
  });

  test(
    'explicit repair propagates stop failure before replacing audio',
    () async {
      final failing = StopHookEngine();
      await usePlayer(
        playbackEngine: failing,
        resolveSource: (_, _) async =>
            const AudioSource('/cache/a', local: true),
      );
      await player.playQueue(tracks);
      failing.onStop = () async => throw StateError('could not close audio');
      try {
        await expectLater(player.prepareLocalRepair('a'), throwsStateError);
        expect(player.currentTrack, tracks.first);
        expect(player.isPlaying, isFalse);
        expect(engine.opens, 1);
      } finally {
        failing.onStop = null;
      }
    },
  );
}

class OpenHookEngine extends FakeEngine {
  Future<void> Function()? onOpen;
  int attempts = 0;

  @override
  Future<void> open(
    String uri, {
    Map<String, String>? headers,
    bool play = true,
    Duration start = Duration.zero,
  }) async {
    attempts++;
    await onOpen?.call();
    await super.open(uri, headers: headers, play: play, start: start);
  }
}

class FocusHookEngine extends FakeEngine {
  Object? openFailure, playFailure;
  final starts = <Duration>[];

  @override
  Future<void> open(
    String uri, {
    Map<String, String>? headers,
    bool play = true,
    Duration start = Duration.zero,
  }) async {
    starts.add(start);
    final failure = openFailure;
    if (failure != null) throw failure;
    await super.open(uri, headers: headers, play: play, start: start);
  }

  @override
  Future<void> play() async {
    final failure = playFailure;
    if (failure != null) throw failure;
    await super.play();
  }
}

class FlakyEngine extends FakeEngine {
  @override
  Future<void> initialize() async {
    if (++initializations == 1) throw StateError('Native init failed');
  }
}

class StopHookEngine extends FakeEngine {
  Future<void> Function()? onStop;

  @override
  Future<void> stop() async {
    await super.stop();
    await onStop?.call();
  }
}
