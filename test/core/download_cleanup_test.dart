import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yun/models/models.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/transfer_service.dart';

import 'fakes.dart';

class _GatedDatabase extends CacheDatabase {
  _GatedDatabase() : super.memory();
  Completer<void>? readStarted, releaseRead, pinStarted, releasePin;
  bool closed = false;
  String? failRemovalKind;
  void Function()? afterInventoryRead;

  @override
  Future<void> remove(String kind, String id) async {
    if (failRemovalKind == kind) {
      failRemovalKind = null;
      throw StateError('Interrupted database cleanup');
    }
    await super.remove(kind, id);
  }

  @override
  Future<List<Map<String, dynamic>>> list(String kind) async {
    if (kind == 'track' && readStarted != null) {
      final started = readStarted!;
      readStarted = null;
      started.complete();
      await releaseRead!.future;
    }
    expect(closed, isFalse);
    final records = await super.list(kind);
    if (kind == 'upload') afterInventoryRead?.call();
    return records;
  }

  @override
  Future<void> put(String kind, String id, Map<String, dynamic> value) async {
    if (kind == 'pin' && pinStarted != null) {
      final started = pinStarted!;
      pinStarted = null;
      started.complete();
      await releasePin!.future;
    }
    expect(closed, isFalse);
    await super.put(kind, id, value);
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

class _Verifier implements DownloadFileVerifier {
  final started = Completer<void>();
  final result = Completer<FileVerificationResult>();
  @override
  Future<FileVerificationResult> verify(
    VerificationFile file,
    void Function(int) onBytes,
  ) {
    if (!started.isCompleted) started.complete();
    return result.future;
  }

  @override
  void cancel() {
    if (!result.isCompleted) result.completeError(VerificationCancelled());
  }

  @override
  Future<void> close() async {}
}

void main() {
  late Directory root, audio;
  late _GatedDatabase db;
  late ApiClient api;
  late TransferService transfers;
  late List<String> fileChanges;
  late List<bool> cleaningChanges;
  String? playing;
  var requests = 0;
  final bytes = [1, 2, 3, 4];
  Track track(String id) => Track(
    id: id,
    title: id,
    sizeBytes: bytes.length,
    sha256: sha256.convert(bytes).toString(),
    album: 'Album',
    artist: 'Artist',
  );

  TransferService create({DownloadFileVerifier Function()? verifier}) =>
      TransferService(
        api: api,
        database: db,
        directory: audio,
        importsDirectory: Directory(p.join(root.path, 'imports')),
        onChanged: () {},
        onTrack: (_) async {},
        onError: (e) => fail('$e'),
        onFileChanged: (id, record) {
          if (record == null) fileChanges.add(id);
        },
        onCleanupChanged: () =>
            cleaningChanges.add(transfers.cleaningDownloads),
        currentTrackId: () => playing,
        verificationWorkerFactory: verifier,
      );

  Future<File> cache(String id, {String? name, bool progress = true}) async {
    await db.put('track', id, track(id).toJson());
    final file = await File(p.join(audio.path, name ?? '$id.audio'))
        .writeAsBytes(bytes);
    await db.put('file', id, {
      'id': id,
      'path': file.path,
      'sha256': track(id).sha256,
    });
    if (progress) {
      await db.put(
        'download',
        id,
        DownloadProgress(
          trackId: id,
          totalBytes: 4,
          receivedBytes: 4,
          status: DownloadStatus.downloaded,
        ).toJson(),
      );
    }
    return file;
  }

  Future<void> pin(String type, String id) =>
      db.put('pin', '$type:$id', PinSelection(type, id).toJson());
  Future<void> gateRead() async {
    db.readStarted = Completer<void>();
    db.releaseRead = Completer<void>();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yun-cleanup-');
    audio = await Directory(p.join(root.path, 'audio')).create();
    db = _GatedDatabase();
    requests = 0;
    playing = null;
    fileChanges = [];
    cleaningChanges = [];
    api = ApiClient(dio: Dio(), credentials: MemoryCredentials())
      ..session = SessionCredentials(
        account: const Account(
          server: 'https://yun.test',
          userId: 'a',
          username: 'a',
        ),
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
      );
    api.dio.httpClientAdapter = FakeAdapter((_, _) {
      requests++;
      return ResponseBody.fromBytes(bytes, 200);
    });
    transfers = create();
  });
  tearDown(() async {
    await transfers.close();
    await db.close();
    await root.delete(recursive: true);
  });

  test('public const summary, deduplicated local totals, preview has no side effects', () async {
    const summary = UnusedDownloadPreview(fileCount: 2, totalBytes: 8);
    expect(summary.fileCount, 2);
    final file = await cache('a', name: 'legacy-cache');
    final part = await File(p.join(audio.path, 'orphan.audio.part'))
        .writeAsBytes([9, 8, 7]);
    await transfers.restoreDownloads();
    await db.put('file', 'alias', {'id': 'alias', 'path': file.path});
    final before = {
      for (final kind in ['track', 'file', 'download', 'pin', 'upload'])
        kind: await db.list(kind),
    };
    final progress = transfers.downloads;
    final preview = await transfers.previewUnusedDownloads();
    expect(preview.fileCount, 2);
    expect(preview.totalBytes, 7);
    expect(transfers.downloads, progress);
    for (final kind in before.keys) {
      expect(await db.list(kind), before[kind]);
    }
    expect(await file.exists(), isTrue);
    expect(await part.exists(), isTrue);
    expect(fileChanges, isEmpty);
    expect(cleaningChanges, [true, false]);
    expect(requests, 0);
    final result = await transfers.purgeUnusedDownloads(preview);
    expect(result.fileCount, 2);
    expect(result.totalBytes, 7);
    expect(await file.exists(), isFalse);
    expect(await part.exists(), isFalse);
    expect(await db.list('file'), isEmpty);
    expect(await db.list('download'), isEmpty);
    expect(transfers.progressFor('a'), isNull);
    expect(fileChanges.toSet(), {'a', 'alias'});
    expect(requests, 0);
    expect((await transfers.purgeUnusedDownloads(preview)).fileCount, 0);
  });

  test('live track/album/playlist overlap and selected repairs preserve every path', () async {
    final kept = await cache('kept', name: 'custom-recorded-cache');
    await pin('track', 'kept');
    await pin('album', albumPinId('Album', 'Artist'));
    await db.put(
      'playlist',
      'p',
      const Playlist(
        id: 'p',
        name: 'P',
        entries: [
          PlaylistEntry(id: '1', trackId: 'kept'),
          PlaylistEntry(id: '2', trackId: 'repair'),
        ],
      ).toJson(),
    );
    await pin('playlist', 'p');
    await db.put('track', 'repair', track('repair').toJson());
    await db.put(
      'download',
      'repair',
      const DownloadProgress(
        trackId: 'repair',
        totalBytes: 4,
        status: DownloadStatus.failed,
        repairRequired: true,
      ).toJson(),
    );
    final paths = [
      kept,
      await File(p.join(audio.path, 'kept.audio')).writeAsBytes(bytes),
      await File(p.join(audio.path, 'kept.audio.part')).writeAsBytes(bytes),
      await File(p.join(audio.path, 'repair.audio')).writeAsBytes(bytes),
      await File(p.join(audio.path, 'repair.audio.part')).writeAsBytes(bytes),
    ];
    await transfers.restoreDownloads();
    final preview = await transfers.previewUnusedDownloads();
    expect(preview.fileCount, 0);
    await transfers.purgeUnusedDownloads(preview);
    for (final file in paths) {
      expect(await file.exists(), isTrue);
    }
    expect(transfers.progressFor('repair')!.repairRequired, isTrue);
    expect(transfers.verificationProgress!.invalidTrackIds, ['repair']);
    // Removing one of several overlapping selections still retains the copy.
    await db.remove('pin', 'track:kept');
    expect((await transfers.previewUnusedDownloads()).fileCount, 0);
    expect(requests, 0);
  });

  test('paused/current track protects audio, partial and custom path at preview and purge', () async {
    final file = await cache('playing', name: 'custom-recorded-cache');
    final standard = await File(p.join(audio.path, 'playing.audio'))
        .writeAsBytes(bytes);
    final part = await File(p.join(audio.path, 'playing.audio.part'))
        .writeAsBytes(bytes);
    playing = 'playing';
    expect((await transfers.previewUnusedDownloads()).fileCount, 0);
    playing = null;
    expect(
      (await transfers.previewUnusedDownloads(protectedTrackId: 'playing'))
          .fileCount,
      0,
    );
    final preview = await transfers.previewUnusedDownloads();
    expect(preview.fileCount, 3);
    playing = 'playing';
    expect((await transfers.purgeUnusedDownloads(preview)).fileCount, 0);
    for (final kept in [file, standard, part]) {
      expect(await kept.exists(), isTrue);
    }
    expect(await db.get('file', 'playing'), isNotNull);
  });

  test('never follows links or removes external, nested, artwork or upload bytes/records', () async {
    final external = await File(p.join(root.path, 'external.audio'))
        .writeAsBytes(bytes);
    final nested = await Directory(p.join(audio.path, 'nested')).create();
    final nestedFile = await File(p.join(nested.path, 'nested.audio'))
        .writeAsBytes(bytes);
    final artwork = await File(p.join(audio.path, 'art.png'))
        .writeAsBytes(bytes);
    final upload = await File(p.join(audio.path, 'upload.source'))
        .writeAsBytes(bytes);
    final imports = await Directory(p.join(root.path, 'imports')).create();
    final source = await File(p.join(imports.path, 'source.audio.part'))
        .writeAsBytes(bytes);
    final link = await Link(p.join(audio.path, 'linked.audio'))
        .create(external.path);
    final dirLink = await Link(p.join(audio.path, 'directory.audio'))
        .create(nested.path);
    final fakeFile = await Directory(p.join(audio.path, 'directory.audio.part'))
        .create();
    final unsafe = {
      'external': external.path,
      'nested': nestedFile.path,
      'art': artwork.path,
      'upload': upload.path,
      'link': link.path,
      'dir': fakeFile.path,
    };
    for (final entry in unsafe.entries) {
      await db.put('file', entry.key, {'id': entry.key, 'path': entry.value});
      await db.put(
        'download',
        entry.key,
        DownloadProgress(
          trackId: entry.key,
          totalBytes: 4,
          status: DownloadStatus.failed,
          repairRequired: true,
        ).toJson(),
      );
    }
    await db.put(
      'upload',
      'source',
      UploadJob(
        id: 'source',
        localPath: source.path,
        filename: 'source',
        sizeBytes: 4,
        ownedSource: true,
      ).toJson(),
    );
    final safe = await File(p.join(audio.path, 'orphan.audio.part'))
        .writeAsBytes([1]);
    final before = await db.list('file');
    final preview = await transfers.previewUnusedDownloads();
    expect(preview.fileCount, 1);
    expect(preview.totalBytes, 1);
    await transfers.purgeUnusedDownloads(preview);
    expect(await safe.exists(), isFalse);
    for (final file in [external, nestedFile, artwork, upload, source]) {
      expect(await file.exists(), isTrue);
    }
    expect(await link.exists(), isTrue);
    expect(await dirLink.exists(), isTrue);
    expect(await db.list('file'), before);
    expect(await db.list('download'), hasLength(unsafe.length));
    expect(await db.get('upload', 'source'), isNotNull);
    expect(requests, 0);
  });

  test('stable symlink ancestors support preview and cleanup', () async {
    await transfers.close();
    final storage = await Directory(p.join(root.path, 'storage')).create();
    final alias = await Link(p.join(root.path, 'storage-alias'))
        .create(storage.path);
    audio = await Directory(p.join(alias.path, 'audio')).create();
    transfers = create();
    final file = await cache('a');
    final preview = await transfers.previewUnusedDownloads();
    expect(preview.fileCount, 1);
    expect((await transfers.purgeUnusedDownloads(preview)).fileCount, 1);
    expect(await file.exists(), isFalse);
    expect(await db.get('file', 'a'), isNull);
  });

  test('retargeted symlink ancestors invalidate cleanup ownership', () async {
    await transfers.close();
    final storage = await Directory(p.join(root.path, 'storage')).create();
    final alias = await Link(p.join(root.path, 'storage-alias'))
        .create(storage.path);
    audio = await Directory(p.join(alias.path, 'audio')).create();
    transfers = create();
    await cache('a');
    final preview = await transfers.previewUnusedDownloads();
    final other = await Directory(p.join(root.path, 'other', 'audio'))
        .create(recursive: true);
    final replacement = await File(p.join(other.path, 'a.audio'))
        .writeAsBytes(bytes);
    await alias.delete();
    await alias.create(p.dirname(other.path));
    expect((await transfers.purgeUnusedDownloads(preview)).fileCount, 0);
    expect(await replacement.exists(), isTrue);
    expect(
      await File(p.join(storage.path, 'audio', 'a.audio')).exists(),
      isTrue,
    );
    expect(await db.get('file', 'a'), isNotNull);
  });

  test('large stale inventories yield between scan batches', () async {
    await db.transaction(() async {
      for (var i = 0; i < 1024; i++) {
        await db.put('file', '$i', {
          'id': '$i',
          'path': p.join(audio.path, '$i.audio'),
        });
      }
    });
    var ticks = 0;
    Timer? heartbeat;
    db.afterInventoryRead = () {
      heartbeat = Timer.periodic(Duration.zero, (_) => ticks++);
    };
    try {
      expect((await transfers.previewUnusedDownloads()).fileCount, 0);
      expect(ticks, greaterThanOrEqualTo(10));
      expect(await db.list('file'), hasLength(1024));
    } finally {
      heartbeat?.cancel();
      db.afterInventoryRead = null;
    }
  });

  test('symlinked audio directory is never scanned or purged', () async {
    await audio.delete();
    final externalDirectory = await Directory(p.join(root.path, 'external'))
        .create();
    final file = await File(p.join(externalDirectory.path, 'orphan.audio'))
        .writeAsBytes(bytes);
    final link = await Link(audio.path).create(externalDirectory.path);
    final preview = await transfers.previewUnusedDownloads();
    expect(preview.fileCount, 0);
    await transfers.purgeUnusedDownloads(preview);
    expect(await file.exists(), isTrue);
    await link.delete();
  });

  test('upload sources are protected even when a malformed job names an owned audio file', () async {
    final source = await File(p.join(audio.path, 'upload.audio'))
        .writeAsBytes(bytes);
    await db.put('file', 'upload', {'id': 'upload', 'path': source.path});
    await db.put(
      'upload',
      'job',
      UploadJob(
        id: 'job',
        localPath: source.path,
        filename: 'upload',
        sizeBytes: 4,
        ownedSource: true,
      ).toJson(),
    );
    final preview = await transfers.previewUnusedDownloads();
    expect(preview.fileCount, 0);
    await transfers.purgeUnusedDownloads(preview);
    expect(await source.exists(), isTrue);
    expect(await db.get('file', 'upload'), isNotNull);
    // A job created after preview also protects its source at confirmation.
    await db.remove('upload', 'job');
    final candidate = await transfers.previewUnusedDownloads();
    expect(candidate.fileCount, 1);
    await db.put(
      'upload',
      'job',
      UploadJob(
        id: 'job',
        localPath: source.path,
        filename: 'upload',
        sizeBytes: 4,
        ownedSource: true,
      ).toJson(),
    );
    expect((await transfers.purgeUnusedDownloads(candidate)).fileCount, 0);
  });

  test('directory replaced by a symlink while confirmation is open preserves everything', () async {
    await cache('a');
    final preview = await transfers.previewUnusedDownloads();
    final relocated = await audio.rename(p.join(root.path, 'relocated'));
    final link = await Link(audio.path).create(relocated.path);
    expect((await transfers.purgeUnusedDownloads(preview)).fileCount, 0);
    expect(await File(p.join(relocated.path, 'a.audio')).exists(), isTrue);
    expect(await db.get('file', 'a'), isNotNull);
    await link.delete();
  });

  test(
    'startup leaves unknown unsafe records and their external bytes alone',
    () async {
      final external = await File(p.join(root.path, 'external.audio'))
          .writeAsBytes(bytes);
      await db.put('file', 'unknown', {'id': 'unknown', 'path': external.path});
      await transfers.restoreDownloads();
      expect(await external.exists(), isTrue);
      expect(await db.get('file', 'unknown'), isNotNull);
      final preview = await transfers.previewUnusedDownloads();
      expect(preview.fileCount, 0);
      await transfers.purgeUnusedDownloads(preview);
      expect(await external.exists(), isTrue);
    },
  );

  test('a preview cannot cross accounts even if a caller improperly reuses a service', () async {
    final file = await cache('a');
    final preview = await transfers.previewUnusedDownloads();
    api.session = const SessionCredentials(
      account: Account(
        server: 'https://yun.test',
        userId: 'other',
        username: 'other',
      ),
      accessToken: 'other',
      refreshToken: 'other',
      expiresAt: 0,
    );
    await expectLater(
      transfers.purgeUnusedDownloads(preview),
      throwsStateError,
    );
    expect(await file.exists(), isTrue);
    expect(requests, 0);
  });

  test(
    'rejects caller-created, foreign-service and closed-service previews',
    () async {
      final file = await cache('a');
      final preview = await transfers.previewUnusedDownloads();
      final other = create();
      await expectLater(other.purgeUnusedDownloads(preview), throwsStateError);
      await other.close();
      await expectLater(
        transfers.purgeUnusedDownloads(
          const UnusedDownloadPreview(fileCount: 1, totalBytes: 4),
        ),
        throwsStateError,
      );
      expect(await file.exists(), isTrue);
      await transfers.close();
      await expectLater(
        transfers.purgeUnusedDownloads(preview),
        throwsA(isA<TransferCancelled>()),
      );
    },
  );

  test('changed stat, replaced record, changed metadata and newly appeared files survive', () async {
    final replaced = await cache('replace');
    final recorded = await cache('record');
    final metadata = await cache('metadata');
    final removed = await cache('removed');
    await db.put('file', 'missing', {
      'id': 'missing',
      'path': p.join(audio.path, 'missing.audio'),
    });
    final preview = await transfers.previewUnusedDownloads();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final oldStat = await replaced.stat();
    await replaced.delete();
    await replaced.writeAsBytes(bytes.reversed.toList());
    await replaced.setLastModified(
      oldStat.modified,
    ); // same size/mtime, changed ctime
    await db.put('file', 'record', {
      'id': 'record',
      'path': recorded.path,
      'sha256': 'new',
    });
    await db.put('track', 'metadata', {
      ...track('metadata').toJson(),
      'revision': 9,
    });
    final appeared = await File(p.join(audio.path, 'missing.audio'))
        .writeAsBytes(bytes);
    final newOrphan = await File(p.join(audio.path, 'new.audio.part'))
        .writeAsBytes(bytes);
    final result = await transfers.purgeUnusedDownloads(preview);
    expect(result.fileCount, 1);
    expect(result.totalBytes, 4);
    expect(await removed.exists(), isFalse);
    for (final file in [replaced, recorded, metadata, appeared, newOrphan]) {
      expect(await file.exists(), isTrue);
    }
    for (final id in ['replace', 'record', 'metadata', 'missing']) {
      expect(await db.get('file', id), isNotNull);
    }
  });

  test('new pins and playlist membership added while confirmation is open protect candidates', () async {
    final a = await cache('a'), b = await cache('b');
    // Change playlist membership, not just the explicit pin set.
    await db.put('playlist', 'p', const Playlist(id: 'p', name: 'P').toJson());
    await pin('playlist', 'p');
    final preview = await transfers.previewUnusedDownloads();
    expect(preview.fileCount, 2);
    await pin('track', 'a');
    await db.put(
      'playlist',
      'p',
      const Playlist(
        id: 'p',
        name: 'P',
        entries: [PlaylistEntry(id: 'b', trackId: 'b')],
      ).toJson(),
    );
    expect((await transfers.purgeUnusedDownloads(preview)).fileCount, 0);
    expect(await a.exists(), isTrue);
    expect(await b.exists(), isTrue);
  });

  test('purge waits for an earlier pin transaction and re-reads its committed selection', () async {
    final file = await cache('a');
    final preview = await transfers.previewUnusedDownloads();
    db.pinStarted = Completer<void>();
    db.releasePin = Completer<void>();
    final started = db.pinStarted!.future;
    final pinning = db.transaction(() => pin('track', 'a'));
    await started;
    final purging = transfers.purgeUnusedDownloads(preview);
    db.releasePin!.complete();
    await pinning;
    expect((await purging).fileCount, 0);
    expect(await file.exists(), isTrue);
  });

  test('stale safe records/deleted repairs are pruned, selected repair survives restart', () async {
    final file = await cache('dead');
    await transfers.restoreDownloads();
    await transfers.verifyDownloads();
    await db.remove('track', 'dead');
    await db.put(
      'download',
      'dead',
      const DownloadProgress(
        trackId: 'dead',
        totalBytes: 4,
        status: DownloadStatus.failed,
        repairRequired: true,
      ).toJson(),
    );
    await file.delete();
    await db.put('track', 'live', track('live').toJson());
    await pin('track', 'live');
    await db.put(
      'download',
      'live',
      const DownloadProgress(
        trackId: 'live',
        totalBytes: 4,
        status: DownloadStatus.failed,
        repairRequired: true,
      ).toJson(),
    );
    await transfers.close();
    transfers = create();
    // Keep the stale record for purge, rather than startup invalidating it first.
    final preview = await transfers.previewUnusedDownloads();
    expect(preview.fileCount, 0);
    await transfers.purgeUnusedDownloads(preview);
    expect(await db.get('file', 'dead'), isNull);
    expect(await db.get('download', 'dead'), isNull);
    await transfers.restoreDownloads();
    expect(transfers.progressFor('dead'), isNull);
    expect(transfers.progressFor('live')!.repairRequired, isTrue);
    expect(transfers.verificationProgress!.invalidTrackIds, ['live']);
    expect(requests, 0);
  });

  test('a disappeared candidate is not counted and stale records are still removed', () async {
    final gone = await cache('gone');
    final remaining = await cache('remaining');
    final preview = await transfers.previewUnusedDownloads();
    await gone.delete();
    final result = await transfers.purgeUnusedDownloads(preview);
    expect(result.fileCount, 1);
    expect(result.totalBytes, 4);
    expect(await remaining.exists(), isFalse);
    expect(await db.list('file'), isEmpty);
    expect(await db.list('download'), isEmpty);
  });

  test('purge prunes deleted verification repairs without disturbing selected repair state', () async {
    final bad = await cache('bad');
    await bad.writeAsBytes(bytes.reversed.toList());
    await transfers.verifyDownloads();
    expect(transfers.verificationProgress!.invalidTrackIds, ['bad']);
    await db.remove('track', 'bad');
    await db.put('track', 'live', track('live').toJson());
    await pin('track', 'live');
    await db.put(
      'download',
      'live',
      const DownloadProgress(
        trackId: 'live',
        totalBytes: 4,
        status: DownloadStatus.failed,
        repairRequired: true,
      ).toJson(),
    );
    final preview = await transfers.previewUnusedDownloads();
    await transfers.purgeUnusedDownloads(preview);
    expect(transfers.progressFor('bad'), isNull);
    expect(transfers.verificationProgress!.invalidTrackIds, isEmpty);
    expect(await db.get('download', 'live'), isNotNull);
    await transfers.close();
    transfers = create();
    await transfers.restoreDownloads();
    expect(transfers.progressFor('live')!.repairRequired, isTrue);
    expect(transfers.verificationProgress!.invalidTrackIds, ['live']);
    expect(requests, 0);
  });

  test(
    'verification and live downloads reject both cleanup operations',
    () async {
      await cache('a');
      final preview = await transfers.previewUnusedDownloads();
      final verifier = _Verifier();
      await transfers.close();
      transfers = create(verifier: () => verifier);
      final scanning = transfers.verifyDownloads();
      await verifier.started.future;
      await expectLater(transfers.previewUnusedDownloads(), throwsStateError);
      await expectLater(
        transfers.purgeUnusedDownloads(preview),
        throwsStateError,
      );
      verifier.result.complete(
        const FileVerificationResult(FileVerificationOutcome.valid),
      );
      await scanning;
      await transfers.close();
      transfers = create();
      final freshPreview = await transfers.previewUnusedDownloads();
      final started = Completer<void>(), release = Completer<void>();
      api.dio.httpClientAdapter = FakeAdapter((_, _) async {
        requests++;
        started.complete();
        await release.future;
        return ResponseBody.fromBytes(bytes, 200);
      });
      final syncing = transfers.reconcile(
        [track('new')],
        [],
        const [PinSelection('track', 'new')],
      );
      await started.future;
      await expectLater(transfers.previewUnusedDownloads(), throwsStateError);
      await expectLater(
        transfers.purgeUnusedDownloads(freshPreview),
        throwsStateError,
      );
      release.complete();
      await syncing;
    },
  );

  test('purge queues reconciliation, blocks verification/another purge, and resumes work', () async {
    final file = await cache('a');
    final preview = await transfers.previewUnusedDownloads();
    await gateRead();
    final started = db.readStarted!.future;
    final purging = transfers.purgeUnusedDownloads(preview);
    await started;
    expect(transfers.cleaningDownloads, isTrue);
    await expectLater(transfers.verifyDownloads(), throwsStateError);
    await expectLater(
      transfers.purgeUnusedDownloads(preview),
      throwsStateError,
    );
    var reconciled = false;
    final syncing = transfers
        .reconcile([], [], [])
        .then((_) => reconciled = true);
    await Future<void>.delayed(Duration.zero);
    expect(reconciled, isFalse);
    db.releaseRead!.complete();
    expect((await purging).fileCount, 1);
    await syncing;
    expect(transfers.cleaningDownloads, isFalse);
    expect(await file.exists(), isFalse);
    expect(requests, 0);
  });

  for (final purge in [false, true]) {
    test(
      'close drains ${purge ? 'purge' : 'preview'} and cancels before any unlink',
      () async {
        final file = await cache('a');
        final preview = await transfers.previewUnusedDownloads();
        await gateRead();
        final started = db.readStarted!.future;
        final operation = purge
            ? transfers.purgeUnusedDownloads(preview)
            : transfers.previewUnusedDownloads();
        final expected = expectLater(
          operation,
          throwsA(isA<TransferCancelled>()),
        );
        await started;
        var closed = false;
        final closing = transfers.close().then((_) => closed = true);
        await Future<void>.delayed(Duration.zero);
        expect(closed, isFalse);
        db.releaseRead!.complete();
        await expected;
        await closing;
        expect(await file.exists(), isTrue);
        expect(await db.get('file', 'a'), isNotNull);
      },
    );
  }

  test(
    'an aborted commit can retry the same preview without deleting new files',
    () async {
      final file = await cache('a');
      await transfers.restoreDownloads();
      final preview = await transfers.previewUnusedDownloads();
      db.failRemovalKind = 'file';
      await expectLater(
        transfers.purgeUnusedDownloads(preview),
        throwsStateError,
      );
      expect(await file.exists(), isFalse);
      expect(await db.get('file', 'a'), isNotNull);
      expect(fileChanges, isEmpty);
      expect(transfers.progressFor('a'), isNotNull);
      final newFile = await File(p.join(audio.path, 'new.audio'))
          .writeAsBytes(bytes);
      final retried = await transfers.purgeUnusedDownloads(preview);
      expect(retried.fileCount, 0);
      expect(await db.get('file', 'a'), isNull);
      expect(transfers.progressFor('a'), isNull);
      expect(await newFile.exists(), isTrue);
    },
  );

  test(
    'failed automatic cleanup remains pending for a no-op refresh retry',
    () async {
      final file = await cache('a');
      db.failRemovalKind = 'file';
      await expectLater(transfers.reconcile([], [], []), throwsStateError);
      expect(transfers.hasPendingReconciliation, isTrue);
      expect(await file.exists(), isFalse);
      expect(await db.get('file', 'a'), isNotNull);
      await transfers.reconcile([], [], []);
      expect(await db.get('file', 'a'), isNull);
      expect(transfers.hasPendingReconciliation, isFalse);
      expect(requests, 0);
    },
  );

  test('reconciliation reclaims deleted-track repair bytes/progress without an HTTP call', () async {
    await db.put(
      'download',
      'dead',
      const DownloadProgress(
        trackId: 'dead',
        totalBytes: 4,
        status: DownloadStatus.failed,
        repairRequired: true,
      ).toJson(),
    );
    final audioFile = await File(p.join(audio.path, 'dead.audio'))
        .writeAsBytes(bytes);
    final part = await File(p.join(audio.path, 'dead.audio.part'))
        .writeAsBytes(bytes);
    await transfers.restoreDownloads();
    await transfers.reconcile([], [], []);
    expect(await audioFile.exists(), isFalse);
    expect(await part.exists(), isFalse);
    expect(await db.get('download', 'dead'), isNull);
    expect(transfers.progressFor('dead'), isNull);
    expect(requests, 0);
  });
}
