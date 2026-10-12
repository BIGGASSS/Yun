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
import 'package:yun/services/transfer_service.dart' show TransferCancelled;

import 'fakes.dart';

class _CleanupDatabase extends CacheDatabase {
  _CleanupDatabase(super.file);
  Completer<void>? readStarted, releaseRead, failedRemoval;
  bool closed = false, failFileRemoval = false;
  @override
  Future<List<Map<String, dynamic>>> list(String kind) async {
    if (kind == 'track' && readStarted != null) {
      final started = readStarted!;
      readStarted = null;
      started.complete();
      await releaseRead!.future;
    }
    expect(closed, isFalse);
    return super.list(kind);
  }

  @override
  Future<void> remove(String kind, String id) async {
    if (kind == 'file' && failFileRemoval) {
      failFileRemoval = false;
      failedRemoval?.complete();
      throw StateError('Interrupted reclamation');
    }
    expect(closed, isFalse);
    await super.remove(kind, id);
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

void main() {
  const account = Account(
    server: 'https://yun.test',
    userId: 'a',
    username: 'a',
  );
  late Directory root, directory;
  late File file;
  late _CleanupDatabase db;
  late MemoryCredentials credentials;
  late ApiClient api;
  late AppController app;
  var requests = 0;
  final bytes = [1, 2, 3, 4];

  Future<void> until(Future<bool> Function() check) async {
    for (var i = 0; i < 200; i++) {
      if (await check()) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Cleanup did not finish');
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yun-app-cleanup-');
    final key = sha256
        .convert(utf8.encode(jsonEncode([account.server, account.userId])))
        .toString();
    directory = await Directory(p.join(root.path, 'accounts', key))
        .create(recursive: true);
    final audio = await Directory(p.join(directory.path, 'audio')).create();
    file = await File(p.join(audio.path, 't.audio')).writeAsBytes(bytes);
    final seed = CacheDatabase(File(p.join(directory.path, 'cache.sqlite')));
    final track = Track(
      id: 't',
      title: 'T',
      sizeBytes: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    );
    await seed.applyLibrary({
      'cursor': 0,
      'reset': true,
      'tracks': [track.toJson()],
    });
    await seed.put('file', 't', {
      'id': 't',
      'path': file.path,
      'sha256': track.sha256,
    });
    await seed.close();
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
    requests = 0;
    api = ApiClient(dio: Dio(), credentials: credentials);
    api.dio.httpClientAdapter = FakeAdapter((options, _) {
      requests++;
      if (options.path.endsWith('/auth/logout')) {
        return ResponseBody.fromString('', 204);
      }
      throw StateError('Unexpected HTTP request ${options.path}');
    });
    app = AppController(
      api: api,
      storageDirectory: () async => root,
      databaseFactory: (file) => db = _CleanupDatabase(file),
      playbackEngine: FakeEngine(),
      enableSystemControls: false,
      automaticRefresh: false,
      listeningMonotonicMs: () => 0,
    );
    await app.initialize();
  });
  tearDown(() async {
    await app.shutdown();
    app.dispose();
    await root.delete(recursive: true);
  });

  test('offline preview/purge update committed inventory and notify cleaning state without HTTP', () async {
    app.isOffline = true;
    final states = <bool>[];
    app.addListener(() => states.add(app.cleaningDownloads));
    final preview = await app.previewUnusedDownloads();
    expect(preview.fileCount, 1);
    expect(preview.totalBytes, 4);
    expect(app.downloadedTrackIds, {'t'});
    expect(app.localPath('t'), file.path);
    final result = await app.purgeUnusedDownloads(preview);
    expect(result.fileCount, 1);
    expect(result.totalBytes, 4);
    expect(app.downloadedTrackIds, isEmpty);
    expect(app.localPath('t'), isNull);
    expect(app.isOffline, isTrue);
    expect(app.cleaningDownloads, isFalse);
    expect(states, [true, false, true, false]);
    expect(requests, 0);
  });

  test(
    'paused playback protects the selected audio even though it is not pinned',
    () async {
      await app.play(app.tracks.single);
      await app.playback.pause();
      expect(app.playback.currentTrack?.id, 't');
      expect(app.playback.isPlaying, isFalse);
      final preview = await app.previewUnusedDownloads();
      expect(preview.fileCount, 0);
      await app.purgeUnusedDownloads(preview);
      expect(await file.exists(), isTrue);
      expect(app.localPath('t'), file.path);
      expect(requests, 0);
    },
  );

  test(
    'a dialog preview cannot cross even a same-account close/reopen generation',
    () async {
      final preview = await app.previewUnusedDownloads();
      await app.logout();
      api.dio.httpClientAdapter = FakeAdapter((options, _) {
        if (options.path.endsWith('/auth/login')) {
          return jsonResponse({
            'access_token': 'a',
            'refresh_token': 'r',
            'expires_at': DateTime.now().millisecondsSinceEpoch + 3600000,
            'user': {'id': 'a', 'username': 'a'},
          });
        }
        // Login's opportunistic refresh may fail while the local account opens.
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      });
      await app.login(account.server, account.username, 'password');
      expect(app.account?.userId, 'a');
      await expectLater(app.purgeUnusedDownloads(preview), throwsStateError);
      expect(await file.exists(), isTrue);
    },
  );

  for (final purge in [false, true]) {
    test(
      'shutdown drains ${purge ? 'purge' : 'preview'} before closing its account database',
      () async {
        final preview = await app.previewUnusedDownloads();
        db.readStarted = Completer<void>();
        db.releaseRead = Completer<void>();
        final started = db.readStarted!.future;
        final operation = purge
            ? app.purgeUnusedDownloads(preview)
            : app.previewUnusedDownloads();
        final expected = expectLater(
          operation,
          throwsA(isA<TransferCancelled>()),
        );
        await started;
        final shuttingDown = app.shutdown();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(db.closed, isFalse);
        db.releaseRead!.complete();
        await expected;
        await shuttingDown;
        expect(db.closed, isTrue);
        expect(await file.exists(), isTrue);
      },
    );
  }

  test('confirmed library deletion reclaims audio despite failed listening-event delivery', () async {
    await db.put('pin', 'track:t', const PinSelection('track', 't').toJson());
    await db.put('event', 'pending', {'id': 'pending', 'track_id': 't'});
    api.dio.httpClientAdapter = FakeAdapter((options, _) {
      if (options.path.endsWith('/library')) {
        return jsonResponse({
          'cursor': 1,
          'reset': false,
          'tracks': [],
          'playlists': [],
          'deleted_track_ids': ['t'],
        });
      }
      if (options.path.endsWith('/listening-events')) {
        return jsonResponse({}, status: 500);
      }
      throw StateError('Unexpected ${options.path}');
    });
    await expectLater(app.refresh(), throwsA(isA<DioException>()));
    await until(
      () async => !await file.exists() && app.downloadedTrackIds.isEmpty,
    );
    expect(app.tracks, isEmpty);
    expect(await db.get('download', 't'), isNull);
    expect(await db.get('event', 'pending'), isNotNull);
  });

  test('a no-op refresh retries an aborted initial deletion cleanup', () async {
    var first = true;
    api.dio.httpClientAdapter = FakeAdapter((options, _) {
      if (options.path.endsWith('/library')) {
        final deleted = first;
        first = false;
        return jsonResponse({
          'cursor': 1,
          'reset': false,
          'tracks': [],
          'playlists': [],
          'deleted_track_ids': deleted ? ['t'] : [],
        });
      }
      throw StateError('Unexpected ${options.path}');
    });
    db.failFileRemoval = true;
    db.failedRemoval = Completer<void>();
    await app.refresh();
    await db.failedRemoval!.future;
    await until(() async => !await file.exists());
    expect(await db.get('file', 't'), isNotNull);
    await app.refresh();
    await until(() async => await db.get('file', 't') == null);
    expect(app.downloadedTrackIds, isEmpty);
  });
}
