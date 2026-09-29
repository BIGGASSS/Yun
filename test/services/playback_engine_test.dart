import 'dart:async';
import 'dart:math' as math;

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
    'volume maps loudness percentages without activating audio focus',
    () async {
      await engine.initialize();
      expect(player.volumeCalls, isEmpty);
      for (final value in [100.0, 37.5, 0.0, 37.5]) {
        await engine.setVolume(value);
      }
      expect(player.volumeCalls, [
        100,
        closeTo(58.0978976016, 1e-8),
        0,
        closeTo(58.0978976016, 1e-8),
      ]);
      expect(player.state.volume, closeTo(58.0978976016, 1e-8));
      expect(player.plays, 0);
      expect(session.activations, isEmpty);
    },
  );

  test('each halving of loudness reduces mpv signal gain by 10 dB', () async {
    await engine.initialize();
    for (final entry in {
      100.0: 0.0,
      50.0: -10.0,
      25.0: -20.0,
      12.5: -30.0,
      6.25: -40.0,
    }.entries) {
      await engine.setVolume(entry.key);
      // Model mpv's native cubic amplitude curve, independently of our mapping.
      final amplitude = math.pow(player.state.volume / 100, 3);
      final decibels = 20 * math.log(amplitude) / math.ln10;
      expect(decibels, closeTo(entry.value, 1e-8));
    }
  });

  test('loudness mapping is bounded and strictly increasing', () async {
    await engine.initialize();
    var previous = -1.0;
    for (var i = 0; i <= 1000; i++) {
      await engine.setVolume(i / 10);
      final nativeVolume = player.state.volume;
      expect(nativeVolume, inInclusiveRange(0.0, 100.0));
      expect(nativeVolume, greaterThan(previous));
      previous = nativeVolume;
    }
    expect(player.volumeCalls.first, 0);
    expect(player.volumeCalls.last, 100);
  });

  test('volume clamps finite input and rejects nonfinite input', () async {
    await engine.initialize();
    await engine.setVolume(-20);
    await engine.setVolume(120);
    for (final value in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      await expectLater(engine.setVolume(value), throwsArgumentError);
    }
    expect(player.volumeCalls, [0, 100]);
  });

  test('volume failures propagate and later commands can retry', () async {
    await engine.initialize();
    player.failVolume = true;
    await expectLater(engine.setVolume(12), throwsStateError);
    expect(player.state.volume, 100);
    player.failVolume = false;
    await engine.setVolume(12);
    expect(player.volumeCalls, [
      closeTo(30.9160773467, 1e-8),
      closeTo(30.9160773467, 1e-8),
    ]);
    expect(player.state.volume, closeTo(30.9160773467, 1e-8));
  });

  test(
    'idle or disposed volume commands do not create a native player',
    () async {
      await engine.setVolume(25);
      expect(session.configurations, 0);
      expect(player.volumeCalls, isEmpty);
      await engine.initialize();
      await engine.dispose();
      await engine.setVolume(25);
      expect(player.volumeCalls, isEmpty);
    },
  );

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
  bool disposed = false, failVolume = false;
  final volumeCalls = <double>[];
  @override
  Future<void> setVolume(double volume) async {
    volumeCalls.add(volume);
    if (failVolume) throw StateError('Native volume failed');
    state = state.copyWith(volume: volume);
  }

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
