import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/playback_controller.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/playback_engine.dart';

import 'fakes.dart';

class _TransitionEngine extends FakeEngine implements TransitionPlaybackEngine {
  int transitions = 0, fullStops = 0, plays = 0;
  bool focused = false, failReleaseOnce = false;
  final starts = <Duration>[];
  Future<void> Function()? onTransition;

  @override
  Future<void> stopForTransition() async {
    transitions++;
    opened = null;
    emit(const EngineState());
    await onTransition?.call();
  }

  @override
  Future<void> stop() async {
    fullStops++;
    opened = null;
    focused = false;
    await super.stop();
    if (failReleaseOnce) {
      failReleaseOnce = false;
      throw const AudioFocusUnavailable();
    }
  }

  @override
  Future<void> open(
    String uri, {
    Map<String, String>? headers,
    bool play = true,
    Duration start = Duration.zero,
  }) async {
    starts.add(start);
    focused = play;
    await super.open(uri, headers: headers, play: play, start: start);
  }

  @override
  Future<void> play() async {
    plays++;
    await super.play();
  }
}

void main() {
  const tracks = [
    Track(id: 'a', title: 'A', durationMs: 120000),
    Track(id: 'b', title: 'B', durationMs: 195000),
  ];
  late _TransitionEngine engine;
  late PlaybackController controller;
  Future<AudioSource> Function(Track)? resolver;

  setUp(() {
    resolver = null;
    engine = _TransitionEngine();
    controller = PlaybackController(
      engine: engine,
      enableSystemControls: false,
      resolveSource: (track, _) async => resolver == null
          ? AudioSource('/cache/${track.id}', local: true)
          : await resolver!(track),
    );
  });

  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
  });

  void complete() => engine.emit(
    const EngineState(
      completed: true,
      position: Duration(seconds: 120),
      duration: Duration(seconds: 120),
    ),
  );

  test(
    'automatic EOF retires source with focus, true queue end releases it',
    () async {
      await controller.playQueue(tracks);
      final stops = engine.fullStops;
      complete();
      complete();
      await controller.flushSettings();
      expect(controller.currentTrack, tracks[1]);
      expect(engine.transitions, 1);
      expect(engine.fullStops, stops);
      expect(engine.focused, isTrue);
      expect(engine.opens, 2);
      complete();
      await controller.flushSettings();
      expect(controller.currentTrack, isNull);
      expect(engine.focused, isFalse);
      expect(engine.fullStops, stops + 1);
    },
  );

  test(
    'retired state cannot affect next track during a slow local lookup',
    () async {
      await controller.playQueue(tracks);
      final entered = Completer<void>();
      final lookup = Completer<AudioSource>();
      resolver = (_) {
        entered.complete();
        return lookup.future;
      };
      complete();
      await entered.future;
      expect(engine.opened, isNull);
      expect(engine.focused, isTrue);
      expect(controller.isPlaying, isFalse);
      engine.emit(const EngineState(completed: true, error: 'retired decoder'));
      expect(controller.error, isNull);
      lookup.complete(const AudioSource('/cache/b', local: true));
      await controller.flushSettings();
      expect(controller.currentTrack, tracks[1]);
      expect(controller.error, isNull);
      expect(engine.opens, 2);
    },
  );

  test(
    'failed source lookup releases a retained grant and stays retryable',
    () async {
      await controller.playQueue(tracks);
      resolver = (_) async =>
          throw const LocalAudioUnavailable('Missing download');
      complete();
      await controller.flushSettings();
      expect(controller.currentTrack, tracks[1]);
      expect(engine.focused, isFalse);
      expect(controller.localPlaybackError, 'Missing download');
      resolver = null;
      await controller.play();
      expect(engine.opened, '/cache/b');
      expect(engine.focused, isTrue);
      expect(controller.error, isNull);
    },
  );

  for (final action in ['pause', 'stop', 'shutdown']) {
    test('$action before queued EOF advance prevents a new open', () async {
      await controller.playQueue(tracks);
      complete();
      await switch (action) {
        'pause' => controller.pause(),
        'stop' => controller.stop(),
        _ => controller.shutdown(),
      };
      await controller.flushSettings();
      expect(engine.opens, 1);
      expect(controller.isPlaying, isFalse);
      if (action == 'pause') {
        await controller.play();
        expect(engine.opens, 2);
        expect(engine.starts.last, Duration.zero);
        complete();
        await controller.flushSettings();
        expect(controller.currentTrack, tracks[1]);
        expect(engine.opens, 3);
      }
    });

    for (final stage in ['native stop', 'checkpoint']) {
      test(
        '$action during automatic $stage cancels the whole transition',
        () async {
          var clock = 0;
          await controller.shutdown();
          controller.dispose();
          engine = _TransitionEngine();
          controller = PlaybackController(
            engine: engine,
            enableSystemControls: false,
            monotonicMs: () => clock,
            resolveSource: (track, _) async =>
                AudioSource('/cache/${track.id}', local: true),
          );
          final entered = Completer<void>();
          final gate = Completer<void>();
          Future<void> stall() async {
            if (!entered.isCompleted) entered.complete();
            await gate.future;
          }

          if (stage == 'native stop') {
            engine.onTransition = stall;
          } else {
            controller.configureRecording('test', (_) => stall());
          }
          await controller.playQueue(tracks);
          clock = 1000;
          complete();
          await entered.future;
          final ending = switch (action) {
            'pause' => controller.pause(),
            'stop' => controller.stop(),
            _ => controller.shutdown(),
          };
          expect(engine.focused, isFalse);
          gate.complete();
          await ending;
          await controller.flushSettings();
          expect(engine.opens, 1);
          expect(controller.isPlaying, isFalse);
        },
      );
    }

    test(
      '$action during automatic source lookup cancels retained-focus playback',
      () async {
        await controller.playQueue(tracks);
        final entered = Completer<void>();
        final lookup = Completer<AudioSource>();
        resolver = (_) {
          entered.complete();
          return lookup.future;
        };
        complete();
        await entered.future;
        expect(engine.focused, isTrue);
        final ending = switch (action) {
          'pause' => controller.pause(),
          'stop' => controller.stop(),
          _ => controller.shutdown(),
        };
        expect(engine.focused, isFalse);
        lookup.complete(const AudioSource('/cache/b', local: true));
        await ending;
        await controller.flushSettings();
        expect(engine.opens, 1, reason: 'Canceled lookup must never submit B');
        expect(controller.isPlaying, isFalse);
        if (action == 'pause') {
          resolver = null;
          await controller.play();
          expect(engine.opened, '/cache/b');
          expect(engine.opens, 2);
        } else {
          expect(controller.currentTrack, isNull);
        }
      },
    );

    test('$action during stream recovery lookup cannot reopen audio', () async {
      resolver = (track) async => AudioSource('https://yun.test/${track.id}');
      await controller.playQueue(tracks);
      final entered = Completer<void>();
      final lookup = Completer<AudioSource>();
      resolver = (_) {
        entered.complete();
        return lookup.future;
      };
      engine.emit(const EngineState(error: 'stream interrupted'));
      await entered.future;
      final ending = switch (action) {
        'pause' => controller.pause(),
        'stop' => controller.stop(),
        _ => controller.shutdown(),
      };
      lookup.complete(const AudioSource('https://yun.test/recovered'));
      await ending;
      await controller.flushSettings();
      expect(engine.opens, 1);
      expect(controller.isPlaying, isFalse);
    });
  }

  test(
    'failed transition checkpoint releases focus and Play reloads media',
    () async {
      var clock = 0;
      var fail = true;
      await controller.shutdown();
      controller.dispose();
      engine = _TransitionEngine();
      controller =
          PlaybackController(
            engine: engine,
            enableSystemControls: false,
            monotonicMs: () => clock,
            resolveSource: (track, _) async =>
                AudioSource('/cache/${track.id}', local: true),
          )..configureRecording('test', (_) async {
            if (fail) throw StateError('checkpoint unavailable');
          });
      await controller.playQueue(tracks);
      clock = 1000;
      complete();
      await controller.flushSettings();
      expect(engine.focused, isFalse);
      expect(engine.opened, isNull);
      expect(controller.currentTrack, tracks[0]);
      expect(controller.error, contains('checkpoint unavailable'));
      fail = false;
      await controller.play();
      expect(engine.opened, '/cache/a');
      expect(engine.plays, 0, reason: 'Play cannot resume an emptied player');
      expect(engine.opens, 2);
      expect(controller.error, isNull);
    },
  );

  test(
    'failed full release before manual Next reloads the selected source',
    () async {
      await controller.playQueue(tracks);
      engine.emit(
        const EngineState(playing: true, position: Duration(seconds: 37)),
      );
      engine.failReleaseOnce = true;
      await expectLater(
        controller.next(),
        throwsA(isA<AudioFocusUnavailable>()),
      );
      expect(controller.currentTrack, tracks[0]);
      expect(engine.opened, isNull);
      expect(controller.audioFocusError, isNotNull);
      await controller.play();
      expect(engine.plays, 0);
      expect(engine.opened, '/cache/a');
      expect(engine.starts.last, const Duration(seconds: 37));
      expect(controller.isPlaying, isTrue);
      expect(controller.error, isNull);
    },
  );

  test(
    'repeat one uses a transition but explicit replacement uses full stop',
    () async {
      await controller.playQueue(tracks);
      controller.setRepeat(RepeatMode.one);
      final stops = engine.fullStops;
      complete();
      await controller.flushSettings();
      expect(controller.currentTrack, tracks[0]);
      expect(engine.transitions, 1);
      expect(engine.fullStops, stops);
      await controller.playQueue(tracks, index: 1);
      expect(engine.fullStops, stops + 1);
      expect(controller.currentTrack, tracks[1]);
    },
  );
}
