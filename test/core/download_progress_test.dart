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
  int transactions = 0;

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
    transactions++;
    final result = await super.transaction(action, requireNew: requireNew);
    await afterCommit?.call();
    return result;
  }
}

class _DownloadRequestGate {
  final _started = Completer<void>();
  final _release = Completer<void>();
  RequestOptions? request;

  Future<void> get started =>
      _started.future.timeout(const Duration(seconds: 5));

  Future<ResponseBody> respond(
    RequestOptions options,
    ResponseBody response,
  ) async {
    if (_started.isCompleted) throw StateError('Unexpected duplicate request');
    request = options;
    _started.complete();
    await _release.future;
    return response;
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}

void main() {
  late Directory root;
  late CacheDatabase db;
  late ApiClient api;
  late TransferService transfers;
  late List<DownloadProgress> observed;
  late List<bool> observedRunning;
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
      if (value != null) {
        observed.add(value);
        observedRunning.add(transfers.hasRunningDownloads);
      }
    },
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yun-progress-');
    db = _GatedDatabase();
    observed = [];
    observedRunning = [];
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

  group('current download batch progress', () {
    Track anotherTrack(String id) =>
        Track(id: id, title: id, sizeBytes: bytes.length, sha256: track.sha256);

    Future<File> cache(Track value) async {
      final file = await File('${root.path}/${value.id}.audio')
          .writeAsBytes(bytes);
      await db.put('track', value.id, value.toJson());
      await db.put('file', value.id, {
        'id': value.id,
        'path': file.path,
        'sha256': value.sha256,
        'references': 1,
      });
      await db.put(
        'download',
        value.id,
        DownloadProgress(
          trackId: value.id,
          totalBytes: value.sizeBytes,
          receivedBytes: value.sizeBytes,
          status: DownloadStatus.downloaded,
        ).toJson(),
      );
      return file;
    }

    List<String> gateRequests(Map<String, _DownloadRequestGate> gates) {
      final requests = <String>[];
      api.dio.httpClientAdapter = FakeAdapter((options, _) {
        final id = Uri.parse(options.path).pathSegments.reversed.elementAt(1);
        requests.add(id);
        return gates[id]!.respond(options, ResponseBody.fromBytes(bytes, 200));
      });
      return requests;
    }

    test(
      '505 cached downloads do not count, including after clearing Done',
      () async {
        final cached = List.generate(505, (i) => anotherTrack('cached-$i'));
        for (final value in cached) {
          await cache(value);
        }
        await transfers.restoreDownloads();
        expect(transfers.downloads, hasLength(505));
        expect(transfers.downloadBatchProgress, (completed: 0, total: 0));
        final allTracks = [...cached, track];
        final allPins = [
          for (final value in allTracks) PinSelection('track', value.id),
        ];
        final gate = _DownloadRequestGate();
        final requests = gateRequests({track.id: gate});
        final running = transfers.reconcile(allTracks, [], allPins);
        try {
          await gate.started;
          expect(transfers.hasRunningDownloads, isTrue);
          expect(transfers.downloadBatchProgress, (completed: 0, total: 1));
          await transfers.clearDoneDownloads(allTracks);
          expect(
            cached.every(
              (value) => transfers.progressFor(value.id)!.historyCleared,
            ),
            isTrue,
          );
          expect(transfers.progressFor(track.id)!.historyCleared, isFalse);
          expect(transfers.downloadBatchProgress, (completed: 0, total: 1));
        } finally {
          gate.release();
          await running;
        }
        expect(requests, [track.id]);
        expect(
          transfers.progressFor(track.id)!.status,
          DownloadStatus.downloaded,
        );
        expect(transfers.hasRunningDownloads, isFalse);
        expect(transfers.downloadBatchProgress, (completed: 0, total: 0));
      },
    );

    test(
      'plans both sequential tasks and retains the first completion',
      () async {
        final second = anotherTrack('second');
        final allTracks = [track, second];
        final allPins = [
          for (final value in allTracks) PinSelection('track', value.id),
        ];
        final firstGate = _DownloadRequestGate();
        final secondGate = _DownloadRequestGate();
        final requests = gateRequests({
          track.id: firstGate,
          second.id: secondGate,
        });
        final committed = Completer<void>(), releaseCommit = Completer<void>();
        (db as _GatedDatabase).afterPut = (kind) async {
          if (kind == 'file' && !committed.isCompleted) {
            committed.complete();
            await releaseCommit.future;
          }
        };
        final running = transfers.reconcile(allTracks, [], allPins);
        try {
          await firstGate.started;
          expect(transfers.downloadBatchProgress, (completed: 0, total: 2));
          expect(transfers.hasRunningDownloads, isTrue);
          expect(
            transfers.progressFor(second.id)!.status,
            DownloadStatus.queued,
          );
          firstGate.release();
          await committed.future.timeout(const Duration(seconds: 5));
          expect(
            transfers.progressFor(track.id)!.status,
            DownloadStatus.verifying,
          );
          expect(transfers.downloadBatchProgress, (completed: 0, total: 2));
          releaseCommit.complete();
          await secondGate.started;
          expect(
            transfers.progressFor(track.id)!.status,
            DownloadStatus.downloaded,
          );
          expect(transfers.hasRunningDownloads, isTrue);
          expect(transfers.downloadBatchProgress, (completed: 1, total: 2));
          await transfers.clearDoneDownloads(allTracks);
          expect(transfers.progressFor(track.id)!.historyCleared, isTrue);
          expect(transfers.downloadBatchProgress, (completed: 1, total: 2));
        } finally {
          firstGate.release();
          secondGate.release();
          if (!releaseCommit.isCompleted) releaseCommit.complete();
          await running;
        }
        expect(requests, [track.id, second.id]);
        expect(
          transfers.progressFor(second.id)!.status,
          DownloadStatus.downloaded,
        );
        expect(transfers.hasRunningDownloads, isFalse);
        expect(transfers.downloadBatchProgress, (completed: 0, total: 0));
      },
    );

    test(
      'failure is not completion and a retry excludes earlier successes',
      () async {
        final failed = anotherTrack('failed');
        final last = anotherTrack('last');
        final allTracks = [track, failed, last];
        final allPins = [
          for (final value in allTracks) PinSelection('track', value.id),
        ];
        for (final value in allTracks) {
          await db.put('track', value.id, value.toJson());
        }
        final lastGate = _DownloadRequestGate(),
            retryGate = _DownloadRequestGate();
        final requests = <String>[];
        var attempts = 0;
        Stream<Uint8List> broken() async* {
          yield Uint8List.fromList(bytes.take(30).toList());
          throw StateError('connection lost');
        }

        api.dio.httpClientAdapter = FakeAdapter((options, _) {
          final id = Uri.parse(options.path).pathSegments.reversed.elementAt(1);
          requests.add(id);
          if (id == failed.id) {
            if (++attempts == 1) return ResponseBody(broken(), 200);
            return retryGate.respond(
              options,
              ResponseBody.fromBytes(
                bytes.sublist(30),
                206,
                headers: {
                  'content-range': ['bytes 30-99/100'],
                },
              ),
            );
          }
          if (id == last.id) {
            return lastGate.respond(
              options,
              ResponseBody.fromBytes(bytes, 200),
            );
          }
          return ResponseBody.fromBytes(bytes, 200);
        });
        final running = transfers.reconcile(allTracks, [], allPins);
        try {
          await lastGate.started;
          expect(
            transfers.progressFor(track.id)!.status,
            DownloadStatus.downloaded,
          );
          expect(
            transfers.progressFor(failed.id)!.status,
            DownloadStatus.failed,
          );
          expect(transfers.progressFor(failed.id)!.receivedBytes, 30);
          expect(transfers.downloadBatchProgress, (completed: 1, total: 3));
        } finally {
          lastGate.release();
          await running;
        }
        expect(transfers.hasRunningDownloads, isFalse);
        expect(transfers.downloadBatchProgress, (completed: 0, total: 0));
        final retrying = transfers.reconcile(allTracks, [], allPins);
        try {
          await retryGate.started;
          expect(retryGate.request!.headers['Range'], 'bytes=30-');
          expect(transfers.hasRunningDownloads, isTrue);
          expect(transfers.downloadBatchProgress, (completed: 0, total: 1));
        } finally {
          retryGate.release();
          await retrying;
        }
        expect(requests, [track.id, failed.id, last.id, failed.id]);
        expect(
          transfers.progressFor(failed.id)!.status,
          DownloadStatus.downloaded,
        );
        expect(transfers.downloadBatchProgress, (completed: 0, total: 0));
      },
    );

    test(
      'explicit redownload of a cached track is a fresh batch task',
      () async {
        final file = await cache(track);
        await transfers.restoreDownloads();
        await transfers.clearDoneDownloads([track]);
        final gate = _DownloadRequestGate();
        final requests = gateRequests({track.id: gate});
        await transfers.reconcile([track], [], pins);
        expect(requests, isEmpty);
        expect(transfers.downloadBatchProgress, (completed: 0, total: 0));
        final running = transfers.redownloadTrack(track, [track], [], pins);
        try {
          await gate.started;
          expect(transfers.progressFor(track.id)!.historyCleared, isFalse);
          expect(transfers.hasRunningDownloads, isTrue);
          expect(transfers.downloadBatchProgress, (completed: 0, total: 1));
          expect(await file.readAsBytes(), bytes);
          await transfers.clearDoneDownloads([track]);
          expect(transfers.downloadBatchProgress, (completed: 0, total: 1));
        } finally {
          gate.release();
          await running;
        }
        expect(requests, [track.id]);
        expect(
          transfers.progressFor(track.id)!.status,
          DownloadStatus.downloaded,
        );
        expect(transfers.downloadBatchProgress, (completed: 0, total: 0));
      },
    );

    test('repair-held files are excluded until explicit redownload', () async {
      final held = anotherTrack('held');
      await (await cache(held)).delete();
      await transfers.restoreDownloads();
      expect(transfers.progressFor(held.id)!.repairRequired, isTrue);
      final allTracks = [held, track];
      final allPins = [
        for (final value in allTracks) PinSelection('track', value.id),
      ];
      final newGate = _DownloadRequestGate(),
          repairGate = _DownloadRequestGate();
      final requests = gateRequests({track.id: newGate, held.id: repairGate});
      final running = transfers.reconcile(allTracks, [], allPins);
      try {
        await newGate.started;
        expect(transfers.downloadBatchProgress, (completed: 0, total: 1));
        expect(transfers.progressFor(held.id)!.repairRequired, isTrue);
        expect(requests, [track.id]);
      } finally {
        newGate.release();
        await running;
      }
      expect(transfers.downloadBatchProgress, (completed: 0, total: 0));
      final repairing = transfers.redownloadTrack(held, allTracks, [], allPins);
      try {
        await repairGate.started;
        expect(transfers.progressFor(held.id)!.repairRequired, isFalse);
        expect(transfers.downloadBatchProgress, (completed: 0, total: 1));
      } finally {
        repairGate.release();
        await repairing;
      }
      expect(requests, [track.id, held.id]);
      expect(transfers.progressFor(held.id)!.status, DownloadStatus.downloaded);
      expect(transfers.downloadBatchProgress, (completed: 0, total: 0));
    });

    test(
      'a newly pinned trailing task retains the earlier batch completion',
      () async {
        final added = anotherTrack('added');
        final allTracks = [track, added];
        final allPins = [
          for (final value in allTracks) PinSelection('track', value.id),
        ];
        final firstGate = _DownloadRequestGate(),
            addedGate = _DownloadRequestGate();
        final requests = gateRequests({
          track.id: firstGate,
          added.id: addedGate,
        });
        final running = transfers.reconcile(allTracks, [], pins);
        Future<void>? trailing;
        try {
          await firstGate.started;
          expect(transfers.downloadBatchProgress, (completed: 0, total: 1));
          trailing = transfers.reconcile(allTracks, [], allPins);
          firstGate.release();
          await addedGate.started;
          expect(
            transfers.progressFor(track.id)!.status,
            DownloadStatus.downloaded,
          );
          expect(transfers.hasRunningDownloads, isTrue);
          expect(transfers.downloadBatchProgress, (completed: 1, total: 2));
          await transfers.clearDoneDownloads(allTracks);
          expect(transfers.downloadBatchProgress, (completed: 1, total: 2));
        } finally {
          firstGate.release();
          addedGate.release();
          await Future.wait([running, ?trailing]);
        }
        expect(requests, [track.id, added.id]);
        expect(
          transfers.progressFor(added.id)!.status,
          DownloadStatus.downloaded,
        );
        expect(transfers.hasRunningDownloads, isFalse);
        expect(transfers.downloadBatchProgress, (completed: 0, total: 0));
      },
    );
    test(
      'verification pause retains the current batch until it resumes',
      () async {
        final second = anotherTrack('second');
        final allTracks = [track, second];
        final allPins = [
          for (final value in allTracks) PinSelection('track', value.id),
        ];
        for (final value in allTracks) {
          await db.put('track', value.id, value.toJson());
        }
        final firstGate = _DownloadRequestGate(),
            secondGate = _DownloadRequestGate();
        final requests = gateRequests({
          track.id: firstGate,
          second.id: secondGate,
        });
        final scanCommitted = Completer<void>(),
            releaseScan = Completer<void>();
        (db as _GatedDatabase).afterCommit = () async {
          if (!scanCommitted.isCompleted) {
            scanCommitted.complete();
            await releaseScan.future;
          }
        };
        final running = transfers.reconcile(allTracks, [], allPins);
        Future<void>? scanning, deferred, resumed;
        try {
          await firstGate.started;
          expect(transfers.downloadBatchProgress, (completed: 0, total: 2));
          scanning = transfers.verifyDownloads();
          firstGate.release();
          await scanCommitted.future.timeout(const Duration(seconds: 5));
          await running;
          expect(
            transfers.verificationProgress!.status,
            VerificationStatus.running,
          );
          expect(
            transfers.progressFor(track.id)!.status,
            DownloadStatus.downloaded,
          );
          expect(
            transfers.progressFor(second.id)!.status,
            DownloadStatus.queued,
          );
          expect(transfers.hasRunningDownloads, isFalse);
          expect(transfers.downloadBatchProgress, (completed: 1, total: 2));
          deferred = transfers.reconcile(allTracks, [], allPins);
          await transfers.clearDoneDownloads(allTracks);
          expect(transfers.downloadBatchProgress, (completed: 1, total: 2));
          releaseScan.complete();
          await secondGate.started;
          // The initial drain ends at the verification pause. Join the resumed
          // drain so cleanup waits for the second worker, not just the scan.
          resumed = transfers.reconcile(allTracks, [], allPins);
          expect(transfers.hasRunningDownloads, isTrue);
          expect(transfers.downloadBatchProgress, (completed: 1, total: 2));
        } finally {
          firstGate.release();
          secondGate.release();
          if (!releaseScan.isCompleted) releaseScan.complete();
          await Future.wait([running, ?scanning, ?deferred, ?resumed]);
        }
        expect(requests, [track.id, second.id]);
        expect(
          transfers.progressFor(second.id)!.status,
          DownloadStatus.downloaded,
        );
        expect(transfers.verificationProgress!.validFiles, 1);
        expect(transfers.hasRunningDownloads, isFalse);
        expect(transfers.downloadBatchProgress, (completed: 0, total: 0));
      },
    );
  });

