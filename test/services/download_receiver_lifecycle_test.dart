import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/services/download_receiver.dart';

const _deadline = Duration(seconds: 5);
const _secret = 'Authorization: Bearer lifecycle-secret';
const _privateUrl = 'https://private.invalid/audio?token=lifecycle-secret';

Never _fatal() => Error.throwWithStackTrace(
  StateError('$_secret $_privateUrl'),
  StackTrace.fromString('private-worker-stack $_secret'),
);

void _fatalBeforeReady(SendPort _) => _fatal();
void _exitBeforeReady(SendPort _) => Isolate.exit();

// Each new worker handles the same command language, so restart tests can
// deliberately fail one request and then succeed on the very same receiver.
void _scriptedWorker(SendPort events) {
  final commands = ReceivePort();
  commands.listen((dynamic message) {
    final command = message as Map;
    final id = command['id'];
    switch (command['type']) {
      case 'receive':
        final request = command['request'] as Map;
        switch (Uri.parse(request['url'] as String).path) {
          case '/fatal':
            events.send({'type': 'progress', 'id': id, 'bytes': 1});
            _fatal();
          case '/exit':
            events.send({'type': 'progress', 'id': id, 'bytes': 1});
            Isolate.exit();
          case '/idle-death':
            events.send({'type': 'done', 'id': id});
            Timer(const Duration(milliseconds: 50), _fatal);
          case '/stale':
            // Old job messages must be acknowledged but never delivered to
            // this job's callback or mistaken for its completion.
            events.send({
              'type': 'progress',
              'id': (id as int) - 1,
              'bytes': 999,
            });
            events.send({'type': 'done', 'id': id - 1});
            events.send({'type': 'progress', 'id': id, 'bytes': 2});
            events.send({'type': 'done', 'id': id});
          default:
            events.send({'type': 'progress', 'id': id, 'bytes': 2});
            events.send({'type': 'done', 'id': id});
        }
      case 'close':
        commands.close();
      case 'cancel':
        events.send({
          'type': 'error',
          'id': id,
          'message': 'Download cancelled',
          'statusCode': null,
          'transportType': null,
          'cancelled': true,
        });
      case 'progressAck':
        break;
    }
  });
  events.send(commands.sendPort);
}

void _slowReadyWorker(SendPort events) {
  // close() is called synchronously after receive(), before spawn resolves.
  Timer(const Duration(milliseconds: 100), () => _scriptedWorker(events));
}

void _gatedCloseWorker(SendPort events) {
  final commands = ReceivePort();
  late Uri endpoint;
  commands.listen((dynamic message) async {
    final command = message as Map;
    if (command['type'] == 'receive') {
      endpoint = Uri.parse((command['request'] as Map)['url'] as String);
      events.send({'type': 'done', 'id': command['id']});
    } else if (command['type'] == 'close') {
      commands.close();
      // A protocol message/closed command port is not proof of isolate exit.
      events.send({'type': 'closed'});
      final client = HttpClient();
      try {
        final request = await client.getUrl(endpoint);
        final response = await request.close();
        await response.drain<void>();
      } finally {
        client.close(force: true);
      }
    }
  });
  events.send(commands.sendPort);
}

Matcher _cancelled() => isA<DownloadReceiveException>().having(
  (error) => error.cancelled,
  'cancelled',
  true,
);

Matcher _workerFailure() => isA<DownloadReceiveException>()
    .having(
      (error) => error.message,
      'sanitized message',
      'Download worker stopped unexpectedly',
    )
    .having(
      (error) => error.toString(),
      'no credentials',
      isNot(contains('secret')),
    )
    .having(
      (error) => error.toString(),
      'no URL',
      isNot(contains('private.invalid')),
    )
    .having(
      (error) => error.toString(),
      'no stack',
      isNot(contains('worker-stack')),
    )
    .having((error) => error.transportType, 'transportType', isNull)
    .having((error) => error.statusCode, 'statusCode', isNull)
    .having((error) => error.cancelled, 'cancelled', false);

