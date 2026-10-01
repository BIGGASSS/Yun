import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/transfer_service.dart';

import 'fakes.dart';

class _ControlledVerifier implements DownloadFileVerifier {
  final started = Completer<void>();
  final result = Completer<FileVerificationResult>();
  bool closed = false;
  @override
  Future<FileVerificationResult> verify(
    VerificationFile file,
    void Function(int) onBytes,
  ) {
    if (!started.isCompleted) started.complete();
    onBytes(file.sizeBytes ~/ 2);
    return result.future;
  }

  @override
  void cancel() {
    if (!result.isCompleted) result.completeError(VerificationCancelled());
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  late Directory directory;
  late CacheDatabase db;
  late ApiClient api;
  late TransferService transfers;
  late List<DownloadVerificationProgress> updates;
  var requests = 0;
  final bytes = List.generate(100, (i) => i);
  Track track(String id) => Track(
    id: id,
    title: id,
    sizeBytes: bytes.length,
    sha256: sha256.convert(bytes).toString(),
  );
  TransferService create({DownloadFileVerifier Function()? verifier}) =>
      TransferService(
        api: api,
        database: db,
        directory: directory,
        onChanged: () {},
        onTrack: (_) async {},
        onError: (_) {},
        verificationWorkerFactory: verifier,
        onVerificationChanged: () {
          final progress = transfers.verificationProgress;
          if (progress != null) updates.add(progress);
        },
      );

  Future<File> cache(
    String id,
    List<int> contents, {
    bool history = false,
  }) async {
    final value = track(id);
    final file = await File('${directory.path}/$id.audio')
        .writeAsBytes(contents);
    await db.put('track', id, value.toJson());
    await db.put('file', id, {
      'id': id,
      'path': file.path,
      'sha256': value.sha256,
    });
    if (history) {
      await db.put(
        'download',
        id,
        DownloadProgress(
          trackId: id,
          totalBytes: value.sizeBytes,
          receivedBytes: value.sizeBytes,
          status: DownloadStatus.downloaded,
          historyCleared: true,
        ).toJson(),
      );
    }
    return file;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('yun-verify-');
    db = CacheDatabase.memory();
    updates = [];
    requests = 0;
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
    await directory.delete(recursive: true);
  });

  test(
    'startup, sync and clear Done never hash existing same-size files',
    () async {
      final file = await cache('t', bytes.reversed.toList(), history: true);
      const pins = [PinSelection('track', 't')];
      await transfers.restoreDownloads();
      expect(transfers.progressFor('t')!.status, DownloadStatus.downloaded);
      await transfers.reconcile([track('t')], [], pins);
      await transfers.clearDoneDownloads([track('t')]);
      expect(await db.get('file', 't'), isNotNull);
      expect(await file.readAsBytes(), bytes.reversed.toList());
      expect(requests, 0);
      expect(updates, isEmpty);
      await transfers.verifyDownloads();
      expect(transfers.verificationProgress!.invalidFiles, 1);
      expect(await db.get('file', 't'), isNull);
      expect(requests, 0);
    },
  );

  test('real isolate verifies valid legacy and history files, invalidates corruption and truncation', () async {
    await cache('legacy', bytes);
    await cache('history', bytes, history: true);
    await cache('corrupt', bytes.reversed.toList(), history: true);
    await cache('short', bytes.take(30).toList());
    final missing = await cache('missing', bytes);
    await missing.delete();
    await db.put('file', 'unknown', {
      'id': 'unknown',
      'path': '${directory.path}/unknown',
    });
    await transfers.verifyDownloads();
    final result = transfers.verificationProgress!;
    expect(result.status, VerificationStatus.completed);
    expect(result.totalFiles, 6);
    expect(result.checkedFiles, 6);
    expect(result.validFiles, 2);
    expect(result.invalidFiles, 3);
    expect(result.skippedFiles, 1);
    expect(result.invalidTrackIds, ['corrupt', 'short', 'missing']);
    expect(result.totalBytes, 500);
    expect(result.processedBytes, 500);
    expect(result.hashedBytes, 300);
    expect(result.fraction, 1);
    expect(requests, 0);
    expect((await db.get('download', 'history'))!['history_cleared'], true);
    expect(await db.get('download', 'legacy'), isNull);
    expect(await db.get('file', 'legacy'), isNotNull);
    for (final id in ['corrupt', 'short', 'missing']) {
      expect(await db.get('file', id), isNull);
      expect(transfers.progressFor(id)!.repairRequired, isTrue);
    }
  });

