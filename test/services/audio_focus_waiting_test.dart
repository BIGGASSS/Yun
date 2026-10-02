import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:yun/core/app_controller.dart' show AppController;
import 'package:yun/core/playback_controller.dart';
import 'package:yun/models/models.dart' as yun;
import 'package:yun/services/android_audio_focus.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/playback_engine.dart';

import '../core/fakes.dart' show MemoryCredentials, FakeAdapter, jsonResponse;
import 'playback_engine_test.dart' show TestPlayer, TestSession, readNative;

const _deadline = Duration(seconds: 3);
const _localUri = '/cache/downloaded.audio';
const _start = Duration(seconds: 37);
const _track = yun.Track(
  id: 'downloaded',
  title: 'Downloaded',
  durationMs: 120000,
);

/// The bridge owns token filtering. This fake deliberately permits stale events
/// to additionally verify that explicit user intent wins inside the engine.
class _Focus implements AndroidAudioFocus {
  final events = StreamController<AndroidFocusChange>.broadcast(sync: true);
  AudioFocusRequestResult nextResult = AudioFocusRequestResult.delayed;
  FutureOr<AudioFocusRequestResult> Function()? onRequest;
  FutureOr<bool> Function()? onAbandon;
  int requests = 0, abandons = 0;
  bool disposed = false;

  @override
  Stream<AndroidFocusChange> get changes => events.stream;

  @override
  Future<AudioFocusRequestResult> request() async {
    requests++;
    return onRequest == null ? nextResult : await onRequest!();
  }

  @override
  Future<bool> abandon() async {
    abandons++;
    return onAbandon == null ? true : await onAbandon!();
  }

  void send(AndroidFocusChange change) {
    if (disposed) return;
    if (change == AndroidFocusChange.gain) {
      nextResult = AudioFocusRequestResult.granted;
    }
    events.add(change);
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await events.close();
  }
}

