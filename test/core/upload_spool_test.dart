import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yun/models/models.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/transfer_service.dart';

import 'fakes.dart';

void main() {
  late Directory root, spool;
  late CacheDatabase db;
  late Dio dio;
  late TransferService transfers;
  late List<Object> errors;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('yun-spool-test-');
    spool = Directory(p.join(root.path, 'imports'));
    db = CacheDatabase.memory();
    dio = Dio();
    final api = ApiClient(dio: dio, credentials: MemoryCredentials())
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
      directory: Directory(p.join(root.path, 'audio')),
      importsDirectory: spool,
      onChanged: () {},
      onTrack: (t) => db.put('track', t.id, t.toJson()),
      onError: errors.add,
    );
    await transfers.restoreUploads();
  });
  tearDown(() async {
    await transfers.close();
    await db.close();
    await root.delete(recursive: true);
  });

  Future<File> source([String name = 'original song.wav']) =>
      File(p.join(root.path, name)).writeAsBytes([1, 2, 3, 4]);

  test(
    'durable copy uploads after picker source disappears, then cleans up',
    () async {
      final original = await source();
      final job = await transfers.enqueueUpload('job', original.path);
      expect(job.filename, 'original song.wav');
      expect(job.ownedSource, isTrue);
      expect(job.localPath, p.join(spool.path, 'job.source'));
      expect(
        UploadJob.fromJson((await db.get('upload', 'job'))!).ownedSource,
        isTrue,
      );
      expect(await File(job.localPath).readAsBytes(), [1, 2, 3, 4]);
      await original.delete();
      dio.httpClientAdapter = FakeAdapter((options, body) {
        if (options.path.endsWith('/complete')) {
          return jsonResponse(const Track(id: 'track', title: 'Song').toJson());
        }
        if (options.method == 'PATCH') {
          expect(body, [1, 2, 3, 4]);
          return jsonResponse({'offset': 4});
        }
        expect(options.data, {
          'filename': 'original song.wav',
          'size_bytes': 4,
        });
        return jsonResponse({'id': 'remote', 'offset': 0});
      });
      await transfers.runUploads();
      expect(errors, isEmpty);
      expect((await db.get('upload', 'job'))!['status'], 'done');
      expect(await File(job.localPath).exists(), isFalse);
      await transfers.retryUpload('job');
      expect(errors, isEmpty);
    },
  );

  test('clear done removes only persisted done jobs and preserves tracks and sources', () async {
    final original = await source();
    final jobs = <UploadJob>[];
    for (final status in [
      'done',
      'queued',
      'uploading',
      'completing',
      'failed',
      'cancelled',
    ]) {
      final job = (await transfers.enqueueUpload(
        status,
        original.path,
      )).copyWith(status: status, offset: 2, remoteId: 'remote-$status');
      await db.put('upload', job.id, job.toJson());
      jobs.add(job);
      // Matching IDs also guard against removing records from other kinds.
      final track = Track(id: job.id, title: 'Imported $status');
      await db.put('track', track.id, track.toJson());
    }
    final legacy = UploadJob(
      id: 'legacy-done',
      localPath: original.path,
      filename: 'original song.wav',
      sizeBytes: 4,
      status: 'done',
    );
    await db.put('upload', legacy.id, legacy.toJson());
    final cancellation = {'id': 'cancelled', 'remote_id': 'remote-cancelled'};
    await db.put('upload_cancel', 'cancelled', cancellation);
    final tracks = await db.list('track');
    final retained = jobs
        .where((job) => job.status != 'done')
        .map((job) => job.toJson())
        .toList();

    // Repeat to verify idempotence, including preservation of owned sources
    // belonging to removed records (this operation only clears history).
    for (var attempt = 0; attempt < 2; attempt++) {
      await transfers.clearDoneUploads();
      expect(await db.get('upload', 'done'), isNull);
      expect(await db.get('upload', legacy.id), isNull);
      expect(await db.list('upload'), retained);
      expect(await db.list('track'), tracks);
      expect(await db.get('upload_cancel', 'cancelled'), cancellation);
      expect(await original.readAsBytes(), [1, 2, 3, 4]);
      for (final job in jobs) {
        expect(await File(job.localPath).readAsBytes(), [1, 2, 3, 4]);
      }
      expect(errors, isEmpty);
    }
  });

  test('successful legacy uploads never delete external originals', () async {
    final original = await source();
    final job = UploadJob(
      id: 'legacy',
      localPath: original.path,
      filename: 'original song.wav',
      sizeBytes: 4,
    );
    final json = job.toJson()..remove('owned_source');
    await db.put('upload', job.id, json);
    dio.httpClientAdapter = FakeAdapter((options, _) {
      if (options.path.endsWith('/complete')) {
        return jsonResponse(const Track(id: 'track', title: 'Song').toJson());
      }
      if (options.method == 'PATCH') return jsonResponse({'offset': 4});
      return jsonResponse({'id': 'remote', 'offset': 0});
    });
    await transfers.runUploads();
    expect((await db.get('upload', job.id))!['status'], 'done');
    expect(await original.readAsBytes(), [1, 2, 3, 4]);
    expect(errors, isEmpty);
  });

  test(
    'offline cancellation removes owned copy before remote cleanup',
    () async {
      final original = await source();
      final job = (await transfers.enqueueUpload(
        'job',
        original.path,
      )).copyWith(remoteId: 'remote');
      await db.put('upload', job.id, job.toJson());
      dio.httpClientAdapter = FakeAdapter((options, _) async {
        expect(await File(job.localPath).exists(), isFalse);
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        );
      });
      await transfers.cancelUpload(job.id);
      expect(await original.readAsBytes(), [1, 2, 3, 4]);
      expect(await File(job.localPath).exists(), isFalse);
      expect((await db.get('upload', job.id))!['status'], 'cancelled');
      expect(await db.get('upload_cancel', job.id), isNotNull);
    },
  );

  test(
    'legacy and forged owned paths never delete external originals',
    () async {
      final original = await source();
      for (final owned in [false, true]) {
        final job = UploadJob(
          id: 'job',
          localPath: original.path,
          filename: 'song.wav',
          sizeBytes: 4,
          ownedSource: owned,
        );
        final json = job.toJson();
        if (!owned) json.remove('owned_source');
        expect(UploadJob.fromJson(json).ownedSource, owned);
        await db.put('upload', job.id, json);
        await transfers.cancelUpload(job.id);
        expect(await original.readAsBytes(), [1, 2, 3, 4]);
      }
      final link = Link(p.join(spool.path, 'link.source'));
      await link.create(original.path);
      await db.put(
        'upload',
        'link',
        UploadJob(
          id: 'link',
          localPath: link.path,
          filename: 'song.wav',
          sizeBytes: 4,
          ownedSource: true,
        ).toJson(),
      );
      await transfers.cancelUpload('link');
      await transfers.restoreUploads();
      expect(await original.readAsBytes(), [1, 2, 3, 4]);
      expect(await link.exists(), isTrue);
    },
  );

  test(
    'startup removes abandoned copies but preserves resumable sources',
    () async {
      final original = await source();
      for (final status in [
        'queued',
        'failed',
        'uploading',
        'completing',
        'done',
        'cancelled',
      ]) {
        final job = await transfers.enqueueUpload(status, original.path);
        await db.put('upload', job.id, job.copyWith(status: status).toJson());
      }
      await File(p.join(spool.path, 'abandoned.source.part')).writeAsBytes([1]);
      await File(p.join(spool.path, 'orphan.source')).writeAsBytes([1]);
      await File(p.join(spool.path, 'unrelated.txt')).writeAsString('keep');
      await Directory(p.join(spool.path, 'nested.source')).create();
      await transfers.restoreUploads();
      expect(
        (await spool.list().toList()).map((f) => p.basename(f.path)),
        unorderedEquals([
          'queued.source',
          'failed.source',
          'uploading.source',
          'completing.source',
          'unrelated.txt',
          'nested.source',
        ]),
      );
      expect(await original.exists(), isTrue);
    },
  );

  test(
    'rejects empty, missing, directory and oversized sources without jobs',
    () async {
      final original = await source();
      await expectLater(
        transfers.enqueueUpload('big', original.path, maxBytes: 3),
        throwsArgumentError,
      );
      final empty = await File(p.join(root.path, 'empty')).create();
      for (final path in [empty.path, '${root.path}/missing', root.path]) {
        await expectLater(
          transfers.enqueueUpload('invalid', path),
          throwsArgumentError,
        );
      }
      // Inclusive limit; a deployment can supply a different server limit.
      final job = await transfers.enqueueUpload(
        'exact',
        original.path,
        maxBytes: 4,
      );
      expect(job.sizeBytes, 4);
      expect(await db.list('upload'), hasLength(1));
      expect(await spool.list().toList(), hasLength(1));
    },
  );

  test(
    'source mutation during streaming copy leaves no partial or queued job',
    () async {
      final original = File(p.join(root.path, 'large.wav'));
      final handle = await original.open(mode: FileMode.write);
      await handle.truncate(32 * 1024 * 1024);
      await handle.close();
      final copying = transfers.enqueueUpload('changing', original.path);
      final failure = expectLater(copying, throwsStateError);
      final partial = File(p.join(spool.path, 'changing.source.part'));
      while (!await partial.exists() || await partial.length() == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await original.setLastModified(DateTime(2000));
      await failure;
      expect(await db.list('upload'), isEmpty);
      expect(await spool.list().toList(), isEmpty);
    },
  );

  test(
    'close waits for active copy and cleans up without writing closed DB',
    () async {
      final original = File(p.join(root.path, 'large.wav'));
      final handle = await original.open(mode: FileMode.write);
      await handle.truncate(32 * 1024 * 1024);
      await handle.close();
      final copying = transfers.enqueueUpload('closing', original.path);
      final failure = expectLater(copying, throwsStateError);
      while (!await File(p.join(spool.path, 'closing.source.part')).exists()) {
        await Future<void>.delayed(Duration.zero);
      }
      await transfers.close();
      await failure;
      expect(await db.list('upload'), isEmpty);
      expect(await spool.list().toList(), isEmpty);
      expect(await original.exists(), isTrue);
    },
  );

  test(
    'concurrent enqueue during upload snapshot is drained without refresh',
    () async {
      final original = await source();
      await transfers.enqueueUpload('first', original.path);
      final started = Completer<void>(), release = Completer<void>();
      var reservations = 0;
      dio.httpClientAdapter = FakeAdapter((options, _) async {
        if (options.path.endsWith('/complete')) {
          return jsonResponse(
            Track(id: 'track$reservations', title: 'Song').toJson(),
          );
        }
        if (options.method == 'PATCH') return jsonResponse({'offset': 4});
        reservations++;
        if (reservations == 1) {
          started.complete();
          await release.future;
        }
        return jsonResponse({'id': 'remote$reservations', 'offset': 0});
      });
      final running = transfers.runUploads();
      await started.future;
      await transfers.enqueueUpload('second', original.path);
      final rerun = transfers.runUploads();
      release.complete();
      await Future.wait([running, rerun]);
      expect(reservations, 2);
      expect((await db.list('upload')).map((j) => j['status']), [
        'done',
        'done',
      ]);
      expect(await spool.list().toList(), isEmpty);
      expect(errors, isEmpty);
    },
  );
}