  test(
    'repair holds survive sync, rescan and restart until explicit redownload',
    () async {
      await cache('t', bytes.reversed.toList());
      await transfers.verifyDownloads();
      // Legacy unselected damaged files keep their repair action after sync.
      await transfers.reconcile([track('t')], [], []);
      expect(requests, 0);
      await transfers.verifyDownloads();
      expect(transfers.verificationProgress!.invalidTrackIds, ['t']);
      await transfers.close();
      transfers = create();
      await transfers.restoreDownloads();
      expect(transfers.verificationProgress!.invalidTrackIds, ['t']);
      const pins = [PinSelection('track', 't')];
      await transfers.reconcile([track('t')], [], pins);
      expect(requests, 0);
      await transfers.redownloadCorruptedFiles([track('t')], [], pins);
      expect(requests, 1);
      expect(await File('${directory.path}/t.audio').readAsBytes(), bytes);
      expect(transfers.progressFor('t')!.repairRequired, isFalse);
      expect(transfers.verificationProgress!.invalidTrackIds, isEmpty);
      await transfers.redownloadCorruptedFiles([track('t')], [], pins);
      expect(requests, 1);
    },
  );

  test('single flight reports partial bytes, cancel closes worker and permits repeat', () async {
    await cache('t', bytes);
    final worker = _ControlledVerifier();
    await transfers.close();
    transfers = create(verifier: () => worker);
    final first = transfers.verifyDownloads();
    expect(transfers.verifyDownloads(), same(first));
    await worker.started.future;
    expect(transfers.verificationProgress!.processedBytes, 50);
    expect(transfers.verificationProgress!.fraction, .5);
    expect(transfers.verificationProgress!.eta, isNull);
    transfers.cancelVerification();
    await first;
    expect(worker.closed, true);
    expect(
      transfers.verificationProgress!.status,
      VerificationStatus.cancelled,
    );
    expect(await db.get('file', 't'), isNotNull);
    await transfers.close();
    transfers = create();
    await transfers.verifyDownloads();
    expect(transfers.verificationProgress!.validFiles, 1);
  });

  test('account close cancels and drains worker without invalidating unchecked audio', () async {
    await cache('t', bytes);
    final worker = _ControlledVerifier();
    await transfers.close();
    transfers = create(verifier: () => worker);
    final scanning = transfers.verifyDownloads();
    await worker.started.future;
    await transfers.close();
    await scanning;
    expect(worker.closed, true);
    expect(await db.get('file', 't'), isNotNull);
  });

  test('changed library identity is skipped rather than invalidated by stale result', () async {
    await cache('t', bytes);
    final worker = _ControlledVerifier();
    await transfers.close();
    transfers = create(verifier: () => worker);
    final scanning = transfers.verifyDownloads();
    await worker.started.future;
    await db.put('track', 't', {...track('t').toJson(), 'sha256': 'new-hash'});
    worker.result.complete(
      const FileVerificationResult(FileVerificationOutcome.invalid),
    );
    await scanning;
    expect(transfers.verificationProgress!.skippedFiles, 1);
    expect(transfers.verificationProgress!.invalidFiles, 0);
    expect(await db.get('file', 't'), isNotNull);
  });

  test('worker failure is terminal and a subsequent scan can run', () async {
    await cache('t', bytes);
    final worker = _ControlledVerifier();
    await transfers.close();
    transfers = create(verifier: () => worker);
    final scanning = transfers.verifyDownloads();
    await worker.started.future;
    worker.result.completeError(StateError('worker failed'));
    await scanning;
    expect(transfers.verificationProgress!.status, VerificationStatus.failed);
    expect(worker.closed, true);
    expect(await db.get('file', 't'), isNotNull);
  });

