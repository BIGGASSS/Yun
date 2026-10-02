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

class _GatedPinDatabase extends CacheDatabase {
  _GatedPinDatabase(super.file);

  Completer<void>? pinWriteStarted, allowPinWrite;
  bool closed = false;

  @override
  Future<void> put(String kind, String id, Map<String, dynamic> value) async {
    if (kind == 'pin' && pinWriteStarted != null) {
      if (!pinWriteStarted!.isCompleted) pinWriteStarted!.complete();
      await allowPinWrite!.future;
    }
    expect(
      closed,
      isFalse,
      reason: 'Writes must drain before database closure',
    );
    await super.put(kind, id, value);
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

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
  Future<Directory> seedAccount({DownloadStatus? interrupted}) async {
    final key = sha256
        .convert(utf8.encode(jsonEncode([account.server, account.userId])))
        .toString();
    final directory = Directory(p.join(root.path, 'accounts', key));
    await directory.create(recursive: true);
    final db = CacheDatabase(File(p.join(directory.path, 'cache.sqlite')));
    final track = Track(
      id: 't',
      title: 'Offline track',
      sizeBytes: 3,
      sha256: sha256.convert([1, 2, 3]).toString(),
    );
    await db.applyLibrary({
      'cursor': 5,
      'reset': true,
      'tracks': [track.toJson()],
    });
    final file = await File(p.join(directory.path, 'offline.audio'))
        .writeAsBytes([1, 2, 3]);
    await db.put('file', 't', {
      'id': 't',
      'path': file.path,
      'sha256': track.sha256,
    });
    if (interrupted != null) {
      await db.put('pin', 'track:t', const PinSelection('track', 't').toJson());
      // Crash after the verified file record commits, before progress saves.
      await db.put(
        'download',
        't',
        DownloadProgress(
          trackId: 't',
          totalBytes: track.sizeBytes,
          status: interrupted,
        ).toJson(),
      );
    }
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

  for (final contents in ['valid', 'truncated', 'same-length corruption']) {
    test(
      'startup checks only metadata and size for $contents legacy audio',
      () async {
        final directory = await seedAccount();
        final databaseFile = File(p.join(directory.path, 'cache.sqlite'));
        final seed = CacheDatabase(databaseFile);
        final record = (await seed.get('file', 't'))!;
        final file = File(record['path'] as String);
        await seed.put(
          'pin',
          'track:t',
          const PinSelection('track', 't').toJson(),
        );
        expect(await seed.get('download', 't'), isNull);
        await seed.close();
        if (contents != 'valid') {
          await file.writeAsBytes(contents == 'truncated' ? [1, 2] : [3, 2, 1]);
        }
        var requests = 0;
        final engine = FakeEngine();
        final app = AppController(
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
          playbackEngine: engine,
          enableSystemControls: false,
          automaticRefresh: false,
        );
        final publishedPaths = <String>[];
        app.addListener(() {
          final path = app.localPath('t');
          if (path != null) publishedPaths.add(path);
        });
        try {
          await app.initialize();
          expect(app.isAuthenticated, isTrue);
          expect(app.tracks.single.id, 't');
          expect(app.pins.single.id, 't');
          // Same-length corruption is intentionally deferred to manual verification.
          final valid = contents != 'truncated';
          expect(
            app.verificationProgress?.invalidTrackIds,
            valid ? isNull : ['t'],
          );
          expect(app.localPath('t'), valid ? file.path : isNull);
          expect(app.downloadedTrackIds, valid ? {'t'} : isEmpty);
          expect(
            app.downloadProgress(app.tracks.single).status,
            valid ? DownloadStatus.downloaded : DownloadStatus.failed,
          );
          if (valid) {
            await app.play(app.tracks.single);
            expect(engine.opened, file.path);
            expect(
              await file.readAsBytes(),
              contents == 'valid' ? [1, 2, 3] : [3, 2, 1],
            );
          } else {
            expect(publishedPaths, isEmpty);
            // Keep bytes until an explicit repair; metadata failure is not a
            // reason to silently redownload or destroy the existing copy.
            expect(await file.exists(), isTrue);
          }
          expect(requests, 0);
        } finally {
          await app.shutdown();
          app.dispose();
        }
        final persisted = CacheDatabase(databaseFile);
        try {
          expect(
            await persisted.get('file', 't'),
            contents != 'truncated' ? record : isNull,
          );
          expect(await persisted.get('pin', 'track:t'), isNotNull);
          final download = DownloadProgress.fromJson(
            (await persisted.get('download', 't'))!,
          );
          expect(download.requiresOfflinePlayback, isTrue);
          expect(
            download.status,
            contents == 'truncated'
                ? DownloadStatus.failed
                : DownloadStatus.downloaded,
          );
          expect(download.repairRequired, contents == 'truncated');
        } finally {
          await persisted.close();
        }
      },
    );
  }

  test(
    'manual verification detects corruption offline without downloading',
    () async {
      final directory = await seedAccount();
      final file = File(p.join(directory.path, 'offline.audio'));
      await file.writeAsBytes([3, 2, 1]);
      var requests = 0;
      final app = AppController(
        api: ApiClient(
          dio: Dio()
            ..httpClientAdapter = FakeAdapter((options, _) {
              requests++;
              throw StateError('Verification must not access the network');
            }),
          credentials: credentials,
        ),
        storageDirectory: () async => root,
        playbackEngine: FakeEngine(),
        enableSystemControls: false,
        automaticRefresh: false,
      );
      try {
        await app.initialize();
        app.isOffline = true;
        expect(app.downloadedTrackIds, {'t'});
        final states = <VerificationStatus>[];
        var appNotifications = 0;
        app.addListener(() => appNotifications++);
        app.verificationChanges.addListener(() {
          final progress = app.verificationProgress;
          if (progress != null) states.add(progress.status);
        });
        await app.verifyDownloads();
        expect(states.first, VerificationStatus.preparing);
        expect(states.last, VerificationStatus.completed);
        expect(app.verificationProgress!.checkedFiles, 1);
        expect(app.verificationProgress!.invalidFiles, 1);
        expect(app.verificationProgress!.invalidTrackIds, ['t']);
        expect(app.downloadedTrackIds, isEmpty);
        expect(app.localPath('t'), isNull);
        expect(appNotifications, 0);
        expect(requests, 0);
        expect(app.isOffline, isTrue);
        expect(app.redownloadCorruptedFiles, throwsStateError);
        expect(app.pins, isEmpty);
      } finally {
        await app.shutdown();
        app.dispose();
      }
    },
  );

  test(
    'explicit repair preserves selections and pins unselected corrupt tracks',
    () async {
      final directory = await seedAccount();
      final db = CacheDatabase(File(p.join(directory.path, 'cache.sqlite')));
      final original = (await db.get('track', 't'))!;
      final originalFile = (await db.get('file', 't'))!;
      final otherFile = await File(p.join(directory.path, 'unselected.audio'))
          .writeAsBytes([3, 2, 1]);
      await File(originalFile['path'] as String).writeAsBytes([3, 2, 1]);
      await db.put('track', 'unselected', {...original, 'id': 'unselected'});
      await db.put('file', 'unselected', {
        ...originalFile,
        'id': 'unselected',
        'path': otherFile.path,
      });
      const playlist = Playlist(
        id: 'saved',
        name: 'Offline playlist',
        entries: [PlaylistEntry(id: 'entry', trackId: 't')],
      );
      await db.put('playlist', playlist.id, playlist.toJson());
      await db.put(
        'pin',
        jsonEncode(['playlist', 'saved']),
        const PinSelection('playlist', 'saved').toJson(),
      );
      await db.close();
      final downloads = <String>[];
      final app = AppController(
        api: ApiClient(
          dio: Dio()
            ..httpClientAdapter = FakeAdapter((options, _) {
              if (options.path.endsWith('/auth/refresh')) {
                return jsonResponse({
                  'access_token': 'fresh',
                  'refresh_token': 'fresh-refresh',
                  'expires_at': DateTime.now().millisecondsSinceEpoch + 3600000,
                });
              }
              if (options.path.endsWith('/audio')) {
                downloads.add(options.path);
                return ResponseBody.fromBytes([1, 2, 3], 200);
              }
              throw StateError('Unexpected request: ${options.path}');
            }),
          credentials: credentials,
        ),
        storageDirectory: () async => root,
        playbackEngine: FakeEngine(),
        enableSystemControls: false,
        automaticRefresh: false,
      );
      try {
        await app.initialize();
        await app.verifyDownloads();
        expect(app.verificationProgress!.invalidFiles, 2);
        expect(downloads, isEmpty);
        expect(app.pins, hasLength(1));
        final repairing = app.redownloadCorruptedFiles();
        expect(app.redownloadingCorruptedFiles, isTrue);
        await repairing;
        expect(app.redownloadingCorruptedFiles, isFalse);
        expect(downloads, hasLength(2));
        expect(app.isPinned('playlist', 'saved'), isTrue);
        expect(app.isPinned('track', 'unselected'), isTrue);
        expect(app.isPinned('track', 't'), isFalse);
        expect(app.pins, hasLength(2));
      } finally {
        await app.shutdown();
        app.dispose();
      }
    },
  );

  for (final closingAction in ['logout', 'shutdown']) {
    test(
      '$closingAction cancels verification and hides account progress',
      () async {
        await seedAccount();
        final app = AppController(
          api: ApiClient(
            dio: Dio()
              ..httpClientAdapter = FakeAdapter((options, _) {
                if (options.path.endsWith('/auth/logout')) {
                  return jsonResponse({});
                }
                throw StateError('Unexpected request');
              }),
            credentials: credentials,
          ),
          storageDirectory: () async => root,
          playbackEngine: FakeEngine(),
          enableSystemControls: false,
          automaticRefresh: false,
        );
        try {
          await app.initialize();
          final verification = app.verifyDownloads();
          expect(app.verificationProgress?.isRunning, isTrue);
          final closing = closingAction == 'logout'
              ? app.logout()
              : app.shutdown();
          expect(app.verificationProgress, isNull);
          await Future.wait([verification, closing]);
          expect(app.isAuthenticated, isFalse);
          expect(app.verificationProgress, isNull);
        } finally {
          await app.shutdown();
          app.dispose();
        }
      },
    );
  }

  for (final closingAction in ['logout', 'shutdown']) {
    for (final repairKind in ['all', 'track']) {
      test(
        '$closingAction drains $repairKind repair pin writes before database closure',
        () async {
          final directory = await seedAccount();
          await File(p.join(directory.path, 'offline.audio'))
              .writeAsBytes([3, 2, 1]);
          late _GatedPinDatabase db;
          var requests = 0;
          final app = AppController(
            api: ApiClient(
              dio: Dio()
                ..httpClientAdapter = FakeAdapter((options, _) {
                  if (options.path.endsWith('/auth/logout')) {
                    return jsonResponse({});
                  }
                  if (options.path.endsWith('/auth/refresh')) {
                    return jsonResponse({
                      'access_token': 'fresh',
                      'refresh_token': 'fresh-refresh',
                      'expires_at':
                          DateTime.now().millisecondsSinceEpoch + 3600000,
                    });
                  }
                  requests++;
                  throw StateError('Closing must stop repair before download');
                }),
              credentials: credentials,
            ),
            storageDirectory: () async => root,
            databaseFactory: (file) => db = _GatedPinDatabase(file),
            playbackEngine: FakeEngine(),
            enableSystemControls: false,
            automaticRefresh: false,
          );
          try {
            await app.initialize();
            await app.verifyDownloads();
            db.pinWriteStarted = Completer<void>();
            db.allowPinWrite = Completer<void>();
            final repair = repairKind == 'all'
                ? app.redownloadCorruptedFiles()
                : app.redownloadTrack(app.tracks.single);
            await db.pinWriteStarted!.future;
            final closing = closingAction == 'logout'
                ? app.logout()
                : app.shutdown();
            expect(app.redownloadingCorruptedFiles, isFalse);
            expect(app.isRedownloadingTrack('t'), isFalse);
            expect(db.closed, isFalse);
            db.allowPinWrite!.complete();
            await Future.wait([repair, closing]);
            expect(db.closed, isTrue);
            expect(app.isAuthenticated, isFalse);
            expect(app.verificationProgress, isNull);
            expect(requests, 0);
          } finally {
            if (db.allowPinWrite?.isCompleted == false) {
              db.allowPinWrite!.complete();
            }
            await app.shutdown();
            app.dispose();
          }
        },
      );
    }
  }

  for (final interrupted in [
    null,
    DownloadStatus.downloading,
    DownloadStatus.verifying,
  ]) {
    test(
      'cleared Done entries stay cleared offline after restart (saved: $interrupted)',
      () async {
        final directory = await seedAccount(interrupted: interrupted);
        var requests = 0;
        AppController create() {
          final app = AppController(
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
          addTearDown(() async {
            await app.shutdown();
            app.dispose();
          });
          return app;
        }

        var app = create();
        await app.initialize();
        final path = app.localPath('t');
        expect(app.downloadProgress(app.tracks.single).historyCleared, isFalse);
        await app.clearDoneDownloads();
        expect(app.downloadProgress(app.tracks.single).historyCleared, isTrue);
        expect(app.downloadedTrackIds, {'t'});
        expect(await File(path!).readAsBytes(), [1, 2, 3]);
        await app.shutdown();
        final persisted = CacheDatabase(
          File(p.join(directory.path, 'cache.sqlite')),
        );
        try {
          final progress = (await persisted.get('download', 't'))!;
          expect(progress['status'], DownloadStatus.downloaded.name);
          expect(progress['history_cleared'], isTrue);
          expect((await persisted.get('file', 't'))!['path'], path);
          if (interrupted != null) {
            expect(await persisted.get('pin', 'track:t'), isNotNull);
          }
        } finally {
          await persisted.close();
        }

        app = create();
        await app.initialize();
        expect(app.downloadProgress(app.tracks.single).historyCleared, isTrue);
        expect(app.localPath('t'), path);
        await app.play(app.tracks.single);
        expect(app.playback.currentTrack?.id, 't');
        expect(requests, 0);
      },
    );
  }
  for (final closingAction in ['logout', 'shutdown']) {
    test('$closingAction drains concurrent download history clears', () async {
      final directory = await seedAccount();
      final databaseFile = File(p.join(directory.path, 'cache.sqlite'));
      final seed = CacheDatabase(databaseFile);
      final fileRecord = (await seed.get('file', 't'))!;
      await seed.transaction(() async {
        for (var i = 0; i < 100; i++) {
          final track = Track(
            id: 'download-$i',
            title: 'Download $i',
            sizeBytes: 3,
            sha256: fileRecord['sha256'] as String,
          );
          await seed.put('track', track.id, track.toJson());
          await seed.put('file', track.id, {...fileRecord, 'id': track.id});
        }
      });
      await seed.close();
      final app = AppController(
        api: ApiClient(
          dio: Dio()
            ..httpClientAdapter = FakeAdapter((options, _) {
              if (options.path.endsWith('/auth/logout')) {
                return jsonResponse({});
              }
              throw StateError('Unexpected network request');
            }),
          credentials: credentials,
        ),
        storageDirectory: () async => root,
        playbackEngine: FakeEngine(),
        enableSystemControls: false,
        automaticRefresh: false,
      );
      try {
        await app.initialize();
        expect(app.downloadedTrackIds, hasLength(101));
        final cleared = <int>[];
        final clearing = [
          for (var i = 0; i < 2; i++)
            app.clearDoneDownloads().then((_) => cleared.add(i)),
        ];
        final closing =
            (closingAction == 'logout' ? app.logout() : app.shutdown()).then((
              _,
            ) {
              expect(cleared, hasLength(2));
            });
        await Future.wait([...clearing, closing]);
        expect(app.isAuthenticated, isFalse);
        final reopened = CacheDatabase(databaseFile);
        try {
          final history = await reopened.list('download');
          expect(history, hasLength(101));
          expect(
            history.every((row) => row['history_cleared'] == true),
            isTrue,
          );
          expect(await reopened.list('file'), hasLength(101));
          expect(await File(fileRecord['path'] as String).exists(), isTrue);
        } finally {
          await reopened.close();
        }
      } finally {
        await app.shutdown();
        app.dispose();
      }
    });
  }

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
        listeningMonotonicMs: () => 0,
      );
      await app.initialize();
      await app.play(app.tracks.single);
      await app.queueNext(app.tracks.single);
      await app.logout();
      expect(app.playback.effectiveQueue, isEmpty);
      await expectLater(
        app.queueNext(const Track(id: 't', title: 'Offline track')),
        throwsStateError,
      );
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
