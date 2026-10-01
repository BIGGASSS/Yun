import 'dart:async';
import 'dart:io';
import 'dart:math';

/// A session-scoped capability for one fixed upstream media URL.
///
/// Only [uri] is passed to the player. Upstream URLs, credentials, redirects and
/// error bodies never appear in local HTTP responses. The default HttpClient
/// uses platform trust roots and normal certificate/hostname verification.
class PlaybackRelay {
  PlaybackRelay._(
    this._server,
    this._ingress,
    this._proxy,
    this._upstream,
    this._headers,
    this._createClient,
    this._onError,
    this._timeout,
    String token,
  ) : uri = Uri(
        scheme: 'http',
        host: InternetAddress.loopbackIPv4.address,
        port: _server.port,
        path: '/$token',
      );

  /// Creates a loopback-only relay. [createClient], when provided, must return
  /// a fresh client on each call (for example, with a test CA SecurityContext).
  /// It must not weaken certificate verification. Its proxy/connection factory
  /// settings are replaced so the relay owns every transport.
  ///
  /// At most four requests reach upstream. Local sockets (including idle and
  /// rejected clients) are capped at sixteen; excess connections are dropped.
  /// [timeout] bounds initial local headers and each connect, response-header,
  /// upstream-idle and downstream-write operation, not total playback time.
  /// [onError] receives a sanitized HttpException and an empty stack trace;
  /// upstream exceptions can contain credentials, so are never exposed.
  static Future<PlaybackRelay> start(
    Uri upstream, {
    Map<String, String>? headers,
    HttpClient Function()? createClient,
    void Function(Object, StackTrace)? onError,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (!{'http', 'https'}.contains(upstream.scheme) ||
        upstream.host.isEmpty ||
        timeout <= Duration.zero) {
      throw ArgumentError('Invalid playback relay configuration');
    }
    final fixedHeaders = Map<String, String>.unmodifiable(headers ?? {});
    final random = Random.secure();
    final token = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final ingress = await _Ingress.bind(16, timeout);
    _Ingress? proxy;
    try {
      if (upstream.scheme == 'https') {
        proxy = await _Ingress.bind(4, timeout);
      }
    } catch (_) {
      // Startup rollback only: release the first listener, then preserve the
      // original failure (including programming errors) for the caller.
      await ingress.close();
      rethrow;
    }
    final server = HttpServer.listenOn(ingress);
    server.serverHeader = null;
    server.idleTimeout = timeout;
    final relay = PlaybackRelay._(
      server,
      ingress,
      proxy,
      upstream,
      fixedHeaders,
      createClient ?? HttpClient.new,
      onError,
      timeout,
      token,
    );
    server.listen(relay._accept, onError: relay._serverFailed);
    proxy?.listen(relay._acceptTunnel, onError: relay._serverFailed);
    return relay;
  }

  final Uri uri;
  final HttpServer _server;
  final _Ingress _ingress;
  final _Ingress? _proxy;
  final Map<int, _Exchange> _tunnels = {};
  final Set<Future<void>> _tunnelHandlers = {};
  final Uri _upstream;
  final Map<String, String> _headers;
  final HttpClient Function() _createClient;
  final void Function(Object, StackTrace)? _onError;
  final Duration _timeout;
  final Set<_Exchange> _requests = {};
  int _active = 0;
  bool _closed = false;
  Future<void>? _closing;

  /// Force-closes clients and sockets, then waits for all handlers to exit.
  /// Safe to call repeatedly, including while requests are connecting.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    final handlers = _requests.toList();
    for (final exchange in handlers) {
      exchange.cancel();
    }
    await _ingress.close();
    await _proxy?.close();
    await _server.close(force: true);
    while (_requests.isNotEmpty || _tunnelHandlers.isNotEmpty) {
      await Future.wait([
        ..._requests.map((exchange) => exchange.done),
        ..._tunnelHandlers,
      ]);
    }
  }

  int? _reject(HttpRequest request) {
    if (_closed) return HttpStatus.serviceUnavailable;
    if (request.headers[HttpHeaders.hostHeader]?.length != 1 ||
        request.headers.value(HttpHeaders.hostHeader) != uri.authority ||
        request.uri.toString() != uri.path) {
      return HttpStatus.notFound;
    }
    var browser = false;
    request.headers.forEach((name, _) {
      if (name == 'origin' ||
          name == 'referer' ||
          name.startsWith('sec-fetch-')) {
        browser = true;
      }
    });
    if (browser) return HttpStatus.forbidden;
    if (request.method != 'GET' && request.method != 'HEAD') {
      return HttpStatus.methodNotAllowed;
    }
    if (request.contentLength > 0 ||
        request.headers[HttpHeaders.transferEncodingHeader] != null) {
      return HttpStatus.badRequest;
    }
    return null;
  }

