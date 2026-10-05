import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';

import 'fakes.dart';

class _InventoryDatabase extends CacheDatabase {
  _InventoryDatabase() : super.memory();

  final reads = <String, int>{};
  Future<void> Function(String)? afterRead;
  Future<void> Function()? afterEventCount;
  Future<void> Function()? afterPinMutation;
  int pinMutations = 0;

  @override
  Future<void> put(String kind, String id, Map<String, dynamic> value) async {
    await super.put(kind, id, value);
    if (kind == 'pin') {
      pinMutations++;
      await afterPinMutation?.call();
    }
  }

  @override
  Future<void> remove(String kind, String id) async {
    await super.remove(kind, id);
    if (kind == 'pin') {
      pinMutations++;
      await afterPinMutation?.call();
    }
  }

  @override
  Future<int> eventCount() async {
    final count = await super.eventCount();
    await afterEventCount?.call();
    return count;
  }

  @override
  Future<List<Map<String, dynamic>>> list(String kind) async {
    reads.update(kind, (count) => count + 1, ifAbsent: () => 1);
    final result = await super.list(kind);
    await afterRead?.call(kind);
    return result;
  }
}

void main() {
  late Directory root;
  late _InventoryDatabase db;
  late ApiClient api;
  AppController? app;
  final bytes = [1, 2, 3];
  late Track track;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yun-incremental-');
    db = _InventoryDatabase();
    track = Track(
      id: 't',
      title: 'Track',
      sizeBytes: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    );
    final credentials = MemoryCredentials();
    await credentials.write(
      ApiClient.sessionKey,
      jsonEncode(
        SessionCredentials(
          account: const Account(
            server: 'https://yun.test',
            userId: 'u',
            username: 'u',
          ),
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
        ).toJson(),
      ),
    );
    api = ApiClient(dio: Dio(), credentials: credentials);
    api.dio.httpClientAdapter = FakeAdapter((options, _) {
      if (options.path.endsWith('/playlists')) {
        return jsonResponse(
          const Playlist(id: 'p', name: 'Playlist', revision: 6).toJson(),
        );
      }
      return ResponseBody.fromBytes(bytes, 200);
    });
    await db.applyLibrary({
      'cursor': 5,
      'reset': true,
      'tracks': [track.toJson()],
    });
    app = null;
  });

  tearDown(() async {
    db.afterRead = null;
    db.afterEventCount = null;
    db.afterPinMutation = null;
    if (app != null) {
      await app!.shutdown();
      app!.dispose();
    } else {
      await db.close();
    }
    await root.delete(recursive: true);
  });

  Future<AppController> open() async {
    final value = app = AppController(
      api: api,
      storageDirectory: () async => root,
      databaseFactory: (_) => db,
      playbackEngine: FakeEngine(),
      enableSystemControls: false,
      automaticRefresh: false,
    );
    await value.initialize();
    db.reads.clear();
    return value;
  }

  Future<void> seedJob(String id, String status) => db.put(
    'upload',
    id,
    UploadJob(
      id: id,
      localPath: '${root.path}/$id.wav',
      filename: '$id.wav',
      sizeBytes: 3,
      status: status,
    ).toJson(),
  );

  for (final pinned in [true, false]) {
    test(
      'bulk ${pinned ? 'pin' : 'unpin'} deduplicates 1000 tracks and publishes '
      'one complete snapshot before reconciling',
      () async {
        final tracks = [
          for (var i = 0; i < 1000; i++)
            Track(
              id: 'bulk-$i',
              title: 'Bulk ${i.toString().padLeft(4, '0')}',
              sizeBytes: bytes.length,
              sha256: track.sha256,
            ),
        ];
        final ids = tracks.map((item) => item.id).toList();
        // Identical audio can share this fixture path; reconciliation must not
        // start deleting cached selections halfway through the pin transaction.
        final cached = await File('${root.path}/cached.audio')
            .writeAsBytes(bytes);
        await db.transaction(() async {
          for (final item in tracks) {
            await db.put('track', item.id, item.toJson());
            await db.put('file', item.id, {
              'id': item.id,
              'path': cached.path,
              'sha256': item.sha256,
            });
            if (!pinned) {
              await db.put(
                'pin',
                jsonEncode(['track', item.id]),
                PinSelection('track', item.id).toJson(),
              );
            }
          }
        });
        final value = await open();
        db.pinMutations = 0;
        final originalPins = value.pins;
        final halfway = Completer<void>();
        final releaseWrites = Completer<void>();
        final reconciliation = Completer<void>();
        final releaseReconciliation = Completer<void>();
        final published = <Set<String>>[];
        final reconciled = <Set<String>>[];
        value.addListener(() {
          published.add(value.pins.map((pin) => pin.id).toSet());
        });
        db.afterPinMutation = () async {
          if (db.pinMutations == 500) {
            halfway.complete();
            await releaseWrites.future;
          }
        };
        db.afterRead = (kind) async {
          if (kind == 'download') {
            reconciled.add(value.pins.map((pin) => pin.id).toSet());
          }
          if (kind == 'file' && db.reads['file'] == 2) {
            reconciliation.complete();
            await releaseReconciliation.future;
          }
        };
        final operation = value.pinTracks([...ids, ...ids], pinned: pinned);
        try {
          await halfway.future;
          expect(db.reads, isEmpty);
          expect(value.pins, same(originalPins));
          expect(published, isEmpty);
          expect(reconciled, isEmpty);
          expect(await cached.exists(), isTrue);
          releaseWrites.complete();
          await operation;
          await reconciliation.future;
          final expected = pinned ? ids.toSet() : <String>{};
          expect(db.pinMutations, 1000);
          expect(value.pins.map((pin) => pin.id).toSet(), expected);
          expect(published, [expected]);
          expect(reconciled, [expected]);
          expect(db.reads, {
            'track': 1,
            'playlist': 1,
            'upload': 1,
            'pin': 1,
            'file': 2, // One full cache read and one reconciliation inventory.
            'download': 1,
          });
          expect(
            (await db.list('pin')).map((pin) => pin['id']).toSet(),
            expected,
          );
        } finally {
          if (!releaseWrites.isCompleted) releaseWrites.complete();
          releaseReconciliation.complete();
          await operation;
        }
      },
    );

    test('empty bulk ${pinned ? 'pin' : 'unpin'} is a no-op', () async {
      final value = await open();
      final originalPins = value.pins;
      var publications = 0;
      value.addListener(() => publications++);
      await value.pinTracks(const [], pinned: pinned);
      expect(db.pinMutations, 0);
      expect(db.reads, isEmpty);
      expect(value.pins, same(originalPins));
      expect(publications, 0);
    });

    test(
      'failed bulk ${pinned ? 'pin' : 'unpin'} rolls back without publication',
      () async {
        final ids = ['first', 'second', 'third'];
        final initialIds = ['retained', if (!pinned) ...ids];
        for (final id in initialIds) {
          await db.put(
            'pin',
            jsonEncode(['track', id]),
            PinSelection('track', id).toJson(),
          );
        }
        final value = await open();
        final originalPins = value.pins;
        var publications = 0;
        value.addListener(() => publications++);
        db.pinMutations = 0;
        final failure = StateError('Injected pin storage failure');
        db.afterPinMutation = () async {
          // Throw after writes have reached SQLite, not before the first write.
          if (db.pinMutations == 2) throw failure;
        };
        await expectLater(
          value.pinTracks(ids, pinned: pinned),
          throwsA(same(failure)),
        );
        expect(db.pinMutations, 2);
        expect(db.reads, isEmpty);
        expect(value.pins, same(originalPins));
        expect(publications, 0);
        expect(
          (await db.list('pin')).map((pin) => pin['id']).toSet(),
          initialIds.toSet(),
        );
      },
    );
  }

  test(
    'clearing large upload history publishes one compacted inventory',
    () async {
      await db.transaction(() async {
        for (var i = 0; i < 1000; i++) {
          await seedJob('history-$i', 'done');
        }
        await seedJob('retained', 'failed');
      });
      final value = await open();
      var notifications = 0;
      value.downloadChanges.addListener(() => notifications++);
      await value.clearDoneUploads();
      expect(value.uploads.map((job) => job.id), ['retained']);
      expect(notifications, 1);
      expect(db.reads, {'upload': 1});
      // Rebuilt indexes must still address the retained record correctly.
      await value.cancelUpload('retained');
      expect(value.uploads.single.status, 'cancelled');
    },
  );

  test('upload chunk deltas do not read or copy retained history', () async {
    await db.transaction(() async {
      for (var i = 0; i < 1000; i++) {
        await seedJob('history-$i', 'done');
      }
    });
    final value = await open();
    final history = value.uploads.first;
    final completedChunks = Completer<void>();
    final release = Completer<void>();
    var offset = 0;
    var chunks = 0;
    api.dio.httpClientAdapter = FakeAdapter((options, body) async {
      if (options.path.endsWith('/uploads')) {
        return jsonResponse({'id': 'remote', 'offset': 0});
      }
      if (options.path.endsWith('/complete')) {
        completedChunks.complete();
        await release.future;
        return jsonResponse(track.toJson());
      }
      chunks++;
      offset += body.length;
      return jsonResponse({'offset': offset});
    });
    final source = await File('${root.path}/source.wav')
        .writeAsBytes(List.filled(9 * 1024 * 1024, 1));
    var broad = 0;
    value.addListener(() => broad++);
    await value.enqueueUpload(source.path);
    await completedChunks.future;
    try {
      expect(chunks, greaterThan(1));
      expect(value.uploads, hasLength(1001));
      expect(value.uploads.last.offset, source.lengthSync());
      expect(value.uploads.first, same(history));
      expect(() => value.uploads.clear(), throwsUnsupportedError);
      // The worker reads its queue once, not once per durable offset update.
      expect(db.reads, {'upload_cancel': 1, 'upload': 1});
      expect(broad, 0);
    } finally {
      release.complete();
    }
  });

  test(
    'many completed downloads publish availability before retry returns',
    () async {
      final tracks = [
        for (var i = 0; i < 12; i++)
          Track(
            id: 't$i',
            title: 'Track $i',
            sizeBytes: bytes.length,
            sha256: track.sha256,
          ),
      ];
      for (final item in tracks) {
        await db.put('track', item.id, item.toJson());
        await db.put('pin', item.id, PinSelection('track', item.id).toJson());
      }
      final value = await open();
      await value.retryDownloads();
      expect(value.downloadedTrackIds, tracks.map((item) => item.id).toSet());
      for (final item in tracks) {
        expect(value.localPath(item.id), isNotNull);
        expect(value.downloadProgress(item).status, DownloadStatus.downloaded);
      }
      expect(() => value.downloadedTrackIds.clear(), throwsUnsupportedError);
      expect(db.reads['file'], 1); // Reconciliation inventory only.
      expect(db.reads['upload'], isNull);
      expect(db.reads['track'], isNull);
    },
  );

  test(
    'full cache snapshot preserves upload updates, additions and tombstones',
    () async {
      await seedJob('remove', 'done');
      await seedJob('change', 'failed');
      final value = await open();
      value.isOffline = true;
      final entered = Completer<void>();
      final release = Completer<void>();
      db.afterRead = (kind) async {
        if (kind == 'upload' && !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      // Online mutation starts a full cache read; park its old upload snapshot.
      final reload = value.createPlaylist('Playlist');
      await entered.future;
      try {
        await value.clearDoneUploads();
        await value.cancelUpload('change');
        final source = await File('${root.path}/new.wav').writeAsBytes(bytes);
        await value.enqueueUpload(source.path);
        expect(value.uploads, hasLength(2));
      } finally {
        release.complete();
      }
      await reload;
      expect(value.uploads, hasLength(2));
      expect(value.uploads.any((job) => job.id == 'remove'), isFalse);
      expect(value.uploads.first.status, 'cancelled');
      expect(value.uploads.last.status, 'queued');
      expect(db.reads['upload'], 2); // Full read + explicit history clear.
    },
  );

  test('full cache snapshot cannot undo file removal or completion', () async {
    final old = Track(
      id: 'old',
      title: 'Old cached track',
      sizeBytes: bytes.length,
      sha256: track.sha256,
    );
    final cached = await File('${root.path}/old.audio').writeAsBytes(bytes);
    await db.put('track', old.id, old.toJson());
    await db.put('file', old.id, {
      'id': old.id,
      'path': cached.path,
      'sha256': old.sha256,
    });
    await db.put('pin', track.id, PinSelection('track', track.id).toJson());
    final value = await open();
    expect(value.localPath(old.id), cached.path);
    final entered = Completer<void>();
    final release = Completer<void>();
    // Pause after the old file's existence has already been accepted, so only
    // the removal delta (not a later stat) can prevent its resurrection.
    db.afterEventCount = () async {
      if (!entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    final reload = value.createPlaylist('Playlist');
    await entered.future;
    try {
      // Reconciliation removes unselected old audio and completes selected audio
      // while the full read still holds the opposite inventory.
      await value.retryDownloads();
      expect(value.localPath(old.id), isNull);
      expect(value.downloadProgress(track).status, DownloadStatus.downloaded);
    } finally {
      release.complete();
    }
    await reload;
    expect(value.localPath(old.id), isNull);
    expect(value.localPath(track.id), isNotNull);
    expect(value.downloadedTrackIds, {track.id});
    expect(db.reads['file'], 2); // Full read + reconciliation, not completion.
  });
}
