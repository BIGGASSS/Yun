import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/download_receiver.dart';
import 'package:yun/services/transfer_service.dart';

import '../core/fakes.dart';

const _deadline = Duration(seconds: 5);

// Model file cleanup taking longer than the shutdown grace period. Only after
// the gate opens may cancellation be acknowledged and forced exit become safe.
void _fileCleanupWorker(SendPort events) {
  final commands = ReceivePort();
  RandomAccessFile? output;
  late Map<dynamic, dynamic> job;
  commands.listen((dynamic message) async {
    final command = message as Map;
    switch (command['type']) {
      case 'receive':
        job = command;
        output = await File((job['request'] as Map)['path'] as String)
            .open(mode: FileMode.write);
        await output!.writeFrom([1, 2]);
        events.send({'type': 'progress', 'id': job['id'], 'bytes': 2});
      case 'cancel':
        final client = HttpClient();
        try {
          final request = await client.getUrl(
            Uri.parse((job['request'] as Map)['url'] as String),
          );
          final response = await request.close();
          await response.drain<void>();
        } finally {
          client.close(force: true);
        }
        await output!.writeFrom([3, 4]);
        await output!.flush();
        await output!.close();
        output = null;
        events.send({
          'type': 'error',
          'id': job['id'],
          'message': 'Download cancelled',
          'cancelled': true,
        });
      case 'close':
        commands.close();
        // Natural exit is impossible until the root's safe fallback kills us.
        Timer.periodic(const Duration(hours: 1), (_) {});
    }
  });
  events.send(commands.sendPort);
}

void main() {
  late Directory directory;
  late File partial;
  late ServerSocket peer;
  late List<Socket> sockets;
  late Completer<void> clientHello;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('receiver-tls-stop-');
    partial = File('${directory.path}/t.audio.part');
    await partial.writeAsBytes([9, 8, 7]);
    sockets = [];
    clientHello = Completer<void>();
    peer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    peer.listen((socket) {
      sockets.add(socket);
      socket.listen((bytes) {
        // Accept and consume the TLS ClientHello, but NEVER answer or close.
        if (bytes.isNotEmpty && !clientHello.isCompleted) {
          clientHello.complete();
        }
      }, onError: (Object _) {});
    });
  });

  tearDown(() async {
    // Cleanup must happen after the close assertion, never to unblock it.
    for (final socket in sockets) {
      socket.destroy();
    }
    await peer.close();
    await directory.delete(recursive: true);
  });

  String url() => 'https://127.0.0.1:${peer.port}/audio';
  DownloadReceiveRequest input() => DownloadReceiveRequest(
    url: url(),
    path: partial.path,
    sha256: 'identity',
    offset: 3,
    sizeBytes: 6,
    headers: const {},
    // Default 15-second connect deadline is deliberately longer than the
    // assertion: neither that deadline nor peer teardown may unblock close.
  );

  for (final cancelFirst in [false, true]) {
    test(
      'stalled TLS: ${cancelFirst ? 'idle close after cancellation' : 'close while receiving'} exits without peer teardown',
      () async {
        final receiver = IsolateDownloadReceiver();
        final token = CancelToken();
        final progress = <int>[];
        final receiving = expectLater(
          receiver.receive(
            input(),
            cancelToken: token,
            onProgress: progress.add,
          ),
          throwsA(
            isA<DownloadReceiveException>().having(
              (error) => error.cancelled,
              'cancelled',
              true,
            ),
          ),
        );
        try {
          await clientHello.future.timeout(_deadline);
          if (cancelFirst) {
            token.cancel();
            await receiving.timeout(_deadline);
          }
          final closing = receiver.close();
          expect(identical(receiver.close(), closing), isTrue);
          await Future.wait([closing, receiving]).timeout(_deadline);
          expect(await partial.readAsBytes(), [9, 8, 7]);
          expect(progress, isEmpty);
          await receiver.close().timeout(_deadline);
          await Future<void>.delayed(const Duration(milliseconds: 150));
          expect(progress, isEmpty);
        } finally {
          // Also make a failing pre-fix test terminate instead of leaking its
          // worker forever. No socket is destroyed before the assertion above.
          for (final socket in sockets) {
            socket.destroy();
          }
          await receiver.close().timeout(_deadline);
          await receiving.timeout(_deadline);
        }
      },
    );
  }

  test(
    'TransferService.close joins a cancelled TLS handshake without the peer',
    () async {
      final database = CacheDatabase.memory();
      final api = ApiClient(credentials: MemoryCredentials())
        ..session = SessionCredentials(
          account: Account(
            server: 'https://127.0.0.1:${peer.port}',
            userId: 'u',
            username: 'u',
          ),
          accessToken: 'test-access',
          refreshToken: 'test-refresh',
          expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
        );
      final errors = <Object>[];
      final service = TransferService(
        api: api,
        database: database,
        directory: directory,
        onChanged: () {},
        onTrack: (_) async {},
        onError: errors.add,
      );
      final track = Track(
        id: 't',
        title: 't',
        sizeBytes: 6,
        sha256: 'identity',
      );
      final running = service.reconcile(
        [track],
        [],
        [const PinSelection('track', 't')],
      );
      try {
        await clientHello.future.timeout(_deadline);
        await Future.wait([service.close(), running]).timeout(_deadline);
        expect(errors, isEmpty);
        expect(await partial.readAsBytes(), [9, 8, 7]);
        expect(await database.get('file', 't'), isNull);
        expect(service.progressFor('t')!.status, DownloadStatus.queued);
      } finally {
        for (final socket in sockets) {
          socket.destroy();
        }
        await service.close().timeout(_deadline);
        await running.timeout(_deadline);
        api.dio.close(force: true);
        await database.close();
      }
    },
  );

  test(
    'forced exit grace starts only after active file cleanup is acknowledged',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final gate = Completer<HttpRequest>();
      server.listen(gate.complete);
      final receiver = IsolateDownloadReceiver(
        workerEntrypoint: _fileCleanupWorker,
      );
      final started = Completer<void>();
      final receiving = expectLater(
        receiver.receive(
          DownloadReceiveRequest(
            url: 'http://127.0.0.1:${server.port}/cleanup',
            path: partial.path,
            sha256: 'identity',
            offset: 0,
            sizeBytes: 4,
            headers: const {},
          ),
          cancelToken: CancelToken(),
          onProgress: (_) {
            if (!started.isCompleted) started.complete();
          },
        ),
        throwsA(
          isA<DownloadReceiveException>().having(
            (e) => e.cancelled,
            'cancelled',
            true,
          ),
        ),
      );
      HttpRequest? blocked;
      try {
        await started.future.timeout(_deadline);
        var closed = false;
        final closing = receiver.close().then((_) => closed = true);
        blocked = await gate.future.timeout(_deadline);
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(
          closed,
          isFalse,
          reason: 'must not kill a worker with active file work',
        );
        expect(await partial.readAsBytes(), [1, 2]);
        await blocked.response.close();
        blocked = null;
        await Future.wait([closing, receiving]).timeout(_deadline);
        expect(await partial.readAsBytes(), [1, 2, 3, 4]);
      } finally {
        await blocked?.response.close();
        await server.close(force: true);
        await receiver.close().timeout(_deadline);
        await receiving.timeout(_deadline);
      }
    },
  );
}