  void _accept(HttpRequest request) {
    // Claim exactly once, before starting any asynchronous handler. The raw
    // listener bounds idle/partial-header sockets and rejection handlers too.
    final inbound = _ingress.claim(request);
    if (inbound == null) return;
    if (_requests.length >= 16) {
      inbound.close();
      return;
    }
    var rejection = _reject(request);
    if (rejection == null && _active >= 4) {
      rejection = HttpStatus.serviceUnavailable;
    }
    final admitted = rejection == null;
    if (admitted) _active++;
    final exchange = _Exchange()..inbound = inbound;
    _requests.add(exchange);
    exchange.done = _serve(request, exchange, rejection).whenComplete(() {
      _tunnels.removeWhere((_, value) => identical(value, exchange));
      _requests.remove(exchange);
      if (admitted) _active--;
    });
  }

  void _report() {
    _onError?.call(
      const HttpException('Playback relay upstream request failed'),
      StackTrace.empty,
    );
  }

  void _serverFailed(Object error, StackTrace stack) {
    if (_closed) return;
    try {
      // Listener I/O failures cannot be returned on a particular request.
      // Sanitize diagnostics and close the relay; unexpected errors still
      // escape to the zone, as do failures in the diagnostic callback.
      if (error is! IOException) Error.throwWithStackTrace(error, stack);
      _report();
    } finally {
      unawaited(close());
    }
  }

  // Dart's direct connectionFactory result is NOT automatically TLS-wrapped.
  // Also SecureSocket.secure detaches the input Socket's RawSocket, after which
  // destroying that input Socket does nothing (SDK socket_patch.dart).
  // A private CONNECT bridge lets HttpClient perform TLS with its own context
  // and hostname checks, while we retain the *opposite* plain TCP endpoint.
  // The bridge forwards TLS records without decrypting application data.
  Future<ConnectionTask<Socket>> _connect(_Exchange exchange) async {
    final proxy = _proxy;
    final task = exchange.connect(
      proxy == null ? _upstream.host : InternetAddress.loopbackIPv4,
      proxy == null ? _upstream.port : proxy.port,
    );
    final socket = task.socket.then((socket) {
      if (exchange.cancelled) {
        socket.destroy();
        throw const _Cancelled();
      }
      if (proxy != null) _tunnels[socket.port] = exchange;
      return socket;
    });
    return ConnectionTask.fromSocket(socket, exchange.cancelUpstream);
  }

  void _acceptTunnel(Socket peer) {
    if (_closed || _tunnelHandlers.length >= 4) {
      peer.destroy();
      return;
    }
    late Future<void> handler;
    handler = _tunnel(peer).whenComplete(() => _tunnelHandlers.remove(handler));
    _tunnelHandlers.add(handler);
  }