void main() {
  late Directory directory;
  late File partial;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('receiver-lifecycle-');
    partial = File('${directory.path}/audio.part');
  });
  tearDown(() => directory.delete(recursive: true));

  DownloadReceiveRequest input({
    String url = 'https://example.invalid/ok',
    int size = 6,
    Duration receiveTimeout = const Duration(seconds: 2),
  }) => DownloadReceiveRequest(
    url: url,
    path: partial.path,
    sha256: 'identity',
    offset: 0,
    sizeBytes: size,
    headers: const {'Authorization': 'Bearer lifecycle-secret'},
    receiveTimeout: receiveTimeout,
  );

  Future<void> receive(
    IsolateDownloadReceiver receiver, {
    String path = '/ok',
    void Function(int)? onProgress,
  }) => receiver
      .receive(
        input(url: 'https://example.invalid$path'),
        cancelToken: CancelToken(),
        onProgress: onProgress ?? (_) {},
      )
      .timeout(_deadline);

  for (final entry in <String, void Function(SendPort)>{
    'fatal error': _fatalBeforeReady,
    'silent exit': _exitBeforeReady,
  }.entries) {
    test('${entry.key} before readiness settles receive and repeated startup', () async {
      final receiver = IsolateDownloadReceiver(workerEntrypoint: entry.value);
      addTearDown(() => receiver.close().timeout(_deadline));
      // A subsequent attempt must not wait forever on the previous ready port.
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(receive(receiver), throwsA(_workerFailure()));
      }
      await receiver.close().timeout(_deadline);
      await receiver.close().timeout(_deadline);
    });
  }

  for (final path in ['/fatal', '/exit']) {
    test(
      '$path during receive is sanitized and the next job restarts',
      () async {
        final receiver = IsolateDownloadReceiver(
          workerEntrypoint: _scriptedWorker,
        );
        addTearDown(() => receiver.close().timeout(_deadline));
        final failedProgress = <int>[];
        for (var attempt = 0; attempt < 2; attempt++) {
          await expectLater(
            receive(receiver, path: path, onProgress: failedProgress.add),
            throwsA(_workerFailure()),
          );
          final progress = <int>[];
          await receive(receiver, onProgress: progress.add);
          expect(progress, [2]);
        }
        expect(failedProgress, [1, 1]);
        await receiver.close().timeout(_deadline);
      },
    );
  }

  test('death while idle does not poison the next receive', () async {
    final receiver = IsolateDownloadReceiver(workerEntrypoint: _scriptedWorker);
    addTearDown(() => receiver.close().timeout(_deadline));
    await receive(receiver, path: '/idle-death');
    // Let the timer fire after the previous job has completed and onExit reach
    // the root. There is no pending receive to consume the fatal VM event.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final progress = <int>[];
    await receive(receiver, onProgress: progress.add);
    expect(progress, [2]);
  });

  for (final entry in <String, void Function(SendPort)>{
    'delayed readiness': _slowReadyWorker,
    'early fatal error': _fatalBeforeReady,
    'early silent exit': _exitBeforeReady,
  }.entries) {
    test(
      'close during spawn with ${entry.key} joins and stays closed',
      () async {
        final receiver = IsolateDownloadReceiver(workerEntrypoint: entry.value);
        addTearDown(() => receiver.close().timeout(_deadline));
        final progress = <int>[];
        final result = expectLater(
          receive(receiver, onProgress: progress.add),
          throwsA(_cancelled()),
        );
        final closing = receiver.close();
        expect(identical(receiver.close(), closing), true);
        await Future.wait([result, closing]).timeout(_deadline);
        expect(progress, isEmpty);
        await expectLater(receive(receiver), throwsA(_cancelled()));
      },
    );
  }

  test(
    'close waits for actual onExit, not a closed protocol message',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final gate = Completer<HttpRequest>();
      server.listen(gate.complete);
      final receiver = IsolateDownloadReceiver(
        workerEntrypoint: _gatedCloseWorker,
      );
      addTearDown(() => receiver.close().timeout(_deadline));
      await receiver
          .receive(
            input(url: 'http://${server.address.address}:${server.port}/close'),
            cancelToken: CancelToken(),
            onProgress: (_) {},
          )
          .timeout(_deadline);
      var closed = false;
      final closing = receiver.close().then((_) => closed = true);
      final request = await gate.future.timeout(_deadline);
      try {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(
          closed,
          false,
          reason: 'worker is still waiting on its HTTP gate',
        );
      } finally {
        await request.response.close();
      }
      await closing.timeout(_deadline);
      expect(closed, true);
    },
  );

  test(
    'old job progress and completion cannot leak into the next job',
    () async {
      final receiver = IsolateDownloadReceiver(
        workerEntrypoint: _scriptedWorker,
      );
      addTearDown(() => receiver.close().timeout(_deadline));
      final first = <int>[];
      final second = <int>[];
      await receive(receiver, onProgress: first.add);
      await receive(receiver, path: '/stale', onProgress: second.add);
      await receiver.close().timeout(_deadline);
      expect(first, [2]);
      expect(second, [2]);
    },
  );

  for (final failure in ['http', 'timeout']) {
    test(
      'real worker preserves $failure classification without credentials',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          expect(
            request.headers.value('authorization'),
            'Bearer lifecycle-secret',
          );
          if (request.uri.path == '/ok') {
            request.response.add([1, 2, 3, 4, 5, 6]);
          } else if (failure == 'http') {
            request.response.statusCode = 403;
            request.response.write(
              '$_secret $_privateUrl private-worker-stack',
            );
          } else {
            return; // No response headers: trigger Dio's receive timeout.
          }
          await request.response.close();
        });
        final base = 'http://${server.address.address}:${server.port}';
        final receiver = IsolateDownloadReceiver();
        addTearDown(() => receiver.close().timeout(_deadline));
        await expectLater(
          receiver
              .receive(
                input(
                  url: '$base/fail?token=lifecycle-secret',
                  receiveTimeout: const Duration(milliseconds: 150),
                ),
                cancelToken: CancelToken(),
                onProgress: (_) {},
              )
              .timeout(_deadline),
          throwsA(
            isA<DownloadReceiveException>()
                .having(
                  (e) => e.transportType,
                  'transportType',
                  failure == 'http'
                      ? DioExceptionType.badResponse
                      : DioExceptionType.receiveTimeout,
                )
                .having(
                  (e) => e.statusCode,
                  'statusCode',
                  failure == 'http' ? 403 : null,
                )
                .having((e) => e.cancelled, 'cancelled', false)
                .having(
                  (e) => e.message,
                  'sanitized message',
                  failure == 'http'
                      ? 'Unexpected download status 403'
                      : 'Download connection failed',
                )
                .having(
                  (e) => e.toString(),
                  'no credentials',
                  isNot(contains('secret')),
                )
                .having((e) => e.toString(), 'no URL', isNot(contains(base)))
                .having(
                  (e) => e.toString(),
                  'no stack',
                  isNot(contains('worker-stack')),
                ),
          ),
        );
        await receiver
            .receive(
              input(url: '$base/ok'),
              cancelToken: CancelToken(),
              onProgress: (_) {},
            )
            .timeout(_deadline);
        expect(await partial.readAsBytes(), [1, 2, 3, 4, 5, 6]);
      },
    );
  }

  test('real worker throttles progress, flushes final count, and leaves no stale callbacks', () async {
    const chunks = 40;
    const chunkSize = 1024;
    final bytes = Uint8List.fromList(List.generate(chunkSize, (i) => i % 251));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.contentLength = chunks * chunkSize;
      for (var i = 0; i < chunks; i++) {
        request.response.add(bytes);
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await request.response.close();
    });
    final receiver = IsolateDownloadReceiver();
    addTearDown(() => receiver.close().timeout(_deadline));
    final first = <int>[];
    final second = <int>[];
    final request = input(
      url: 'http://${server.address.address}:${server.port}/audio',
      size: chunks * chunkSize,
    );
    await receiver
        .receive(request, cancelToken: CancelToken(), onProgress: first.add)
        .timeout(_deadline);
    final snapshot = List<int>.of(first);
    await receiver
        .receive(request, cancelToken: CancelToken(), onProgress: second.add)
        .timeout(_deadline);
    await receiver.close().timeout(_deadline);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(first, snapshot);
    for (final progress in [first, second]) {
      expect(progress.first, 0);
      expect(progress.last, chunks * chunkSize);
      expect(progress.length, greaterThan(2));
      expect(progress.length, lessThan(chunks ~/ 2));
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThan(progress[i - 1]));
      }
    }
    expect(await partial.readAsBytes(), [
      for (var i = 0; i < chunks; i++) ...bytes,
    ]);
  });

  test('real worker bounds unacknowledged progress and bypasses ACK for terminal count', () async {
    // Spawn the real public entrypoint directly to model a suspended root that
    // cannot send progressAck. The high-level receiver always ACKs immediately.
    final events = ReceivePort();
    final exits = ReceivePort();
    final ready = Completer<SendPort>();
    final done = Completer<void>();
    final acknowledgedProgress = Completer<void>();
    final progress = <int>[];
    final subscription = events.listen((dynamic event) {
      if (event is SendPort) {
        ready.complete(event);
      } else if (event is Map && event['type'] == 'progress') {
        expect(event['id'], 7);
        progress.add(event['bytes'] as int);
        if (progress.length == 2) acknowledgedProgress.complete();
      } else if (event is Map && event['type'] == 'done') {
        done.complete();
      } else {
        done.completeError(StateError('Unexpected worker event: $event'));
      }
    });
    final exited = exits.first;
    final isolate = await Isolate.spawn(
      IsolateDownloadReceiver().workerEntrypoint,
      events.sendPort,
      onExit: exits.sendPort,
      onError: events.sendPort,
    );
    addTearDown(() async {
      isolate.kill(priority: Isolate.immediate);
      await subscription.cancel();
      events.close();
      exits.close();
    });
    final commands = await ready.future.timeout(_deadline);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final burstSent = Completer<void>();
    final finish = Completer<void>();
    addTearDown(() {
      if (!finish.isCompleted) finish.complete();
    });
    server.listen((request) async {
      request.response.bufferOutput = false;
      request.response.contentLength = 21;
      for (var i = 0; i < 20; i++) {
        request.response.add([i]);
        await request.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      burstSent.complete();
      await finish.future;
      request.response.add([20]);
      await request.response.close();
    });
    commands.send({
      'type': 'receive',
      'id': 7,
      'request': {
        'url': 'http://${server.address.address}:${server.port}/audio',
        'path': partial.path,
        'sha256': 'identity',
        'offset': 0,
        'sizeBytes': 21,
        'headers': <String, String>{},
        'connectTimeout': null,
        'sendTimeout': null,
        'receiveTimeout': null,
      },
    });
    await burstSent.future.timeout(_deadline);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(progress, [0], reason: 'only one ordinary message may await ACK');
    commands.send({'type': 'progressAck', 'id': 6});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(progress, [0], reason: 'an old job ACK must not release this job');
    commands.send({'type': 'progressAck', 'id': 7});
    await acknowledgedProgress.future.timeout(_deadline);
    expect(progress, [0, 20]);
    // Do not ACK the second message. Terminal progress must still be sent.
    finish.complete();
    await done.future.timeout(_deadline);
    expect(progress, [0, 20, 21]);
    expect(await partial.readAsBytes(), List.generate(21, (i) => i));
    commands.send({'type': 'progressAck', 'id': 7});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(progress, [
      0,
      20,
      21,
    ], reason: 'late ACK cannot revive the throttle');
    commands.send({'type': 'close'});
    await exited.timeout(_deadline);
  });
}
