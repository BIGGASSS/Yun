import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yun/services/playback_relay.dart';

void main() {
  Future<HttpServer> server(void Function(HttpRequest) handle) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handle);
    addTearDown(() => server.close(force: true));
    return server;
  }

  Uri source(HttpServer server) => Uri.parse(
    'http://127.0.0.1:${server.port}/private/audio?token=url-secret',
  );

  Future<PlaybackRelay> relay(
    Uri upstream, {
    Map<String, String>? headers,
    HttpClient Function()? createClient,
    void Function(Object, StackTrace)? onError,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final relay = await PlaybackRelay.start(
      upstream,
      headers: headers,
      createClient: createClient,
      onError: onError,
      timeout: timeout,
    );
    addTearDown(relay.close);
    return relay;
  }

  test(
    'loopback capability is random, opaque and fixed to the upstream',
    () async {
      final upstream = await server((request) {
        expect(request.uri.toString(), '/private/audio?token=url-secret');
        request.response.write('audio');
        unawaited(request.response.close());
      });
      final first = await relay(source(upstream));
      final second = await relay(source(upstream));
      expect(first.uri.host, '127.0.0.1');
      expect(first.uri.scheme, 'http');
      expect(first.uri.path, matches(RegExp(r'^/[0-9a-f]{64}$')));
      expect(first.uri.path, isNot(second.uri.path));
      expect(first.uri.query, isEmpty);
      expect(first.uri.userInfo, isEmpty);
      expect((await _fetch(first.uri)).text, 'audio');
    },
  );

  test(
    'range seeks, HEAD, credentials and response-header isolation',
    () async {
      final requests = <HttpRequest>[];
      final upstream = await server((request) {
        requests.add(request);
        expect(
          request.headers.value('authorization'),
          'Bearer upstream-secret',
        );
        expect(request.headers.value('cookie'), 'session=fixed-secret');
        expect(request.headers.value('x-evil'), isNull);
        expect(request.headers.value('accept-encoding'), 'identity');
        expect(
          request.headers.value('host'),
          '127.0.0.1:${request.connectionInfo!.localPort}',
        );
        expect(request.headers.value('range'), 'bytes=2-5');
        expect(request.headers.value('if-range'), '"version"');
        final response = request.response;
        response.statusCode = 206;
        response.headers
          ..set('content-type', 'audio/mpeg')
          ..set('content-range', 'bytes 2-5/10')
          ..set('accept-ranges', 'bytes')
          ..set('etag', '"version"')
          ..set('last-modified', 'Wed, 21 Oct 2015 07:28:00 GMT')
          ..set('location', 'https://private.invalid/audio?token=url-secret');
        response.headers
          ..set('set-cookie', 'secret=upstream-secret')
          ..set('www-authenticate', 'Bearer upstream-secret')
          ..set('content-disposition', 'attachment; filename="private-path"')
          ..set('x-private', 'url-secret');
        response.contentLength = 4;
        if (request.method != 'HEAD') response.write('2345');
        unawaited(response.close());
      });
      final fixedHeaders = {
        'Authorization': 'Bearer upstream-secret',
        'Cookie': 'session=fixed-secret',
      };
      final playback = await relay(source(upstream), headers: fixedHeaders);
      fixedHeaders['Authorization'] = 'mutated';
      for (final method in ['GET', 'HEAD', 'GET']) {
        final result = await _fetch(
          playback.uri,
          method: method,
          headers: {
            'Range': 'bytes=2-5',
            'If-Range': '"version"',
            'Authorization': 'Bearer local-attacker',
            'Cookie': 'local-attacker',
            'X-Evil': 'not-forwarded',
          },
        );
        expect(result.status, 206);
        expect(result.text, method == 'HEAD' ? '' : '2345');
        expect(result.headers['content-length'], ['4']);
        expect(result.headers['content-range'], ['bytes 2-5/10']);
        expect(result.headers['accept-ranges'], ['bytes']);
        expect(result.headers['etag'], ['"version"']);
        expect(result.headers['content-type'], ['audio/mpeg']);
        expect(result.headers['last-modified'], isNotNull);
        expect(result.headers['cache-control'], ['no-store']);
        for (final name in [
          'location',
          'set-cookie',
          'www-authenticate',
          'content-disposition',
          'x-private',
        ]) {
          expect(result.headers[name], isNull);
        }
        expect(result.headers.toString(), isNot(contains('secret')));
      }
      expect(requests.map((r) => r.method), ['GET', 'HEAD', 'GET']);
    },
  );

  test('rejects invalid capabilities, hosts, browser requests and methods', () async {
    var hits = 0;
    final upstream = await server((request) {
      hits++;
      unawaited(request.response.close());
    });
    final playback = await relay(source(upstream));
    final authority = playback.uri.authority;
    final path = playback.uri.path;
    final cases = <(String, String, Map<String, String>, int)>[
      ('GET', '/wrong', {}, 404),
      ('GET', '$path?url=${source(upstream)}', {}, 404),
      ('GET', '$path/', {}, 404),
      ('GET', playback.uri.toString(), {}, 404),
      ('GET', path, {'Host': 'localhost:${playback.uri.port}'}, 404),
      ('GET', path, {'Host': 'attacker.invalid'}, 404),
      ('GET', path, {'Origin': 'null'}, 403),
      ('GET', path, {'Origin': 'http://127.0.0.1'}, 403),
      ('GET', path, {'Referer': 'https://attacker.invalid/'}, 403),
      ('GET', path, {'Sec-Fetch-Site': 'cross-site'}, 403),
      ('GET', path, {'Sec-Fetch-Mode': 'no-cors'}, 403),
      ('POST', path, {}, 405),
      ('OPTIONS', path, {}, 405),
      ('CONNECT', path, {}, 405),
      ('GET', path, {'Content-Length': '4'}, 400),
    ];
    for (final (method, target, headers, status) in cases) {
      final response = await _raw(
        playback.uri,
        '$method $target HTTP/1.1\r\n'
        '${{'Host': authority, ...headers}.entries.map((e) => '${e.key}: ${e.value}\r\n').join()}'
        '\r\n',
      );
      expect(
        response,
        startsWith('HTTP/1.1 $status '),
        reason: '$method $target $headers',
      );
      expect(response, isNot(contains('secret')));
    }
    expect(hits, 0);
  });

  for (final status in [301, 302, 303, 307, 308]) {
    test(
      'rejects $status redirects, including same-origin, without fetching',
      () async {
        var hits = 0;
        final errors = <Object>[];
        final upstream = await server((request) {
          hits++;
          request.response
            ..statusCode = status
            ..headers.set('location', '/private/redirect?token=other-secret')
            ..write('private error body: url-secret');
          unawaited(request.response.close());
        });
        final playback = await relay(
          source(upstream),
          onError: (e, s) {
            errors.add(e);
            expect(s.toString(), isEmpty);
          },
        );
        final response = await _fetch(playback.uri);
        expect(response.status, 502);
        expect(response.text, isEmpty);
        expect(response.headers['location'], isNull);
        expect(hits, 1);
        expect(errors, hasLength(1));
        expect(errors.single.toString(), isNot(contains('secret')));
        expect(errors.single.toString(), isNot(contains('/private')));
      },
    );
  }

  test(
    'cross-origin redirects never disclose credentials to the target',
    () async {
      var targetHits = 0;
      final target = await server((request) {
        targetHits++;
        unawaited(request.response.close());
      });
      final upstream = await server((request) {
        expect(request.headers.value('authorization'), 'Bearer fixed-secret');
        request.response
          ..statusCode = 302
          ..headers.set('location', source(target).toString());
        unawaited(request.response.close());
      });
      final playback = await relay(
        source(upstream),
        headers: {'Authorization': 'Bearer fixed-secret'},
      );
      expect((await _fetch(playback.uri)).status, 502);
      expect(targetHits, 0);
    },
  );

  test('upstream error statuses have no body or sensitive headers', () async {
    for (final status in [401, 403, 404, 416, 500, 503]) {
      final upstream = await server((request) {
        request.response
          ..statusCode = status
          ..headers.set('content-type', 'text/html')
          ..headers.set('content-range', 'bytes */10')
          ..headers.set('www-authenticate', 'secret')
          ..write('private URL and credentials');
        unawaited(request.response.close());
      });
      final playback = await relay(source(upstream));
      final result = await _fetch(playback.uri);
      expect(result.status, status);
      expect(result.text, isEmpty);
      expect(result.headers['www-authenticate'], isNull);
      expect(result.headers['content-range'], ['bytes */10']);
    }
  });

  test(
    'at most four upstream requests; close cancels all and is idempotent',
    () async {
      final held = <HttpRequest>[];
      final ready = Completer<void>();
      final upstream = await server((request) {
        held.add(request);
        if (held.length == 4) ready.complete();
      });
      final playback = await relay(source(upstream));
      final sockets = <Socket>[];
      for (var i = 0; i < 4; i++) {
        sockets.add(await _open(playback.uri));
      }
      addTearDown(() {
        for (final socket in sockets) {
          socket.destroy();
        }
      });
      await ready.future.timeout(const Duration(seconds: 2));
      expect((await _fetch(playback.uri)).status, 503);
      expect(held, hasLength(4));
      await playback.close().timeout(const Duration(seconds: 1));
      await playback.close();
      await expectLater(_fetch(playback.uri), throwsA(isA<SocketException>()));
      for (final socket in sockets) {
        expect(await socket.fold<int>(0, (n, bytes) => n + bytes.length), 0);
      }
    },
  );

  test(
    'disconnect during headers cancels promptly and permits reconnect',
    () async {
      final upstreamSockets = <Socket>[];
      final arrivals = StreamController<Socket>();
      addTearDown(arrivals.close);
      final upstream = await server((request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        upstreamSockets.add(socket);
        arrivals.add(socket);
      });
      addTearDown(() {
        for (final socket in upstreamSockets) {
          socket.destroy();
        }
      });
      final errors = <Object>[];
      final playback = await relay(
        source(upstream),
        onError: (e, _) => errors.add(e),
      );
      final iterator = StreamIterator(arrivals.stream);
      addTearDown(iterator.cancel);
      for (var i = 0; i < 8; i++) {
        final downstream = await _open(playback.uri);
        await iterator.moveNext().timeout(const Duration(seconds: 1));
        final disconnected = iterator.current.drain<void>();
        downstream.destroy();
        await disconnected.timeout(const Duration(seconds: 1));
      }
      expect(errors, isEmpty);
    },
  );

  test('header timeout returns a sanitized 502 and closes upstream', () async {
    final disconnected = Completer<void>();
    final upstream = await server((request) async {
      final socket = await request.response.detachSocket(writeHeaders: false);
      addTearDown(socket.destroy);
      await socket.drain<void>();
      disconnected.complete();
    });
    final errors = <Object>[];
    final playback = await relay(
      source(upstream),
      timeout: const Duration(milliseconds: 150),
      onError: (e, _) => errors.add(e),
    );
    final response = await _fetch(playback.uri);
    expect(response.status, 502);
    expect(response.text, isEmpty);
    await disconnected.future.timeout(const Duration(seconds: 1));
    expect(errors, hasLength(1));
  });

  test(
    'upstream idle timeout ends a started response without an error body',
    () async {
      final disconnected = Completer<void>();
      final upstream = await server((request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        addTearDown(socket.destroy);
        socket.write(
          'HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nConnection: close\r\n\r\nabc',
        );
        await socket.flush();
        await socket.drain<void>();
        disconnected.complete();
      });
      final errors = <Object>[];
      final playback = await relay(
        source(upstream),
        timeout: const Duration(milliseconds: 150),
        onError: (e, _) => errors.add(e),
      );
      final response = await _fetch(playback.uri);
      expect(response.status, 200);
      expect(response.text, 'abc');
      expect(errors, hasLength(1));
      await disconnected.future.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'streaming is incremental, not accumulated until upstream completion',
    () async {
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      final upstream = await server((request) async {
        request.response.headers.contentType = ContentType('audio', 'mpeg');
        request.response.bufferOutput = false;
        request.response.add([1, 2, 3]);
        await request.response.flush();
        await release.future;
        request.response.add([4, 5]);
        await request.response.close();
      });
      final playback = await relay(source(upstream));
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(playback.uri)).close();
      final iterator = StreamIterator(response);
      expect(
        await iterator.moveNext().timeout(const Duration(seconds: 1)),
        isTrue,
      );
      expect(iterator.current, [1, 2, 3]);
      release.complete();
      final rest = <int>[];
      while (await iterator.moveNext()) {
        rest.addAll(iterator.current);
      }
      expect(rest, [4, 5]);
    },
  );

  test('stalled downstream bounds buffering and cancels the upstream producer', () async {
    var produced = 0;
    final finished = Completer<void>();
    final chunk = Uint8List(64 * 1024);
    Stream<List<int>> audio() async* {
      while (true) {
        produced += chunk.length;
        yield chunk;
      }
    }

    final upstream = await server((request) async {
      try {
        await request.response.addStream(audio());
        await request.response.close();
      } on IOException {
        // The relay cancels the producer when the downstream stops reading.
      } finally {
        finished.complete();
      }
    });
    final errors = <Object>[];
    final playback = await relay(
      source(upstream),
      timeout: const Duration(milliseconds: 250),
      onError: (e, _) => errors.add(e),
    );
    final downstream = await _open(playback.uri); // Deliberately never listen.
    addTearDown(downstream.destroy);
    await finished.future.timeout(const Duration(seconds: 5));
    expect(produced, greaterThan(0));
    // OS socket buffers vary, but an infinite source must not be drained into
    // relay memory. This generous ceiling is still tiny relative to the source.
    expect(produced, lessThan(64 * 1024 * 1024));
    expect(errors, isEmpty); // Stalled downstream is a local cancellation.
  });

  test(
    'disconnect and close cancel active streaming, not just header waits',
    () async {
      final sockets = <Socket>[];
      final errors = <Object>[];
      final arrivals = StreamController<Socket>();
      addTearDown(arrivals.close);
      final upstream = await server((request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        sockets.add(socket);
        socket.write('HTTP/1.1 200 OK\r\nConnection: close\r\n\r\naudio');
        await socket.flush();
        arrivals.add(socket);
      });
      addTearDown(() {
        for (final socket in sockets) {
          socket.destroy();
        }
      });
      final playback = await relay(
        source(upstream),
        onError: (e, _) => errors.add(e),
      );
      final iterator = StreamIterator(arrivals.stream);
      addTearDown(iterator.cancel);
      for (final closeRelay in [false, true]) {
        final downstream = await _open(playback.uri);
        addTearDown(downstream.destroy);
        final data = Completer<void>();
        downstream.listen((bytes) {
          if (!data.isCompleted && ascii.decode(bytes).contains('audio')) {
            data.complete();
          }
        });
        await iterator.moveNext();
        final disconnected = iterator.current.drain<void>();
        await data.future.timeout(const Duration(seconds: 1));
        if (closeRelay) {
          await playback.close().timeout(const Duration(seconds: 1));
        } else {
          downstream.destroy();
        }
        await disconnected.timeout(const Duration(seconds: 1));
      }
      expect(errors, isEmpty);
    },
  );

  test(
    'TLS handshake timeout is bounded and returns no diagnostic details',
    () async {
      final upstream = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(upstream.close);
      final hello = Completer<void>();
      final disconnected = Completer<void>();
      upstream.listen((socket) {
        addTearDown(socket.destroy);
        socket.listen((_) {
          if (!hello.isCompleted) hello.complete();
        }, onDone: disconnected.complete);
      });
      final errors = <Object>[];
      final playback = await relay(
        Uri.parse('https://127.0.0.1:${upstream.port}/private?token=secret'),
        timeout: const Duration(milliseconds: 150),
        onError: (e, _) => errors.add(e),
      );
      final result = await _fetch(playback.uri)
          .timeout(const Duration(seconds: 2));
      await hello.future.timeout(const Duration(seconds: 1));
      await disconnected.future.timeout(const Duration(seconds: 1));
      expect(result.status, 502);
      expect(result.text, isEmpty);
      expect(errors, hasLength(1));
      expect(errors.single.toString(), isNot(contains('secret')));
    },
  );

  test(
    'close after ClientHello cancels a stalled TLS handshake socket',
    () async {
      final upstream = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(upstream.close);
      final hello = Completer<void>();
      final disconnected = Completer<void>();
      upstream.listen((socket) {
        addTearDown(socket.destroy);
        socket.listen((bytes) {
          if (!hello.isCompleted) hello.complete();
        }, onDone: disconnected.complete);
      });
      final playback = await relay(
        Uri.parse('https://127.0.0.1:${upstream.port}/secret'),
      );
      final downstream = await _open(playback.uri);
      addTearDown(downstream.destroy);
      await hello.future.timeout(const Duration(seconds: 1));
      await playback.close().timeout(const Duration(seconds: 1));
      await disconnected.future.timeout(const Duration(seconds: 1));
    },
  );

  test('close during connection startup cancels promptly', () async {
    final upstream = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(upstream.close);
    final arrived = Completer<Socket>();
    upstream.listen(arrived.complete);
    final playback = await relay(
      Uri.parse('https://127.0.0.1:${upstream.port}/secret'),
    );
    final downstream = await _open(playback.uri);
    addTearDown(downstream.destroy);
    final socket = await arrived.future.timeout(const Duration(seconds: 1));
    addTearDown(socket.destroy);
    final disconnected = socket.drain<void>();
    await playback.close().timeout(const Duration(seconds: 1));
    await disconnected.timeout(const Duration(seconds: 1));
  });

  test(
    'repeated stalled TLS seeks and timeouts release every transport',
    () async {
      final upstream = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(upstream.close);
      final arrivals = StreamController<(Future<void>, Future<void>)>();
      addTearDown(arrivals.close);
      var active = 0;
      upstream.listen((socket) {
        active++;
        final hello = Completer<void>();
        final disconnected = Completer<void>();
        arrivals.add((hello.future, disconnected.future));
        addTearDown(socket.destroy);
        socket.listen(
          (bytes) {
            if (!hello.isCompleted) hello.complete();
            expect(String.fromCharCodes(bytes), isNot(contains('TLS-secret')));
          },
          onDone: () {
            active--;
            disconnected.complete();
          },
        );
      });
      final playback = await relay(
        Uri.parse('https://127.0.0.1:${upstream.port}/TLS-secret'),
        headers: {'Authorization': 'Bearer TLS-secret'},
        timeout: const Duration(milliseconds: 150),
      );
      final iterator = StreamIterator(arrivals.stream);
      addTearDown(iterator.cancel);
      for (var i = 0; i < 12; i++) {
        final socket = await _open(playback.uri);
        addTearDown(socket.destroy);
        final response = socket.fold<List<int>>(
          [],
          (all, bytes) => all..addAll(bytes),
        );
        expect(
          await iterator.moveNext().timeout(const Duration(seconds: 1)),
          isTrue,
        );
        final (hello, disconnected) = iterator.current;
        await hello.timeout(const Duration(seconds: 1));
        if (i.isEven) socket.destroy();
        await disconnected.timeout(const Duration(seconds: 1));
        final bytes = await response.timeout(const Duration(seconds: 1));
        if (i.isOdd) expect(ascii.decode(bytes), startsWith('HTTP/1.1 502 '));
        expect(active, 0);
      }
    },
  );

  for (final scheme in ['http', 'https']) {
    for (final cancellation in ['close', 'disconnect', 'timeout']) {
      test('$cancellation cancels a pending $scheme connect task', () async {
        final rootZone = Zone.current;
        final started = Completer<void>();
        final cancelled = Completer<void>();
        final connecting = Completer<Socket>();
        final playback = await IOOverrides.runZoned(
          () => relay(
            Uri.parse('$scheme://pending.invalid/secret'),
            timeout: const Duration(milliseconds: 150),
          ),
          socketStartConnect:
              (host, port, {sourceAddress, sourcePort = 0}) async {
                if (host != 'pending.invalid') {
                  return rootZone.run(() => Socket.startConnect(host, port));
                }
                started.complete();
                return ConnectionTask.fromSocket(connecting.future, () {
                  if (!cancelled.isCompleted) {
                    cancelled.complete();
                    connecting.completeError(
                      const SocketException('cancelled'),
                    );
                  }
                });
              },
        );
        final downstream = await _open(playback.uri);
        addTearDown(downstream.destroy);
        final response = downstream.fold<List<int>>(
          [],
          (all, bytes) => all..addAll(bytes),
        );
        await started.future.timeout(const Duration(seconds: 1));
        if (cancellation == 'close') {
          await playback.close().timeout(const Duration(seconds: 1));
        }
        if (cancellation == 'disconnect') downstream.destroy();
        await cancelled.future.timeout(const Duration(seconds: 1));
        final bytes = await response.timeout(const Duration(seconds: 1));
        if (cancellation == 'timeout') {
          expect(ascii.decode(bytes), startsWith('HTTP/1.1 502 '));
        }
      });
    }
  }

  test(
    'close does not await a late connection task and destroys its late socket',
    () async {
      final started = Completer<void>();
      final lateTask = Completer<ConnectionTask<Socket>>();
      final playback = await IOOverrides.runZoned(
        () => relay(Uri.parse('http://pending.invalid/secret')),
        socketStartConnect: (host, port, {sourceAddress, sourcePort = 0}) {
          started.complete();
          return lateTask.future;
        },
      );
      final downstream = await _open(playback.uri);
      addTearDown(downstream.destroy);
      await started.future.timeout(const Duration(seconds: 1));
      await playback.close().timeout(const Duration(seconds: 1));
      final upstream = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(upstream.close);
      final disconnected = Completer<void>();
      upstream.listen((socket) {
        addTearDown(socket.destroy);
        socket.listen((_) {}, onDone: disconnected.complete);
      });
      final lateSocket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        upstream.port,
      );
      addTearDown(lateSocket.destroy);
      final cancelled = Completer<void>();
      lateTask.complete(
        ConnectionTask.fromSocket(Future.value(lateSocket), cancelled.complete),
      );
      await cancelled.future.timeout(const Duration(seconds: 1));
      await disconnected.future.timeout(const Duration(seconds: 1));
    },
  );

  test('idle and partial-header local sockets have a hard admission cap and deadline', () async {
    var hits = 0;
    final upstream = await server((request) {
      hits++;
      request.response.write('audio');
      unawaited(request.response.close());
    });
    final playback = await relay(
      source(upstream),
      timeout: const Duration(milliseconds: 500),
    );
    final readers = <Future<void>>[];
    var sharedPort = 0;
    for (var i = 0; i < 16; i++) {
      // Linux supports the full 127/8 loopback range. Reuse one source port
      // across distinct addresses to verify slots are keyed by both fields.
      final socket = await Socket.connect(
        playback.uri.host,
        playback.uri.port,
        sourceAddress: Platform.isLinux ? '127.0.0.${i + 1}' : null,
        sourcePort: Platform.isLinux ? sharedPort : 0,
      );
      sharedPort = socket.port;
      addTearDown(socket.destroy);
      if (i.isOdd) {
        socket.write('GET ${playback.uri.path} HTTP/1.1\r\nHost:');
        await socket.flush();
      }
      readers.add(socket.drain<void>());
    }
    // The seventeenth socket is dropped without waiting for the header timer.
    final excess = await Socket.connect(playback.uri.host, playback.uri.port);
    addTearDown(excess.destroy);
    await excess.drain<void>().timeout(const Duration(milliseconds: 250));
    await Future.wait(readers).timeout(const Duration(seconds: 2));
    expect(hits, 0);
    expect((await _fetch(playback.uri)).text, 'audio');
    expect(hits, 1);
  });

  test(
    'rejection floods and malformed headers do not prevent subsequent playback',
    () async {
      final upstream = await server((request) {
        request.response.write('audio');
        unawaited(request.response.close());
      });
      final playback = await relay(
        source(upstream),
        timeout: const Duration(milliseconds: 250),
      );
      final closed = <Future<void>>[];
      for (var i = 0; i < 80; i++) {
        final socket = await Socket.connect(
          playback.uri.host,
          playback.uri.port,
        );
        addTearDown(socket.destroy);
        closed.add(socket.drain<void>().catchError((Object _) {}));
        unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
        socket.write(
          i.isEven
              ? 'GET /wrong HTTP/1.1\r\nHost: ${playback.uri.authority}\r\n\r\n'
              : 'not an HTTP request\r\n\r\n',
        );
      }
      await Future.wait(closed).timeout(const Duration(seconds: 2));
      // Malformed requests may close without being emitted to the handler;
      // their admission slots also have the absolute header deadline.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect((await _fetch(playback.uri)).text, 'audio');
    },
  );

  test(
    'server stream failures are sanitized and close the relay at the boundary',
    () async {
      final rootZone = Zone.current;
      late _FaultServerSocket listener;
      final errors = <Object>[];
      final playback = await IOOverrides.runZoned(
        () => relay(
          Uri.parse('http://unused.invalid/secret'),
          onError: (error, stack) {
            errors.add(error);
            expect(stack.toString(), isEmpty);
          },
        ),
        serverSocketBind:
            (host, port, {backlog = 0, v6Only = false, shared = false}) async {
              // Run the real bind outside this override to avoid recursion.
              final socket = await rootZone.run(
                () => ServerSocket.bind(host, port, backlog: backlog),
              );
              return listener = _FaultServerSocket(socket);
            },
      );
      final idle = await Socket.connect(playback.uri.host, playback.uri.port);
      addTearDown(idle.destroy);
      listener.errors.addError(
        const SocketException('private-host credentials-secret'),
      );
      await idle.drain<void>().timeout(const Duration(seconds: 1));
      await playback.close().timeout(const Duration(seconds: 1));
      expect(errors, hasLength(1));
      expect(errors.single.toString(), isNot(contains('secret')));
      await expectLater(_fetch(playback.uri), throwsA(isA<SocketException>()));
    },
  );

  for (final failure in ['diagnostic callback', 'client factory']) {
    test('$failure programming errors escape the request boundary', () async {
      final upstream = await server((request) {
        request.response.statusCode = 302;
        unawaited(request.response.close());
      });
      final unexpected = StateError('unexpected $failure failure');
      final escaped = Completer<Object>();
      final ready = Completer<PlaybackRelay>();
      runZonedGuarded(() async {
        ready.complete(
          await PlaybackRelay.start(
            source(upstream),
            createClient: failure == 'client factory'
                ? () => throw unexpected
                : null,
            onError: (_, _) => throw unexpected,
          ),
        );
      }, (error, _) => escaped.complete(error));
      final playback = await ready.future;
      addTearDown(playback.close);
      // No synthetic 502 should disguise an unexpected implementation error.
      await expectLater(_fetch(playback.uri), throwsA(isA<HttpException>()));
      expect(
        await escaped.future.timeout(const Duration(seconds: 1)),
        same(unexpected),
      );
      await playback.close().timeout(const Duration(seconds: 1));
    });
  }

  test(
    'server diagnostic callback failure escapes but still closes sockets',
    () async {
      final rootZone = Zone.current;
      late _FaultServerSocket listener;
      final unexpected = StateError('unexpected diagnostic failure');
      final escaped = Completer<Object>();
      final ready = Completer<PlaybackRelay>();
      runZonedGuarded(() async {
        ready.complete(
          await IOOverrides.runZoned(
            () => PlaybackRelay.start(
              Uri.parse('http://unused.invalid/secret'),
              onError: (_, _) => throw unexpected,
            ),
            serverSocketBind:
                (
                  host,
                  port, {
                  backlog = 0,
                  v6Only = false,
                  shared = false,
                }) async {
                  final socket = await rootZone.run(
                    () => ServerSocket.bind(host, port, backlog: backlog),
                  );
                  return listener = _FaultServerSocket(socket);
                },
          ),
        );
      }, (error, _) => escaped.complete(error));
      final playback = await ready.future;
      addTearDown(playback.close);
      final idle = await Socket.connect(playback.uri.host, playback.uri.port);
      addTearDown(idle.destroy);
      listener.errors.addError(const SocketException('private secret'));
      expect(
        await escaped.future.timeout(const Duration(seconds: 1)),
        same(unexpected),
      );
      await idle.drain<void>().timeout(const Duration(seconds: 1));
      await playback.close().timeout(const Duration(seconds: 1));
      await expectLater(_fetch(playback.uri), throwsA(isA<SocketException>()));
    },
  );

  test(
    'private CONNECT bridge rejects foreign callers and bounds idle sockets',
    () async {
      final rootZone = Zone.current;
      final ports = <int>[];
      var upstreamHits = 0;
      final upstream = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(upstream.close);
      upstream.listen((socket) {
        upstreamHits++;
        socket.destroy();
      });
      final playback = await IOOverrides.runZoned(
        () => relay(Uri.parse('https://127.0.0.1:${upstream.port}/secret')),
        serverSocketBind:
            (host, port, {backlog = 0, v6Only = false, shared = false}) async {
              final socket = await rootZone.run(
                () => ServerSocket.bind(host, port, backlog: backlog),
              );
              ports.add(socket.port);
              return socket;
            },
      );
      expect(ports, hasLength(2));
      final proxy = Uri.parse('http://127.0.0.1:${ports.last}');
      expect(
        await _raw(
          proxy,
          'CONNECT 127.0.0.1:${upstream.port} HTTP/1.1\r\n\r\n',
        ),
        isEmpty,
      );
      final idle = <Future<void>>[];
      for (var i = 0; i < 4; i++) {
        final socket = await Socket.connect(proxy.host, proxy.port);
        addTearDown(socket.destroy);
        idle.add(socket.drain<void>());
      }
      final excess = await Socket.connect(proxy.host, proxy.port);
      addTearDown(excess.destroy);
      await excess.drain<void>().timeout(const Duration(milliseconds: 250));
      await playback.close().timeout(const Duration(seconds: 1));
      await Future.wait(idle).timeout(const Duration(seconds: 1));
      expect(upstreamHits, 0);
    },
  );

  group('real TLS (no badCertificateCallback)', () {
    late Directory certificates;
    late SecurityContext serverContext;
    late SecurityContext wrongNameContext;
    late SecurityContext trustedContext;

    setUpAll(() async {
      certificates = await Directory.systemTemp.createTemp('yun-relay-tls-');
      Future<void> openssl(List<String> args) async {
        final result = await Process.run(
          'openssl',
          args,
          workingDirectory: certificates.path,
        );
        if (result.exitCode != 0) {
          throw StateError('openssl failed: ${result.stderr}');
        }
      }

      await openssl([
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        'ca.key',
        '-out',
        'ca.pem',
        '-days',
        '2',
        '-subj',
        '/CN=Relay Test CA',
      ]);
      await openssl([
        'req',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        'server.key',
        '-out',
        'server.csr',
        '-subj',
        '/CN=localhost',
      ]);
      await File('${certificates.path}/extensions').writeAsString(
        'subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1\nextendedKeyUsage=serverAuth\n',
      );
      await openssl([
        'x509',
        '-req',
        '-in',
        'server.csr',
        '-CA',
        'ca.pem',
        '-CAkey',
        'ca.key',
        '-CAcreateserial',
        '-out',
        'server.pem',
        '-days',
        '2',
        '-extfile',
        'extensions',
      ]);
      serverContext = SecurityContext()
        ..useCertificateChain('${certificates.path}/server.pem')
        ..usePrivateKey('${certificates.path}/server.key');
      await File('${certificates.path}/extensions').writeAsString(
        'subjectAltName=DNS:wrong.invalid,IP:127.0.0.2\nextendedKeyUsage=serverAuth\n',
      );
      await openssl([
        'x509',
        '-req',
        '-in',
        'server.csr',
        '-CA',
        'ca.pem',
        '-CAkey',
        'ca.key',
        '-CAcreateserial',
        '-out',
        'wrong.pem',
        '-days',
        '2',
        '-extfile',
        'extensions',
      ]);
      wrongNameContext = SecurityContext()
        ..useCertificateChain('${certificates.path}/wrong.pem')
        ..usePrivateKey('${certificates.path}/server.key');
      trustedContext = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates('${certificates.path}/ca.pem');
    });
    tearDownAll(() async {
      await certificates.delete(recursive: true);
    });

    for (final framing in [
      'keep-alive',
      'connection-close',
      'close-delimited',
    ]) {
      for (final slow in [false, true]) {
        test(
          'TLS EOF drains $framing large body, slow consumer=$slow',
          () async {
            final audio = Uint8List.fromList(
              List.generate(8 * 1024 * 1024, (i) => i % 251),
            );
            Stream<List<int>> chunks() async* {
              for (var offset = 0; offset < audio.length; offset += 64 * 1024) {
                yield Uint8List.sublistView(audio, offset, offset + 64 * 1024);
              }
            }

            final upstream = await HttpServer.bindSecure(
              InternetAddress.loopbackIPv4,
              0,
              serverContext,
            );
            addTearDown(() => upstream.close(force: true));
            final produced = Completer<void>();
            upstream.listen((request) async {
              if (framing == 'close-delimited') {
                final socket = await request.response.detachSocket(
                  writeHeaders: false,
                );
                addTearDown(socket.destroy);
                socket.listen((_) {}, onDone: socket.destroy);
                socket.write('HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n');
                await socket.addStream(chunks());
                await socket.close();
              } else {
                request.response
                  ..persistentConnection = framing == 'keep-alive'
                  ..contentLength = audio.length;
                await request.response.addStream(chunks());
                await request.response.close();
              }
              produced.complete();
            });
            final errors = <Object>[];
            final playback = await relay(
              Uri.parse('https://localhost:${upstream.port}/audio'),
              createClient: () => HttpClient(context: trustedContext),
              onError: (error, _) => errors.add(error),
            );
            final client = HttpClient();
            addTearDown(() => client.close(force: true));
            final response = await (await client.getUrl(playback.uri)).close();
            expect(response.statusCode, 200);
            expect(
              response.contentLength,
              framing == 'close-delimited' ? -1 : audio.length,
            );
            final received = BytesBuilder(copy: false);
            await for (final chunk in response) {
              received.add(chunk);
              if (slow) {
                // Pause the HTTP/TCP subscription between chunks, allowing the
                // upstream FIN to race with buffered TLS and downstream bytes.
                await Future<void>.delayed(const Duration(milliseconds: 2));
              }
            }
            expect(received.length, audio.length);
            expect(received.takeBytes(), audio);
            await produced.future.timeout(const Duration(seconds: 2));
            expect(errors, isEmpty);
            await playback.close().timeout(const Duration(seconds: 1));
          },
        );
      }
    }

    test(
      'TLS bridge backpressure is bounded and its producer is cancelled',
      () async {
        var produced = 0;
        final finished = Completer<void>();
        final chunk = Uint8List(64 * 1024);
        Stream<List<int>> audio() async* {
          while (true) {
            produced += chunk.length;
            yield chunk;
          }
        }

        final upstream = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          serverContext,
        );
        addTearDown(() => upstream.close(force: true));
        upstream.listen((request) async {
          try {
            await request.response.addStream(audio());
            await request.response.close();
          } on IOException {
            // Downstream timeout destroys both sides of the TLS bridge.
          } finally {
            finished.complete();
          }
        });
        final playback = await relay(
          Uri.parse('https://localhost:${upstream.port}/audio'),
          createClient: () => HttpClient(context: trustedContext),
          timeout: const Duration(milliseconds: 250),
        );
        final downstream = await _open(playback.uri);
        addTearDown(downstream.destroy);
        await finished.future.timeout(const Duration(seconds: 5));
        expect(produced, greaterThan(0));
        expect(produced, lessThan(64 * 1024 * 1024));
        await playback.close().timeout(const Duration(seconds: 1));
      },
    );

    for (final (host, trusted, valid) in [
      ('localhost', true, true),
      ('127.0.0.1', true, true),
      ('localhost', true, false),
      ('127.0.0.1', true, false),
      ('127.0.0.1', false, false),
      ('[::1]', true, true),
      ('[::1]', true, false),
      ('[::1]', false, false),
    ]) {
      test(
        '$host trusted=$trusted valid=$valid, certificate checked before HTTP',
        () async {
          var hits = 0;
          final upstream = await HttpServer.bindSecure(
            host == '[::1]'
                ? InternetAddress.loopbackIPv6
                : InternetAddress.loopbackIPv4,
            0,
            trusted && !valid ? wrongNameContext : serverContext,
          );
          addTearDown(() => upstream.close(force: true));
          upstream.listen(
            (request) {
              hits++;
              expect(
                request.headers.value('authorization'),
                'Bearer TLS-secret',
              );
              request.response.write('audio');
              unawaited(request.response.close());
            },
            onError: (Object error) {
              expect(error, isA<HandshakeException>());
            },
          );
          final errors = <Object>[];
          final playback = await relay(
            Uri.parse(
              'https://$host:${upstream.port}/private?token=TLS-secret',
            ),
            headers: {'Authorization': 'Bearer TLS-secret'},
            createClient: trusted
                ? () => HttpClient(context: trustedContext)
                : null,
            onError: (e, _) => errors.add(e),
          );
          final response = await _fetch(playback.uri);
          expect(response.status, valid ? 200 : 502);
          expect(response.text, valid ? 'audio' : '');
          expect(hits, valid ? 1 : 0);
          expect(errors.length, valid ? 0 : 1);
          expect(errors.toString(), isNot(contains('TLS-secret')));
          expect(errors.toString(), isNot(contains('/private')));
        },
      );
    }
  });
}

