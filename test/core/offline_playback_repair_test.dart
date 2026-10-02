import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yun/core/app_controller.dart';
import 'package:yun/core/playback_controller.dart' show LocalAudioUnavailable;
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/playback_engine.dart';

import 'fakes.dart';

class _ReplacingFileDatabase extends CacheDatabase {
  _ReplacingFileDatabase(super.file);
  Future<void> Function()? beforeTransaction;

  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) async {
    final replacement = beforeTransaction;
    beforeTransaction = null;
    await replacement?.call();
    return super.transaction(action, requireNew: requireNew);
  }
}

void main() {
  const account = Account(
    server: 'https://yun.test',
    userId: 'a',
    username: 'listener',
  );
  const bytes = [1, 2, 3, 4];
  late Directory root;
  late File audio;
  late MemoryCredentials credentials;
  late Dio dio;
  late AppController app;
  late FakeEngine engine;
  late Track track;
  var requests = 0;

  Future<void> openApp({CacheDatabase Function(File)? databaseFactory}) async {
    engine = FakeEngine();
    app = AppController(
      api: ApiClient(dio: dio, credentials: credentials),
      storageDirectory: () async => root,
      databaseFactory: databaseFactory,
      playbackEngine: engine,
      enableSystemControls: false,
      automaticRefresh: false,
    );
    await app.initialize();
  }

  Future<void> closeApp() async {
    await app.shutdown();
    app.dispose();
  }

  Future<void> seed({
    bool file = true,
    bool completed = true,
    bool pinned = true,
  }) async {
    final key = sha256
        .convert(utf8.encode(jsonEncode([account.server, account.userId])))
        .toString();
    final directory = Directory(p.join(root.path, 'accounts', key));
    await directory.create(recursive: true);
    final db = CacheDatabase(File(p.join(directory.path, 'cache.sqlite')));
    await db.put('track', track.id, track.toJson());
    if (pinned) {
      await db.put(
        'pin',
        jsonEncode(['album', albumPinId('Album', 'Artist')]),
        PinSelection('album', albumPinId('Album', 'Artist')).toJson(),
      );
    }
    audio = File(p.join(directory.path, 'cached.audio'));
    if (file) {
      await audio.writeAsBytes(bytes);
      await db.put('file', track.id, {
        'id': track.id,
        'path': audio.path,
        'sha256': track.sha256,
      });
    }
    await db.put(
      'download',
      track.id,
      DownloadProgress(
        trackId: track.id,
        totalBytes: track.sizeBytes,
        status: completed ? DownloadStatus.downloaded : DownloadStatus.queued,
        historyCleared: completed,
      ).toJson(),
    );
    await db.close();
    await credentials.write(
      ApiClient.sessionKey,
      jsonEncode(
        SessionCredentials(
          account: account,
          accessToken: 'access',
          refreshToken: 'refresh',
          expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
        ).toJson(),
      ),
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yun-offline-repair-');
    credentials = MemoryCredentials();
    track = Track(
      id: 't',
      title: 'Downloaded track',
      artist: 'Artist',
      album: 'Album',
      sizeBytes: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    );
    requests = 0;
    dio = Dio()
      ..httpClientAdapter = FakeAdapter((options, _) {
        requests++;
        throw StateError('Unexpected network request ${options.path}');
      });
  });

  tearDown(() async {
    await closeApp();
    await root.delete(recursive: true);
  });

  test(
    'missing downloaded audio stays offline on repeated Play and restart',
    () async {
      await seed();
      await openApp();
      await audio.delete();
      await expectLater(app.play(track), throwsA(isA<LocalAudioUnavailable>()));
      expect(
        app.playback.localPlaybackError,
        contains('missing or unavailable'),
      );
      expect(app.localPath(track.id), isNull);
      expect(app.downloadProgress(track).repairRequired, isTrue);
      await expectLater(
        app.playback.play(),
        throwsA(isA<LocalAudioUnavailable>()),
      );
      await expectLater(app.play(track), throwsA(isA<LocalAudioUnavailable>()));
      await app.retryDownloads();
      expect(engine.opens, 0);
      expect(requests, 0);
      await closeApp();
      await openApp();
      expect(app.downloadProgress(track).repairRequired, isTrue);
      await expectLater(app.play(track), throwsA(isA<LocalAudioUnavailable>()));
      expect(app.playback.localPlaybackError, isNotNull);
      expect(engine.opens, 0);
      expect(requests, 0);
    },
  );

  test(
    'a verified replacement winning the missing-file race plays locally',
    () async {
      await seed();
      late _ReplacingFileDatabase db;
      await openApp(
        databaseFactory: (file) => db = _ReplacingFileDatabase(file),
      );
      await audio.delete();
      final replacement = File('${audio.path}.replacement');
      db.beforeTransaction = () async {
        await replacement.writeAsBytes(bytes);
        await db.put('file', track.id, {
          'id': track.id,
          'path': replacement.path,
          'sha256': track.sha256,
        });
      };
      await app.play(track);
      expect(engine.opened, replacement.path);
      expect(app.playback.localPlaybackError, isNull);
      expect(app.downloadProgress(track).repairRequired, isFalse);
      expect(requests, 0);
    },
  );

  test(
    'missing record retains completed intent even with cleared activity',
    () async {
      await seed(file: false);
      await openApp();
      await expectLater(app.play(track), throwsA(isA<LocalAudioUnavailable>()));
      await expectLater(
        app.playback.play(),
        throwsA(isA<LocalAudioUnavailable>()),
      );
      expect(app.playback.localPlaybackError, isNotNull);
      expect(app.downloadProgress(track).status, DownloadStatus.failed);
      expect(engine.opens, 0);
      expect(requests, 0);
    },
  );

  test('queued first download remains a genuinely online track', () async {
    await seed(file: false, completed: false);
    await openApp();
    await app.play(track);
    expect(engine.opened, 'https://yun.test/api/v1/tracks/t/audio');
    expect(app.playback.localPlaybackError, isNull);
    expect(requests, 0);
  });

  test(
    'manual verification hold cannot silently stream an unselected download',
    () async {
      await seed(pinned: false);
      await openApp();
      await audio.writeAsBytes(bytes.reversed.toList());
      await app.verifyDownloads();
      expect(app.downloadProgress(track).repairRequired, isTrue);
      await expectLater(app.play(track), throwsA(isA<LocalAudioUnavailable>()));
      await expectLater(
        app.playback.play(),
        throwsA(isA<LocalAudioUnavailable>()),
      );
      expect(app.playback.localPlaybackError, contains('failed verification'));
      expect(requests, 0);
      expect(engine.opens, 0);
    },
  );

  test(
    'decoder error keeps bytes and requires an explicit verified redownload',
    () async {
      await seed();
      await openApp();
      await app.play(track);
      engine.emit(const EngineState(error: 'decoder could not read packet'));
      await app.playback.flushSettings();
      expect(
        app.playback.localPlaybackError,
        contains('decoder could not read packet'),
      );
      expect(await audio.readAsBytes(), bytes);
      expect(requests, 0);
      final downloaded = Completer<void>();
      final release = Completer<void>();
      dio.httpClientAdapter = FakeAdapter((options, _) async {
        requests++;
        expect(options.path, endsWith('/tracks/t/audio'));
        expect(await audio.readAsBytes(), bytes);
        downloaded.complete();
        await release.future;
        return ResponseBody.fromBytes(bytes, 200);
      });
      final first = app.redownloadTrack(track);
      final second = app.redownloadTrack(track);
      await downloaded.future;
      expect(app.isRedownloadingTrack(track.id), isTrue);
      expect(app.playback.isPlaying, isFalse);
      // During repair, even an explicit Play cannot turn into streaming.
      await expectLater(
        app.playback.play(),
        throwsA(isA<LocalAudioUnavailable>()),
      );
      expect(engine.opens, 1);
      release.complete();
      await Future.wait([first, second]);
      expect(requests, 1);
      expect(app.isRedownloadingTrack(track.id), isFalse);
      expect(app.pins, hasLength(1));
      expect(app.pins.single.type, 'album');
      expect(app.playback.isPlaying, isFalse);
      expect(engine.opens, 1);
      expect(app.downloadProgress(track).status, DownloadStatus.downloaded);
      await app.playback.play();
      expect(engine.opens, 2);
      expect(engine.opened, app.localPath(track.id));
      expect(app.playback.localPlaybackError, isNull);
    },
  );

  test('repair completion cannot interrupt a newer online track', () async {
    await seed(file: false);
    await openApp();
    final requested = Completer<void>(), release = Completer<void>();
    dio.httpClientAdapter = FakeAdapter((options, _) async {
      requests++;
      requested.complete();
      await release.future;
      return ResponseBody.fromBytes(bytes, 200);
    });
    final repair = app.redownloadTrack(track);
    try {
      await requested.future;
      const next = Track(id: 'online', title: 'Online track');
      await app.play(next, queue: [next]);
      expect(engine.opened, 'https://yun.test/api/v1/tracks/online/audio');
      expect(app.playback.isPlaying, isTrue);
      release.complete();
      await repair;
      expect(app.playback.currentTrack?.id, 'online');
      expect(app.playback.isPlaying, isTrue);
      expect(engine.opens, 1);
      expect(requests, 1);
    } finally {
      if (!release.isCompleted) release.complete();
      await repair;
    }
  });

  test(
    'failed explicit repair remains offline through repeated Play and restart',
    () async {
      await seed(file: false, pinned: false);
      await openApp();
      dio.httpClientAdapter = FakeAdapter((options, _) {
        requests++;
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      });
      await expectLater(app.redownloadTrack(track), throwsStateError);
      expect(requests, 1);
      expect(app.isRedownloadingTrack(track.id), isFalse);
      expect(app.pins.single.type, 'track');
      expect(app.downloadProgress(track).requiresOfflinePlayback, isTrue);
      await expectLater(app.play(track), throwsA(isA<LocalAudioUnavailable>()));
      await expectLater(
        app.playback.play(),
        throwsA(isA<LocalAudioUnavailable>()),
      );
      expect(engine.opens, 0);
      expect(requests, 1);
      await closeApp();
      await openApp();
      await expectLater(app.play(track), throwsA(isA<LocalAudioUnavailable>()));
      expect(engine.opens, 0);
      expect(requests, 1);
      dio.httpClientAdapter = FakeAdapter((options, _) {
        requests++;
        return ResponseBody.fromBytes(bytes, 200);
      });
      await app.redownloadTrack(track);
      expect(requests, 2);
      expect(engine.opens, 0);
      await app.playback.play();
      expect(engine.opened, app.localPath(track.id));
    },
  );
}
