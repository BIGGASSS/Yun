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
  late Directory root;
  late MemoryCredentials credentials;
  const account = Account(
    server: 'https://yun.test',
    userId: 'user',
    username: 'listener',
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('yun-account-test-');
    credentials = MemoryCredentials();
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  Future<Directory> seedAccount() async {
    final key = sha256
        .convert(utf8.encode(jsonEncode([account.server, account.userId])))
        .toString();
    final directory = Directory(p.join(root.path, 'accounts', key));
    await directory.create(recursive: true);
    final db = CacheDatabase(File(p.join(directory.path, 'cache.sqlite')));
    await db.applyLibrary({
      'cursor': 5,
      'reset': true,
      'tracks': [const Track(id: 't', title: 'Offline track').toJson()],
    });
    final file = await File(p.join(directory.path, 'offline.audio'))
        .writeAsBytes([1, 2, 3]);
    await db.put('file', 't', {'id': 't', 'path': file.path, 'sha256': ''});
    await db.put('event', 'pending', {'id': 'pending', 'track_id': 't'});
    await db.close();
    await credentials.write(
      ApiClient.sessionKey,
      jsonEncode(
        const SessionCredentials(
          account: account,
          accessToken: 'expired',
          refreshToken: 'r',
          expiresAt: 0,
        ).toJson(),
      ),
    );
    return directory;
  }

  test('expired offline session restores cache and plays without a network request', () async {
    await seedAccount();
    var requests = 0;
    final dio = Dio()
      ..httpClientAdapter = FakeAdapter((options, _) {
        requests++;
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      });
    final engine = FakeEngine();
    final app = AppController(
      api: ApiClient(dio: dio, credentials: credentials),
      storageDirectory: () async => root,
      playbackEngine: engine,
      enableSystemControls: false,
      automaticRefresh: false,
    );
    await app.initialize();
    expect(app.isAuthenticated, isTrue);
    expect(app.pendingEventCount, 1);
    expect(app.downloadedTrackIds, {'t'});
    await app.play(app.tracks.single);
    expect(engine.opened, app.localPath('t'));
    expect(requests, 0);
    await expectLater(app.refresh(), throwsA(isA<DioException>()));
    expect(app.isAuthenticated, isTrue);
    expect(app.isOffline, isTrue);
    expect(app.error, isNull);
    await app.logout();
    expect(app.localPath('t'), isNull);
    expect(app.tracks, isEmpty);
    expect(await credentials.read(ApiClient.sessionKey), isNull);
    await app.shutdown();
    app.dispose();
  });

  test('cleared Done entries stay cleared after restart and audio remains playable', () async {
    await seedAccount();
    var requests = 0;
    AppController create() => AppController(
      api: ApiClient(
        dio: Dio()
          ..httpClientAdapter = FakeAdapter((options, _) {
            requests++;
            throw DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
            );
          }),
        credentials: credentials,
      ),
      storageDirectory: () async => root,
      playbackEngine: FakeEngine(),
      enableSystemControls: false,
      automaticRefresh: false,
    );
    var app = create();
    await app.initialize();
    final path = app.localPath('t');
    expect(app.downloadProgress(app.tracks.single).historyCleared, isFalse);
    await app.clearDoneDownloads();
    expect(app.downloadProgress(app.tracks.single).historyCleared, isTrue);
    expect(app.downloadedTrackIds, {'t'});
    expect(await File(path!).readAsBytes(), [1, 2, 3]);
    await app.shutdown();
    app.dispose();

    app = create();
    await app.initialize();
    expect(app.downloadProgress(app.tracks.single).historyCleared, isTrue);
    expect(app.localPath('t'), path);
    await app.play(app.tracks.single);
    expect(app.playback.currentTrack?.id, 't');
    expect(requests, 0);
    await app.shutdown();
    app.dispose();
  });
  for (final type in [
    DioExceptionType.connectionError,
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
  ]) {
    test('$type stays quiet on repeated refreshes and recovers', () async {
      await seedAccount();
      Object? failure = DioException(
        requestOptions: RequestOptions(path: '/library'),
        type: type,
      );
      final dio = Dio()
        ..httpClientAdapter = FakeAdapter((options, _) {
          if (failure != null) throw failure;
          if (options.path.endsWith('/auth/refresh')) {
            return jsonResponse({
              'access_token': 'a',
              'refresh_token': 'r2',
              'expires_at': DateTime.now().millisecondsSinceEpoch + 3600000,
            });
          }
          if (options.path.endsWith('/listening-events')) {
            return jsonResponse({
              'acknowledged_ids': ['pending'],
            });
          }
          return jsonResponse({'cursor': 6, 'reset': false});
        });
      final app = AppController(
        api: ApiClient(dio: dio, credentials: credentials),
        storageDirectory: () async => root,
        playbackEngine: FakeEngine(),
        enableSystemControls: false,
        automaticRefresh: false,
      );
      try {
        await app.initialize();
        for (var i = 0; i < 3; i++) {
          await expectLater(app.refresh(), throwsA(same(failure)));
          expect(app.isOffline, isTrue);
          expect(app.error, isNull);
          expect(app.pendingEventCount, 1);
          expect(app.downloadedTrackIds, {'t'});
        }
        // A quiet network failure must not erase a different actionable error.
        app.error = 'Storage failure';
        await expectLater(app.refresh(), throwsA(same(failure)));
        expect(app.error, 'Storage failure');
        app.clearError();
        failure = null;
        await app.refresh();
        expect(app.isOffline, isFalse);
        expect(app.error, isNull);
        expect(app.pendingEventCount, 0);
      } finally {
        await app.shutdown();
        app.dispose();
      }
    });
  }

  test('actionable refresh failures still populate the error banner', () async {
    await seedAccount();
    late Object failure;
    final dio = Dio()..httpClientAdapter = FakeAdapter((_, _) => throw failure);
    final app = AppController(
      api: ApiClient(dio: dio, credentials: credentials),
      storageDirectory: () async => root,
      playbackEngine: FakeEngine(),
      enableSystemControls: false,
      automaticRefresh: false,
    );
    try {
      await app.initialize();
      final options = RequestOptions(path: '/auth/refresh');
      for (final value in [
        for (final status in [401, 500])
          DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: options, statusCode: status),
          ),
        DioException(
          requestOptions: options,
          type: DioExceptionType.badCertificate,
        ),
        StateError('Storage unavailable'),
      ]) {
        failure = value;
        app.clearError();
        await expectLater(app.refresh(), throwsA(isA<Exception>()));
        expect(app.error, isNotNull);
      }
    } finally {
      await app.shutdown();
      app.dispose();
    }
  });

  test(
    'outbox only drops acknowledged submitted IDs; library cursor is reused',
    () async {
      await seedAccount();
      await credentials.write(
        ApiClient.sessionKey,
        jsonEncode(
          SessionCredentials(
            account: account,
            accessToken: 'a',
            refreshToken: 'r',
            expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
          ).toJson(),
        ),
      );
      var eventRequests = 0;
      final dio = Dio()
        ..httpClientAdapter = FakeAdapter((options, body) {
          if (options.path.endsWith('/library')) {
            expect(options.queryParameters['cursor'], 5);
            return jsonResponse({
              'cursor': 6,
              'reset': false,
              'tracks': [],
              'playlists': [],
            });
          }
          if (options.path.endsWith('/listening-events')) {
            eventRequests++;
            return jsonResponse({
              'acknowledged_ids': eventRequests == 1
                  ? ['unsubmitted']
                  : ['pending'],
            });
          }
          throw StateError('unexpected ${options.path}');
        });
      final app = AppController(
        api: ApiClient(dio: dio, credentials: credentials),
        storageDirectory: () async => root,
        playbackEngine: FakeEngine(),
        enableSystemControls: false,
        automaticRefresh: false,
      );
      await app.initialize();
      await app.refresh();
      expect(app.pendingEventCount, 1);
      await app.flushOutbox();
      expect(app.pendingEventCount, 0);
      await app.shutdown();
      app.dispose();
    },
  );
  test(
    'logout retains account data and another user cannot access it',
    () async {
      final directory = await seedAccount();
      var user = 'other';
      final dio = Dio()
        ..httpClientAdapter = FakeAdapter((options, _) {
          if (options.path.endsWith('/auth/logout')) {
            return ResponseBody.fromString('', 204);
          }
          if (options.path.endsWith('/auth/login')) {
            return jsonResponse({
              'access_token': 'a',
              'refresh_token': 'r',
              'expires_at': DateTime.now().millisecondsSinceEpoch + 3600000,
              'user': {'id': user, 'username': user},
            });
          }
          if (options.path.endsWith('/library')) {
            throw DioException(
              requestOptions: options,
              type: DioExceptionType.connectionError,
            );
          }
          throw StateError('unexpected ${options.path}');
        });
      final app = AppController(
        api: ApiClient(dio: dio, credentials: credentials),
        storageDirectory: () async => root,
        playbackEngine: FakeEngine(),
        enableSystemControls: false,
        automaticRefresh: false,
      );
      await app.initialize();
      await app.logout();
      expect(
        await File(p.join(directory.path, 'offline.audio')).exists(),
        isTrue,
      );
      await app.login(account.server, 'other', 'password');
      expect(app.tracks, isEmpty);
      expect(app.downloadedTrackIds, isEmpty);
      expect(app.pendingEventCount, 0);
      user = 'user';
      await app.login(account.server, 'listener', 'password');
      expect(app.tracks.single.id, 't');
      expect(app.downloadedTrackIds, {'t'});
      expect(app.pendingEventCount, 1);
      await app.shutdown();
      app.dispose();
    },
  );
}
