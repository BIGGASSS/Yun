import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:yun/services/playback_engine.dart';

void main() {
  late TestPlayer player;
  late TestSession session;
  late MediaKitEngine engine;
  setUp(() {
    player = TestPlayer();
    session = TestSession();
    engine = MediaKitEngine(
      createPlayer: () async => player,
      loadSession: () async => session,
    );
  });
  tearDown(() async {
    await engine.dispose();
    await session.interruptions.close();
    await session.noisy.close();
  });

  test(
    'failed session configuration disposes partial player and retries',
    () async {
      session.failConfiguration = true;
      await expectLater(engine.initialize(), throwsStateError);
      expect(player.disposed, isTrue);
      expect(session.interruptions.hasListener, isFalse);
      player = TestPlayer();
      session.failConfiguration = false;
      await engine.initialize();
      await engine.play();
      expect(player.plays, 1);
      expect(session.configurations, 2);
      expect(session.interruptions.hasListener, isTrue);
    },
  );

  test(
    'concurrent initialization shares one player and configuration',
    () async {
      await Future.wait([engine.initialize(), engine.initialize()]);
      expect(session.configurations, 1);
    },
  );

  test('interruption resumes only if originally playing; duplicate begins are safe', () async {
    await engine.play();
    session.interruptions.add(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    session.interruptions.add(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    expect(player.state.playing, isFalse);
    session.interruptions.add(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    await Future<void>.delayed(Duration.zero);
    expect(player.plays, 2);
    await engine.pause();
    session.interruptions.add(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    session.interruptions.add(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    await Future<void>.delayed(Duration.zero);
    expect(player.plays, 2);
  });

  test('unknown interruption end clears pending automatic resume', () async {
    await engine.play();
    session.interruptions.add(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    session.interruptions.add(
      AudioInterruptionEvent(false, AudioInterruptionType.unknown),
    );
    session.interruptions.add(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    await Future<void>.delayed(Duration.zero);
    expect(player.plays, 1);
  });

  test(
    'explicit pause, stop and becoming noisy cancel interruption resume',
    () async {
      for (final action in <Future<void> Function()>[
        engine.pause,
        engine.stop,
        () async => session.noisy.add(null),
      ]) {
        await engine.play();
        final plays = player.plays;
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        await action();
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(Duration.zero);
        expect(player.plays, plays);
        expect(player.state.playing, isFalse);
      }
    },
  );

  test('stop wins over an interruption resume awaiting audio focus', () async {
    await engine.play();
    session.interruptions.add(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    session.activation = Completer<bool>();
    session.interruptions.add(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    await Future<void>.delayed(Duration.zero);
    await engine.stop();
    session.activation!.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(session.activations.sublist(session.activations.length - 3), [
      true,
      false,
      false,
    ]);
    expect(player.plays, 1);
    expect(player.state.playing, isFalse);
  });
}

class TestPlayer implements Player {
  @override
  PlayerState state = const PlayerState();
  @override
  final PlayerStream stream = TestPlayerStream();
  int plays = 0;
  bool disposed = false;
  @override
  Future<void> play() async {
    plays++;
    state = state.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
  }

  @override
  Future<void> stop() => pause();
  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestPlayerStream implements PlayerStream {
  @override
  Stream<bool> get playing => const Stream.empty();
  @override
  Stream<bool> get buffering => const Stream.empty();
  @override
  Stream<bool> get completed => const Stream.empty();
  @override
  Stream<Duration> get position => const Stream.empty();
  @override
  Stream<Duration> get duration => const Stream.empty();
  @override
  Stream<String> get error => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestSession implements AudioSession {
  final interruptions = StreamController<AudioInterruptionEvent>.broadcast(
    sync: true,
  );
  final noisy = StreamController<void>.broadcast(sync: true);
  bool failConfiguration = false;
  int configurations = 0;
  Completer<bool>? activation;
  final activations = <bool>[];
  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      interruptions.stream;
  @override
  Stream<void> get becomingNoisyEventStream => noisy.stream;
  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {
    configurations++;
    if (failConfiguration) throw StateError('AudioSession unavailable');
  }

  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration fallbackConfiguration =
        const AudioSessionConfiguration.music(),
  }) async {
    activations.add(active);
    return active && activation != null ? activation!.future : true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