  test(
    'verification waits for current download then holds corrupt repairs',
    () async {
      await cache('bad', bytes.reversed.toList());
      await db.put('track', 'new', track('new').toJson());
      final started = Completer<void>(), release = Completer<void>();
      api.dio.httpClientAdapter = FakeAdapter((options, _) async {
        requests++;
        started.complete();
        await release.future;
        return ResponseBody.fromBytes(bytes, 200);
      });
      const pins = [PinSelection('track', 'new'), PinSelection('track', 'bad')];
      final syncing = transfers.reconcile(
        [track('new'), track('bad')],
        [],
        pins,
      );
      await started.future;
      final scanning = transfers.verifyDownloads();
      expect(
        transfers.verificationProgress!.status,
        VerificationStatus.preparing,
      );
      release.complete();
      await Future.wait([syncing, scanning]);
      // Drain the automatic pass deferred by verification.
      await transfers.reconcile([track('new'), track('bad')], [], pins);
      expect(requests, 1);
      expect(transfers.verificationProgress!.validFiles, 1);
      expect(transfers.verificationProgress!.invalidTrackIds, ['bad']);
      expect(await db.get('file', 'bad'), isNull);
      expect(await db.get('file', 'new'), isNotNull);
    },
  );

  test(
    'cancel preparing does not wait for an unrelated live download',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      api.dio.httpClientAdapter = FakeAdapter((options, _) async {
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
      final scanning = transfers.verifyDownloads();
      transfers.cancelVerification();
      await scanning.timeout(const Duration(seconds: 2));
      expect(
        transfers.verificationProgress!.status,
        VerificationStatus.cancelled,
      );
      release.complete();
      await syncing;
    },
  );

  test(
    'sync requested during scan waits and leaves damaged files held',
    () async {
      await cache('t', bytes);
      final worker = _ControlledVerifier();
      await transfers.close();
      transfers = create(verifier: () => worker);
      final scanning = transfers.verifyDownloads();
      await worker.started.future;
      final syncing = transfers.reconcile(
        [track('t')],
        [],
        const [PinSelection('track', 't')],
      );
      worker.result.complete(
        const FileVerificationResult(FileVerificationOutcome.invalid),
      );
      await Future.wait([scanning, syncing]);
      expect(requests, 0);
      expect(await db.get('file', 't'), isNull);
      expect(transfers.progressFor('t')!.repairRequired, isTrue);
    },
  );

  test(
    'cancel a real worker during startup resolves as cancellation',
    () async {
      final file = await cache('t', bytes);
      final worker = IsolateDownloadFileVerifier();
      final verifying = worker.verify(
        VerificationFile(
          path: file.path,
          sizeBytes: bytes.length,
          sha256: track('t').sha256,
          recordedSha256: track('t').sha256,
        ),
        (_) {},
      );
      final expectation = expectLater(
        verifying,
        throwsA(isA<VerificationCancelled>()),
      );
      worker.cancel();
      await expectation;
      await worker.close();
    },
  );

  test('empty cache completes immediately without hashing', () async {
    await transfers.verifyDownloads();
    expect(
      transfers.verificationProgress!.status,
      VerificationStatus.completed,
    );
    expect(transfers.verificationProgress!.totalFiles, 0);
    expect(transfers.verificationProgress!.fraction, 1);
    expect(transfers.verificationProgress!.eta, isNull);
  });

  test('ETA waits for measured throughput and excludes metadata-only work', () {
    const measuring = DownloadVerificationProgress(
      status: VerificationStatus.running,
      processedBytes: 500,
      totalBytes: 1500,
      hashedBytes: 100,
      elapsed: Duration(milliseconds: 500),
    );
    expect(measuring.eta, isNull);
    const measured = DownloadVerificationProgress(
      status: VerificationStatus.running,
      processedBytes: 500,
      totalBytes: 1500,
      hashedBytes: 100,
      elapsed: Duration(seconds: 2),
    );
    expect(measured.eta, const Duration(seconds: 20));
    expect(measured.fraction, 1 / 3);
    const noHash = DownloadVerificationProgress(
      status: VerificationStatus.running,
      processedBytes: 500,
      totalBytes: 1500,
      elapsed: Duration(seconds: 2),
    );
    expect(noHash.eta, isNull);
  });
}
