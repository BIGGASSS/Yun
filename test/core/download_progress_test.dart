import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/transfer_service.dart';

import 'fakes.dart';

class _GatedDatabase extends CacheDatabase {
  _GatedDatabase() : super.memory();

  Future<void> Function(String kind)? afterPut;
  Future<void> Function()? afterCommit;

  @override
  Future<void> put(String kind, String id, Map<String, dynamic> value) async {
    await super.put(kind, id, value);
    await afterPut?.call(kind);
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) async {
    final result = await super.transaction(action, requireNew: requireNew);
    await afterCommit?.call();
    return result;
  }
}

void main() {
  late Directory root;
  late CacheDatabase db;
  late ApiClient api;
  late TransferService transfers;
  late List<DownloadProgress> observed;
  final bytes = List.generate(100, (i) => i);
  late Track track;
  const pins = [PinSelection('track', 't')];

  TransferService create() => TransferService(
    api: api,
    database: db,
    directory: root,
    onChanged: () {},
    onTrack: (_) async {},
    onError: (_) {},
    onDownloadChanged: () {
      final value = transfers.downloads['t'];
      if (value != null) observed.add(value);
    },
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yun-progress-');
    db = _GatedDatabase();
    observed = [];
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
    track = Track(
      id: 't',
      title: 'T',
      sizeBytes: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    );
    transfers = create();
  });
  tearDown(() async {
    await transfers.close();
    await db.close();
    await root.delete(recursive: true);
  });

  test(
    'byte progress includes resumed offset before verified completion',
    () async {
      await File('${root.path}/t.audio.part')
          .writeAsBytes(bytes.take(40).toList());
      final release = Completer<void>();
      final delivered = Completer<void>();
      Stream<Uint8List> stream() async* {
        yield Uint8List.fromList(bytes.sublist(40, 60));
        delivered.complete();
        await release.future;
        yield Uint8List.fromList(bytes.sublist(60));
      }

      api.dio.httpClientAdapter = FakeAdapter((options, _) {
        expect(options.headers['Range'], 'bytes=40-');
        return ResponseBody(
          stream(),
          206,
          headers: {
            'content-range': ['bytes 40-99/100'],
            'etag': ['"${track.sha256}"'],
          },
        );
      });
      final running = transfers.reconcile([track], [], pins);
      await delivered.future;
      while (transfers.downloads['t']!.receivedBytes < 60) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(transfers.downloads['t']!.status, DownloadStatus.downloading);
      expect(transfers.downloads['t']!.receivedBytes, 60);
      expect(transfers.downloads['t']!.fraction, .6);
      expect(await db.get('file', 't'), isNull);
      release.complete();
      await running;
      expect(observed.any((p) => p.receivedBytes == 40), isTrue);
      expect(observed.any((p) => p.status == DownloadStatus.verifying), isTrue);
      expect(transfers.downloads['t']!.status, DownloadStatus.downloaded);
      expect((await db.get('download', 't'))!['received_bytes'], 100);
      expect(await File('${root.path}/t.audio').readAsBytes(), bytes);
    },
  );

  test('failed stream persists partial bytes and error, restart resumes and clears error', () async {
    Stream<Uint8List> broken() async* {
      yield Uint8List.fromList(bytes.take(30).toList());
      throw StateError('connection lost');
    }

    api.dio.httpClientAdapter = FakeAdapter(
      (_, _) => ResponseBody(broken(), 200),
    );
    await transfers.reconcile([track], [], pins);
    expect(transfers.downloads['t']!.status, DownloadStatus.failed);
    expect(transfers.downloads['t']!.receivedBytes, 30);
    expect(transfers.downloads['t']!.error, contains('connection lost'));
    expect(await db.get('file', 't'), isNull);
    await transfers.close();
    transfers = create();
    await transfers.restoreDownloads();
    expect(transfers.downloads['t']!.receivedBytes, 30);
    expect(transfers.downloads['t']!.status, DownloadStatus.failed);
    api.dio.httpClientAdapter = FakeAdapter((options, _) {
      expect(options.headers['Range'], 'bytes=30-');
      return ResponseBody.fromBytes(
        bytes.sublist(30),
        206,
        headers: {
          'content-range': ['bytes 30-99/100'],
        },
      );
    });
    await transfers.reconcile([track], [], pins);
    expect(transfers.downloads['t']!.status, DownloadStatus.downloaded);
    expect(transfers.downloads['t']!.error, isNull);
    await transfers.reconcile([track], [], []);
    expect(transfers.downloads, isEmpty);
    expect(await db.list('download'), isEmpty);
  });

  test('checksum failure reports failed with zero resumable bytes, never downloaded', () async {
    api.dio.httpClientAdapter = FakeAdapter(
      (_, _) => ResponseBody.fromBytes(List.filled(100, 9), 200),
    );
    await transfers.reconcile([track], [], pins);
    final progress = transfers.downloads['t']!;
    expect(progress.status, DownloadStatus.failed);
    expect(progress.receivedBytes, 0);
    expect(progress.error, contains('checksum mismatch'));
    expect(
      observed.where((p) => p.status == DownloadStatus.downloaded),
      isEmpty,
    );
    expect(await db.get('file', 't'), isNull);
    expect(await File('${root.path}/t.audio.part').exists(), isFalse);
  });

  test(
    'interrupted download restores queued using actual durable partial size',
    () async {
      await db.put(
        'download',
        't',
        const DownloadProgress(
          trackId: 't',
          totalBytes: 100,
          receivedBytes: 20,
          status: DownloadStatus.downloading,
        ).toJson(),
      );
      await File('${root.path}/t.audio.part')
          .writeAsBytes(bytes.take(40).toList());
      await transfers.restoreDownloads();
      expect(transfers.downloads['t']!.status, DownloadStatus.queued);
      expect(transfers.downloads['t']!.receivedBytes, 40);
    },
  );

  for (final status in [
    DownloadStatus.downloading,
    DownloadStatus.verifying,
    DownloadStatus.downloaded,
  ]) {
    test('$status restores completed from a committed verified file', () async {
      final file = await File('${root.path}/t.audio').writeAsBytes(bytes);
      await db.put('track', track.id, track.toJson());
      await db.put('file', track.id, {
        'id': track.id,
        'path': file.path,
        'sha256': track.sha256,
      });
      await db.put(
        'download',
        track.id,
        DownloadProgress(
          trackId: track.id,
          totalBytes: 90,
          receivedBytes: 20,
          status: status,
          error: 'stale error',
        ).toJson(),
      );
      api.dio.httpClientAdapter = FakeAdapter(
        (_, _) => throw StateError('Restore and clear must work offline'),
      );
      await transfers.close();
      transfers = create();
      await transfers.restoreDownloads();
      final restored = transfers.progressFor(track.id)!;
      expect(restored.status, DownloadStatus.downloaded);
      expect(restored.receivedBytes, track.sizeBytes);
      expect(restored.totalBytes, track.sizeBytes);
      expect(restored.error, isNull);
      expect(restored.historyCleared, isFalse);
      expect(await db.get('download', track.id), restored.toJson());
      await transfers.clearDoneDownloads([track]);
      expect(transfers.progressFor(track.id)!.historyCleared, isTrue);
      expect(await file.readAsBytes(), bytes);
    });

    for (final invalid in [
      'missing file',
      'missing record',
      'missing track',
      'older revision',
      'truncated file',
      'not a file',
    ]) {
      test(
        '$status stays queued with $invalid instead of valid audio',
        () async {
          final file = File('${root.path}/t.audio');
          if (invalid != 'missing file') {
            await file.writeAsBytes(
              invalid == 'truncated file'
                  ? bytes.take(50).toList()
                  : invalid == 'same-length corruption'
                  ? bytes.reversed.toList()
                  : bytes,
            );
          }
          if (invalid != 'missing track') {
            await db.put('track', track.id, track.toJson());
          }
          if (invalid != 'missing record') {
            await db.put('file', track.id, {
              'id': track.id,
              'path': invalid == 'not a file' ? root.path : file.path,
              'sha256': invalid == 'older revision' ? 'old-hash' : track.sha256,
            });
          }
          await db.put(
            'download',
            track.id,
            DownloadProgress(
              trackId: track.id,
              totalBytes: track.sizeBytes,
              receivedBytes: 20,
              status: status,
              historyCleared: status == DownloadStatus.downloaded,
            ).toJson(),
          );
          await File('${root.path}/t.audio.part')
              .writeAsBytes(bytes.take(40).toList());
          await transfers.restoreDownloads();
          final restored = transfers.progressFor(track.id)!;
          expect(restored.status, DownloadStatus.queued);
          expect(restored.receivedBytes, 40);
          expect(restored.historyCleared, isFalse);
          expect(await db.get('file', track.id), isNull);
          if (invalid != 'missing record' && invalid != 'not a file') {
            expect(await file.exists(), isFalse);
          }
          expect((await db.get('download', track.id))!['status'], 'queued');
          await transfers.clearDoneDownloads([track]);
          expect(transfers.progressFor(track.id), same(restored));
          expect(
            (await db.get('download', track.id))!['history_cleared'],
            isFalse,
          );
          api.dio.httpClientAdapter = FakeAdapter((options, _) {
            expect(options.headers['Range'], 'bytes=40-');
            return ResponseBody.fromBytes(
              bytes.sublist(40),
              206,
              headers: {
                'content-range': ['bytes 40-99/100'],
              },
            );
          });
          await transfers.reconcile([track], [], pins);
          expect(
            transfers.progressFor(track.id)!.status,
            DownloadStatus.downloaded,
          );
          expect(await file.readAsBytes(), bytes);
          expect(await db.get('file', track.id), isNotNull);
        },
      );
    }
  }

  for (final status in [DownloadStatus.queued, DownloadStatus.failed]) {
    test(
      'startup defers same-size corruption with $status activity to manual check',
      () async {
        final file = await File('${root.path}/t.audio')
            .writeAsBytes(bytes.reversed.toList());
        await db.put('track', track.id, track.toJson());
        await db.put('file', track.id, {
          'id': track.id,
          'path': file.path,
          'sha256': track.sha256,
        });
        final saved = DownloadProgress(
          trackId: track.id,
          totalBytes: track.sizeBytes,
          status: status,
          error: status == DownloadStatus.failed ? 'connection lost' : null,
        );
        await db.put('download', track.id, saved.toJson());
        await transfers.restoreDownloads();
        expect(await db.get('file', track.id), isNotNull);
        expect(await file.exists(), isTrue);
        expect(transfers.progressFor(track.id)!.toJson(), saved.toJson());
        expect(await db.get('download', track.id), saved.toJson());
        await transfers.verifyDownloads();
        expect(await db.get('file', track.id), isNull);
        expect(await file.exists(), isFalse);
        expect(transfers.verificationProgress!.invalidFiles, 1);
        expect(transfers.progressFor(track.id)!.repairRequired, isTrue);
      },
    );
  }

  test(
    'clear Done does not dismiss a live replacement at file commit',
    () async {
      var payload = bytes;
      api.dio.httpClientAdapter = FakeAdapter(
        (_, _) => ResponseBody.fromBytes(payload, 200),
      );
      await transfers.reconcile([track], [], pins);
      await transfers.clearDoneDownloads([track]);
      expect(transfers.progressFor(track.id)!.historyCleared, isTrue);

      payload = bytes.reversed.toList();
      track = Track(
        id: track.id,
        title: track.title,
        sizeBytes: payload.length,
        sha256: sha256.convert(payload).toString(),
      );
      final committed = Completer<void>(), release = Completer<void>();
      (db as _GatedDatabase).afterPut = (kind) async {
        if (kind == 'file') {
          committed.complete();
          await release.future;
        }
      };
      final running = transfers.reconcile([track], [], pins);
      try {
        await committed.future;
        expect(
          transfers.progressFor(track.id)!.status,
          DownloadStatus.verifying,
        );
        expect((await db.get('file', track.id))!['sha256'], track.sha256);
        expect(await File('${root.path}/t.audio').readAsBytes(), payload);
        await transfers.clearDoneDownloads([track]);
        expect(
          transfers.progressFor(track.id)!.status,
          DownloadStatus.verifying,
        );
        expect(transfers.progressFor(track.id)!.historyCleared, isFalse);
        expect(
          (await db.get('download', track.id))!['history_cleared'],
          isFalse,
        );
      } finally {
        release.complete();
        await running;
      }
      expect(
        transfers.progressFor(track.id)!.status,
        DownloadStatus.downloaded,
      );
      expect(transfers.progressFor(track.id)!.historyCleared, isFalse);
      expect((await db.get('download', track.id))!['history_cleared'], isFalse);
    },
  );

  test('download starting during clear commit keeps fresh progress', () async {
    api.dio.httpClientAdapter = FakeAdapter(
      (_, _) => ResponseBody.fromBytes(bytes, 200),
    );
    await transfers.reconcile([track], [], pins);
    final committed = Completer<void>(), releaseClear = Completer<void>();
    (db as _GatedDatabase).afterCommit = () async {
      committed.complete();
      await releaseClear.future;
    };
    final clearing = transfers.clearDoneDownloads([track]);
    await committed.future;
    await File('${root.path}/t.audio').delete();
    final started = Completer<void>(), releaseDownload = Completer<void>();
    api.dio.httpClientAdapter = FakeAdapter((_, _) async {
      started.complete();
      await releaseDownload.future;
      return ResponseBody.fromBytes(bytes, 200);
    });
    final running = transfers.reconcile([track], [], pins);
    try {
      await started.future;
      releaseClear.complete();
      await clearing;
      expect(
        transfers.progressFor(track.id)!.status,
        DownloadStatus.downloading,
      );
      expect(transfers.progressFor(track.id)!.historyCleared, isFalse);
      expect((await db.get('download', track.id))!['history_cleared'], isFalse);
    } finally {
      if (!releaseClear.isCompleted) releaseClear.complete();
      releaseDownload.complete();
      await Future.wait([clearing, running]);
    }
    expect(transfers.progressFor(track.id)!.status, DownloadStatus.downloaded);
    expect(transfers.progressFor(track.id)!.historyCleared, isFalse);
  });

  test(
    'clear Done persists across restart and sync, while a new download appears',
    () async {
      var requests = 0;
      api.dio.httpClientAdapter = FakeAdapter((_, _) {
        requests++;
        return ResponseBody.fromBytes(bytes, 200);
      });
      await transfers.reconcile([track], [], pins);
      final localRecord = await db.get('file', track.id);
      await db.put('track', track.id, track.toJson());
      await db.put('pin', 'track:t', pins.single.toJson());
      const failed = DownloadProgress(
        trackId: 'failed',
        totalBytes: 100,
        receivedBytes: 30,
        status: DownloadStatus.failed,
        error: 'connection lost',
      );
      const pending = DownloadProgress(trackId: 'pending', totalBytes: 100);
      await db.put('download', failed.trackId, failed.toJson());
      await db.put('download', pending.trackId, pending.toJson());
      await transfers.restoreDownloads();
      await transfers.clearDoneDownloads([track]);
      expect(transfers.progressFor(track.id)!.historyCleared, isTrue);
      expect((await db.get('download', track.id))!['history_cleared'], isTrue);
      expect(await db.get('file', track.id), localRecord);
      expect(await File('${root.path}/t.audio').readAsBytes(), bytes);
      expect(await db.get('pin', 'track:t'), pins.single.toJson());
      expect(await db.get('download', failed.trackId), failed.toJson());
      expect(await db.get('download', pending.trackId), pending.toJson());

      await transfers.close();
      transfers = create();
      await transfers.restoreDownloads();
      expect(transfers.progressFor(track.id)!.historyCleared, isTrue);
      await transfers.reconcile([track], [], pins);
      expect(requests, 1);
      expect(transfers.progressFor(track.id)!.historyCleared, isTrue);

      await File('${root.path}/t.audio').delete();
      await transfers.reconcile([track], [], pins);
      expect(requests, 2);
      expect(
        transfers.progressFor(track.id)!.status,
        DownloadStatus.downloaded,
      );
      expect(transfers.progressFor(track.id)!.historyCleared, isFalse);
      expect((await db.get('download', track.id))!['history_cleared'], isFalse);
    },
  );

  test(
    'clear Done includes older files without a download activity record',
    () async {
      final file = await File('${root.path}/t.audio').writeAsBytes(bytes);
      await db.put('file', track.id, {
        'id': track.id,
        'path': file.path,
        'sha256': track.sha256,
      });
      expect(transfers.progressFor(track.id), isNull);
      await transfers.clearDoneDownloads([track]);
      expect(transfers.progressFor(track.id)!.historyCleared, isTrue);
      expect(await file.exists(), isTrue);
      expect(await db.get('file', track.id), isNotNull);
    },
  );

  test(
    'close before a request starts does not create a fresh live transport',
    () async {
      final saved = Completer<void>(), release = Completer<void>();
      (db as _GatedDatabase).afterPut = (kind) async {
        if (kind == 'download' && !saved.isCompleted) {
          saved.complete();
          await release.future;
        }
      };
      var requests = 0;
      api.dio.httpClientAdapter = FakeAdapter((_, _) {
        requests++;
        return ResponseBody.fromBytes(bytes, 200);
      });
      final running = transfers.reconcile([track], [], pins);
      await saved.future;
      final closing = transfers.close();
      release.complete();
      await Future.wait([running, closing]);
      expect(requests, 0);
      expect(transfers.progressFor(track.id)!.status, DownloadStatus.queued);
      expect(await db.get('file', track.id), isNull);
    },
  );

  test('old download records default to visible completed activity', () {
    final record = DownloadProgress(
      trackId: track.id,
      totalBytes: 100,
      status: DownloadStatus.downloaded,
    ).toJson()..remove('history_cleared');
    expect(DownloadProgress.fromJson(record).historyCleared, isFalse);
  });
}