Future<void> _drain() async {
  // Flush asynchronous adapter continuations without real-time polling.
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late TestPlayer player;
  late TestSession session;
  late _Focus focus;
  late MediaKitEngine engine;
  late List<EngineState> states;
  late StreamSubscription<EngineState> subscription;

  setUp(() {
    player = TestPlayer();
    session = TestSession();
    focus = _Focus();
    engine = MediaKitEngine(
      createPlayer: () async => player,
      loadSession: () async => session,
      androidAudioFocus: true,
      focus: focus,
    );
    states = [];
    subscription = engine.states.listen(states.add);
  });

  tearDown(() async {
    await subscription.cancel();
    await engine.dispose().timeout(_deadline);
    await session.interruptions.close();
    await session.noisy.close();
  });

  Future<EngineState> nextPlaying() => engine.states
      .firstWhere((state) => state.playing && !state.waitingForAudio)
      .timeout(_deadline);

  PlaybackController controller({
    required Future<AudioSource> Function(yun.Track, bool) resolve,
  }) {
    final result = PlaybackController(
      engine: engine,
      enableSystemControls: false,
      resolveSource: resolve,
    );
    addTearDown(() async {
      await result.shutdown().timeout(_deadline);
      result.dispose();
    });
    return result;
  }

  test(
    'delayed local open waits, then GAIN opens original file and start',
    () async {
      await engine.open(_localUri, start: _start);
      expect(player.opens, 0);
      expect(focus.requests, 1);
      expect(focus.abandons, 0);
      expect(states.last.waitingForAudio, isTrue);
      expect(states.last.playing, isFalse);
      expect(states.last.buffering, isFalse);
      expect(states.last.position, _start);
      expect(states.where((state) => state.error != null), isEmpty);
      // The custom Android bridge must be the only owner of activation.
      expect(session.activations, isEmpty);

      final resumed = nextPlaying();
      focus.send(AndroidFocusChange.gain);
      await resumed;
      expect(player.opens, 1);
      expect(player.opened, _localUri);
      expect(player.media!.start, _start);
      expect(player.seeks, 0);
      expect(states.last.waitingForAudio, isFalse);
    },
  );

  test(
    'delayed network open retains upstream, auth headers and start on GAIN',
    () async {
      final requests = <HttpRequest>[];
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => upstream.close(force: true));
      upstream.listen((request) {
        requests.add(request);
        request.response.write('original audio');
        unawaited(request.response.close());
      });
      final uri = 'http://127.0.0.1:${upstream.port}/original?token=secret';
      await engine.open(
        uri,
        headers: {'Authorization': 'Bearer secret'},
        start: _start,
      );
      expect(player.opens, 0);
      expect(requests, isEmpty);
      expect(states.last.waitingForAudio, isTrue);

      final resumed = nextPlaying();
      focus.send(AndroidFocusChange.gain);
      await resumed;
      expect(player.opens, 1);
      expect(player.opened, isNot(uri));
      expect(player.media!.httpHeaders, isNull);
      expect(player.media!.start, _start);
      expect((await readNative(player.opened!)).body, 'original audio');
      expect(requests, hasLength(1));
      expect(requests.single.uri.path, '/original');
      expect(requests.single.uri.queryParameters['token'], 'secret');
      expect(requests.single.headers.value('authorization'), 'Bearer secret');
      expect(states.where((state) => state.error != null), isEmpty);
    },
  );

  for (final cancel in [false, true]) {
    test(
      'seek while waiting updates selected start (cancel and retry: $cancel)',
      () async {
        await engine.open(_localUri, start: _start);
        const target = Duration(seconds: 63);
        await engine.seek(target);
        expect(
          player.seeks,
          0,
          reason: 'Unopened selection cannot seek old native media',
        );
        expect(states.last.position, target);
        if (cancel) {
          await engine.pause();
          focus.nextResult = AudioFocusRequestResult.granted;
          await engine.play();
        } else {
          final resumed = nextPlaying();
          focus.send(AndroidFocusChange.gain);
          await resumed;
        }
        expect(player.opens, 1);
        expect(player.media!.start, target);
        expect(player.opened, _localUri);
        expect(states.last.waitingForAudio, isFalse);
      },
    );
  }

  test(
    'repeated Play while delayed never re-requests or polls focus',
    () async {
      await engine.open(_localUri);
      for (var attempt = 0; attempt < 5; attempt++) {
        await engine.play();
      }
      await _drain();
      expect(focus.requests, 1);
      expect(focus.abandons, 0);
      expect(player.opens, 0);
      expect(player.plays, 0);
      expect(states.last.waitingForAudio, isTrue);
    },
  );

  test(
    'FAILED is a typed denial, never pending, and later GAIN cannot start it',
    () async {
      focus.nextResult = AudioFocusRequestResult.failed;
      await expectLater(
        engine.open(_localUri),
        throwsA(isA<AudioFocusUnavailable>()),
      );
      expect(states.any((state) => state.waitingForAudio), isFalse);
      expect(focus.abandons, greaterThan(0));
      focus.send(AndroidFocusChange.gain);
      await _drain();
      expect(player.opens, 0);
      expect(player.plays, 0);
      expect(focus.requests, 1);
    },
  );

  for (final action in [
    'pause',
    'stop',
    'noisy',
    'dispose',
    'permanent loss',
  ]) {
    test('$action cancels a delayed open and rejects late GAIN', () async {
      await engine.open(_localUri, start: _start);
      expect(states.last.waitingForAudio, isTrue);
      switch (action) {
        case 'pause':
          await engine.pause();
        case 'stop':
          await engine.stop();
        case 'noisy':
          focus.send(AndroidFocusChange.noisy);
          await _drain();
        case 'dispose':
          await engine.dispose();
        case 'permanent loss':
          focus.send(AndroidFocusChange.loss);
          await _drain();
      }
      focus.send(AndroidFocusChange.gain);
      await _drain();
      expect(player.opens, 0);
      expect(player.plays, 0);
      expect(focus.requests, 1);
      expect(focus.abandons, greaterThan(0));
      if (action != 'dispose') {
        expect(states.last.waitingForAudio, isFalse);
        expect(states.last.playing, isFalse);
      }
    });
  }

  for (final action in [
    'pause',
    'stop',
    'noisy',
    'replace',
    'dispose',
    'permanent loss',
  ]) {
    for (final response in [
      AudioFocusRequestResult.granted,
      AudioFocusRequestResult.delayed,
    ]) {
      test(
        '$action while request settles rejects late $response and GAIN',
        () async {
          final entered = Completer<void>();
          final reply = Completer<AudioFocusRequestResult>();
          focus.onRequest = () {
            entered.complete();
            return reply.future;
          };
          addTearDown(() {
            if (!reply.isCompleted) reply.complete(response);
          });
          final opening = engine
              .open(_localUri, start: _start)
              .then<Object?>((_) => null, onError: (Object error) => error);
          await entered.future.timeout(_deadline);
          switch (action) {
            case 'pause':
              await engine.pause();
            case 'stop':
              await engine.stop();
            case 'noisy':
              focus.send(AndroidFocusChange.noisy);
              await _drain();
            case 'replace':
              await engine.open('/cache/replacement.audio', play: false);
            case 'dispose':
              await engine.dispose();
            case 'permanent loss':
              focus.send(AndroidFocusChange.loss);
              await _drain();
          }
          focus.send(AndroidFocusChange.gain);
          reply.complete(response);
          final failure = await opening.timeout(_deadline);
          await _drain();
          focus.send(AndroidFocusChange.gain);
          await _drain();
          expect(
            failure,
            action == 'permanent loss' ? isA<AudioFocusUnavailable>() : isNull,
          );
          expect(player.opens, action == 'replace' ? 1 : 0);
          expect(player.plays, 0);
          expect(focus.requests, 1);
          if (action != 'dispose') {
            expect(player.state.playing, isFalse);
            expect(states.any((state) => state.waitingForAudio), isFalse);
          }
        },
      );
    }
  }

  test('replacement discards delayed source, including a late GAIN', () async {
    await engine.open(_localUri, start: _start);
    await engine.open('/cache/replacement.audio', play: false);
    final requests = focus.requests;
    focus.send(AndroidFocusChange.gain);
    await _drain();
    expect(player.opens, 1);
    expect(player.opened, '/cache/replacement.audio');
    expect(player.state.playing, isFalse);
    expect(player.plays, 0);
    expect(focus.requests, requests);
    expect(states.last.waitingForAudio, isFalse);
  });

  for (final action in ['pause', 'noisy', 'permanent loss']) {
    test(
      '$action cancels waiting, then explicit Play uses same source and start',
      () async {
        await engine.open(_localUri, start: _start);
        switch (action) {
          case 'pause':
            await engine.pause();
          case 'noisy':
            focus.send(AndroidFocusChange.noisy);
            await _drain();
          case 'permanent loss':
            focus.send(AndroidFocusChange.loss);
            await _drain();
        }
        focus.nextResult = AudioFocusRequestResult.granted;
        await engine.play();
        expect(player.opens, 1);
        expect(player.opened, _localUri);
        expect(player.media!.start, _start);
        expect(player.state.playing, isTrue);
        expect(states.last.waitingForAudio, isFalse);
      },
    );
  }

  test('GAIN arriving before DELAYED request reply is not lost', () async {
    final entered = Completer<void>();
    final reply = Completer<AudioFocusRequestResult>();
    focus.onRequest = () {
      if (focus.requests == 1) {
        entered.complete();
        return reply.future;
      }
      return AudioFocusRequestResult.granted;
    };
    final opening = engine.open(_localUri, start: _start);
    await entered.future.timeout(_deadline);
    final resumed = nextPlaying();
    focus.send(AndroidFocusChange.gain);
    reply.complete(AudioFocusRequestResult.delayed);
    await opening.timeout(_deadline);
    await resumed;
    expect(player.opens, 1);
    expect(player.media!.start, _start);
    expect(states.last.waitingForAudio, isFalse);
  });

  test(
    'GAIN while interrupted native open settles never overlaps native opens',
    () async {
      focus.nextResult = AudioFocusRequestResult.granted;
      final entered = Completer<void>();
      final finish = Completer<void>();
      var activeOpens = 0, maxOpens = 0;
      player.onOpen = () async {
        activeOpens++;
        if (activeOpens > maxOpens) maxOpens = activeOpens;
        if (player.opens == 1) {
          entered.complete();
          await finish.future;
        }
        activeOpens--;
      };
      addTearDown(() {
        if (!finish.isCompleted) finish.complete();
      });
      final opening = engine.open(_localUri, start: _start);
      await entered.future.timeout(_deadline);
      focus.send(AndroidFocusChange.transientLoss);
      expect(states.last.waitingForAudio, isTrue);
      focus.send(AndroidFocusChange.gain);
      await _drain();
      expect(player.opens, 1);
      finish.complete();
      await opening.timeout(_deadline);
      await _drain();
      expect(maxOpens, 1);
      expect(player.state.playing, isTrue);
      expect(states.last.waitingForAudio, isFalse);
      expect(player.media!.start, _start);
    },
  );

  for (final action in ['pause', 'stop']) {
    test('$action wins over GAIN awaiting interrupted native open', () async {
      focus.nextResult = AudioFocusRequestResult.granted;
      final entered = Completer<void>();
      final finish = Completer<void>();
      player.onOpen = () {
        entered.complete();
        return finish.future;
      };
      addTearDown(() {
        if (!finish.isCompleted) finish.complete();
      });
      final opening = engine.open(_localUri);
      await entered.future.timeout(_deadline);
      focus.send(AndroidFocusChange.transientLoss);
      focus.send(AndroidFocusChange.gain);
      final cancelled = action == 'pause' ? engine.pause() : engine.stop();
      finish.complete();
      await Future.wait([opening, cancelled]).timeout(_deadline);
      await _drain();
      expect(player.opens, 1);
      expect(player.plays, 0);
      expect(player.state.playing, isFalse);
      expect(states.last.waitingForAudio, isFalse);
    });
  }

  test(
    'late GAIN cannot bypass pending abandon during explicit retry',
    () async {
      await engine.open(_localUri, start: _start);
      final entered = Completer<void>();
      final released = Completer<bool>();
      focus.onAbandon = () {
        if (!entered.isCompleted) entered.complete();
        return released.future;
      };
      addTearDown(() {
        if (!released.isCompleted) released.complete(true);
      });
      final pausing = engine.pause();
      await entered.future.timeout(_deadline);
      final retry = engine.play();
      focus.send(AndroidFocusChange.gain);
      await _drain();
      expect(focus.requests, 1);
      expect(player.opens, 0);
      released.complete(true);
      await Future.wait([pausing, retry]).timeout(_deadline);
      expect(focus.requests, 2);
      expect(player.opens, 1);
      expect(player.opened, _localUri);
      expect(player.media!.start, _start);
      expect(player.state.playing, isTrue);
    },
  );

  test(
    'pause cancels GAIN resume request and retry retains original selection',
    () async {
      await engine.open(_localUri, start: _start);
      final entered = Completer<void>();
      final reply = Completer<AudioFocusRequestResult>();
      focus.onRequest = () {
        if (focus.requests == 2) {
          entered.complete();
          return reply.future;
        }
        return AudioFocusRequestResult.granted;
      };
      focus.send(AndroidFocusChange.gain);
      await entered.future.timeout(_deadline);
      await engine.pause();
      reply.complete(AudioFocusRequestResult.granted);
      await _drain();
      expect(player.opens, 0);
      expect(player.plays, 0);
      await engine.play();
      expect(player.opens, 1);
      expect(player.media!.start, _start);
      expect(player.opened, _localUri);
    },
  );

  for (final gain in [false, true]) {
    test(
      'transient callback before FAILED reply cannot remain pending (gain: $gain)',
      () async {
        final entered = Completer<void>();
        final reply = Completer<AudioFocusRequestResult>();
        focus.onRequest = () {
          entered.complete();
          return reply.future;
        };
        final opening = engine.open(_localUri);
        final failed = expectLater(
          opening,
          throwsA(isA<AudioFocusUnavailable>()),
        );
        await entered.future.timeout(_deadline);
        focus.send(AndroidFocusChange.transientLoss);
        if (gain) focus.send(AndroidFocusChange.gain);
        reply.complete(AudioFocusRequestResult.failed);
        await failed.timeout(_deadline);
        focus.send(AndroidFocusChange.gain);
        await _drain();
        expect(states.last.waitingForAudio, isFalse);
        expect(player.opens, 0);
        expect(player.plays, 0);
        expect(focus.requests, 1);
      },
    );
  }

  test(
    'duplicate GAIN preserves resume waiting for original request to settle',
    () async {
      final entered = Completer<void>();
      final reply = Completer<AudioFocusRequestResult>();
      focus.onRequest = () {
        if (focus.requests == 1) {
          entered.complete();
          return reply.future;
        }
        return AudioFocusRequestResult.granted;
      };
      final opening = engine.open(_localUri, start: _start);
      await entered.future.timeout(_deadline);
      focus.send(AndroidFocusChange.transientLoss);
      final resumed = nextPlaying();
      focus.send(AndroidFocusChange.gain);
      focus.send(AndroidFocusChange.gain);
      reply.complete(AudioFocusRequestResult.delayed);
      await opening.timeout(_deadline);
      await resumed;
      expect(player.opens, 1);
      expect(player.media!.start, _start);
      expect(focus.abandons, 0);
      expect(states.last.waitingForAudio, isFalse);
    },
  );

  test('loaded playback transient loss waits without polling and resumes same position', () async {
    focus.nextResult = AudioFocusRequestResult.granted;
    await engine.open(_localUri);
    await engine.seek(_start);
    focus.send(AndroidFocusChange.transientLoss);
    await _drain();
    expect(player.state.playing, isFalse);
    expect(states.last.waitingForAudio, isTrue);
    final requests = focus.requests;
    final plays = player.plays;
    await engine.play();
    await engine.play();
    expect(focus.requests, requests);
    expect(focus.abandons, 0);
    final resumed = nextPlaying();
    focus.send(AndroidFocusChange.gain);
    await resumed;
    expect(player.opens, 1);
    expect(player.plays, plays + 1);
    expect(player.state.position, _start);
    expect(states.last.waitingForAudio, isFalse);
  });

  test(
    'Android noisy event pauses loaded playback and never auto-resumes',
    () async {
      focus.nextResult = AudioFocusRequestResult.granted;
      await engine.open(_localUri);
      await engine.seek(_start);
      expect(session.activations, isEmpty);
      expect(session.noisy.hasListener, isFalse);
      final plays = player.plays;
      focus.send(AndroidFocusChange.noisy);
      await _drain();
      expect(player.state.playing, isFalse);
      expect(states.last.waitingForAudio, isFalse);
      expect(focus.abandons, greaterThan(0));
      focus.send(AndroidFocusChange.gain);
      await _drain();
      expect(player.plays, plays);
      expect(player.state.position, _start);
      await engine.play();
      expect(player.state.playing, isTrue);
    },
  );

  for (final local in [true, false]) {
    test(
      'controller keeps ${local ? 'offline' : 'network'} selection through wait and GAIN',
      () async {
        var resolutions = 0;
        final playback = controller(
          resolve: (track, localFirst) async {
            expect(track.id, _track.id);
            expect(localFirst, isTrue);
            resolutions++;
            if (resolutions > 1) {
              throw StateError('Must not re-resolve while waiting');
            }
            return AudioSource(
              local ? _localUri : 'https://yun.test/audio?original',
              local: local,
              headers: local ? null : {'Authorization': 'Bearer original'},
            );
          },
        );
        await playback.playQueue([_track]);
        expect(playback.currentTrack, _track);
        expect(playback.isWaitingForAudio, isTrue);
        expect(playback.isPlaying, isFalse);
        expect(playback.error, isNull);
        expect(playback.localPlaybackError, isNull);
        expect(playback.audioFocusError, isNull);
        await playback.play();
        await playback.play();
        expect(resolutions, 1);
        expect(focus.requests, 1);
        final resumed = nextPlaying();
        focus.send(AndroidFocusChange.gain);
        await resumed;
        expect(resolutions, 1);
        expect(playback.isPlaying, isTrue);
        expect(playback.isWaitingForAudio, isFalse);
        expect(playback.error, isNull);
        expect(player.opens, 1);
        if (local) {
          expect(player.opened, _localUri);
        }
      },
    );
  }

  for (final action in ['pause', 'toggle', 'stop', 'shutdown']) {
    test('controller $action cancels waiting and ignores late GAIN', () async {
      var resolutions = 0;
      final playback = controller(
        resolve: (_, _) async {
          resolutions++;
          return const AudioSource(_localUri, local: true);
        },
      );
      await playback.playQueue([_track]);
      switch (action) {
        case 'pause':
          await playback.pause();
        case 'toggle':
          await playback.toggle();
        case 'stop':
        case 'account-switch stop':
          // AppController's account teardown drains this public stop boundary.
          await playback.stop();
        case 'shutdown':
          await playback.shutdown();
      }
      focus.send(AndroidFocusChange.gain);
      await _drain();
      expect(playback.isWaitingForAudio, isFalse);
      expect(playback.isPlaying, isFalse);
      expect(player.opens, 0);
      expect(player.plays, 0);
      expect(resolutions, 1);
      if (action != 'pause' && action != 'toggle') {
        expect(playback.currentTrack, isNull);
      }
    });
  }

  test(
    'controller pause then explicit retry preserves offline resolved file',
    () async {
      var resolutions = 0;
      final playback = controller(
        resolve: (_, _) async {
          resolutions++;
          if (resolutions > 1) {
            throw StateError('Offline source must be preserved');
          }
          return const AudioSource(_localUri, local: true);
        },
      );
      await playback.playQueue([_track]);
      await playback.pause();
      focus.nextResult = AudioFocusRequestResult.granted;
      await playback.play();
      expect(resolutions, 1);
      expect(player.opened, _localUri);
      expect(playback.isPlaying, isTrue);
      expect(playback.isWaitingForAudio, isFalse);
      expect(playback.localPlaybackError, isNull);
    },
  );

  for (final transition in ['logout', 'account switch']) {
    test(
      'AppController $transition cancels delayed downloaded audio',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'yun-focus-account-',
        );
        addTearDown(() => root.delete(recursive: true));
        const account = yun.Account(
          server: 'https://yun.test',
          userId: 'original',
          username: 'original',
        );
        final key = sha256
            .convert(utf8.encode(jsonEncode([account.server, account.userId])))
            .toString();
        final directory = await Directory(path.join(root.path, 'accounts', key))
            .create(recursive: true);
        final file = await File(path.join(directory.path, 'downloaded.audio'))
            .writeAsBytes([1, 2, 3]);
        final track = yun.Track(
          id: _track.id,
          title: _track.title,
          sizeBytes: 3,
          sha256: sha256.convert([1, 2, 3]).toString(),
        );
        final db = CacheDatabase(
          File(path.join(directory.path, 'cache.sqlite')),
        );
        await db.applyLibrary({
          'cursor': 1,
          'reset': true,
          'tracks': [track.toJson()],
        });
        await db.put('file', track.id, {
          'id': track.id,
          'path': file.path,
          'sha256': track.sha256,
        });
        await db.close();
        final credentials = MemoryCredentials();
        await credentials.write(
          ApiClient.sessionKey,
          jsonEncode(
            const SessionCredentials(
              account: account,
              accessToken: 'expired',
              refreshToken: 'refresh',
              expiresAt: 0,
            ).toJson(),
          ),
        );
        var requests = 0;
        final dio = Dio()
          ..httpClientAdapter = FakeAdapter((options, _) {
            requests++;
            if (options.path.endsWith('/auth/logout')) {
              return ResponseBody.fromString('', 204);
            }
            if (options.path.endsWith('/auth/login')) {
              return jsonResponse({
                'access_token': 'new',
                'refresh_token': 'new-refresh',
                'expires_at': DateTime.now().millisecondsSinceEpoch + 3600000,
                'user': {'id': 'other', 'username': 'other'},
              });
            }
            throw DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
            );
          });
        final app = AppController(
          api: ApiClient(dio: dio, credentials: credentials),
          storageDirectory: () async => root,
          playbackEngine: engine,
          automaticRefresh: false,
          enableSystemControls: false,
          listeningMonotonicMs: () => 0,
        );
        addTearDown(() async {
          await app.shutdown().timeout(_deadline);
          app.dispose();
        });
        await app.initialize();
        await app.play(app.tracks.single);
        expect(app.playback.isWaitingForAudio, isTrue);
        expect(app.playback.localPlaybackError, isNull);
        expect(app.downloadedTrackIds, {track.id});
        expect(
          requests,
          0,
          reason: 'Waiting for offline audio must not use network',
        );
        if (transition == 'logout') {
          await app.logout();
          expect(app.account, isNull);
        } else {
          await app.login(account.server, 'other', 'test-password');
          expect(app.account?.userId, 'other');
        }
        focus.send(AndroidFocusChange.gain);
        await _drain();
        expect(app.playback.currentTrack, isNull);
        expect(app.playback.isWaitingForAudio, isFalse);
        expect(app.playback.isPlaying, isFalse);
        expect(player.opens, 0);
        expect(player.plays, 0);
        expect(await file.exists(), isTrue);
      },
    );
  }
}
