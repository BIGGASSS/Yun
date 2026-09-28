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
  late MemoryCredentials credentials;
  late Dio dio;
  late AppController app;
  const account = Account(
    server: 'https://yun.test',
    userId: 'user',
    username: 'listener',
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('yun-app-upload-test-');
    final key = sha256
        .convert(utf8.encode(jsonEncode([account.server, account.userId])))
        .toString();
    accountDirectory = Directory(p.join(root.path, 'accounts', key));
    credentials = MemoryCredentials();
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
    dio = Dio()
      ..httpClientAdapter = FakeAdapter((options, _) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      });
    app = AppController(
      api: ApiClient(dio: dio, credentials: credentials),
      storageDirectory: () async => root,
      playbackEngine: FakeEngine(),
      enableSystemControls: false,
      automaticRefresh: false,
    );
    await app.initialize();
  });
  tearDown(() async {
    await app.shutdown();
    app.dispose();
    await root.delete(recursive: true);
  });

  test(
    'concurrent offline imports stay local without unlocking online mutations',
    () async {
      await expectLater(app.refresh(), throwsA(isA<DioException>()));
      expect(app.isOffline, isTrue);
      var requests = 0;
      dio.httpClientAdapter = FakeAdapter((options, _) {
        requests++;
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      });
      final original = await File(p.join(root.path, 'picked.wav'))
          .writeAsBytes([1, 2, 3]);
      await Future.wait(
        List.generate(3, (_) => app.enqueueUpload(original.path)),
      );
      expect(app.uploads, hasLength(3));
      expect(app.uploads.map((job) => job.localPath).toSet(), hasLength(3));
      expect(
        app.uploads.every(
          (job) => job.ownedSource && job.filename == 'picked.wav',
        ),
        isTrue,
      );
      expect(app.isOffline, isTrue);
      expect(requests, 0);
      await original.delete();
      for (final job in app.uploads) {
        expect(await File(job.localPath).readAsBytes(), [1, 2, 3]);
      }
      // An online mutation is still attempted, not queued or silently accepted.
      await expectLater(
        app.createPlaylist('Online only'),
        throwsA(isA<DioException>()),
      );
      expect(requests, 1);
      expect(app.playlists, isEmpty);
      await app.cancelUpload(app.uploads.first.id);
      expect(app.isOffline, isTrue);
      expect(requests, 1);
      expect(
        (await Directory(p.join(accountDirectory.path, 'imports'))
            .list()
            .toList()),
        hasLength(2),
      );
    },
  );

  test(
    'logout awaits an in-flight picker copy and isolates the next account',
    () async {
      // Keep the test independent of upload networking.
      await expectLater(app.refresh(), throwsA(isA<DioException>()));
      final original = File(p.join(root.path, 'large.wav'));
      final handle = await original.open(mode: FileMode.write);
      await handle.truncate(32 * 1024 * 1024);
      await handle.close();
      final copying = app.enqueueUpload(original.path);
      final failure = expectLater(copying, throwsStateError);
      final imports = Directory(p.join(accountDirectory.path, 'imports'));
      while (!(await imports.list().toList()).any(
        (f) => f.path.endsWith('.part'),
      )) {
        await Future<void>.delayed(Duration.zero);
      }
      await app.logout();
      await failure;
      expect(app.uploads, isEmpty);
      expect(await imports.list().toList(), isEmpty);
      expect(await original.exists(), isTrue);
      final oldDb = CacheDatabase(
        File(p.join(accountDirectory.path, 'cache.sqlite')),
      );
      expect(await oldDb.list('upload'), isEmpty);
      await oldDb.close();
      dio.httpClientAdapter = FakeAdapter((options, _) {
        if (options.path.endsWith('/auth/login')) {
          return jsonResponse({
            'access_token': 'new',
            'refresh_token': 'r',
            'expires_at': DateTime.now().millisecondsSinceEpoch + 3600000,
            'user': {'id': 'other', 'username': 'other'},
          });
        }
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      });
      await app.login(account.server, 'other', 'password');
      expect(app.account!.userId, 'other');
      expect(app.uploads, isEmpty);
      final small = await File(p.join(root.path, 'other.wav'))
          .writeAsBytes([4, 5]);
      await app.enqueueUpload(small.path);
      expect(app.uploads, hasLength(1));
      expect(
        p.isWithin(accountDirectory.path, app.uploads.single.localPath),
        isFalse,
      );
      expect(await imports.list().toList(), isEmpty);
    },
  );

  test(
    'account reopen collects abandoned spool files but retains failed uploads',
    () async {
      await expectLater(app.refresh(), throwsA(isA<DioException>()));
      final original = await File(p.join(root.path, 'picked.wav'))
          .writeAsBytes([1, 2, 3]);
      await app.enqueueUpload(original.path);
      final job = app.uploads.single;
      await app.shutdown();
      final db = CacheDatabase(
        File(p.join(accountDirectory.path, 'cache.sqlite')),
      );
      await db.put('upload', job.id, job.copyWith(status: 'failed').toJson());
      await db.close();
      final imports = Directory(p.join(accountDirectory.path, 'imports'));
      await File(p.join(imports.path, 'abandoned.source.part'))
          .writeAsBytes([1]);
      await File(p.join(imports.path, 'orphan.source')).writeAsBytes([1]);
      final reopened = AppController(
        api: ApiClient(dio: dio, credentials: credentials),
        storageDirectory: () async => root,
        playbackEngine: FakeEngine(),
        enableSystemControls: false,
        automaticRefresh: false,
      );
      try {
        await reopened.initialize();
        expect(reopened.uploads.single.status, 'failed');
        expect((await imports.list().toList()).map((f) => f.path), [
          job.localPath,
        ]);
        expect(await File(job.localPath).readAsBytes(), [1, 2, 3]);
      } finally {
        await reopened.shutdown();
        reopened.dispose();
      }
    },
  );
}
