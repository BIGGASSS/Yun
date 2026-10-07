import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/services/download_receiver.dart';

void main() {
  late Directory directory;
  late File partial;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('download-receiver-test');
    partial = File('${directory.path}/audio.part');
  });
  tearDown(() => directory.delete(recursive: true));

  DownloadReceiveRequest input({
    int offset = 0,
    int size = 6,
    String url = 'https://example.invalid/audio',
  }) => DownloadReceiveRequest(
    url: url,
    path: partial.path,
    sha256: 'identity',
    offset: offset,
    sizeBytes: size,
    headers: {
      'Authorization': 'Bearer test-secret',
      if (offset > 0) 'Range': 'bytes=$offset-',
      if (offset > 0) 'If-Range': '"identity"',
    },
  );

  Response<dynamic> response(
    Stream<Uint8List> stream, {
    int status = 200,
    Map<String, List<String>> headers = const {},
  }) => Response<dynamic>(
    requestOptions: RequestOptions(path: '/audio'),
    statusCode: status,
    headers: Headers.fromMap(headers),
    data: ResponseBody(stream, status, headers: headers),
  );

  Stream<Uint8List> chunks(List<List<int>> bytes) =>
      Stream.fromIterable(bytes.map(Uint8List.fromList));

  Matcher cancelled() => isA<DownloadReceiveException>().having(
    (error) => error.cancelled,
    'cancelled',
    true,
  );

  test('inline resumes and publishes each accepted chunk', () async {
    await partial.writeAsBytes([1, 2]);
    final progress = <int>[];
    CancelToken? bodyToken;
    final receiver = InlineDownloadReceiver(
      request: (request, token) async {
        bodyToken = token;
        expect(request.offset, 2);
        return response(
          chunks([
            [3],
            [4, 5, 6],
          ]),
          status: 206,
          headers: {
            'etag': ['"identity"'],
            'content-range': ['bytes 2-5/6'],
          },
        );
      },
    );
    addTearDown(receiver.close);
    final token = CancelToken();
    await receiver.receive(
      input(offset: 2),
      cancelToken: token,
      onProgress: progress.add,
    );
    expect(progress, [2, 3, 6]);
    expect(await partial.readAsBytes(), [1, 2, 3, 4, 5, 6]);
    expect(token.isCancelled, false);
    expect(bodyToken!.isCancelled, true);
  });

  test('200 resets a partial rather than appending', () async {
    await partial.writeAsBytes([9, 9]);
    final progress = <int>[];
    final receiver = InlineDownloadReceiver(
      request: (_, _) async => response(
        chunks([
          [1, 2, 3],
        ]),
      ),
    );
    addTearDown(receiver.close);
    await receiver.receive(
      input(offset: 2, size: 3),
      cancelToken: CancelToken(),
      onProgress: progress.add,
    );
    expect(progress, [0, 3]);
    expect(await partial.readAsBytes(), [1, 2, 3]);
  });

  test('overflow rejects entire chunk and flushes accepted tail', () async {
    final receiver = InlineDownloadReceiver(
      request: (_, _) async => response(
        chunks([
          [1, 2],
          [3, 4, 5, 6, 7],
        ]),
      ),
    );
    addTearDown(receiver.close);
    final token = CancelToken();
    final progress = <int>[];
    await expectLater(
      receiver.receive(input(), cancelToken: token, onProgress: progress.add),
      throwsA(
        isA<DownloadReceiveException>().having(
          (error) => error.message,
          'message',
          contains('exceeds'),
        ),
      ),
    );
    expect(await partial.readAsBytes(), [1, 2]);
    expect(progress, [0, 2]);
    expect(token.isCancelled, false);
  });

  test(
    'transport failure flushes tail without disclosing exception text',
    () async {
      Stream<Uint8List> broken() async* {
        yield Uint8List.fromList([1, 2]);
        throw StateError('Authorization: Bearer secret');
      }

      final receiver = InlineDownloadReceiver(
        request: (_, _) async => response(broken()),
      );
      addTearDown(receiver.close);
      await expectLater(
        receiver.receive(
          input(),
          cancelToken: CancelToken(),
          onProgress: (_) {},
        ),
        throwsA(
          isA<DownloadReceiveException>().having(
            (error) => error.message,
            'message',
            isNot(contains('secret')),
          ),
        ),
      );
      expect(await partial.readAsBytes(), [1, 2]);
    },
  );

  test(
    'cancel drops buffered tail and closes a stalled custom stream',
    () async {
      final controller = StreamController<Uint8List>();
      final stopped = Completer<void>();
      controller.onCancel = stopped.complete;
      final accepted = Completer<void>();
      final receiver = InlineDownloadReceiver(
        request: (_, _) async => response(controller.stream),
      );
      addTearDown(receiver.close);
      final token = CancelToken();
      final running = receiver.receive(
        input(),
        cancelToken: token,
        onProgress: (bytes) {
          if (bytes == 2) accepted.complete();
        },
      );
      final result = expectLater(running, throwsA(cancelled()));
      controller.add(Uint8List.fromList([1, 2]));
      await accepted.future;
      token.cancel();
      await result.timeout(const Duration(seconds: 2));
      await stopped.future;
      expect(await partial.length(), 0);
      await partial.delete(); // No live file handle remains after completion.
      await controller.close();
    },
  );

  test('close cancels stalled custom headers and is idempotent', () async {
    final pending = Completer<Response<dynamic>>();
    final started = Completer<void>();
    final receiver = InlineDownloadReceiver(
      request: (_, _) {
        started.complete();
        return pending.future;
      },
    );
    final result = expectLater(
      receiver.receive(input(), cancelToken: CancelToken(), onProgress: (_) {}),
      throwsA(cancelled()),
    );
    await started.future;
    await receiver.close().timeout(const Duration(seconds: 2));
    await result;
    await receiver.close();
    expect(await partial.exists(), false);
    // Even a non-cooperative callback returning a late response is disposed.
    final stopped = Completer<void>();
    final controller = StreamController<Uint8List>(onCancel: stopped.complete);
    pending.complete(response(controller.stream));
    await stopped.future.timeout(const Duration(seconds: 2));
    await controller.close();
  });

  for (final invalid in ['etag', 'range', 'status']) {
    test(
      'invalid $invalid closes unread body without changing partial',
      () async {
        await partial.writeAsBytes([8, 9]);
        final stopped = Completer<void>();
        final controller = StreamController<Uint8List>(
          onCancel: stopped.complete,
        );
        CancelToken? bodyToken;
        final receiver = InlineDownloadReceiver(
          request: (_, token) async {
            bodyToken = token;
            return response(
              controller.stream,
              status: invalid == 'status' ? 401 : 206,
              headers: {
                'etag': [invalid == 'etag' ? '"wrong"' : '"identity"'],
                'content-range': [
                  invalid == 'range' ? 'bytes 1-5/6' : 'bytes 2-5/6',
                ],
              },
            );
          },
        );
        addTearDown(receiver.close);
        await expectLater(
          receiver.receive(
            input(offset: 2),
            cancelToken: CancelToken(),
            onProgress: (_) {},
          ),
          throwsA(
            isA<DownloadReceiveException>().having(
              (error) => error.statusCode,
              'status',
              invalid == 'status' ? 401 : null,
            ),
          ),
        );
        await stopped.future;
        expect(bodyToken!.isCancelled, true);
        expect(await partial.readAsBytes(), [8, 9]);
        await controller.close();
      },
    );
  }

  test('large chunks use bounded writes and preserve exact bytes', () async {
    final bytes = Uint8List.fromList(List.generate(700000, (i) => i % 251));
    final receiver = InlineDownloadReceiver(
      request: (_, _) async => response(Stream.value(bytes)),
    );
    addTearDown(receiver.close);
    await receiver.receive(
      input(size: bytes.length),
      cancelToken: CancelToken(),
      onProgress: (_) {},
    );
    expect(await partial.readAsBytes(), bytes);
  });

  test('worker persists across HTTP errors and successful tracks', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      expect(request.headers.value('authorization'), 'Bearer test-secret');
      if (request.uri.path == '/unauthorized') {
        request.response.statusCode = 401;
      } else {
        request.response.headers.set('etag', '"identity"');
        request.response.add([1, 2, 3, 4, 5, 6]);
      }
      await request.response.close();
    });
    final base = 'http://${server.address.address}:${server.port}';
    final receiver = IsolateDownloadReceiver();
    addTearDown(receiver.close);
    await expectLater(
      receiver.receive(
        input(url: '$base/unauthorized'),
        cancelToken: CancelToken(),
        onProgress: (_) {},
      ),
      throwsA(
        isA<DownloadReceiveException>().having(
          (e) => e.statusCode,
          'status',
          401,
        ),
      ),
    );
    for (var i = 0; i < 2; i++) {
      final progress = <int>[];
      await receiver.receive(
        input(url: '$base/ok'),
        cancelToken: CancelToken(),
        onProgress: progress.add,
      );
      expect(progress.first, 0);
      expect(progress.last, 6);
      expect(await partial.readAsBytes(), [1, 2, 3, 4, 5, 6]);
    }
    await receiver.close();
    await receiver.close();
  });

  test('worker cancellation during startup permits the next job', () async {
    final receiver = IsolateDownloadReceiver();
    addTearDown(receiver.close);
    final token = CancelToken();
    final result = expectLater(
      receiver.receive(input(), cancelToken: token, onProgress: (_) {}),
      throwsA(cancelled()),
    );
    token.cancel();
    await result.timeout(const Duration(seconds: 3));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.add([1, 2, 3, 4, 5, 6]);
      await request.response.close();
    });
    await receiver.receive(
      input(url: 'http://${server.address.address}:${server.port}/audio'),
      cancelToken: CancelToken(),
      onProgress: (_) {},
    );
    expect(await partial.length(), 6);
  });

  for (final stalled in ['headers', 'body']) {
    test(
      'worker close interrupts stalled $stalled and joins cleanup',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final requested = Completer<void>();
        final accepted = Completer<void>();
        server.listen((request) async {
          requested.complete();
          if (stalled == 'body') {
            request.response.bufferOutput = false;
            request.response.contentLength = 6;
            request.response.add([1, 2]);
            await request.response.flush();
          }
        });
        final receiver = IsolateDownloadReceiver();
        addTearDown(receiver.close);
        var notifications = 0;
        final result = expectLater(
          receiver.receive(
            input(url: 'http://${server.address.address}:${server.port}/audio'),
            cancelToken: CancelToken(),
            onProgress: (bytes) {
              notifications++;
              if (bytes == 2 && !accepted.isCompleted) accepted.complete();
            },
          ),
          throwsA(cancelled()),
        );
        await requested.future;
        if (stalled == 'body') {
          await accepted.future.timeout(const Duration(seconds: 3));
        }
        await receiver.close().timeout(const Duration(seconds: 3));
        await result;
        final count = notifications;
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(notifications, count);
        if (stalled == 'body') {
          expect(await partial.length(), 0);
          await partial.delete();
        } else {
          expect(await partial.exists(), false);
        }
      },
    );
  }
}