  Future<void> _tunnel(Socket peer) async {
    final input = StreamIterator(peer);
    _Exchange? exchange;
    _Inbound? inbound;
    try {
      // Keep the ingress header deadline until the complete CONNECT arrives.
      // HttpServer cannot parse an IP-literal CONNECT authority as a Uri, so
      // recognize only the exact request line generated by our HttpClient.
      var head = '';
      while (!head.endsWith('\r\n\r\n')) {
        if (!await input.moveNext()) return;
        if (head.length + input.current.length > 8192) return;
        head += String.fromCharCodes(input.current);
      }
      // HttpClient writes "$host:$port" for CONNECT, including unbracketed
      // IPv6 literals. Match its fixed destination exactly; this is not an
      // externally supplied proxy target to parse or resolve.
      final authority = '${_upstream.host}:${_upstream.port}';
      if (!head.startsWith('CONNECT $authority HTTP/1.1\r\n')) return;
      if (peer.remoteAddress.address != InternetAddress.loopbackIPv4.address) {
        return;
      }
      exchange = _tunnels.remove(peer.remotePort);
      if (exchange == null ||
          exchange.cancelled ||
          exchange.upstreamCancelled) {
        return;
      }
      // Only a socket opened by this exchange's factory can select the fixed
      // destination. An arbitrary local caller cannot use this as a proxy.
      inbound = _proxy!.claimSocket(peer);
      if (inbound == null) return;
      exchange.tunnelInbound = inbound;
      exchange.tunnelPeer = peer;
      final task = exchange.connect(_upstream.host, _upstream.port);
      final upstream = await task.socket;
      if (exchange.cancelled || exchange.upstreamCancelled) return;
      peer.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      await peer.flush();
      Stream<List<int>> remaining() async* {
        while (await input.moveNext()) {
          yield input.current;
        }
      }

      // EOF is not cancellation: drain queued TLS records and half-close only
      // that direction. Destroying the bridge on upstream EOF truncates valid
      // Connection: close responses before HttpClient can decrypt their tail.
      // addStream preserves backpressure. The exchange's operation deadlines,
      // downstream disconnect and relay close still force-cancel both pipes.
      Future<void> pipe(Stream<List<int>> source, Socket destination) async {
        try {
          await destination.addStream(source);
          await destination.flush();
          await destination.close();
        } catch (_) {
          // Cleanup and rethrow, never swallow: a failed pipe cannot drain.
          // Abort its sibling rather than hanging in Future.wait. The outer
          // boundary handles only I/O errors; programming errors escape.
          exchange!.cancelUpstream();
          rethrow;
        }
      }

      await Future.wait([pipe(remaining(), upstream), pipe(upstream, peer)]);
    } on _Cancelled {
      // A connect task was explicitly stopped by seek/stop, timeout or close.
    } on IOException {
      // A transport failure invalidates this opaque tunnel. Closing it makes
      // HttpClient fail; _serve emits a sanitized 502 only before local headers.
      exchange?.cancelUpstream();
    } finally {
      peer.destroy();
      inbound?.close();
      await input.cancel();
    }
  }

  Future<void> _serve(
    HttpRequest local,
    _Exchange exchange,
    int? rejection,
  ) async {
    StreamSubscription<List<int>>? incoming;
    StreamIterator<List<int>>? body;
    var sentHeaders = false;
    try {
      // Detach so peer EOF is observable even while awaiting upstream headers.
      // HttpResponse.done alone does not reliably detect that case. We use
      // close-delimited HTTP, not chunking, and never reuse the local socket.
      final socket = await exchange.wait(
        local.response.detachSocket(writeHeaders: false).then((socket) {
          if (exchange.cancelled) socket.destroy();
          return socket;
        }),
        _timeout,
      );
      exchange.socket = socket;
      unawaited(
        socket.done.then<void>(
          (_) {},
          onError: (Object error) {
            exchange.cancel();
          },
        ),
      );
      if (exchange.cancelled || _closed) throw const _Cancelled();
      incoming = socket.listen(
        (_) => exchange.cancel(), // No request bodies or pipelined requests.
        onDone: exchange.cancel,
        onError: (Object error) => exchange.cancel(),
      );
      if (rejection != null) {
        await _write(exchange, _responseHead(rejection));
        await _finish(exchange);
        return;
      }
      final client = _createClient();
      exchange.client = client;
      client.connectionTimeout = _timeout;
      client.autoUncompress = false;
      client.findProxy = (_) =>
          _proxy == null ? 'DIRECT' : 'PROXY 127.0.0.1:${_proxy.port}';
      client.connectionFactory = (_, _, _) => _connect(exchange);
      final request = await exchange.wait(
        client.openUrl(local.method, _upstream).then((request) {
          if (exchange.cancelled) request.abort();
          return request;
        }),
        _timeout,
      );
      request.followRedirects = false;
      request.maxRedirects = 0;
      _headers.forEach(request.headers.set);
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      for (final name in ['range', 'if-range']) {
        final values = local.headers[name];
        if (values != null) request.headers.set(name, values);
      }
      final upstream = await exchange.wait(request.close(), _timeout);
      final status = upstream.statusCode;
      body = StreamIterator(upstream);
      if (status < 200 || (status >= 300 && status < 400) || status > 599) {
        throw const HttpException('Invalid upstream status');
      }
      if (status >= 400) {
        // Preserve useful statuses (notably 416), but never upstream error
        // bodies, authentication challenges, cookies or redirect locations.
        final range = upstream.headers.value('content-range');
        await _write(
          exchange,
          _responseHead(status, headers: {'content-range': ?range}),
        );
        await _finish(exchange);
        return;
      }
      final headers = <String, String>{};
      for (final name in _responseHeaders) {
        final values = upstream.headers[name];
        if (values != null) headers[name] = values.join(', ');
      }
      sentHeaders = true;
      await _write(
        exchange,
        _responseHead(status, headers: headers, empty: false),
      );
      if (local.method != 'HEAD') {
        // One upstream chunk at a time. Waiting for flush propagates socket
        // backpressure instead of building an unbounded in-memory queue.
        while (await exchange.wait(body.moveNext(), _timeout)) {
          await _write(exchange, body.current);
        }
      }
      await _finish(exchange);
    } on _Cancelled {
      // A player seek/stop or relay close is not an upstream failure.
    } on IOException {
      // Network/TLS/HTTP failures are expected at this request boundary. Never
      // expose their potentially credential-bearing messages or error bodies.
      await _failed(exchange, sentHeaders);
    } on TimeoutException {
      // An upstream connect/header/idle deadline has the same safe response:
      // 502 before headers, otherwise EOF. Programming errors are not caught.
      await _failed(exchange, sentHeaders);
    } finally {
      exchange.cancel();
      await body?.cancel();
      await incoming?.cancel();
    }
  }

