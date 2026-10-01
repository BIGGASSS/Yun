import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:yun/core/playback_controller.dart';
import 'package:yun/models/models.dart' as yun;
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

  for (final scheme in ['http', 'https']) {
    test(
      '$scheme credentials and upstream URI never reach native open',
      () async {
        player.onOpen = () {
          expect(player.platform.properties['tls-verify'], 'yes');
          final uri = Uri.parse(player.opened!);
          expect(uri.scheme, 'http');
          expect(uri.host, InternetAddress.loopbackIPv4.address);
          expect(uri.userInfo, isEmpty);
          expect(uri.query, isEmpty);
          expect(player.media!.httpHeaders, isNull);
          expect(player.opened, isNot(contains('secret')));
          expect(player.opened, isNot(contains('yun.test')));
        };
        await engine.open(
          '$scheme://user:secret@yun.test/audio?token=secret',
          headers: {
            'Authorization': 'Bearer secret',
            'Cookie': 'session=secret',
          },
        );
        expect(player.opens, 1);
      },
    );
  }

  test(
    'fake native open reads authenticated range through real HTTP',
    () async {
      final requests = <HttpRequest>[];
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => upstream.close(force: true));
      upstream.listen((request) {
        requests.add(request);
        expect(request.uri.path, '/audio');
        expect(request.uri.queryParameters['token'], 'secret');
        expect(request.headers.value('authorization'), 'Bearer secret');
        expect(request.headers.value('cookie'), 'session=secret');
        expect(request.headers.value('range'), 'bytes=2-5');
        expect(request.headers.value('if-range'), '"version"');
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set('content-range', 'bytes 2-5/8');
        request.response.write('2345');
        unawaited(request.response.close());
      });
      var clients = 0;
      await engine.dispose();
      player = TestPlayer();
      engine = MediaKitEngine(
        createPlayer: () async => player,
        loadSession: () async => session,
        createHttpClient: () {
          clients++;
          return HttpClient(context: SecurityContext());
        },
      );
      player.onOpen = () async {
        expect(player.media!.httpHeaders, isNull);
        final response = await readNative(
          player.opened!,
          headers: {'Range': 'bytes=2-5', 'If-Range': '"version"'},
        );
        expect(response.status, HttpStatus.partialContent);
        expect(response.body, '2345');
        expect(response.range, 'bytes 2-5/8');
      };
      await engine.open(
        'http://127.0.0.1:${upstream.port}/audio?token=secret',
        headers: {'Authorization': 'Bearer secret', 'Cookie': 'session=secret'},
        start: const Duration(seconds: 12),
        play: false,
      );
      expect(requests, hasLength(1));
      expect(clients, 1);
      expect(player.media!.start, const Duration(seconds: 12));
      expect(player.state.playing, isFalse);
      expect(player.seeks, 0);
    },
  );

  test('pause, resume and seek preserve an established relay', () async {
    final upstream = await serveAudio();
    addTearDown(() => upstream.close(force: true));
    await engine.open('http://127.0.0.1:${upstream.port}/audio');
    final uri = player.opened!;
    await engine.pause();
    expect((await readNative(uri)).body, 'audio');
    await engine.play();
    await engine.seek(const Duration(seconds: 30));
    expect(player.opened, uri);
    expect((await readNative(uri)).body, 'audio');
    expect(player.seeks, 1);
    await engine.stop();
    await expectLater(readNative(uri), throwsA(isA<SocketException>()));
  });

  for (final action in ['stop', 'dispose', 'replace', 'failed open']) {
    test('$action closes the relay capability', () async {
      final upstream = await serveAudio();
      addTearDown(() => upstream.close(force: true));
      final source = 'http://127.0.0.1:${upstream.port}/audio';
      if (action == 'failed open') {
        player.onOpen = () => throw StateError('Open failed');
        await expectLater(engine.open(source), throwsStateError);
      } else {
        await engine.open(source);
      }
      final uri = player.opened!;
      switch (action) {
        case 'stop':
          await engine.stop();
        case 'dispose':
          await engine.dispose();
        case 'replace':
          await engine.open(source);
          expect(player.opened, isNot(uri));
          expect((await readNative(player.opened!)).body, 'audio');
        case 'failed open':
          break;
      }
      await expectLater(readNative(uri), throwsA(isA<SocketException>()));
    });
  }

  for (final action in ['pause', 'stop', 'dispose', 'replace']) {
    test('$action closes relay while native open is pending', () async {
      final upstream = await serveAudio();
      addTearDown(() => upstream.close(force: true));
      final entered = Completer<void>();
      final finish = Completer<void>();
      player.onOpen = () {
        entered.complete();
        return finish.future;
      };
      final opening = engine.open('http://127.0.0.1:${upstream.port}/audio');
      await entered.future;
      final uri = player.opened!;
      player.onOpen = null;
      switch (action) {
        case 'pause':
          await engine.pause();
        case 'stop':
          await engine.stop();
        case 'dispose':
          await engine.dispose();
        case 'replace':
          await engine.open('/cache/new.audio');
      }
      await expectLater(readNative(uri), throwsA(isA<SocketException>()));
      finish.complete();
      await opening;
    });

    test(
      '$action cancels open awaiting focus without stale relay errors',
      () async {
        final states = <EngineState>[];
        final subscription = engine.states.listen(states.add);
        addTearDown(subscription.cancel);
        final focused = Completer<void>();
        session.activation = Completer<bool>();
        session.onActivate = () => focused.complete();
        final opening = engine.open(
          'https://user:secret@yun.test/audio?secret',
        );
        await focused.future;
        session.onActivate = null;
        switch (action) {
          case 'pause':
            await engine.pause();
          case 'stop':
            await engine.stop();
          case 'dispose':
            await engine.dispose();
          case 'replace':
            await engine.open('/cache/new.audio', play: false);
        }
        session.activation!.complete(true);
        await opening;
        expect(player.opens, action == 'replace' ? 1 : 0);
        expect(states.where((state) => state.error != null), isEmpty);
      },
    );
  }

  test('focus denial closes pending relay and allows another open', () async {
    session.activation = Completer<bool>()..complete(false);
    await expectLater(engine.open('https://yun.test/audio'), throwsStateError);
    expect(player.opens, 0);
    session.activation = null;
    await engine.open('/cache/new.audio');
    expect(player.opens, 1);
  });

  test('relay errors are sanitized and scoped to the current source', () async {
    await engine.dispose();
    player = TestPlayer();
    engine = MediaKitEngine(
      createPlayer: () async => player,
      loadSession: () async => session,
      createHttpClient: () =>
          throw const HttpException('secret upstream credentials'),
    );
    final errors = <String>[];
    final subscription = engine.states.listen((state) {
      if (state.error != null) errors.add(state.error!);
    });
    addTearDown(subscription.cancel);
    await engine.open('https://user:secret@yun.test/audio?token=secret');
    await readNative(player.opened!);
    expect(errors, ['Unable to load audio from the server.']);
    expect(errors.single, isNot(contains('secret')));
    await engine.open('/cache/local.audio');
    await Future<void>.delayed(Duration.zero);
    expect(errors, hasLength(1));
  });

  test('switching cancels in-flight HTTP without stale errors', () async {
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));
    final received = Completer<HttpRequest>();
    upstream.listen(received.complete);
    final errors = <String>[];
    final subscription = engine.states.listen((state) {
      if (state.error != null) errors.add(state.error!);
    });
    addTearDown(subscription.cancel);
    await engine.open('http://127.0.0.1:${upstream.port}/secret');
    final reading = readNative(player.opened!);
    // Cancellation can close HTTP before its response headers arrive.
    final cancelled = expectLater(reading, throwsA(isA<HttpException>()));
    await received.future;
    await engine.open('/cache/local.audio');
    await cancelled;
    await Future<void>.delayed(Duration.zero);
    expect(errors, isEmpty);
  });

  test('pause/stop/dispose safely cancel binds before native open', () async {
    for (final cancel in ['pause', 'stop', 'dispose']) {
      for (var ticks = 0; ticks < 5; ticks++) {
        final candidatePlayer = TestPlayer();
        final candidateSession = TestSession()..activation = Completer<bool>();
        final candidate = MediaKitEngine(
          createPlayer: () async => candidatePlayer,
          loadSession: () async => candidateSession,
        );
        await candidate.initialize();
        final opening = candidate.open('https://yun.test/audio');
        for (var i = 0; i < ticks; i++) {
          await Future<void>.value();
        }
        switch (cancel) {
          case 'pause':
            await candidate.pause();
          case 'stop':
            await candidate.stop();
          case 'dispose':
            await candidate.dispose();
        }
        candidateSession.activation!.complete(true);
        await opening;
        expect(candidatePlayer.opens, 0);
        await candidate.dispose();
        await candidateSession.interruptions.close();
        await candidateSession.noisy.close();
      }
    }
  });

  for (final path in [
    '/cache/audio',
    'file:///cache/audio',
    'content://audio/1',
  ]) {
    test('local source $path is passed through unchanged', () async {
      await engine.open(path, start: const Duration(seconds: 7), play: false);
      expect(player.opened, Media(path).uri);
      expect(player.media!.start, const Duration(seconds: 7));
      expect(player.state.playing, isFalse);
    });
  }

  test(
    'TLS configuration failure blocks open, disposes and permits retry',
    () async {
      player.platform.rejectTls = true;
      await expectLater(
        engine.open(
          'https://yun.test/audio',
          headers: {'Authorization': 'Bearer secret'},
        ),
        throwsStateError,
      );
      expect(player.opens, 0);
      expect(player.disposed, isTrue);
      expect(session.configurations, 0);
      player = TestPlayer();
      await engine.open('https://yun.test/audio');
      expect(player.opens, 1);
      expect(player.platform.properties['tls-verify'], 'yes');
    },
  );

  test(
    'paused open supplies load-time position without focus or seek',
    () async {
      await engine.open(
        'https://yun.test/audio',
        play: false,
        start: const Duration(seconds: 42),
      );
      expect(player.media!.start, const Duration(seconds: 42));
      expect(player.state.playing, isFalse);
      expect(player.seeks, 0);
      expect(session.activations, [false]);
      await engine.open('/cache/next.audio');
      expect(player.media!.start, Duration.zero);
      expect(player.state.playing, isTrue);
    },
  );

  for (final uri in ['/cache/download.audio', 'file:///cache/download.audio']) {
    test(
      'local $uri survives TCP diagnostics before the first audio tick',
      () async {
        var remoteResolutions = 0;
        final playback = PlaybackController(
          engine: engine,
          enableSystemControls: false,
          resolveSource: (_, localFirst) async {
            if (!localFirst) {
              remoteResolutions++;
              throw StateError('Internet unavailable');
            }
            return AudioSource(uri, local: true);
          },
        );
        addTearDown(() async {
          await playback.shutdown();
          playback.dispose();
        });
        player.onOpen = () {
          player.stream.errors.add('tcp: Connection to server failed');
        };
        await playback.playQueue([
          const yun.Track(id: 'local', title: 'Local'),
        ]);
        expect(playback.isPlaying, isTrue);
        expect(playback.currentTrack?.id, 'local');
        expect(playback.error, isNull);
        expect(player.opens, 1);
        expect(remoteResolutions, 0);
      },
    );
  }

  test(
    'late TCP diagnostics after switching to local audio do not stop it',
    () async {
      final playback = PlaybackController(
        engine: engine,
        enableSystemControls: false,
        resolveSource: (track, _) async => track.id == 'remote'
            ? const AudioSource('https://yun.test/audio')
            : const AudioSource('/cache/download.audio', local: true),
      );
      addTearDown(() async {
        await playback.shutdown();
        playback.dispose();
      });
      await playback.playQueue([
        const yun.Track(id: 'remote', title: 'Remote'),
      ]);
      await playback.playQueue([const yun.Track(id: 'local', title: 'Local')]);
      final stops = player.stops;
      player.stream.errors.add('tcp: Connection reset by peer');
      await Future<void>.delayed(Duration.zero);
      expect(player.opens, 2);
      expect(player.stops, stops);
      expect(playback.currentTrack?.id, 'local');
      expect(playback.isPlaying, isTrue);
      expect(playback.error, isNull);
    },
  );

  test(
    'TCP diagnostics during local audio focus acquisition do not fail open',
    () async {
      var remoteResolutions = 0;
      final playback = PlaybackController(
        engine: engine,
        enableSystemControls: false,
        resolveSource: (_, localFirst) async {
          if (!localFirst) {
            remoteResolutions++;
            throw StateError('Internet unavailable');
          }
          return const AudioSource('/cache/download.audio', local: true);
        },
      );
      addTearDown(() async {
        await playback.shutdown();
        playback.dispose();
      });
      session.activation = Completer<bool>();
      final opening = playback.playQueue([
        const yun.Track(id: 'local', title: 'Local'),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(session.activations.last, isTrue);
      player.stream.errors.add('tcp: Connection reset by peer');
      session.activation!.complete(true);
      await opening;
      expect(remoteResolutions, 0);
      expect(player.opens, 1);
      expect(playback.isPlaying, isTrue);
      expect(playback.error, isNull);
    },
  );

  test('Play resolves and reopens after native open fails', () async {
    var resolutions = 0;
    final playback = PlaybackController(
      engine: engine,
      enableSystemControls: false,
      resolveSource: (_, _) async {
        resolutions++;
        return const AudioSource('https://yun.test/audio');
      },
    );
    addTearDown(() async {
      await playback.shutdown();
      playback.dispose();
    });
    player.onOpen = () => throw StateError('Open failed');
    await expectLater(
      playback.playQueue([const yun.Track(id: 'a', title: 'A')]),
      throwsStateError,
    );
    expect(playback.error, contains('Open failed'));
    player.onOpen = null;
    await playback.play();
    expect(resolutions, 2);
    expect(player.opens, 2);
    expect(playback.isPlaying, isTrue);
    expect(playback.error, isNull);
  });

  test('local file and decoder errors still reach playback recovery', () async {
    final playback = PlaybackController(
      engine: engine,
      enableSystemControls: false,
      resolveSource: (_, localFirst) async => localFirst
          ? const AudioSource('/cache/download.audio', local: true)
          : const AudioSource('https://yun.test/audio'),
    );
    addTearDown(() async {
      await playback.shutdown();
      playback.dispose();
    });
    await playback.playQueue([const yun.Track(id: 'local', title: 'Local')]);
    player.stream.errors.add('Failed to decode audio');
    await playback.flushSettings();
    expect(player.opens, 2);
    expect(Uri.parse(player.opened!).host, '127.0.0.1');
    expect(player.media!.httpHeaders, isNull);
    expect(playback.isPlaying, isTrue);
  });

  test(
    'TCP diagnostics remain errors for remote audio after a local source',
    () async {
      final states = <EngineState>[];
      final subscription = engine.states.listen(states.add);
      addTearDown(subscription.cancel);
      await engine.open('/cache/download.audio');
      await engine.stop();
      player.stream.errors.add('tcp: Connection timed out after stop');
      expect(states.last.error, 'tcp: Connection timed out after stop');
      await engine.open('https://yun.test/audio');
      player.stream.errors.add('tcp: Connection timed out');
      expect(states.last.error, 'tcp: Connection timed out');
    },
  );

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

Future<HttpServer> serveAudio() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) {
    request.response.write('audio');
    unawaited(request.response.close());
  });
  return server;
}