class _FaultServerSocket extends Stream<Socket> implements ServerSocket {
  _FaultServerSocket(this.socket);
  final ServerSocket socket;
  final errors = StreamController<Socket>();

  @override
  InternetAddress get address => socket.address;
  @override
  int get port => socket.port;
  @override
  Future<ServerSocket> close() => socket.close();

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    socket.listen(errors.add, onError: errors.addError, onDone: errors.close);
    return errors.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

class _Reply {
  _Reply(this.status, this.headers, this.bytes);
  final int status;
  final Map<String, List<String>> headers;
  final List<int> bytes;
  String get text => utf8.decode(bytes);
}

Future<_Reply> _fetch(
  Uri uri, {
  String method = 'GET',
  Map<String, String> headers = const {},
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, uri);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    final response = await request.close();
    final copied = <String, List<String>>{};
    response.headers.forEach((name, values) => copied[name] = values);
    final bytes = await response.fold<List<int>>(
      [],
      (all, bytes) => all..addAll(bytes),
    );
    return _Reply(response.statusCode, copied, bytes);
  } finally {
    client.close(force: true);
  }
}

Future<Socket> _open(Uri uri) async {
  final socket = await Socket.connect(uri.host, uri.port);
  socket.write('GET ${uri.path} HTTP/1.1\r\nHost: ${uri.authority}\r\n\r\n');
  await socket.flush();
  return socket;
}

Future<String> _raw(Uri uri, String request) async {
  final socket = await Socket.connect(uri.host, uri.port);
  try {
    socket.write(request);
    await socket.flush();
    return await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 2));
  } finally {
    socket.destroy();
  }
}
