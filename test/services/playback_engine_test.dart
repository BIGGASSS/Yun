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
      androidAudioFocus: true,
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
    await expectLater(
      engine.open('https://yun.test/audio'),
      throwsA(isA<AudioFocusUnavailable>()),
    );
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
    'retired relay failed-open errors do not stop a new local source',
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
      final retired = player.opened!;
      final diagnostic = 'Failed to open $retired.';
      player.onOpen = () => player.stream.errors.add(diagnostic);
      await playback.playQueue([const yun.Track(id: 'local', title: 'Local')]);
      final stops = player.stops;
      player.stream.errors.add(diagnostic);
      await Future<void>.delayed(Duration.zero);
      expect(player.opens, 2);
      expect(player.stops, stops);
      expect(playback.currentTrack?.id, 'local');
      expect(playback.isPlaying, isTrue);
      expect(playback.error, isNull);
    },
  );

  test('only the current relay owns explicit failed-open errors', () async {
    final errors = <String>[];
    final subscription = engine.states.listen((state) {
      if (state.error != null) errors.add(state.error!);
    });
    addTearDown(subscription.cancel);
    await engine.open('https://yun.test/old');
    final retired = player.opened!;
    await engine.open('https://yun.test/new');
    for (final diagnostic in [
      'Failed to open $retired.',
      'cplayer: Failed to open "$retired".\n',
    ]) {
      player.stream.errors.add(diagnostic);
    }
    expect(errors, isEmpty);
    final currentError = 'Failed to open ${player.opened}.';
    player.stream.errors.add(currentError);
    player.stream.errors.add('Failed to decode audio');
    player.stream.errors.add('Failed to open audio output device');
    expect(errors, [
      currentError,
      'Failed to decode audio',
      'Failed to open audio output device',
    ]);
  });

  for (final oldUri in [
    '/cache/old.audio',
    'file:///cache/old%20track.audio',
    "/cache/old's track.audio.",
  ]) {
    test('known retired local path is isolated exactly: $oldUri', () async {
      final errors = <String>[];
      final subscription = engine.states.listen((state) {
        if (state.error != null) errors.add(state.error!);
      });
      addTearDown(subscription.cancel);
      await engine.open(oldUri);
      final retired = player.opened!;
      final oldErrors = [
        'Failed to open $retired.',
        "Cannot open file '$retired': No such file or directory",
      ];
      await engine.stop();
      player.onOpen = () => oldErrors.forEach(player.stream.errors.add);
      await engine.open('/cache/current.audio');
      oldErrors.forEach(player.stream.errors.add);
      expect(errors, isEmpty);

      // Neither a current failure nor an unfamiliar dependency path may be
      // hidden just because an earlier local source was retired.
      final current = player.opened!;
      final currentErrors = [
        'Failed to open $current.',
        "Cannot open file '$current': Permission denied",
        'Failed to open /cache/unknown.audio.',
        "Cannot open file '$retired': nested.audio': Permission denied",
        'Failed to decode current audio',
      ];
      currentErrors.forEach(player.stream.errors.add);
      expect(errors, currentErrors);

      // Selecting the same path again makes its errors current, even if it
      // also occurs in the retirement history.
      player.onOpen = null;
      await engine.open(oldUri);
      await engine.stop();
      await engine.open(oldUri);
      errors.clear();
      oldErrors.forEach(player.stream.errors.add);
      expect(errors, oldErrors);
    });
  }

  test('preparing a replacement does not own old native errors', () async {
    final errors = <String>[];
    final subscription = engine.states.listen((state) {
      if (state.error != null) errors.add(state.error!);
    });
    addTearDown(subscription.cancel);
    await engine.open('https://yun.test/old');
    final retired = player.opened!;
    session.activation = Completer<bool>();
    final focused = Completer<void>();
    session.onActivate = focused.complete;
    final opening = engine.open('/cache/download.audio');
    await focused.future;
    player.stream.errors.add('tcp: Connection reset by peer');
    player.stream.errors.add('Failed to open $retired.');
    player.stream.errors.add('Failed to decode retired audio');
    expect(errors, isEmpty);
    session.activation!.complete(true);
    await opening;
    player.stream.errors.add('Failed to decode current audio');
    expect(errors, ['Failed to decode current audio']);
  });

  for (final diagnostic in [
    'Failed to open /cache/download.audio.',
    'Failed to open file:///cache/download.audio.',
    'Failed to decode audio',
    'Audio output device failed',
  ]) {
    test(
      'current local error is preserved before first tick: $diagnostic',
      () async {
        final errors = <String>[];
        final subscription = engine.states.listen((state) {
          if (state.error != null) errors.add(state.error!);
        });
        addTearDown(subscription.cancel);
        player.onOpen = () => player.stream.errors.add(diagnostic);
        await engine.open('/cache/download.audio');
        expect(errors, [diagnostic]);
        player.stream.errors.add(diagnostic);
        expect(errors, [diagnostic, diagnostic]);
      },
    );
  }

  test('failed open releases native error ownership', () async {
    final errors = <String>[];
    final subscription = engine.states.listen((state) {
      if (state.error != null) errors.add(state.error!);
    });
    addTearDown(subscription.cancel);
    player.onOpen = () => throw StateError('Open failed');
    await expectLater(engine.open('/cache/failed.audio'), throwsStateError);
    player.stream.errors.add('Failed to decode retired audio');
    expect(errors, isEmpty);
    player.onOpen = null;
    await engine.open('/cache/next.audio');
    player.stream.errors.add('Failed to decode current audio');
    expect(errors, ['Failed to decode current audio']);
  });

  test('pausing a pending local open preserves its error ownership', () async {
    final errors = <String>[];
    final subscription = engine.states.listen((state) {
      if (state.error != null) errors.add(state.error!);
    });
    addTearDown(subscription.cancel);
    final entered = Completer<void>();
    final finish = Completer<void>();
    player.onOpen = () {
      entered.complete();
      return finish.future;
    };
    final opening = engine.open('/cache/download.audio');
    await entered.future;
    await engine.pause();
    finish.complete();
    await opening;
    await engine.play();
    player.stream.errors.add('Failed to decode current audio');
    expect(errors, ['Failed to decode current audio']);
  });

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

  test('local decoder failure is reported without a remote fallback', () async {
    var remoteResolutions = 0;
    final playback = PlaybackController(
      engine: engine,
      enableSystemControls: false,
      resolveSource: (_, localFirst) async {
        if (!localFirst) {
          remoteResolutions++;
          return const AudioSource('https://yun.test/audio');
        }
        return const AudioSource('/cache/download.audio', local: true);
      },
    );
    addTearDown(() async {
      await playback.shutdown();
      playback.dispose();
    });
    await playback.playQueue([const yun.Track(id: 'local', title: 'Local')]);
    player.stream.errors.add('Failed to decode audio');
    await playback.flushSettings();
    expect(player.opens, 1);
    expect(remoteResolutions, 0);
    expect(playback.isPlaying, isFalse);
    expect(playback.error, contains('Failed to decode audio'));
  });

  test(
    'TCP diagnostics remain errors for remote audio after a local source',
    () async {
      final errors = <String>[];
      final subscription = engine.states.listen((state) {
        if (state.error != null) errors.add(state.error!);
      });
      addTearDown(subscription.cancel);
      await engine.open('/cache/download.audio');
      await engine.stop();
      player.stream.errors.add('tcp: Connection timed out after stop');
      expect(errors, isEmpty);
      await engine.open('https://yun.test/audio');
      player.stream.errors.add('tcp: Connection timed out');
      expect(errors, ['tcp: Connection timed out']);
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

  test('transient interruption keeps registration and waits for delayed pause before resume', () async {
    await engine.open('/cache/valid.audio');
    final paused = Completer<void>();
    player.onPause = () => paused.future;
    session.interruptions.add(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    session.interruptions.add(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    await Future<void>.delayed(Duration.zero);
    expect(session.activations, [true]);
    expect(player.plays, 0);
    paused.complete();
    await Future<void>.delayed(Duration.zero);
    expect(player.plays, 1);
    expect(player.state.playing, isTrue);
    expect(session.active, isTrue);
    expect(session.activations, [true, true]);
  });

  test(
    'explicit Play cannot use cached focus during a transient interruption',
    () async {
      await engine.open('/cache/valid.audio');
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await Future<void>.delayed(Duration.zero);
      await engine.play();
      expect(player.plays, 0);
      expect(player.state.playing, isFalse);
      expect(session.activations, [true]);
    },
  );

  for (final action in ['pause', 'stop']) {
    test(
      'new Play waits for delayed $action and obsolete cleanup cannot release its focus',
      () async {
        await engine.open('/cache/valid.audio');
        final halted = Completer<void>();
        player.onPause = () => halted.future;
        final halting = action == 'pause' ? engine.pause() : engine.stop();
        // Let Stop submit its native command before the new user intent.
        await Future<void>.delayed(Duration.zero);
        final playing = engine.play();
        await Future<void>.delayed(Duration.zero);
        expect(player.plays, 0);
        halted.complete();
        await Future.wait([halting, playing]);
        expect(player.state.playing, isTrue);
        expect(session.active, isTrue);
        expect(session.activations.last, isTrue);
      },
    );
  }

  test('new Play waits for focus release already in flight', () async {
    await engine.open('/cache/valid.audio');
    final releasing = Completer<void>();
    final released = Completer<void>();
    session.onSetActive = (active) async {
      if (!active) {
        if (!releasing.isCompleted) releasing.complete();
        await released.future;
      }
      return true;
    };
    final pausing = engine.pause();
    await releasing.future;
    final playing = engine.play();
    await Future<void>.delayed(Duration.zero);
    expect(session.activations, [true, false]);
    expect(player.plays, 0);
    released.complete();
    await Future.wait([pausing, playing]);
    expect(session.activations, [true, false, true]);
    expect(session.active, isTrue);
    expect(player.state.playing, isTrue);
  });

  test(
    'denied Android-style cached focus request is cleared before retry',
    () async {
      var cached = false, requests = 0;
      session.onSetActive = (active) {
        if (!active) {
          cached = false;
          return true;
        }
        if (cached) return true;
        cached = true;
        requests++;
        return requests > 1;
      };
      await expectLater(
        engine.open('/cache/valid.audio'),
        throwsA(isA<AudioFocusUnavailable>()),
      );
      expect(player.opens, 0);
      expect(cached, isFalse);
      expect(session.active, isFalse);
      await engine.open('/cache/valid.audio');
      expect(requests, 2);
      expect(player.opens, 1);
      expect(player.state.playing, isTrue);
      expect(session.active, isTrue);
    },
  );

  for (final path in ['/cache/valid.audio', 'https://yun.test/audio']) {
    test(
      'interruption before native submission waits and gain opens $path',
      () async {
        final states = <EngineState>[];
        final subscription = engine.states.listen(states.add);
        addTearDown(subscription.cancel);
        session.activation = Completer<bool>();
        final activating = Completer<void>();
        session.onActivate = () {
          if (!activating.isCompleted) activating.complete();
        };
        final opening = engine.open(path, start: const Duration(seconds: 19));
        await activating.future;
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        session.activation!.complete(true);
        await opening;
        expect(player.opens, 0);
        expect(session.active, isTrue);
        expect(states.last.waitingForAudio, isTrue);
        expect(states.last.position, const Duration(seconds: 19));
        expect(states.where((state) => state.error != null), isEmpty);
        session.activation = null;
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(player.opens, 1);
        expect(player.media!.start, const Duration(seconds: 19));
        expect(player.state.playing, isTrue);
        expect(states.last.waitingForAudio, isFalse);
      },
    );
  }

  test(
    'automatic resume denial keeps typed focus metadata in engine state',
    () async {
      await engine.open('/cache/valid.audio');
      final states = <EngineState>[];
      final subscription = engine.states.listen(states.add);
      addTearDown(subscription.cancel);
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await Future<void>.delayed(Duration.zero);
      session.activation = Completer<bool>()..complete(false);
      session.interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await Future<void>.delayed(Duration.zero);
      final failure = states.singleWhere((state) => state.audioFocusFailure);
      expect(failure.error, const AudioFocusUnavailable().message);
      expect(failure.error, isNot(contains('Bad state')));
      expect(player.plays, 0);
      expect(session.active, isFalse);
    },
  );

  for (final action in ['pause', 'stop']) {
    test('failed native $action still releases focus', () async {
      await engine.open('/cache/valid.audio');
      player.onPause = () => throw StateError('Native pause failed');
      await expectLater(
        action == 'pause' ? engine.pause() : engine.stop(),
        throwsStateError,
      );
      expect(session.active, isFalse);
      expect(session.activations.last, isFalse);
      player.onPause = null;
      await engine.play();
      expect(session.active, isTrue);
      expect(player.state.playing, isTrue);
    });
  }

  test(
    'failed native open releases acquired focus before a later retry',
    () async {
      player.onOpen = () => throw StateError('Native open failed');
      await expectLater(engine.open('/cache/valid.audio'), throwsStateError);
      expect(session.active, isFalse);
      expect(session.activations.last, isFalse);
      player.onOpen = null;
      await engine.open('/cache/valid.audio');
      expect(session.active, isTrue);
      expect(player.state.playing, isTrue);
    },
  );

  test('controller resumes the selected local source after interrupted initial focus', () async {
    final controller = PlaybackController(
      engine: engine,
      enableSystemControls: false,
      resolveSource: (_, _) async =>
          const AudioSource('/cache/valid.audio', local: true),
    );
    addTearDown(() async {
      await controller.shutdown();
      controller.dispose();
    });
    session.activation = Completer<bool>();
    final activating = Completer<void>();
    session.onActivate = () {
      if (!activating.isCompleted) activating.complete();
    };
    final opening = controller.playQueue([
      const yun.Track(id: 'valid', title: 'Valid'),
    ]);
    await activating.future;
    session.interruptions.add(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    session.activation!.complete(true);
    await opening;
    expect(player.opens, 0);
    expect(controller.isWaitingForAudio, isTrue);
    expect(controller.audioFocusError, isNull);
    expect(controller.localPlaybackError, isNull);
    session.activation = null;
    session.interruptions.add(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.isWaitingForAudio, isFalse);
    expect(player.opens, 1);
    expect(player.opened, '/cache/valid.audio');
    expect(controller.isPlaying, isTrue);
    expect(controller.error, isNull);
  });

  test(
    'permanent loss releases the request and explicit Play asks the OS again',
    () async {
      var cached = false, requests = 0;
      session.onSetActive = (active) {
        if (!active) {
          cached = false;
          return true;
        }
        if (cached) return true;
        cached = true;
        requests++;
        return requests == 1;
      };
      await engine.open('/cache/valid.audio');
      final paused = Completer<void>();
      player.onPause = () => paused.future;
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      );
      // Even an explicit retry before native pause settles must make a fresh
      // request, not rely on audio_session's stale registration cache.
      final retry = engine.play();
      final denied = expectLater(retry, throwsA(isA<AudioFocusUnavailable>()));
      paused.complete();
      await denied;
      expect(requests, 2);
      expect(player.plays, 0);
      expect(player.state.playing, isFalse);
      expect(cached, isFalse);
      session.interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await Future<void>.delayed(Duration.zero);
      expect(player.plays, 0);
    },
  );

  test(
    'focus release failure preserves typed denial and must clear before retry',
    () async {
      var rejectRelease = true, cached = false, requests = 0;
      session.onSetActive = (active) {
        if (!active) {
          if (rejectRelease) throw StateError('Focus release failed');
          cached = false;
          return true;
        }
        if (cached) return true;
        cached = true;
        requests++;
        return requests > 1;
      };
      await expectLater(
        engine.open('/cache/valid.audio'),
        throwsA(isA<AudioFocusUnavailable>()),
      );
      expect(player.opens, 0);
      expect(cached, isTrue);
      await expectLater(
        engine.open('/cache/valid.audio'),
        throwsA(isA<AudioFocusUnavailable>()),
      );
      expect(player.opens, 0);
      expect(requests, 1);
      rejectRelease = false;
      await engine.open('/cache/valid.audio');
      expect(requests, 2);
      expect(player.opens, 1);
      expect(session.active, isTrue);
    },
  );

  test(
    'interrupted pre-open retains registration instead of releasing it',
    () async {
      final activating = Completer<void>();
      final grant = Completer<bool>();
      var rejectRelease = true;
      session.onSetActive = (active) async {
        if (active) {
          if (!activating.isCompleted) activating.complete();
          return grant.future;
        }
        if (rejectRelease) throw StateError('Focus release failed');
        return true;
      };
      final opening = engine.open('/cache/valid.audio');
      await activating.future;
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      grant.complete(true);
      await opening;
      expect(player.opens, 0);
      expect(session.activations, [true]);
      rejectRelease = false;
      await engine.pause();
      expect(session.activations, [true, false]);
    },
  );

  for (final action in ['pause', 'stop', 'noisy']) {
    test(
      'interruption during delayed explicit $action cannot re-arm auto-resume',
      () async {
        await engine.open('/cache/valid.audio');
        final paused = Completer<void>();
        player.onPause = () => paused.future;
        final halting = action == 'pause'
            ? engine.pause()
            : action == 'stop'
            ? engine.stop()
            : Future<void>.sync(() => session.noisy.add(null));
        session.interruptions.add(
          AudioInterruptionEvent(true, AudioInterruptionType.pause),
        );
        session.interruptions.add(
          AudioInterruptionEvent(false, AudioInterruptionType.pause),
        );
        paused.complete();
        await halting;
        await Future<void>.delayed(Duration.zero);
        expect(player.plays, 0);
        expect(player.state.playing, isFalse);
        expect(session.active, isFalse);
        if (action == 'stop') expect(player.stops, 1);
      },
    );
  }

  test('Apple unknown interruption begin still honors resumable end', () async {
    await engine.dispose();
    player = TestPlayer();
    engine = MediaKitEngine(
      createPlayer: () async => player,
      loadSession: () async => session,
      androidAudioFocus: false,
    );
    await engine.open('/cache/valid.audio');
    session.interruptions.add(
      AudioInterruptionEvent(true, AudioInterruptionType.unknown),
    );
    await Future<void>.delayed(Duration.zero);
    expect(player.state.playing, isFalse);
    expect(session.activations, [true]);
    session.interruptions.add(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    await Future<void>.delayed(Duration.zero);
    expect(player.plays, 1);
    expect(player.state.playing, isTrue);
  });

  test('unsuccessful release stays focus-typed and blocks cached activation until cleared', () async {
    await engine.open('/cache/valid.audio');
    var allowRelease = false;
    session.onSetActive = (active) => active || allowRelease;
    await expectLater(engine.pause(), throwsA(isA<AudioFocusUnavailable>()));
    final requestsBefore = session.activations.where((active) => active).length;
    await expectLater(engine.play(), throwsA(isA<AudioFocusUnavailable>()));
    expect(
      session.activations.where((active) => active).length,
      requestsBefore,
    );
    expect(player.plays, 0);
    allowRelease = true;
    await engine.play();
    expect(player.plays, 1);
    expect(session.active, isTrue);
  });

  test(
    'new open waiting for a failed release receives focus-typed failure',
    () async {
      await engine.open('/cache/valid.audio');
      final releasing = Completer<void>();
      final release = Completer<bool>();
      session.onSetActive = (active) {
        if (active) return true;
        if (!releasing.isCompleted) releasing.complete();
        return release.future;
      };
      final pausing = engine.pause();
      final pauseFailed = expectLater(
        pausing,
        throwsA(isA<AudioFocusUnavailable>()),
      );
      await releasing.future;
      final opening = engine.open('/cache/next.audio');
      final openFailed = expectLater(
        opening,
        throwsA(isA<AudioFocusUnavailable>()),
      );
      release.completeError(StateError('Focus release failed'));
      await Future.wait([pauseFailed, openFailed]);
      expect(player.opens, 1);
      session.onSetActive = null;
    },
  );

  for (final action in ['pause', 'stop']) {
    test(
      'failed native $action remains the original cause if focus cleanup also fails',
      () async {
        await engine.open('/cache/valid.audio');
        player.onPause = () => throw StateError('Native pause failed');
        session.onSetActive = (active) {
          if (!active) throw StateError('Focus release failed');
          return true;
        };
        await expectLater(
          action == 'pause' ? engine.pause() : engine.stop(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'Native pause failed',
            ),
          ),
        );
        player.onPause = null;
        session.onSetActive = null;
      },
    );
  }

  test(
    'activation platform failure is focus-typed and cannot open native audio',
    () async {
      session.onSetActive = (active) {
        if (active) throw StateError('OS activation failed');
        return true;
      };
      await expectLater(
        engine.open('/cache/valid.audio'),
        throwsA(isA<AudioFocusUnavailable>()),
      );
      expect(player.opens, 0);
      expect(session.active, isFalse);
      session.onSetActive = null;
      await engine.open('/cache/valid.audio');
      expect(player.opens, 1);
    },
  );

  test(
    'late focus grant after dispose is released through its captured session',
    () async {
      session.activation = Completer<bool>();
      final activating = Completer<void>();
      session.onActivate = activating.complete;
      final opening = engine.open('/cache/valid.audio');
      await activating.future;
      await engine.dispose();
      expect(session.active, isFalse);
      session.activation!.complete(true);
      await opening;
      expect(player.opens, 0);
      expect(session.active, isFalse);
      expect(session.activations, [true, false, false]);
    },
  );

  test(
    'obsolete automatic-resume denial cannot publish an error for newer Play',
    () async {
      await engine.open('/cache/valid.audio');
      final states = <EngineState>[];
      final subscription = engine.states.listen(states.add);
      addTearDown(subscription.cancel);
      session.interruptions.add(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await Future<void>.delayed(Duration.zero);
      final releasing = Completer<void>();
      final released = Completer<bool>();
      var requests = 0;
      session.onSetActive = (active) {
        if (active) return ++requests > 1;
        if (!releasing.isCompleted) releasing.complete();
        return released.future;
      };
      session.interruptions.add(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      await releasing.future;
      final playing = engine.play();
      released.complete(true);
      await playing;
      await Future<void>.delayed(Duration.zero);
      expect(player.plays, 1);
      expect(player.state.playing, isTrue);
      expect(session.active, isTrue);
      expect(states.where((state) => state.error != null), isEmpty);
      session.onSetActive = null;
    },
  );

  test('dispose still destroys native player and retries release after a pending halt fails', () async {
    await engine.open('/cache/valid.audio');
    final releasing = Completer<void>();
    final release = Completer<bool>();
    var releases = 0;
    session.onSetActive = (active) {
      if (active || ++releases > 1) return true;
      releasing.complete();
      return release.future;
    };
    final pausing = engine.pause();
    final pauseFailed = expectLater(
      pausing,
      throwsA(isA<AudioFocusUnavailable>()),
    );
    await releasing.future;
    final disposing = engine.dispose();
    final disposeFailed = expectLater(
      disposing,
      throwsA(isA<AudioFocusUnavailable>()),
    );
    await Future<void>.delayed(Duration.zero);
    release.completeError(StateError('Focus release failed'));
    await Future.wait([pauseFailed, disposeFailed]);
    expect(player.disposed, isTrue);
    expect(session.active, isFalse);
    expect(releases, 2);
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
  FutureOr<void> Function()? onOpen, onPause, onStop;
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
    if (onPause != null) await onPause!();
    state = state.copyWith(playing: false);
    stream.playingEvents.add(false);
  }

  @override
  Future<void> stop() async {
    stops++;
    if (onStop != null) await onStop!();
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
  FutureOr<bool> Function(bool)? onSetActive;
  bool active = false;
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
    final accepted = onSetActive != null
        ? await onSetActive!(active)
        : active && activation != null
        ? await activation!.future
        : true;
    if (accepted) this.active = active;
    return accepted;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
