import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yun/models/models.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/transfer_service.dart';

import 'fakes.dart';

class _CountingList<T> extends ListBase<T> {
  _CountingList(this.values);
  final List<T> values;
  int reads = 0;
  @override
  int get length => values.length;
  @override
  set length(int value) => throw UnsupportedError('read only');
  @override
  T operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, T value) => throw UnsupportedError('read only');
}

class _ControlledAutomaticVerifier implements DownloadFileVerifier {
  final started = Completer<VerificationFile>();
  final result = Completer<FileVerificationResult>();
  bool cancelled = false, closed = false;

  @override
  Future<FileVerificationResult> verify(
    VerificationFile file,
    void Function(int) onBytes,
  ) {
    started.complete(file);
    onBytes(file.sizeBytes ~/ 2);
    return result.future;
  }

  @override
  void cancel() {
    cancelled = true;
    if (!result.isCompleted) result.completeError(VerificationCancelled());
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  late Directory root;
  late CacheDatabase db;
  late Dio dio;
  late ApiClient api;
  late TransferService transfers;
  late List<Object> errors;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('yun-transfer-test-');
    db = CacheDatabase.memory();
    dio = Dio();
    api = ApiClient(dio: dio, credentials: MemoryCredentials())
      ..session = SessionCredentials(
        account: const Account(
          server: 'https://yun.test',
          userId: 'u',
          username: 'u',
        ),
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
      );
    errors = [];
    transfers = TransferService(
      api: api,
      database: db,
      directory: root,
      onChanged: () {},
      onTrack: (t) => db.put('track', t.id, t.toJson()),
      onError: errors.add,
    );
  });
  tearDown(() async {
    await transfers.close();
    await db.close();
    await root.delete(recursive: true);
  });
  test('pin membership indexes preserve overlapping selections and deduplicate entries', () {
    const tracks = [
      Track(
        id: 'a',
        title: 'A',
        album: 'Album',
        artist: 'Various',
        albumArtist: 'Group',
      ),
      Track(id: 'b', title: 'B', album: 'Album', artist: 'Group'),
      Track(id: 'c', title: 'C', album: 'Album', artist: 'Other'),
    ];
    const playlists = [
      Playlist(
        id: 'p',
        name: 'P',
        entries: [
          PlaylistEntry(id: '1', trackId: 'a'),
          PlaylistEntry(id: '2', trackId: 'a'),
          PlaylistEntry(id: '3', trackId: 'missing'),
        ],
      ),
      // Duplicate playlist identities are merged, as with the previous scan.
      Playlist(
        id: 'p',
        name: 'P',
        entries: [PlaylistEntry(id: '4', trackId: 'b')],
      ),
    ];
    expect(
      pinReferences(
        [
          const PinSelection('track', 'a'),
          PinSelection('album', albumPinId('Album', 'Group')),
          const PinSelection('playlist', 'p'),
          const PinSelection('track', 'missing'),
          const PinSelection('album', 'missing'),
          const PinSelection('playlist', 'missing'),
        ],
        tracks,
        playlists,
      ),
      {'a': 3, 'b': 2},
    );
  });

  test('thousands of album and playlist pins index the library only once', () {
    // Count source reads rather than asserting a machine-dependent time limit.
    for (final albumCount in [1000, 4000]) {
      final tracks = _CountingList(
        List.generate(
          albumCount * 10,
          (i) => Track(
            id: '$i',
            title: '$i',
            album: '${i ~/ 10}',
            artist: 'Artist',
          ),
        ),
      );
      final playlists = _CountingList(
        List.generate(
          albumCount,
          (i) => Playlist(
            id: '$i',
            name: '$i',
            entries: [PlaylistEntry(id: '$i', trackId: '${i * 10}')],
          ),
        ),
      );
      final refs = pinReferences(
        [
          for (var i = 0; i < albumCount; i++)
            PinSelection('album', albumPinId('$i', 'Artist')),
          for (var i = 0; i < albumCount; i++) PinSelection('playlist', '$i'),
        ],
        tracks,
        playlists,
      );
      expect(refs, hasLength(albumCount * 10));
      expect(refs['0'], 2);
      expect(refs['1'], 1);
      expect(tracks.reads, tracks.length);
      expect(playlists.reads, playlists.length);
    }
  });

  test('download resumes with Range/If-Range and verifies checksum before exposing file', () async {
    final bytes = List.generate(100, (i) => i);
    final hash = sha256.convert(bytes).toString();
    final track = Track(id: 't', title: 'Track', sizeBytes: 100, sha256: hash);
    await File(p.join(root.path, 't.audio.part'))
        .writeAsBytes(bytes.take(40).toList());
    dio.httpClientAdapter = FakeAdapter((options, body) {
      expect(options.headers['Range'], 'bytes=40-');
      expect(options.headers['If-Range'], '"$hash"');
      return ResponseBody.fromBytes(
        bytes.skip(40).toList(),
        206,
        headers: {
          'etag': ['"$hash"'],
          'content-range': ['bytes 40-99/100'],
        },
      );
    });
    await transfers.reconcile([track], [], [const PinSelection('track', 't')]);
    expect(errors, isEmpty);
    final file = (await db.get('file', 't'))!;
    expect(await File(file['path'] as String).readAsBytes(), bytes);
    expect(await File(p.join(root.path, 't.audio.part')).exists(), isFalse);
    await transfers.reconcile([track], [], []);
    expect(await db.get('file', 't'), isNull);
    expect(await File(file['path'] as String).exists(), isFalse);
  });
  test(
    'server ignoring Range restarts the partial rather than appending',
    () async {
      final bytes = [1, 2, 3, 4];
      final track = Track(
        id: 't',
        title: 'T',
        sizeBytes: 4,
        sha256: sha256.convert(bytes).toString(),
      );
      await File(p.join(root.path, 't.audio.part')).writeAsBytes([9, 9]);
      dio.httpClientAdapter = FakeAdapter(
        (_, _) => ResponseBody.fromBytes(bytes, 200),
      );
      await transfers.reconcile(
        [track],
        [],
        [const PinSelection('track', 't')],
      );
      expect(errors, isEmpty);
      expect(await File(p.join(root.path, 't.audio')).readAsBytes(), bytes);
    },
  );
  test('checksum failure never creates a playable cache record', () async {
    final track = Track(
      id: 't',
      title: 'T',
      sizeBytes: 4,
      sha256: sha256.convert([1, 2, 3, 4]).toString(),
    );
    dio.httpClientAdapter = FakeAdapter(
      (_, _) => ResponseBody.fromBytes([0, 0, 0, 0], 200),
    );
    await transfers.reconcile([track], [], [const PinSelection('track', 't')]);
    expect(errors, hasLength(1));
    expect(await db.get('file', 't'), isNull);
    expect(await File(p.join(root.path, 't.audio.part')).exists(), isFalse);
  });
  for (final scenario in [(0, 200), (2, 206), (2, 200)]) {
    final (resumeOffset, status) = scenario;
    test(
      'oversized $status stream at offset $resumeOffset cancels before writing overflow',
      () async {
        final bytes = [1, 2, 3, 4];
        final hash = sha256.convert(bytes).toString();
        final track = Track(id: 't', title: 'T', sizeBytes: 4, sha256: hash);
        final other = Track(
          id: 'other',
          title: 'Other',
          sizeBytes: 4,
          sha256: hash,
        );
        const pins = [
          PinSelection('track', 't'),
          PinSelection('track', 'other'),
        ];
        final partial = File(p.join(root.path, 't.audio.part'));
        if (resumeOffset > 0) {
          await partial.writeAsBytes(bytes.take(resumeOffset).toList());
        }
        var streamCancelled = false;
        final body = StreamController<Uint8List>(
          onCancel: () => streamCancelled = true,
        );
        addTearDown(body.close);
        CancelToken? requestToken;
        dio.httpClientAdapter = FakeAdapter((options, _) {
          if (options.path.endsWith('/other/audio')) {
            expect(options.cancelToken!.isCancelled, isFalse);
            return ResponseBody.fromBytes(bytes, 200);
          }
          expect(
            options.headers['Range'],
            resumeOffset > 0 ? 'bytes=2-' : isNull,
          );
          requestToken = options.cancelToken;
          final start = status == 206 ? resumeOffset : 0;
          body.add(Uint8List.fromList(bytes.sublist(start, 3)));
          body.add(Uint8List.fromList([4, 5]));
          // No EOF: the worker must cancel rather than wait for the producer.
          return ResponseBody(
            body.stream,
            status,
            headers: {
              if (status == 206) 'content-range': ['bytes 2-3/4'],
            },
          );
        });
        await transfers
            .reconcile([track, other], [], pins)
            .timeout(const Duration(seconds: 5));
        expect(requestToken!.isCancelled, isTrue);
        expect(streamCancelled, isTrue);
        expect(errors, hasLength(1));
        expect(errors.single.toString(), contains('exceeds expected size'));
        expect(await partial.readAsBytes(), [1, 2, 3]);
        expect(await db.get('file', track.id), isNull);
        expect(await File(p.join(root.path, 't.audio')).exists(), isFalse);
        expect(transfers.progressFor(track.id)!.status, DownloadStatus.failed);
        expect(transfers.progressFor(track.id)!.receivedBytes, 3);
        expect(
          transfers.progressFor(other.id)!.status,
          DownloadStatus.downloaded,
        );

        dio.httpClientAdapter = FakeAdapter((options, _) {
          expect(options.cancelToken!.isCancelled, isFalse);
          expect(options.headers['Range'], 'bytes=3-');
          return ResponseBody.fromBytes(
            [4],
            206,
            headers: {
              'content-range': ['bytes 3-3/4'],
            },
          );
        });
        await transfers.reconcile([track, other], [], pins);
        expect(errors, hasLength(1));
        expect(await File(p.join(root.path, 't.audio')).readAsBytes(), bytes);
        expect(
          transfers.progressFor(track.id)!.status,
          DownloadStatus.downloaded,
        );
      },
    );
  }

  for (final corrupt in [
    [1, 2],
    [1, 2, 3, 4, 5],
  ]) {
    test(
      'reconciliation rejects wrong-size completed bytes $corrupt before retry',
      () async {
        final bytes = [1, 2, 3, 4];
        final track = Track(
          id: 't',
          title: 'T',
          sizeBytes: bytes.length,
          sha256: sha256.convert(bytes).toString(),
        );
        const pins = [PinSelection('track', 't')];
        dio.httpClientAdapter = FakeAdapter(
          (_, _) => ResponseBody.fromBytes(bytes, 200),
        );
        await transfers.reconcile([track], [], pins);
        await transfers.clearDoneDownloads([track]);
        final file = File(p.join(root.path, 't.audio'));
        await file.writeAsBytes(corrupt);
        var repairRequests = 0;
        dio.httpClientAdapter = FakeAdapter((options, _) async {
          repairRequests++;
          expect(await db.get('file', track.id), isNull);
          // Preserve suspect bytes until a replacement has passed verification.
          expect(await file.readAsBytes(), corrupt);
          throw DioException(requestOptions: options, error: 'offline');
        });
        await transfers.reconcile([track], [], pins);
        expect(repairRequests, 0);
        expect(errors, isEmpty);
        expect(await db.get('file', track.id), isNull);
        expect(await file.exists(), isTrue);
        expect(transfers.progressFor(track.id)!.status, DownloadStatus.failed);
        expect(transfers.progressFor(track.id)!.repairRequired, isTrue);
        expect(transfers.progressFor(track.id)!.historyCleared, isFalse);
        await transfers.redownloadTrack(track, [track], [], pins);
        expect(repairRequests, 1);
        expect(errors, hasLength(1));
        expect(
          transfers.progressFor(track.id)!.requiresOfflinePlayback,
          isTrue,
        );
        dio.httpClientAdapter = FakeAdapter(
          (_, _) => ResponseBody.fromBytes(bytes, 200),
        );
        await transfers.redownloadTrack(track, [track], [], pins);
        expect(errors, hasLength(1));
        expect(await file.readAsBytes(), bytes);
        expect(await db.get('file', track.id), isNotNull);
        expect(
          transfers.progressFor(track.id)!.status,
          DownloadStatus.downloaded,
        );
      },
    );
  }

  test('upload reconciles durable server offset after a lost chunk acknowledgement', () async {
    final source = File(p.join(root.path, 'song.mp3'));
    await source.writeAsBytes([1, 2, 3, 4, 5, 6]);
    final job = UploadJob(
      id: 'job',
      localPath: source.path,
      filename: 'song.mp3',
      sizeBytes: 6,
      remoteId: 'remote',
    );
    await db.put('upload', 'job', job.toJson());
    var durableOffset = 2;
    var patches = 0;
    dio.httpClientAdapter = FakeAdapter((options, body) {
      if (options.method == 'GET') {
        return jsonResponse({'id': 'remote', 'offset': durableOffset});
      }
      if (options.method == 'PATCH') {
        patches++;
        expect(options.headers['Upload-Offset'], 2);
        expect(body, [3, 4, 5, 6]);
        durableOffset = 6;
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          error: 'ack lost',
        );
      }
      if (options.path.endsWith('/complete')) {
        return jsonResponse(const Track(id: 't', title: 'Song').toJson());
      }
      throw StateError('unexpected ${options.method} ${options.path}');
    });
    await transfers.runUploads();
    expect(UploadJob.fromJson((await db.get('upload', 'job'))!).offset, 2);
    expect(
      UploadJob.fromJson((await db.get('upload', 'job'))!).status,
      'failed',
    );
    await transfers.retryUpload('job');
    final completed = UploadJob.fromJson((await db.get('upload', 'job'))!);
    expect(completed.offset, 6);
    expect(completed.status, 'done');
    expect(patches, 1);
    expect(await db.get('track', 't'), isNotNull);
  });
  for (final status in [403, 500]) {
    test(
      'upload status $status never recreates reservation or resets progress',
      () async {
        final job = UploadJob(
          id: 'job',
          localPath: '${root.path}/missing.wav',
          filename: 'fixture.wav',
          sizeBytes: 6,
          offset: 2,
          remoteId: 'remote',
        );
        await db.put('upload', job.id, job.toJson());
        final methods = <String>[];
        dio.httpClientAdapter = FakeAdapter((options, _) {
          methods.add(options.method);
          return jsonResponse({'error': 'unavailable'}, status: status);
        });
        await transfers.runUploads();
        final saved = UploadJob.fromJson((await db.get('upload', job.id))!);
        expect(methods, ['GET']);
        expect(saved.remoteId, 'remote');
        expect(saved.offset, 2);
        expect(saved.status, 'failed');
        expect(errors, hasLength(1));
        expect(
          errors.single,
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            status,
          ),
        );
      },
    );
  }

  for (final offset in [-1, 7]) {
    test('invalid remote offset $offset never attempts completion', () async {
      final job = UploadJob(
        id: 'job',
        localPath: '${root.path}/missing.wav',
        filename: 'fixture.wav',
        sizeBytes: 6,
        remoteId: 'remote',
      );
      await db.put('upload', job.id, job.toJson());
      final methods = <String>[];
      dio.httpClientAdapter = FakeAdapter((options, _) {
        methods.add(options.method);
        return jsonResponse({'offset': offset});
      });
      await transfers.runUploads();
      expect(methods, ['GET']);
      expect((await db.get('upload', job.id))!['status'], 'failed');
      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('invalid upload offset'));
    });
  }

  test(
    'failed replacement creation persists cleared ID and retries safely',
    () async {
      final source = await File('${root.path}/source.wav')
          .writeAsBytes([1, 2, 3]);
      final job = UploadJob(
        id: 'job',
        localPath: source.path,
        filename: 'fixture.wav',
        sizeBytes: 3,
        offset: 2,
        remoteId: 'expired',
      );
      await db.put('upload', job.id, job.toJson());
      final calls = <String>[];
      var unavailable = true;
      dio.httpClientAdapter = FakeAdapter((options, _) {
        calls.add('${options.method} ${Uri.parse(options.path).path}');
        if (options.method == 'GET') return jsonResponse({}, status: 404);
        if (options.path.endsWith('/complete')) {
          return jsonResponse(
            const Track(id: 'track', title: 'Recovered').toJson(),
          );
        }
        if (options.method == 'PATCH') return jsonResponse({'offset': 3});
        return unavailable
            ? jsonResponse({}, status: 503)
            : jsonResponse({'id': 'replacement', 'offset': 0});
      });
      await transfers.runUploads();
      final failed = UploadJob.fromJson((await db.get('upload', job.id))!);
      expect(failed.remoteId, isNull);
      expect(failed.offset, 0);
      expect(failed.status, 'failed');
      expect(errors, hasLength(1));
      unavailable = false;
      await transfers.retryUpload(job.id);
      expect((await db.get('upload', job.id))!['status'], 'done');
      expect(calls, [
        'GET /api/v1/uploads/expired',
        'POST /api/v1/uploads',
        'POST /api/v1/uploads',
        'PATCH /api/v1/uploads/replacement',
        'POST /api/v1/uploads/replacement/complete',
      ]);
    },
  );

  test(
    'pin changes during download are reconciled before worker completes',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final bytes = [1, 2, 3];
      final track = Track(
        id: 't',
        title: 'T',
        sizeBytes: 3,
        sha256: sha256.convert(bytes).toString(),
      );
      dio.httpClientAdapter = FakeAdapter((_, _) async {
        started.complete();
        await release.future;
        return ResponseBody.fromBytes(bytes, 200);
      });
      final first = transfers.reconcile(
        [track],
        [],
        [const PinSelection('track', 't')],
      );
      await started.future;
      final second = transfers.reconcile([track], [], []);
      release.complete();
      await Future.wait([first, second]);
      expect(await db.get('file', 't'), isNull);
      expect(await File(p.join(root.path, 't.audio')).exists(), isFalse);
    },
  );
  test(
    'unpin cancels a stalled body and never starts obsolete queued tracks',
    () async {
      final bytes = [1, 2, 3];
      final tracks = [
        for (final id in ['a', 'b', 'c'])
          Track(
            id: id,
            title: id,
            sizeBytes: bytes.length,
            sha256: sha256.convert(bytes).toString(),
          ),
      ];
      final started = Completer<void>();
      var bodyCancelled = false;
      final body = StreamController<Uint8List>(
        onCancel: () => bodyCancelled = true,
      );
      addTearDown(body.close);
      CancelToken? activeToken;
      final requests = <String>[];
      dio.httpClientAdapter = FakeAdapter((options, _) {
        requests.add(options.path.split('/').reversed.elementAt(1));
        if (options.path.endsWith('/a/audio')) {
          activeToken = options.cancelToken;
          body.add(Uint8List.fromList([1]));
          started.complete();
          return ResponseBody(body.stream, 200);
        }
        return ResponseBody.fromBytes(bytes, 200);
      });
      final first = transfers.reconcile(tracks, [], [
        for (final track in tracks) PinSelection('track', track.id),
      ]);
      await started.future;
      final latest = transfers.reconcile(tracks, [], [
        const PinSelection('track', 'c'),
      ]);
      expect(activeToken!.isCancelled, isTrue);
      await Future.wait([first, latest]).timeout(const Duration(seconds: 5));
      expect(bodyCancelled, isTrue);
      expect(requests, ['a', 'c']);
      expect(errors, isEmpty);
      expect(transfers.progressFor('a'), isNull);
      expect(transfers.progressFor('b'), isNull);
      expect(await db.get('download', 'a'), isNull);
      expect(await db.get('file', 'a'), isNull);
      expect(await File(p.join(root.path, 'a.audio.part')).exists(), isFalse);
      expect(await db.get('file', 'c'), isNotNull);
      expect(transfers.hasRunningDownloads, isFalse);
      expect(transfers.downloadBatchProgress, (completed: 0, total: 0));
    },
  );

  test(
    'overlapping reference retains active download but replaces obsolete batch',
    () async {
      final bytes = [1, 2, 3];
      final tracks = [
        for (final id in ['a', 'b', 'c'])
          Track(
            id: id,
            title: id,
            album: id,
            artist: 'Artist',
            sizeBytes: bytes.length,
            sha256: sha256.convert(bytes).toString(),
          ),
      ];
      final started = Completer<void>(), release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      CancelToken? activeToken;
      final requests = <String>[];
      dio.httpClientAdapter = FakeAdapter((options, _) async {
        requests.add(options.path.split('/').reversed.elementAt(1));
        if (options.path.endsWith('/a/audio')) {
          activeToken = options.cancelToken;
          started.complete();
          await release.future;
        }
        return ResponseBody.fromBytes(bytes, 200);
      });
      final albumPin = PinSelection('album', albumPinId('a', 'Artist'));
      final first = transfers.reconcile(tracks, [], [
        const PinSelection('track', 'a'),
        albumPin,
        const PinSelection('track', 'b'),
      ]);
      await started.future;
      final intermediate = transfers.reconcile(tracks, [], [
        albumPin,
        const PinSelection('track', 'b'),
      ]);
      final latest = transfers.reconcile(tracks, [], [
        albumPin,
        const PinSelection('track', 'c'),
      ]);
      expect(activeToken!.isCancelled, isFalse);
      release.complete();
      await Future.wait([first, intermediate, latest]);
      expect(requests, ['a', 'c']);
      expect(errors, isEmpty);
      expect((await db.get('file', 'a'))!['references'], 1);
      expect(await db.get('file', 'b'), isNull);
      expect(await db.get('file', 'c'), isNotNull);
    },
  );

  for (final action in ['complete', 'unpin', 'close', 'invalid', 'skipped']) {
    test(
      'automatic verifier $action gates publication and is drained',
      () async {
        await transfers.close();
        final worker = _ControlledAutomaticVerifier();
        final completed = <String>[];
        transfers = TransferService(
          api: api,
          database: db,
          directory: root,
          onChanged: () {},
          onTrack: (_) async {},
          onError: errors.add,
          onDownloaded: (track) async => completed.add(track.id),
          verificationWorkerFactory: () => worker,
        );
        final bytes = [1, 2, 3, 4];
        final track = Track(
          id: 't',
          title: 'T',
          sizeBytes: bytes.length,
          sha256: sha256.convert(bytes).toString(),
        );
        dio.httpClientAdapter = FakeAdapter(
          (_, _) => ResponseBody.fromBytes(bytes, 200),
        );
        final downloading = transfers.reconcile(
          [track],
          [],
          [const PinSelection('track', 't')],
        );
        final input = await worker.started.future;
        expect(input.path, endsWith('t.audio.part'));
        expect(input.sha256, track.sha256);
        expect(input.sizeBytes, bytes.length);
        expect(transfers.progressFor('t')!.status, DownloadStatus.verifying);
        expect(await db.get('file', 't'), isNull);
        expect(await File(p.join(root.path, 't.audio')).exists(), isFalse);
        expect(completed, isEmpty);
        if (action == 'unpin') {
          await transfers
              .reconcile([track], [], [])
              .timeout(const Duration(seconds: 5));
        } else if (action == 'close') {
          await transfers.close().timeout(const Duration(seconds: 5));
        } else {
          worker.result.complete(
            FileVerificationResult(switch (action) {
              'complete' => FileVerificationOutcome.valid,
              'invalid' => FileVerificationOutcome.invalid,
              _ => FileVerificationOutcome.skipped,
            }),
          );
        }
        await downloading;
        expect(worker.closed, isTrue);
        expect(worker.cancelled, action == 'unpin' || action == 'close');
        expect(completed, action == 'complete' ? ['t'] : isEmpty);
        expect(
          await db.get('file', 't'),
          action == 'complete' ? isNotNull : isNull,
        );
        expect(
          await File(p.join(root.path, 't.audio')).exists(),
          action == 'complete',
        );
        expect(
          await File(p.join(root.path, 't.audio.part')).exists(),
          action == 'close' || action == 'skipped',
        );
        expect(
          errors,
          action == 'invalid' || action == 'skipped' ? hasLength(1) : isEmpty,
        );
        if (action == 'close') {
          expect(transfers.progressFor('t')!.status, DownloadStatus.queued);
          expect(transfers.progressFor('t')!.error, isNull);
          // A complete partial survives account close and is verified on retry,
          // without a second request or ever exposing unverified bytes.
          transfers = TransferService(
            api: api,
            database: db,
            directory: root,
            onChanged: () {},
            onTrack: (_) async {},
            onError: errors.add,
          );
          dio.httpClientAdapter = FakeAdapter(
            (_, _) => throw StateError('No network expected'),
          );
          await transfers.reconcile(
            [track],
            [],
            [const PinSelection('track', 't')],
          );
          expect(await db.get('file', 't'), isNotNull);
          expect(errors, isEmpty);
        }
      },
    );
  }

  test(
    'offline upload cancellation persists server cleanup for retry',
    () async {
      const job = UploadJob(
        id: 'job',
        localPath: 'unused',
        filename: 'song.mp3',
        sizeBytes: 6,
        remoteId: 'remote',
      );
      await db.put('upload', 'job', job.toJson());
      var offline = true;
      var deletes = 0;
      dio.httpClientAdapter = FakeAdapter((options, _) {
        expect(options.method, 'DELETE');
        if (offline) {
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          );
        }
        deletes++;
        return ResponseBody.fromString('', 204);
      });
      await transfers.cancelUpload('job');
      expect((await db.get('upload', 'job'))!['status'], 'cancelled');
      expect(await db.get('upload_cancel', 'job'), isNotNull);
      offline = false;
      await transfers.runUploads();
      expect(deletes, 1);
      expect(await db.get('upload_cancel', 'job'), isNull);
    },
  );
}