  test(
    'legacy completion migration commits once before publishing memory',
    () async {
      final file = await File('${root.path}/legacy.audio').writeAsBytes(bytes);
      for (final id in ['t', 'second', 'third']) {
        await db.put('track', id, {...track.toJson(), 'id': id});
        await db.put('file', id, {
          'id': id,
          'path': file.path,
          'sha256': track.sha256,
        });
      }
      final committed = Completer<void>(), release = Completer<void>();
      (db as _GatedDatabase).afterCommit = () async {
        committed.complete();
        await release.future;
      };
      final restoring = transfers.restoreDownloads();
      try {
        await committed.future;
        expect((db as _GatedDatabase).transactions, 1);
        expect(transfers.downloads, isEmpty);
        expect(await db.list('download'), hasLength(3));
      } finally {
        release.complete();
        await restoring;
      }
      expect(transfers.downloads, hasLength(3));
      expect(
        transfers.downloads.values.every(
          (progress) =>
              progress.requiresOfflinePlayback && !progress.historyCleared,
        ),
        isTrue,
      );
      expect(await file.readAsBytes(), bytes);
    },
  );

  test(
    'failed legacy migration publishes no partial download intent',
    () async {
      final file = await File('${root.path}/legacy.audio').writeAsBytes(bytes);
      for (final id in ['t', 'second']) {
        await db.put('track', id, {...track.toJson(), 'id': id});
        await db.put('file', id, {
          'id': id,
          'path': file.path,
          'sha256': track.sha256,
        });
      }
      var writes = 0;
      (db as _GatedDatabase).afterPut = (kind) async {
        if (kind == 'download' && ++writes == 2) throw StateError('disk full');
      };
      await expectLater(transfers.restoreDownloads(), throwsStateError);
      expect(transfers.downloads, isEmpty);
      expect(await db.list('download'), isEmpty);
      expect(await db.list('file'), hasLength(2));
      expect(await file.readAsBytes(), bytes);
    },
  );

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
      expect(transfers.hasRunningDownloads, isFalse);
      final running = transfers.reconcile([track], [], pins);
      await delivered.future;
      while (transfers.downloads['t']!.receivedBytes < 60) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(transfers.downloads['t']!.status, DownloadStatus.downloading);
      expect(transfers.hasRunningDownloads, isTrue);
      expect(transfers.downloads['t']!.receivedBytes, 60);
      expect(transfers.downloads['t']!.fraction, .6);
      expect(await db.get('file', 't'), isNull);
      release.complete();
      await running;
      expect(observed.any((p) => p.receivedBytes == 40), isTrue);
      expect(observed.any((p) => p.status == DownloadStatus.verifying), isTrue);
      expect(transfers.downloads['t']!.status, DownloadStatus.downloaded);
      expect(transfers.hasRunningDownloads, isFalse);
      expect(
        observedRunning,
        observed.map(
          (progress) =>
              progress.status == DownloadStatus.downloading ||
              progress.status == DownloadStatus.verifying,
        ),
      );
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
    expect(transfers.hasRunningDownloads, isFalse);
    expect(observedRunning, contains(true));
    expect(observedRunning.last, isFalse);
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
      expect(transfers.hasRunningDownloads, isFalse);
      expect(transfers.downloads['t']!.receivedBytes, 40);
    },
  );

  test('an explicitly started repair resumes after restart while retaining offline intent', () async {
    await db.put('track', track.id, track.toJson());
    await db.put(
      'download',
      track.id,
      DownloadProgress(
        trackId: track.id,
        totalBytes: track.sizeBytes,
        status: DownloadStatus.downloading,
        previouslyDownloaded: true,
      ).toJson(),
    );
    await File('${root.path}/t.audio.part')
        .writeAsBytes(bytes.take(40).toList());
    await transfers.restoreDownloads();
    final restored = transfers.progressFor(track.id)!;
    expect(restored.status, DownloadStatus.queued);
    expect(restored.requiresOfflinePlayback, isTrue);
    expect(restored.repairRequired, isFalse);
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
    expect(transfers.progressFor(track.id)!.status, DownloadStatus.downloaded);
    expect(await File('${root.path}/t.audio').readAsBytes(), bytes);
  });

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
        '$status preserves download intent with $invalid instead of valid audio',
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
          final held =
              status == DownloadStatus.downloaded ||
              (invalid != 'missing track' && invalid != 'missing record');
          expect(
            restored.status,
            held ? DownloadStatus.failed : DownloadStatus.queued,
          );
          expect(restored.repairRequired, held);
          expect(restored.receivedBytes, held ? 0 : 40);
          expect(restored.historyCleared, isFalse);
          expect(await db.get('file', track.id), isNull);
          await transfers.clearDoneDownloads([track]);
          expect(transfers.progressFor(track.id), same(restored));
          var requests = 0;
          api.dio.httpClientAdapter = FakeAdapter((options, _) {
            requests++;
            if (held) {
              expect(options.headers['Range'], isNull);
              return ResponseBody.fromBytes(bytes, 200);
            }
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
          if (held) {
            expect(requests, 0);
            expect(transfers.progressFor(track.id)!.repairRequired, isTrue);
            await transfers.redownloadTrack(track, [track], [], pins);
          }
          expect(requests, 1);
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
        final restored = transfers.progressFor(track.id)!;
        expect(restored.status, DownloadStatus.downloaded);
        expect(restored.requiresOfflinePlayback, isTrue);
        expect(await db.get('download', track.id), restored.toJson());
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
      final running = transfers.redownloadTrack(track, [track], [], pins);
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
      (db as _GatedDatabase).afterCommit = null;
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
    final running = transfers.redownloadTrack(track, [track], [], pins);
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
      expect(requests, 1);
      expect(transfers.progressFor(track.id)!.repairRequired, isTrue);
      await transfers.redownloadTrack(track, [track], [], pins);
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
      expect(transfers.hasRunningDownloads, isFalse);
      expect(await db.get('file', track.id), isNull);
    },
  );

  test('old download records default to visible completed activity', () {
    final record =
        DownloadProgress(
            trackId: track.id,
            totalBytes: 100,
            status: DownloadStatus.downloaded,
          ).toJson()
          ..remove('history_cleared')
          ..remove('previously_downloaded');
    expect(DownloadProgress.fromJson(record).historyCleared, isFalse);
    expect(DownloadProgress.fromJson(record).requiresOfflinePlayback, isTrue);
  });
}
