import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/playback_controller.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/playback_engine.dart';
import 'package:yun/services/system_media_controls.dart';

import 'fakes.dart';

class _Controls implements SystemMediaControls {
  int initializations = 0, updates = 0, disposals = 0;
  bool ready = false;
  Future<void> Function()? onInitialize, onUpdate;
  MediaCommands? commands;
  Track? track;
  bool playing = false, waiting = false;

  @override
  Future<void> initialize(MediaCommands commands) async {
    initializations++;
    await onInitialize?.call();
    this.commands = commands;
    ready = true;
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
  }) async {
    expect(ready, isTrue, reason: 'Never publish an uninitialized service');
    updates++;
    await onUpdate?.call();
    this.track = track;
    this.playing = playing;
    waiting = waitingForAudio;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

void main() {
  const tracks = [Track(id: 'a', title: 'A'), Track(id: 'b', title: 'B')];
  late FakeEngine engine;
  late _Controls controls;
  late PlaybackController player;
  late List<String> resolutions;

  setUp(() {
    engine = FakeEngine();
    controls = _Controls();
    resolutions = [];
    player = PlaybackController(
      engine: engine,
      controls: controls,
      resolveSource: (track, localFirst) async {
        expect(localFirst, isTrue);
        resolutions.add(track.id);
        return AudioSource('/cache/${track.id}', local: true);
      },
    );
  });
  tearDown(() async {
    await player.shutdown();
    player.dispose();
  });

  test(
    'failed service stays visible during foreground play and Play recovers',
    () async {
      controls.onInitialize = () async =>
          throw StateError('service unavailable');
      await player.playQueue(tracks);
      expect(player.isPlaying, isTrue);
      expect(player.systemMediaControlsAvailable, isFalse);
      expect(player.systemMediaControlsError, contains('Background playback'));
      expect(player.error, contains('service unavailable'));
      expect(player.localPlaybackError, isNull);
      expect(player.audioFocusError, isNull);
      expect(controls.updates, 0);
      await player.pause();
      controls.onInitialize = null;
      await player.play();
      await Future<void>.delayed(Duration.zero);
      expect(controls.initializations, 2);
      expect(engine.initializations, 1);
      expect(engine.opens, 1);
      expect(resolutions, ['a']);
      expect(player.systemMediaControlsAvailable, isTrue);
      expect(player.systemMediaControlsError, isNull);
      expect(player.error, isNull);
      expect(controls.track, tracks.first);
      expect(controls.playing, isTrue);
      await player.play();
      await player.next();
      await player.previous();
      expect(controls.initializations, 2);
      expect(engine.initializations, 1);
    },
  );

  test(
    'repeated failures retry only once per new user playback attempt',
    () async {
      controls.onInitialize = () async =>
          throw StateError('service unavailable');
      await player.playQueue(tracks);
      for (var i = 0; i < 30; i++) {
        engine.emit(EngineState(playing: true, position: Duration(seconds: i)));
      }
      await player.seek(const Duration(seconds: 1));
      await player.setVolume(25);
      player.setShuffle(true);
      player.setRepeat(RepeatMode.one);
      await player.checkpoint();
      await player.pause();
      expect(controls.initializations, 1);
      expect(player.error, contains('service unavailable'));
      // Completion/repeat is an engine event, not a new user attempt.
      engine.emit(const EngineState(completed: true));
      await player.flushSettings();
      expect(controls.initializations, 1);
      expect(player.error, contains('service unavailable'));
      for (var i = 0; i < 3; i++) {
        await player.play();
      }
      expect(controls.initializations, 4);
      expect(engine.initializations, 1);
      expect(controls.updates, 0);
    },
  );

  test(
    'concurrent playback commands share a failed initialization attempt',
    () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      controls.onInitialize = () async {
        if (!started.isCompleted) started.complete();
        await gate.future;
        throw StateError('service unavailable');
      };
      final first = player.playQueue(tracks);
      await started.future;
      final plays = List.generate(20, (_) => player.play());
      gate.complete();
      await Future.wait([first, ...plays]);
      expect(controls.initializations, 1);
      expect(engine.initializations, 1);
      controls.onInitialize = null;
      await player.play();
      expect(controls.initializations, 2);
    },
  );

  test(
    'new selection replaces a source still waiting on initialization',
    () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      controls.onInitialize = () async {
        started.complete();
        await gate.future;
      };
      final first = player.playQueue([tracks.first]);
      await started.future;
      final replacement = player.playQueue([tracks.last]);
      gate.complete();
      await Future.wait([first, replacement]);
      expect(resolutions, ['b']);
      expect(engine.opens, 1);
      expect(player.currentTrack, tracks.last);
      expect(controls.initializations, 1);
    },
  );

  for (final action in ['stop', 'pause', 'shutdown']) {
    test('$action during initialization prevents late source open', () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      controls.onInitialize = () async {
        started.complete();
        await gate.future;
      };
      final playing = player.playQueue(tracks);
      await started.future;
      final ending = switch (action) {
        'stop' => player.stop(),
        'pause' => player.pause(),
        _ => player.shutdown(),
      };
      gate.complete();
      await Future.wait([playing, ending]);
      expect(engine.opens, 0);
      expect(resolutions, isEmpty);
      expect(player.isPlaying, isFalse);
      expect(player.currentTrack, isNull);
      if (action == 'shutdown') {
        expect(controls.disposals, 1);
        expect(player.systemMediaControlsAvailable, isFalse);
      }
      if (action == 'stop') {
        await player.playQueue(tracks);
        expect(engine.opens, 1);
        expect(controls.initializations, 1);
      }
    });
  }

  test(
    'dispose while initialization fails neither opens nor notifies late',
    () async {
      final started = Completer<void>();
      final gate = Completer<void>();
      controls.onInitialize = () async {
        started.complete();
        await gate.future;
        throw StateError('late failure');
      };
      final opening = player.playQueue(tracks);
      await started.future;
      player.dispose();
      gate.complete();
      await opening;
      await player.shutdown();
      expect(engine.opens, 0);
      expect(controls.disposals, 1);
      // tearDown must not dispose the ChangeNotifier twice.
      player = PlaybackController(
        engine: FakeEngine(),
        enableSystemControls: false,
        resolveSource: (_, _) async => const AudioSource('/unused'),
      );
    },
  );

  test(
    'successful later updates clear only the bridge update warning',
    () async {
      await player.playQueue(tracks);
      await Future<void>.delayed(Duration.zero);
      controls.onUpdate = () async => throw StateError('bridge update failed');
      await player.pause();
      await Future<void>.delayed(Duration.zero);
      expect(player.systemMediaControlsError, contains('bridge update failed'));
      expect(player.localPlaybackError, isNull);
      controls.onUpdate = null;
      await player.play();
      await Future<void>.delayed(Duration.zero);
      expect(player.systemMediaControlsError, isNull);
      expect(controls.initializations, 1);
    },
  );

  test(
    'service recovery does not clear an independent local failure',
    () async {
      controls.onInitialize = () async =>
          throw StateError('service unavailable');
      await player.playQueue(tracks);
      engine.emit(const EngineState(error: 'decoder failure'));
      await player.flushSettings();
      expect(player.localPlaybackError, contains('decoder failure'));
      expect(player.systemMediaControlsError, contains('service unavailable'));
      await player.stop();
      expect(player.localPlaybackError, isNull);
      expect(player.error, contains('service unavailable'));
    },
  );

  test(
    'waiting state reaches the service after a recovered initialization',
    () async {
      controls.onInitialize = () async =>
          throw StateError('service unavailable');
      await player.playQueue(tracks);
      engine.emit(const EngineState(waitingForAudio: true));
      expect(player.isWaitingForAudio, isTrue);
      controls.onInitialize = null;
      await player.play();
      engine.emit(const EngineState(waitingForAudio: true));
      await Future<void>.delayed(Duration.zero);
      expect(controls.waiting, isTrue);
      expect(controls.playing, isFalse);
    },
  );

  test(
    'disabled service stays lazy and never retries an injected adapter',
    () async {
      await player.shutdown();
      player.dispose();
      engine = FakeEngine();
      player = PlaybackController(
        engine: engine,
        controls: controls,
        enableSystemControls: false,
        resolveSource: (_, _) async => const AudioSource('/local', local: true),
      );
      await player.playQueue(tracks);
      await player.play();
      expect(controls.initializations, 0);
      expect(player.systemMediaControlsAvailable, isFalse);
      expect(player.systemMediaControlsError, isNull);
    },
  );

  test(
    'volume applies before open and service retry does not reset gain',
    () async {
      controls.onInitialize = () async =>
          throw StateError('service unavailable');
      await player.setVolume(23);
      expect(engine.initializations, 0);
      await player.playQueue(tracks);
      expect(engine.calls.take(4), ['initialize', 'volume', 'stop', 'open']);
      await player.setVolume(41);
      controls.onInitialize = null;
      await player.play();
      expect(engine.initializations, 1);
      expect(engine.volumeCalls, [23, 41]);
      expect(player.volume, 41);
    },
  );
}
