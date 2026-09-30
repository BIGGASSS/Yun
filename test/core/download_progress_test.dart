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
    db = CacheDatabase.memory();
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

  test('old download records default to visible completed activity', () {
    final record = DownloadProgress(
      trackId: track.id,
      totalBytes: 100,
      status: DownloadStatus.downloaded,
    ).toJson()..remove('history_cleared');
    expect(DownloadProgress.fromJson(record).historyCleared, isFalse);
  });
}
