import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/transfer_service.dart';

import 'fakes.dart';

SessionCredentials sessionFor(String server) => SessionCredentials(
  account: Account(server: server, userId: 'user', username: 'listener'),
  accessToken: 'access',
  refreshToken: 'refresh',
  expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
);

void main() {
  test(
    'default API requests have finite connect, send and receive timeouts',
    () async {
      final api = ApiClient(credentials: MemoryCredentials())
        ..session = sessionFor('https://yun.test');
      addTearDown(() => api.dio.close(force: true));
      api.dio.httpClientAdapter = FakeAdapter((options, bytes) {
        expect(options.connectTimeout, const Duration(seconds: 15));
        expect(options.sendTimeout, const Duration(seconds: 60));
        expect(options.receiveTimeout, const Duration(seconds: 60));
        expect(bytes, [1, 2, 3]);
        return jsonResponse({'offset': 3});
      });
      await api.request(
        '/uploads/remote',
        method: 'PATCH',
        data: Uint8List.fromList([1, 2, 3]),
        headers: {
          'Content-Type': 'application/octet-stream',
          'Upload-Offset': 0,
        },
      );
    },
  );

  test(
    'a peer accepting but not reading an upload produces Dio sendTimeout',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sockets = <Socket>[];
      final accepted = Completer<void>();
      final subscription = server.listen((socket) {
        sockets.add(socket);
        if (!accepted.isCompleted) accepted.complete();
        // Deliberately never listen to the socket: the peer stops draining writes.
      });
      final api = ApiClient(credentials: MemoryCredentials())
        ..session = sessionFor('http://127.0.0.1:${server.port}');
      api.dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => HttpClient()..findProxy = (_) => 'DIRECT',
      );
      // Exercise the real adapter without waiting for the production 60s bound.
      api.dio.options.sendTimeout = const Duration(milliseconds: 500);
      addTearDown(() async {
        api.dio.close(force: true);
        for (final socket in sockets) {
          socket.destroy();
        }
        await subscription.cancel();
        await server.close();
      });
      final chunk = Uint8List(1024 * 1024);
      final request = api.request(
        '/uploads/remote',
        method: 'PATCH',
        // Larger than loopback socket buffers, with bounded source memory.
        data: Stream<Uint8List>.fromIterable(List.filled(64, chunk)),
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Length': 64 * chunk.length,
          'Upload-Offset': 0,
        },
      );
      await expectLater(
        request.timeout(const Duration(seconds: 5)),
        throwsA(
          isA<DioException>()
              .having((e) => e.type, 'type', DioExceptionType.sendTimeout)
              .having((e) => e.response, 'response', isNull),
        ),
      );
      expect(accepted.isCompleted, isTrue);
      expect(sockets, hasLength(1)); // No automatic replay after a timeout.
    },
  );

  for (final type in [
    DioExceptionType.connectionTimeout,
    DioExceptionType.sendTimeout,
    DioExceptionType.receiveTimeout,
  ]) {
    test(
      'API preserves $type without refreshing or replaying the chunk',
      () async {
        final dio = Dio();
        addTearDown(() => dio.close(force: true));
        final api = ApiClient(dio: dio, credentials: MemoryCredentials())
          ..session = sessionFor('https://yun.test');
        var calls = 0;
        late DioException failure;
        dio.httpClientAdapter = FakeAdapter((options, _) {
          calls++;
          failure = DioException(requestOptions: options, type: type);
          throw failure;
        });
        await expectLater(
          api.request('/uploads/remote', method: 'PATCH', data: [1]),
          throwsA(isA<DioException>().having((e) => e.type, 'type', type)),
        );
        expect(calls, 1);
        expect(failure.response, isNull);
        expect(api.session!.accessToken, 'access');
      },
    );
  }

  for (final serverOffsetAfterTimeout in [2, 4, 6]) {
    test(
      'send timeout retains acknowledged offset and retry reconciles server offset $serverOffsetAfterTimeout',
      () async {
        final root = await Directory.systemTemp.createTemp('yun-api-timeout-');
        final db = CacheDatabase.memory();
        final api = ApiClient(credentials: MemoryCredentials())
          ..session = sessionFor('https://yun.test');
        final errors = <Object>[];
        final transfers = TransferService(
          api: api,
          database: db,
          directory: root,
          onChanged: () {},
          onTrack: (track) => db.put('track', track.id, track.toJson()),
          onError: errors.add,
        );
        addTearDown(() async {
          await transfers.close();
          api.dio.close(force: true);
          await db.close();
          await root.delete(recursive: true);
        });
        final source = await File('${root.path}/song.mp3')
            .writeAsBytes([1, 2, 3, 4, 5, 6]);
        await db.put(
          'upload',
          'job',
          UploadJob(
            id: 'job',
            localPath: source.path,
            filename: 'song.mp3',
            sizeBytes: 6,
            offset: 2,
            remoteId: 'remote',
          ).toJson(),
        );
        var durableOffset = 2;
        var timedOut = false;
        final methods = <String>[];
        api.dio.httpClientAdapter = FakeAdapter((options, body) {
          methods.add(options.method);
          if (options.method == 'GET') {
            return jsonResponse({'id': 'remote', 'offset': durableOffset});
          }
          if (options.method == 'PATCH') {
            expect(options.sendTimeout, const Duration(seconds: 60));
            expect(options.headers['Upload-Offset'], durableOffset);
            expect(body, [1, 2, 3, 4, 5, 6].sublist(durableOffset));
            if (!timedOut) {
              timedOut = true;
              // A timed-out write may have committed none, some, or all bytes.
              durableOffset = serverOffsetAfterTimeout;
              throw DioException.sendTimeout(
                timeout: options.sendTimeout!,
                requestOptions: options,
              );
            }
            durableOffset = 6;
            return jsonResponse({'offset': durableOffset});
          }
          if (options.path.endsWith('/complete')) {
            expect(durableOffset, 6);
            return jsonResponse(
              const Track(id: 'track', title: 'Song').toJson(),
            );
          }
          throw StateError(
            'Unexpected request: ${options.method} ${options.path}',
          );
        });

        await transfers.runUploads();
        final failed = UploadJob.fromJson((await db.get('upload', 'job'))!);
        expect(failed.offset, 2);
        expect(failed.remoteId, 'remote');
        expect(failed.status, 'failed');
        expect(methods, ['GET', 'PATCH']);
        expect(errors, hasLength(1));
        expect(
          errors.single,
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.sendTimeout,
          ),
        );

        await transfers.retryUpload('job');
        final completed = UploadJob.fromJson((await db.get('upload', 'job'))!);
        expect(completed.status, 'done');
        expect(completed.offset, 6);
        expect(completed.remoteId, 'remote');
        expect(methods, [
          'GET',
          'PATCH',
          'GET',
          if (serverOffsetAfterTimeout < 6) 'PATCH',
          'POST',
        ]);
        expect(errors, hasLength(1));
        expect(await db.get('track', 'track'), isNotNull);
      },
    );
  }
}
