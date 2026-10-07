import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yun/core/app_controller.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';

import 'fakes.dart';

void main() {
  late Directory root, accountDirectory;
  late Dio dio;
  late AppController app;
  late Track track;
  const account = Account(
    server: 'https://yun.test',
    userId: 'user',
    username: 'listener',
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yun-download-errors-');
    final key = sha256
        .convert(utf8.encode(jsonEncode([account.server, account.userId])))
        .toString();
    accountDirectory = Directory(p.join(root.path, 'accounts', key));
    await accountDirectory.create(recursive: true);
    track = Track(
      id: 't',
      title: 'Pinned track',
      sizeBytes: 3,
      sha256: sha256.convert([1, 2, 3]).toString(),
    );
    final db = CacheDatabase(
      File(p.join(accountDirectory.path, 'cache.sqlite')),
    );
    try {
      await db.applyLibrary({
        'cursor': 5,
        'reset': true,
        'tracks': [track.toJson()],
      });
    } finally {
      await db.close();
    }
    final credentials = MemoryCredentials();
    await credentials.write(
      ApiClient.sessionKey,
      jsonEncode(
        SessionCredentials(
          account: account,
          accessToken: 'original',
          refreshToken: 'r',
          // A download, not proactive token refresh, must produce the error.
          expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
        ).toJson(),
      ),
    );
    dio = Dio()
      ..httpClientAdapter = FakeAdapter((options, _) {
        fail('Unexpected request: ${options.path}');
      });
    // Custom Dio selects the inline receiver's shared processing path. Do not
    // inject DownloadReceiveException: real Dio/file failures must be converted.
    app = AppController(
      api: ApiClient(dio: dio, credentials: credentials),
      storageDirectory: () async => root,
      playbackEngine: FakeEngine(),
      enableSystemControls: false,
      automaticRefresh: false,
    );
    await app.initialize();
    expect(app.isOffline, isFalse);
    expect(app.error, isNull);
  });

  tearDown(() async {
    await app.shutdown();
    app.dispose();
    dio.close(force: true);
    await root.delete(recursive: true);
  });

  Future<void> pinAndWaitForError() async {
    final reported = Completer<void>();
    void listener() {
      // Download progress is published before the background error callback.
      // Wait for the app-level notification to observe the classification too.
      if (app.downloadProgress(track).status == DownloadStatus.failed &&
          !reported.isCompleted) {
        reported.complete();
      }
    }

    app.addListener(listener);
    try {
      await app.pinTrack(track.id);
      await reported.future.timeout(const Duration(seconds: 5));
    } finally {
      app.removeListener(listener);
    }
    expect(app.isAuthenticated, isTrue);
    expect(app.isPinned('track', track.id), isTrue);
    expect(app.localPath(track.id), isNull);
    expect(app.downloadedTrackIds, isEmpty);
    expect(app.downloadProgress(track).status, DownloadStatus.failed);
  }

  for (final type in [
    DioExceptionType.connectionError,
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
  ]) {
    test('download $type marks offline without an error banner', () async {
      var requests = 0;
      dio.httpClientAdapter = FakeAdapter((options, _) {
        expect(options.path, endsWith('/tracks/t/audio'));
        requests++;
        throw DioException(requestOptions: options, type: type);
      });

      await pinAndWaitForError();
      expect(requests, 1);
      expect(app.isOffline, isTrue);
      expect(app.error, isNull);
      expect(app.downloadProgress(track).error, 'Download connection failed');

      // Quiet background failures must not erase another actionable banner.
      app.error = 'Existing storage error';
      await app.retryDownloads();
      expect(requests, 2);
      expect(app.isOffline, isTrue);
      expect(app.error, 'Existing storage error');
    });
  }

  test(
    'download 401 refreshes once, then reports offline and a banner',
    () async {
      var refreshes = 0;
      final authorization = <Object?>[];
      dio.httpClientAdapter = FakeAdapter((options, _) {
        if (options.path.endsWith('/auth/refresh')) {
          refreshes++;
          return jsonResponse({
            'access_token': 'rotated',
            'refresh_token': 'r2',
            'expires_at': DateTime.now().millisecondsSinceEpoch + 3600000,
          });
        }
        expect(options.path, endsWith('/tracks/t/audio'));
        authorization.add(options.headers['Authorization']);
        return jsonResponse({'error': 'unauthorized'}, status: 401);
      });

      await pinAndWaitForError();
      expect(refreshes, 1);
      expect(authorization, ['Bearer original', 'Bearer rotated']);
      expect(app.isOffline, isTrue);
      expect(app.error, 'Unexpected download status 401');
      expect(app.downloadProgress(track).error, app.error);
    },
  );

  test(
    'download 500 reports a banner without marking offline or refreshing',
    () async {
      var requests = 0;
      dio.httpClientAdapter = FakeAdapter((options, _) {
        expect(options.path, endsWith('/tracks/t/audio'));
        requests++;
        return jsonResponse({'error': 'server failure'}, status: 500);
      });

      await pinAndWaitForError();
      expect(requests, 1);
      expect(app.isOffline, isFalse);
      expect(app.error, 'Unexpected download status 500');
      expect(app.downloadProgress(track).error, app.error);
    },
  );

  test(
    'receiver write failure reports a banner without marking offline',
    () async {
      dio.httpClientAdapter = FakeAdapter((options, _) async {
        expect(options.path, endsWith('/tracks/t/audio'));
        // Sabotage the output after resume metadata has been read, so the real
        // receiver's File.open fails (also works when tests run as root).
        await Directory(p.join(accountDirectory.path, 'audio', 't.audio.part'))
            .create();
        return ResponseBody.fromBytes([1, 2, 3], 200);
      });

      await pinAndWaitForError();
      expect(app.isOffline, isFalse);
      expect(app.error, 'Could not write downloaded audio');
      expect(app.downloadProgress(track).error, app.error);
    },
  );

  test('receiver checksum identity failure reports a banner without marking offline', () async {
    dio.httpClientAdapter = FakeAdapter((options, _) {
      expect(options.path, endsWith('/tracks/t/audio'));
      return ResponseBody.fromBytes(
        [1, 2, 3],
        200,
        headers: {
          'etag': ['"different-checksum"'],
        },
      );
    });

    await pinAndWaitForError();
    expect(app.isOffline, isFalse);
    expect(app.error, 'Audio checksum identity changed; refresh library');
    expect(app.downloadProgress(track).error, app.error);
  });

  test(
    'download checksum mismatch reports a banner without marking offline',
    () async {
      dio.httpClientAdapter = FakeAdapter((options, _) {
        expect(options.path, endsWith('/tracks/t/audio'));
        return ResponseBody.fromBytes([3, 2, 1], 200);
      });

      await pinAndWaitForError();
      expect(app.isOffline, isFalse);
      expect(app.error, contains('Downloaded audio checksum mismatch'));
      expect(app.downloadProgress(track).error, app.error);
    },
  );
}