Future<({int status, String body, String? range})> readNative(
  String uri, {
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final request = await client.getUrl(Uri.parse(uri));
    headers.forEach(request.headers.set);
    final response = await request.close().timeout(const Duration(seconds: 2));
    final body = await response.transform(utf8.decoder).join();
    return (
      status: response.statusCode,
      body: body,
      range: response.headers.value('content-range'),
    );
  } finally {
    client.close(force: true);
  }
}

class TestPlayer implements Player {
  @override
  final TestNativePlayer platform = TestNativePlayer();
  Media? media;
  int seeks = 0;
  @override
  PlayerState state = const PlayerState();
  @override
  final TestPlayerStream stream = TestPlayerStream();
  int plays = 0, opens = 0, stops = 0;
  String? opened;
  FutureOr<void> Function()? onOpen;
  bool disposed = false, failVolume = false;
  final volumeCalls = <double>[];
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    media = playable as Media;
    opened = media!.uri;
    opens++;
    await onOpen?.call();
    if (disposed) return;
    state = state.copyWith(
      playing: play,
      duration: const Duration(seconds: 120),
    );
    stream.playingEvents.add(play);
  }

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
    stream.playingEvents.add(true);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    stream.playingEvents.add(false);
  }

  @override
  Future<void> stop() async {
    stops++;
    await pause();
  }

  @override
  Future<void> seek(Duration position) async {
    seeks++;
    state = state.copyWith(position: position);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await stream.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestNativePlayer implements NativePlayer {
  final properties = <String, String>{};
  bool rejectTls = false;

  @override
  Future<void> setProperty(
    String property,
    String value, {
    bool waitForInitialization = true,
  }) async {
    if (!rejectTls) properties[property] = value;
  }

  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async => properties[property] ?? '';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestPlayerStream implements PlayerStream {
  final playingEvents = StreamController<bool>.broadcast(sync: true);
  final errors = StreamController<String>.broadcast(sync: true);
  Future<void> close() async {
    await playingEvents.close();
    await errors.close();
  }

  @override
  Stream<bool> get playing => playingEvents.stream;
  @override
  Stream<bool> get buffering => const Stream.empty();
  @override
  Stream<bool> get completed => const Stream.empty();
  @override
  Stream<Duration> get position => const Stream.empty();
  @override
  Stream<Duration> get duration => const Stream.empty();
  @override
  Stream<String> get error => errors.stream;
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
  void Function()? onActivate;
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
    if (active) onActivate?.call();
    return active && activation != null ? activation!.future : true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