  static const _responseHeaders = [
    'content-type',
    'content-length',
    'content-range',
    'content-encoding',
    'accept-ranges',
    'etag',
    'last-modified',
  ];

  List<int> _responseHead(
    int status, {
    Map<String, String> headers = const {},
    bool empty = true,
  }) {
    final head = StringBuffer('HTTP/1.1 $status Relay\r\n')
      ..write('connection: close\r\ncache-control: no-store\r\n')
      ..write('x-content-type-options: nosniff\r\n');
    headers.forEach((name, value) {
      // Defensive even though HttpClient already parses HTTP headers.
      if (!value.contains('\r') && !value.contains('\n')) {
        head.write('$name: $value\r\n');
      }
    });
    if (empty) head.write('content-length: 0\r\n');
    head.write('\r\n');
    return head.toString().codeUnits;
  }

  Future<void> _write(_Exchange exchange, List<int> bytes) async {
    try {
      if (exchange.cancelled) throw const _Cancelled();
      exchange.socket!.add(bytes);
      await exchange.wait(exchange.socket!.flush(), _timeout);
    } on IOException {
      exchange.cancel();
      throw const _Cancelled();
    } on TimeoutException {
      exchange.cancel();
      throw const _Cancelled();
    }
  }

  Future<void> _finish(_Exchange exchange) async {
    try {
      if (exchange.cancelled) throw const _Cancelled();
      // Unlike destroy(), close() drains the write sink before sending FIN.
      // Keep the read subscription and deadline live during this final drain
      // so a stalled/disconnected player or relay close can still cancel it.
      await exchange.wait(exchange.socket!.close(), _timeout);
    } on IOException {
      exchange.cancel();
      throw const _Cancelled();
    } on TimeoutException {
      exchange.cancel();
      throw const _Cancelled();
    }
  }

