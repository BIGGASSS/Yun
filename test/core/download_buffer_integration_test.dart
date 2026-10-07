import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/download_buffer.dart';
import 'package:yun/services/transfer_service.dart';

import 'fakes.dart';

const _bufferSize = BufferedDownloadWriter.bufferSize;
const _timeout = Duration(seconds: 5);

Uint8List _bytes(int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + 17) % 251));

Track _track(Uint8List bytes, {String id = 't'}) => Track(
  id: id,
  title: id,
  sizeBytes: bytes.length,
  sha256: sha256.convert(bytes).toString(),
);

List<PinSelection> _pins(List<Track> tracks) => [
  for (final track in tracks) PinSelection('track', track.id),
];

/// Kept open deliberately: cancellation must not depend on a producer's EOF.
class _OpenBody {
  _OpenBody() {
    controller = StreamController<Uint8List>(onCancel: () => cancelled = true);
  }

  late final StreamController<Uint8List> controller;
  bool cancelled = false;

  void release() {
    // Do not await close: it can wait forever if setup failed before listening.
    if (!controller.isClosed) unawaited(controller.close());
  }
}

Future<void> _waitForBytes(
  TransferService transfers,
  int bytes, {
  String id = 't',
}) async {
  final clock = Stopwatch()..start();
  while (true) {
    final progress = transfers.progressFor(id);
    if (progress?.status == DownloadStatus.downloading &&
        progress?.receivedBytes == bytes) {
      return;
    }
    if (progress?.status == DownloadStatus.failed ||
        clock.elapsed >= _timeout) {
      throw StateError(
        'Did not consume $bytes bytes for $id: ${progress?.toJson()}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  late Directory root;
  late CacheDatabase db;
  late ApiClient api;
  late TransferService transfers;
  late List<Object> errors;
  late List<DownloadProgress> observed;
  late int notifications;
  void Function(DownloadProgress)? onProgress;

  File partial(String id) => File('${root.path}/$id.audio.part');
  File audio(String id) => File('${root.path}/$id.audio');

  TransferService create() => TransferService(
    api: api,
    database: db,
    directory: root,
    onChanged: () {},
    onTrack: (track) => db.put('track', track.id, track.toJson()),
    onError: errors.add,
    onDownloadChanged: () {
      notifications++;
      final progress = transfers.progressFor('t');
      if (progress != null) {
        observed.add(progress);
        onProgress?.call(progress);
      }
    },
  );

  Future<void> expectQuiet() async {
    final count = notifications;
    await Future<void>.delayed(DownloadProgressThrottle.interval * 2);
    expect(notifications, count, reason: 'No stale trailing byte callback');
  }

  Future<void> expectDownloaded(Track track, Uint8List bytes) async {
    expect(transfers.progressFor(track.id)!.status, DownloadStatus.downloaded);
    expect(transfers.progressFor(track.id)!.receivedBytes, bytes.length);
    expect(await audio(track.id).readAsBytes(), bytes);
    expect(await partial(track.id).exists(), isFalse);
    final record = (await db.get('file', track.id))!;
    expect(record['sha256'], track.sha256);
    expect(record['path'], audio(track.id).path);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yun-download-buffer-');
    db = CacheDatabase.memory();
    errors = [];
    observed = [];
    notifications = 0;
    onProgress = null;
    api = ApiClient(dio: Dio(), credentials: MemoryCredentials())
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
    // Use the production SHA verifier: successful writes must preserve order.
    transfers = create();
  });

  tearDown(() async {
    try {
      await transfers.close().timeout(_timeout);
    } finally {
      api.dio.close(force: true);
      await db.close();
      await root.delete(recursive: true);
    }
  });

  for (final size in [
    _bufferSize - 1,
    _bufferSize,
    _bufferSize + 1,
    3 * _bufferSize + 37,
  ]) {
    test(
      'single $size-byte fragment flushes only full buffers before EOF',
      () async {
        final bytes = _bytes(size);
        final track = _track(bytes);
        final body = _OpenBody();
        api.dio.httpClientAdapter = FakeAdapter((_, _) {
          body.controller.add(bytes);
          return ResponseBody(body.controller.stream, 200);
        });
        final running = transfers.reconcile([track], [], _pins([track]));
        try {
          await _waitForBytes(transfers, size);
          expect(
            await partial('t').length(),
            size ~/ _bufferSize * _bufferSize,
          );
          expect(await db.get('file', 't'), isNull);
          expect(await audio('t').exists(), isFalse);
          body.release();
          await running.timeout(_timeout);
          await expectDownloaded(track, bytes);
          expect(errors, isEmpty);
          expect(
            observed.map((p) => p.status),
            contains(DownloadStatus.verifying),
          );
          expect(
            observed.map((p) => p.status),
            contains(DownloadStatus.downloaded),
          );
        } finally {
          body.release();
          await running.timeout(_timeout);
        }
      },
    );
  }

  test(
    'thousands of tiny fragments retain order across a buffer boundary',
    () async {
      final bytes = _bytes(_bufferSize + 4099);
      final track = _track(bytes);
      final body = _OpenBody();
      api.dio.httpClientAdapter = FakeAdapter((_, _) {
        for (var start = 0; start < bytes.length; start += 31) {
          final end = start + 31 < bytes.length ? start + 31 : bytes.length;
          body.controller.add(Uint8List.sublistView(bytes, start, end));
        }
        return ResponseBody(body.controller.stream, 200);
      });
      final running = transfers.reconcile([track], [], _pins([track]));
      try {
        await _waitForBytes(transfers, bytes.length);
        expect(await partial('t').length(), _bufferSize);
        body.release();
        await running.timeout(_timeout);
        await expectDownloaded(track, bytes);
        expect(errors, isEmpty);
      } finally {
        body.release();
        await running.timeout(_timeout);
      }
    },
  );

  for (final failure in ['stream error', 'short EOF']) {
    test(
      '$failure flushes the accepted buffered prefix and retries its Range',
      () async {
        final bytes = _bytes(2 * _bufferSize + 173);
        final track = _track(bytes);
        final prefixLength = _bufferSize + 61;
        final body = _OpenBody();
        var requests = 0;
        api.dio.httpClientAdapter = FakeAdapter((options, _) {
          requests++;
          expect(options.headers['Range'], isNull);
          body.controller.add(Uint8List.sublistView(bytes, 0, prefixLength));
          return ResponseBody(body.controller.stream, 200);
        });
        final running = transfers.reconcile([track], [], _pins([track]));
        try {
          await _waitForBytes(transfers, prefixLength);
          expect(await partial('t').length(), _bufferSize);
          if (failure == 'stream error') {
            body.controller.addError(StateError('connection lost'));
          } else {
            body.release();
          }
          await running.timeout(_timeout);
          expect(
            requests,
            1,
            reason: 'A failed transfer is not automatically retried',
          );
          expect(errors, hasLength(1));
          final failed = transfers.progressFor('t')!;
          expect(failed.status, DownloadStatus.failed);
          expect(failed.receivedBytes, prefixLength);
          expect(
            failed.error,
            contains(
              failure == 'stream error'
                  ? 'Download reception failed'
                  : 'Incomplete download',
            ),
          );
          expect(
            await partial('t').readAsBytes(),
            bytes.sublist(0, prefixLength),
          );
          expect(
            (await db.get('download', 't'))!['received_bytes'],
            prefixLength,
          );
          expect(await db.get('file', 't'), isNull);
          expect(await audio('t').exists(), isFalse);
          await expectQuiet();

          api.dio.httpClientAdapter = FakeAdapter((options, _) {
            requests++;
            expect(options.headers['Range'], 'bytes=$prefixLength-');
            expect(options.headers['If-Range'], '"${track.sha256}"');
            return ResponseBody.fromBytes(
              bytes.sublist(prefixLength),
              206,
              headers: {
                'content-range': [
                  'bytes $prefixLength-${bytes.length - 1}/${bytes.length}',
                ],
              },
            );
          });
          await transfers
              .reconcile([track], [], _pins([track]))
              .timeout(_timeout);
          expect(requests, 2);
          expect(errors, hasLength(1));
          await expectDownloaded(track, bytes);
          expect(transfers.progressFor('t')!.error, isNull);
        } finally {
          body.release();
          await running.timeout(_timeout);
        }
      },
    );
  }

  test('oversized fragment is rejected whole, drains accepted tail, and releases the next track without EOF', () async {
    final bytes = _bytes(2 * _bufferSize + 71);
    final track = _track(bytes);
    final otherBytes = _bytes(19);
    final other = _track(otherBytes, id: 'other');
    final tracks = [track, other];
    final prefixLength = _bufferSize + 61;
    final body = _OpenBody();
    final requests = <String>[];
    CancelToken? token;
    api.dio.httpClientAdapter = FakeAdapter((options, _) {
      requests.add(options.path);
      expect(options.cancelToken!.isCancelled, isFalse);
      if (options.path.endsWith('/other/audio')) {
        return ResponseBody.fromBytes(otherBytes, 200);
      }
      token = options.cancelToken;
      body.controller.add(Uint8List.sublistView(bytes, 0, prefixLength));
      return ResponseBody(body.controller.stream, 200);
    });
    final running = transfers.reconcile(tracks, [], _pins(tracks));
    try {
      await _waitForBytes(transfers, prefixLength);
      expect(await partial('t').length(), _bufferSize);
      body.controller.add(
        Uint8List.fromList([...bytes.sublist(prefixLength), 255]),
      );
      // No close/release until the worker finishes: overflow must cancel it.
      await running.timeout(_timeout);
      expect(token!.isCancelled, isTrue);
      expect(body.cancelled, isTrue);
      expect(requests.map((p) => p.split('/').reversed.elementAt(1)), [
        't',
        'other',
      ]);
      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('exceeds expected size'));
      expect(transfers.progressFor('t')!.status, DownloadStatus.failed);
      expect(transfers.progressFor('t')!.receivedBytes, prefixLength);
      expect(await partial('t').readAsBytes(), bytes.sublist(0, prefixLength));
      expect(await db.get('file', 't'), isNull);
      await expectDownloaded(other, otherBytes);

      api.dio.httpClientAdapter = FakeAdapter((options, _) {
        expect(options.path, endsWith('/t/audio'));
        expect(options.cancelToken!.isCancelled, isFalse);
        expect(options.headers['Range'], 'bytes=$prefixLength-');
        return ResponseBody.fromBytes(
          bytes.sublist(prefixLength),
          206,
          headers: {
            'content-range': [
              'bytes $prefixLength-${bytes.length - 1}/${bytes.length}',
            ],
          },
        );
      });
      await transfers.reconcile(tracks, [], _pins(tracks)).timeout(_timeout);
      await expectDownloaded(track, bytes);
      expect(errors, hasLength(1));
    } finally {
      body.release();
      await running.timeout(_timeout);
    }
  });

  for (final action in ['close', 'unpin']) {
    test(
      '$action after full buffer plus tail does not drain pending bytes',
      () async {
        final bytes = _bytes(2 * _bufferSize + 101);
        final track = _track(bytes);
        final prefixLength = _bufferSize + 73;
        final body = _OpenBody();
        CancelToken? token;
        api.dio.httpClientAdapter = FakeAdapter((options, _) {
          token = options.cancelToken;
          body.controller.add(Uint8List.sublistView(bytes, 0, prefixLength));
          return ResponseBody(body.controller.stream, 200);
        });
        final running = transfers.reconcile([track], [], _pins([track]));
        Future<void>? stopping;
        try {
          // Request arrival is not enough: the tail must actually be consumed.
          await _waitForBytes(transfers, prefixLength);
          expect(await partial('t').length(), _bufferSize);
          stopping = action == 'close'
              ? transfers.close()
              : transfers.reconcile([track], [], []);
          await Future.wait([running, stopping]).timeout(_timeout);
          expect(token!.isCancelled, isTrue);
          expect(body.cancelled, isTrue);
          expect(errors, isEmpty);
          expect(transfers.hasRunningDownloads, isFalse);
          expect(await db.get('file', 't'), isNull);
          expect(await audio('t').exists(), isFalse);
          // Cancellation publishes the durable offset before unpin removes it.
          expect(
            observed
                .where((p) => p.status == DownloadStatus.queued)
                .map((p) => p.receivedBytes),
            contains(_bufferSize),
          );
          expect(
            observed
                .where((p) => p.status == DownloadStatus.queued)
                .map((p) => p.receivedBytes),
            isNot(contains(prefixLength)),
          );
          if (action == 'close') {
            expect(
              await partial('t').readAsBytes(),
              bytes.sublist(0, _bufferSize),
            );
            expect(transfers.progressFor('t')!.receivedBytes, _bufferSize);
            expect(
              (await db.get('download', 't'))!['received_bytes'],
              _bufferSize,
            );
          } else {
            expect(await partial('t').exists(), isFalse);
            expect(transfers.progressFor('t'), isNull);
            expect(await db.get('download', 't'), isNull);
          }
          await expectQuiet();
        } finally {
          body.release();
          await Future.wait([running, ?stopping]).timeout(_timeout);
        }
      },
    );
  }

  test('isolated buffered progress gets a trailing tick; terminal statuses notify immediately', () async {
    final bytes = _bytes(40);
    final track = _track(bytes);
    final body = _OpenBody();
    final byteTick = Completer<DownloadProgress>();
    onProgress = (progress) {
      if (progress.status == DownloadStatus.downloading &&
          progress.receivedBytes > 0 &&
          !byteTick.isCompleted) {
        byteTick.complete(progress);
      }
    };
    api.dio.httpClientAdapter = FakeAdapter(
      (_, _) => ResponseBody(body.controller.stream, 200),
    );
    final running = transfers.reconcile([track], [], _pins([track]));
    try {
      await _waitForBytes(transfers, 0);
      final clock = Stopwatch()..start();
      body.controller.add(Uint8List.sublistView(bytes, 0, 23));
      await _waitForBytes(transfers, 23);
      expect(await partial('t').length(), 0);
      expect((await byteTick.future.timeout(_timeout)).receivedBytes, 23);
      expect(
        clock.elapsed,
        greaterThanOrEqualTo(DownloadProgressThrottle.interval),
      );
      body.controller.add(Uint8List.sublistView(bytes, 23));
      await _waitForBytes(transfers, bytes.length);
      body.release();
      await running.timeout(_timeout);
      await expectDownloaded(track, bytes);
      expect(observed.map((p) => p.status), contains(DownloadStatus.verifying));
      expect(
        observed.map((p) => p.status),
        contains(DownloadStatus.downloaded),
      );
      expect(errors, isEmpty);
      await expectQuiet();
    } finally {
      body.release();
      await running.timeout(_timeout);
    }
  });

  test(
    'failed file write is discarded rather than retried by error-tail flush',
    () async {
      var writes = 0;
      final failure = FileSystemException('disk full');
      final writer = BufferedDownloadWriter(
        write: (_, _) async {
          writes++;
          throw failure;
        },
      );
      await expectLater(
        writer.add(_bytes(_bufferSize + 17)),
        throwsA(same(failure)),
      );
      await writer.flush();
      expect(
        writes,
        1,
        reason: 'A failed write may have already written a prefix',
      );
    },
  );
}