  Future<void> _failed(_Exchange exchange, bool sentHeaders) async {
    if (exchange.cancelled) return;
    exchange.cancelUpstream();
    _report();
    if (exchange.socket != null) {
      try {
        if (!sentHeaders) {
          await _write(exchange, _responseHead(HttpStatus.badGateway));
        }
        await _finish(exchange);
      } on _Cancelled {
        // The downstream disappeared while the failure was being returned.
      }
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

class _Exchange {
  Socket? socket;
  HttpClient? client;
  _Inbound? inbound;
  _Inbound? tunnelInbound;
  Socket? tunnelPeer;
  // At most two TCP tasks/sockets per exchange (proxy client + upstream).
  // These are cleared at cancellation, never kept in a session-long list.
  final Set<ConnectionTask<Socket>> _connecting = {};
  final Set<Socket> _sockets = {};
  bool upstreamCancelled = false;
  int _connectionsStarted = 0;
  late Future<void> done;
  bool cancelled = false;
  void Function()? _cancelWait;

  Future<T> wait<T>(Future<T> operation, Duration timeout) async {
    final result = Completer<T>();
    void fail(Object error, [StackTrace? stack]) {
      if (!result.isCompleted) result.completeError(error, stack);
    }

    // Only the current operation has a cancellation listener. Attaching a new
    // listener to a session-long Future for each chunk would leak memory.
    _cancelWait = () => fail(const _Cancelled());
    final timer = Timer(timeout, () => fail(TimeoutException('Relay timeout')));
    unawaited(
      operation.then<void>((value) {
        if (!result.isCompleted) result.complete(value);
      }, onError: fail),
    );
    if (cancelled) _cancelWait!();
    try {
      return await result.future;
    } finally {
      timer.cancel();
      _cancelWait = null;
    }
  }

  ConnectionTask<Socket> connect(Object host, int port) {
    if (cancelled || upstreamCancelled) throw const _Cancelled();
    if (++_connectionsStarted > 2) {
      throw const HttpException('Relay connection limit');
    }
    final result = Completer<Socket>();
    ConnectionTask<Socket>? pending;
    late ConnectionTask<Socket> tracked;
    var stopped = false;
    void fail(Object error, [StackTrace? stack]) {
      _connecting.remove(tracked);
      if (!result.isCompleted) result.completeError(error, stack);
    }

    tracked = ConnectionTask.fromSocket(result.future, () {
      stopped = true;
      pending?.cancel();
      fail(const _Cancelled());
    });
    _connecting.add(tracked);
    // Return a cancellable task immediately, even if startConnect itself has
    // not delivered its task yet. Late tasks are cancelled and late sockets
    // destroyed. SDK task.cancel cancels the lookup subscription and pending
    // connects; it cannot abort an OS resolver call already in progress.
    unawaited(
      Future.sync(() => Socket.startConnect(host, port)).then<void>((task) {
        pending = task;
        unawaited(
          task.socket.then<void>((socket) {
            _connecting.remove(tracked);
            if (stopped || cancelled || upstreamCancelled) {
              socket.destroy();
            } else {
              _sockets.add(socket);
              result.complete(socket);
            }
          }, onError: fail),
        );
        if (stopped || cancelled || upstreamCancelled) task.cancel();
      }, onError: fail),
    );
    return tracked;
  }

  void cancelUpstream() {
    if (upstreamCancelled) return;
    upstreamCancelled = true;
    for (final task in _connecting.toList()) {
      task.cancel();
    }
    _connecting.clear();
    for (final socket in _sockets) {
      socket.destroy();
    }
    _sockets.clear();
    tunnelPeer?.destroy();
    tunnelInbound?.close();
    client?.close(force: true);
  }

  void cancel() {
    cancelled = true;
    _cancelWait?.call();
    cancelUpstream();
    socket?.destroy();
    inbound?.close();
  }
}

/// Caps accepted sockets *before* HTTP parsing, including idle clients and
/// clients that never finish a header. Excess sockets are destroyed without
/// creating asynchronous rejection handlers. We keep no pending-admission
/// queue; the listening socket's OS backlog is also finite.
class _Ingress extends Stream<Socket> implements ServerSocket {
  _Ingress(this._server, this._limit, this._timeout);

  static Future<_Ingress> bind(int limit, Duration timeout) async => _Ingress(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0, backlog: limit),
    limit,
    timeout,
  );

  final ServerSocket _server;
  final int _limit;
  final Duration _timeout;
  final Map<(String, int), _Inbound> _sockets = {};
  Future<ServerSocket>? _closing;

  @override
  InternetAddress get address => _server.address;
  @override
  int get port => _server.port;

  _Inbound? claim(HttpRequest request) {
    final info = request.connectionInfo;
    return info == null
        ? null
        : _claim((info.remoteAddress.address, info.remotePort));
  }

  _Inbound? claimSocket(Socket socket) =>
      _claim((socket.remoteAddress.address, socket.remotePort));

  _Inbound? _claim((String, int) key) {
    final inbound = _sockets[key];
    if (inbound == null) return null;
    if (inbound.claimed) {
      inbound.close(); // No pipelining or reuse.
      return null;
    }
    inbound.claimed = true;
    inbound.timer?.cancel();
    return inbound;
  }

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _server.listen(
    (socket) {
      if (_closing != null || _sockets.length >= _limit) {
        socket.destroy();
        return;
      }
      // Source ports alone are not unique: distinct loopback addresses can
      // connect using the same port. Never overwrite a still-owned endpoint.
      final key = (socket.remoteAddress.address, socket.remotePort);
      if (_sockets.containsKey(key)) {
        socket.destroy();
        return;
      }
      final inbound = _Inbound(socket, () => _sockets.remove(key));
      _sockets[key] = inbound;
      inbound.timer = Timer(_timeout, inbound.close);
      unawaited(
        socket.done.then<void>((_) {
          if (!inbound.claimed) inbound.close();
        }, onError: (Object error) => inbound.close()),
      );
      onData?.call(socket);
    },
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  Future<ServerSocket> close() {
    for (final inbound in _sockets.values.toList()) {
      inbound.close();
    }
    return _closing ??= _server.close();
  }
}

class _Inbound {
  _Inbound(this.socket, this._release);
  final Socket socket;
  final void Function() _release;
  Timer? timer;
  bool claimed = false;
  bool _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    timer?.cancel();
    socket.destroy();
    _release();
  }
}
