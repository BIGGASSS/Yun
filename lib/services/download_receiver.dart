import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'download_buffer.dart';

/// A snapshot of one authenticated request, never an API client or token store.
class DownloadReceiveRequest {
  const DownloadReceiveRequest({
    required this.url,
    required this.path,
    required this.sha256,
    required this.offset,
    required this.sizeBytes,
    required this.headers,
    this.connectTimeout = const Duration(seconds: 15),
    this.sendTimeout = const Duration(seconds: 60),
    this.receiveTimeout = const Duration(seconds: 60),
  });

  final String url, path, sha256;
  final int offset, sizeBytes;
  final Map<String, String> headers;
  final Duration? connectTimeout, sendTimeout, receiveTimeout;

  Map<String, Object?> _toMessage() => {
    'url': url,
    'path': path,
    'sha256': sha256,
    'offset': offset,
    'sizeBytes': sizeBytes,
    'headers': Map<String, String>.of(headers),
    'connectTimeout': connectTimeout?.inMicroseconds,
    'sendTimeout': sendTimeout?.inMicroseconds,
    'receiveTimeout': receiveTimeout?.inMicroseconds,
  };

  factory DownloadReceiveRequest._fromMessage(Map<dynamic, dynamic> message) {
    Duration? duration(String key) => message[key] == null
        ? null
        : Duration(microseconds: message[key] as int);
    return DownloadReceiveRequest(
      url: message['url'] as String,
      path: message['path'] as String,
      sha256: message['sha256'] as String,
      offset: message['offset'] as int,
      sizeBytes: message['sizeBytes'] as int,
      headers: Map<String, String>.from(message['headers'] as Map),
      connectTimeout: duration('connectTimeout'),
      sendTimeout: duration('sendTimeout'),
      receiveTimeout: duration('receiveTimeout'),
    );
  }
}

class DownloadReceiveException implements Exception {
  const DownloadReceiveException(
    this.message, {
    this.statusCode,
    this.transportType,
    this.cancelled = false,
  });

  final String message;
  final int? statusCode;
  // Preserve background/offline classification without copying Dio's request
  // options (and their credentials) across the isolate boundary.
  final DioExceptionType? transportType;
  final bool cancelled;

  @override
  String toString() => message;
}

abstract class DownloadReceiver {
  Future<void> receive(
    DownloadReceiveRequest request, {
    required CancelToken cancelToken,
    required void Function(int receivedBytes) onProgress,
  });

  Future<void> close();
}

typedef _Request = Future<Response<dynamic>> Function(
  DownloadReceiveRequest request,
  CancelToken cancelToken,
);

const _cancelled = DownloadReceiveException(
  'Download cancelled',
  cancelled: true,
);

void _checkCancelled(CancelToken token) {
  if (token.isCancelled) throw _cancelled;
}

/// Drop the callback when finished: a long-lived caller token must not retain
/// the file, worker, response, or progress callback of a completed download.
class _CancellationLink {
  _CancellationLink(CancelToken source, this.callback) {
    if (source.isCancelled) {
      callback?.call();
    } else {
      unawaited(source.whenCancel.then((_) => callback?.call()));
    }
  }

  void Function()? callback;
  void dispose() => callback = null;
}

DownloadReceiveException _sanitize(Object error) {
  if (error is DownloadReceiveException) return error;
  if (error is DioException) {
    final status = error.response?.statusCode;
    return DownloadReceiveException(
      status == null
          ? 'Download connection failed'
          : 'Unexpected download status $status',
      statusCode: status,
      transportType: error.type,
    );
  }
  if (error is FileSystemException) {
    return const DownloadReceiveException('Could not write downloaded audio');
  }
  // Exception strings can include URLs, Authorization headers and credentials.
  return const DownloadReceiveException('Download reception failed');
}

/// StreamIterator.cancel also releases a pending moveNext on a stalled custom
/// stream. Keep one cancellation listener per job, not one per network chunk.
class _BodyReader {
  _BodyReader(ResponseBody body)
    : _stream = body.stream,
      iterator = StreamIterator(body.stream);

  final Stream<Uint8List> _stream;
  final StreamIterator<Uint8List> iterator;
  Future<void>? _closing;
  bool _started = false;

  Future<bool> moveNext() {
    _started = true;
    return iterator.moveNext();
  }

  Future<void> close() => _closing ??=
      (_started
              ? iterator.cancel()
              // StreamIterator is lazy: cancelling before the first moveNext
              // does not subscribe, and would leave the unread body alive.
              : _stream.listen((_) {}, onError: (Object _) {}).cancel())
          .catchError((Object _) {
            // Cleanup is best effort; preserve the transport/file error.
          });
}

Future<void> _closeUnreadBody(Response<dynamic> response) async {
  final body = response.data;
  if (body is ResponseBody) await _BodyReader(body).close();
}

Future<void> _receiveToFile(
  DownloadReceiveRequest input,
  _Request request,
  CancelToken caller,
  void Function(int) onProgress,
) async {
  final bodyToken = CancelToken();
  _BodyReader? reader;
  Response<dynamic>? response;
  final link = _CancellationLink(caller, () {
    bodyToken.cancel();
    final current = reader;
    if (current != null) unawaited(current.close());
  });
  try {
    _checkCancelled(caller);
    if (input.offset < 0 || input.sizeBytes < input.offset) {
      throw const DownloadReceiveException('Invalid download offset');
    }
    // Race headers too: injected callbacks need not implement Dio cancellation.
    final pending = request(input, bodyToken).then((value) {
      if (bodyToken.isCancelled) {
        unawaited(_closeUnreadBody(value));
        throw _cancelled;
      }
      return value;
    });
    response = await Future.any<Response<dynamic>>([
      pending,
      caller.whenCancel.then<Response<dynamic>>((_) => throw _cancelled),
    ]);
    _checkCancelled(caller);
    if (response.statusCode != 200 && response.statusCode != 206) {
      // Error pages can have their own ETags. Check status before audio identity
      // so a 401 always reaches the root's bounded authentication retry.
      throw DownloadReceiveException(
        'Unexpected download status ${response.statusCode}',
        statusCode: response.statusCode,
        transportType: DioExceptionType.badResponse,
      );
    }
    final etag = response.headers.value('etag');
    if (etag != null && etag != '"${input.sha256}"') {
      throw const DownloadReceiveException(
        'Audio checksum identity changed; refresh library',
      );
    }
    var offset = input.offset;
    if (response.statusCode == 206) {
      final range = response.headers.value('content-range');
      if (range == null || !range.startsWith('bytes $offset-')) {
        throw const DownloadReceiveException('Invalid resume response');
      }
    } else {
      offset = 0;
    }
    onProgress(offset);
    _checkCancelled(caller);
    final body = response.data;
    if (body is! ResponseBody) {
      throw const DownloadReceiveException('Invalid download response');
    }
    reader = _BodyReader(body);
    final output = await File(input.path)
        .open(mode: offset > 0 ? FileMode.append : FileMode.write);
    try {
      _checkCancelled(caller);
      final writer = BufferedDownloadWriter(
        write: (bytes, length) async {
          _checkCancelled(caller);
          await output.writeFrom(bytes, 0, length);
          _checkCancelled(caller);
        },
      );
      try {
        while (await reader.moveNext()) {
          _checkCancelled(caller);
          final chunk = reader.iterator.current;
          if (chunk.length > input.sizeBytes - offset) {
            // Do not accept even the apparently valid prefix of this chunk.
            bodyToken.cancel();
            throw const DownloadReceiveException(
              'Downloaded audio exceeds expected size',
            );
          }
          await writer.add(chunk);
          _checkCancelled(caller);
          offset += chunk.length;
          onProgress(offset);
        }
      } catch (_) {
        bodyToken.cancel();
        // Internal transport abort is NOT user cancellation. Preserve accepted
        // bytes on failure, but never drain the buffered tail after user stop.
        _checkCancelled(caller);
        await writer.flush();
        _checkCancelled(caller);
        rethrow;
      }
      _checkCancelled(caller);
      await writer.flush();
      _checkCancelled(caller);
      await output.flush();
      _checkCancelled(caller);
    } finally {
      await output.close();
    }
    _checkCancelled(caller);
  } catch (error) {
    if (caller.isCancelled) throw _cancelled;
    throw _sanitize(error);
  } finally {
    link.dispose();
    bodyToken.cancel();
    if (reader != null) {
      await reader.close();
    } else if (response != null) {
      await _closeUnreadBody(response);
    }
  }
}

class _ReceiveJob {
  _ReceiveJob(this.id, CancelToken caller, this.onProgress) {
    link = _CancellationLink(caller, token.cancel);
  }

  final int id;
  final void Function(int) onProgress;
  final token = CancelToken();
  late final _CancellationLink link;
  final settled = Completer<void>();
  Completer<void>? result;
}

/// Injection seam for custom Dio instances. Uses exactly the worker's file
/// routine, but deliberately publishes every accepted chunk for live UI tests.
class InlineDownloadReceiver implements DownloadReceiver {
  InlineDownloadReceiver({required this.request});

  final Future<Response<dynamic>> Function(DownloadReceiveRequest, CancelToken)
  request;
  _ReceiveJob? _active;
  bool _closed = false;
  Future<void>? _closing;

  @override
  Future<void> receive(
    DownloadReceiveRequest request, {
    required CancelToken cancelToken,
    required void Function(int receivedBytes) onProgress,
  }) {
    if (_closed) return Future.error(_cancelled);
    if (_active != null) {
      return Future.error(StateError('A download is already receiving'));
    }
    final job = _active = _ReceiveJob(0, cancelToken, onProgress);
    return _run(request, job);
  }

  Future<void> _run(DownloadReceiveRequest request, _ReceiveJob job) async {
    try {
      await _receiveToFile(request, this.request, job.token, job.onProgress);
      _checkCancelled(job.token);
    } finally {
      job.link.dispose();
      _active = null;
      job.settled.complete();
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    _active?.token.cancel();
    return _closing ??= _active?.settled.future ?? Future.value();
  }
}

/// One persistent native Dio client and one file operation at a time. The root
/// only exchanges request snapshots, byte counts, and sanitized result fields;
/// no audio buffers, client closures, stores, or plugins cross the isolate.
class IsolateDownloadReceiver implements DownloadReceiver {
  IsolateDownloadReceiver({this.workerEntrypoint = _downloadReceiveWorker});

  /// Injection seam for worker-lifecycle tests. Production uses the top-level
  /// entry below; no closures capturing the root isolate are sent to it.
  final void Function(SendPort) workerEntrypoint;
  ReceivePort? _events;
  SendPort? _commands;
  Isolate? _isolate;
  Future<void>? _starting, _spawning, _closing;
  Completer<void>? _ready, _exited;
  DownloadReceiveException? _failure;
  _ReceiveJob? _active;
  int _nextId = 0;
  bool _closed = false;
  bool _shutdownSent = false;

  Future<void> _start() {
    final events = _events = ReceivePort();
    final ready = _ready = Completer<void>();
    _exited = Completer<void>();
    events.listen(_onEvent);
    // Attach error handling immediately, including failures before the ready
    // handshake. Normal cancellation never kills an isolate with an open file.
    _spawning =
        Isolate.spawn(
          workerEntrypoint,
          events.sendPort,
          onError: events.sendPort,
          onExit: events.sendPort,
          errorsAreFatal: true,
          debugName: 'download-receiver',
        ).then((isolate) {
          _isolate = isolate;
          if (_failure != null) isolate.kill(priority: Isolate.immediate);
        }, onError: (Object _, StackTrace _) => _failWorker(spawnFailed: true));
    return ready.future;
  }

  void _failWorker({bool spawnFailed = false}) {
    final failure = _failure ??= const DownloadReceiveException(
      'Download worker stopped unexpectedly',
    );
    _commands = null;
    _isolate?.kill(priority: Isolate.immediate);
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.completeError(failure);
    final result = _active?.result;
    if (result != null && !result.isCompleted) result.completeError(failure);
    // A kill request is not an exit acknowledgement. Keep the event port until
    // onExit, except when spawning failed and there cannot be an isolate.
    if (spawnFailed) _disposePorts();
  }

  void _disposePorts() {
    _events?.close();
    _events = null;
    final exited = _exited;
    if (exited != null && !exited.isCompleted) exited.complete();
  }

  void _onEvent(dynamic message) {
    if (message is SendPort) {
      if (_failure != null) return;
      _commands = message;
      if (!_ready!.isCompleted) _ready!.complete();
      return;
    }
    if (message == null) {
      if (_shutdownSent) {
        _commands = null;
        _disposePorts();
      } else {
        _failWorker();
        _disposePorts();
      }
      return;
    }
    if (message is! Map) {
      // VM error events contain exception/stack strings. Never forward these
      // strings: an uncaught Dio error could include request credentials.
      _failWorker();
      return;
    }
    if (message['type'] == 'progress') {
      _commands?.send({'type': 'progressAck', 'id': message['id']});
    }
    final job = _active;
    if (job == null || message['id'] != job.id) return;
    if (message['type'] == 'progress') {
      if (!job.token.isCancelled && !_closed) {
        try {
          job.onProgress(message['bytes'] as int);
        } catch (_) {
          job.token.cancel();
        }
      }
      return;
    }
    final result = job.result;
    if (result == null || result.isCompleted) return;
    if (message['type'] == 'done') {
      result.complete();
    } else if (message['type'] == 'error') {
      result.completeError(
        DownloadReceiveException(
          message['message'] as String,
          statusCode: message['statusCode'] as int?,
          transportType: message['transportType'] == null
              ? null
              : DioExceptionType.values.byName(
                  message['transportType'] as String,
                ),
          cancelled: message['cancelled'] as bool,
        ),
      );
    }
  }

  @override
  Future<void> receive(
    DownloadReceiveRequest request, {
    required CancelToken cancelToken,
    required void Function(int receivedBytes) onProgress,
  }) {
    if (_closed) return Future.error(_cancelled);
    if (_active != null) {
      return Future.error(StateError('A download is already receiving'));
    }
    final job = _active = _ReceiveJob(++_nextId, cancelToken, onProgress);
    return _run(request, job);
  }

  Future<void> _run(DownloadReceiveRequest request, _ReceiveJob job) async {
    final cancellation = _CancellationLink(job.token, () {
      if (job.result != null) {
        _commands?.send({'type': 'cancel', 'id': job.id});
      }
    });
    try {
      _checkCancelled(job.token);
      if (_failure != null) {
        // A failed worker must be fully gone before another job can open the
        // same partial file. Ordinary HTTP/file errors keep the worker alive.
        await _exited?.future;
        await _spawning;
        _checkCancelled(job.token);
        _starting = null;
        _failure = null;
        _isolate = null;
      }
      await Future.any([
        _starting ??= _start(),
        job.token.whenCancel.then<void>((_) => throw _cancelled),
      ]);
      _checkCancelled(job.token);
      if (_failure != null) throw _failure!;
      final fields = request._toMessage();
      final result = job.result = Completer<void>();
      _commands!.send({'type': 'receive', 'id': job.id, 'request': fields});
      // Once dispatched, cancellation waits for worker acknowledgement, which
      // is sent only AFTER the file handle and response have been closed.
      await result.future;
      _checkCancelled(job.token);
    } catch (error) {
      if (_failure != null) {
        await _exited?.future;
        await _spawning;
      }
      if (job.token.isCancelled) throw _cancelled;
      rethrow;
    } finally {
      cancellation.dispose();
      job.link.dispose();
      _active = null;
      job.settled.complete();
    }
  }

  @override
  Future<void> close() {
    _closed = true;
    _active?.token.cancel();
    return _closing ??= _shutdown();
  }

  Future<void> _shutdown() async {
    await _active?.settled.future;
    try {
      await _starting;
    } catch (_) {
      // The receiving job observes startup failures; close remains idempotent.
    }
    await _spawning;
    final commands = _commands;
    if (commands != null) {
      _shutdownSent = true;
      commands.send({'type': 'close'});
    }
    await _exited?.future;
    _disposePorts();
    _isolate = null;
  }
}

// This top-level entry captures no UI-isolate objects. Commands are handled
// synchronously while the single async file task runs, so stop can interrupt
// stalled headers/body without racing a second writer against the same file.
void _downloadReceiveWorker(SendPort events) {
  _DownloadReceiveWorker(events).listen();
}

class _DownloadReceiveWorker {
  _DownloadReceiveWorker(this.events);

  final SendPort events;
  final commands = ReceivePort();
  final dio = Dio();
  CancelToken? _token;
  int? _id;
  void Function()? _ackProgress;
  bool _closing = false;

  void listen() {
    commands.listen((dynamic message) {
      final command = message as Map;
      switch (command['type']) {
        case 'receive':
          final id = command['id'] as int;
          if (_closing || _token != null) {
            _sendError(
              id,
              const DownloadReceiveException('Download worker is busy'),
            );
            return;
          }
          final input = DownloadReceiveRequest._fromMessage(
            command['request'] as Map,
          );
          final token = _token = CancelToken();
          _id = id;
          unawaited(_run(id, input, token));
        case 'progressAck':
          if (command['id'] == _id) _ackProgress?.call();
        case 'cancel':
          if (command['id'] == _id) _token?.cancel();
        case 'close':
          _closing = true;
          _token?.cancel();
          if (_token == null) _shutdown();
      }
    });
    events.send(commands.sendPort);
  }

  Future<Response<dynamic>> _request(
    DownloadReceiveRequest input,
    CancelToken token,
  ) {
    dio.options.connectTimeout = input.connectTimeout;
    return dio.get<dynamic>(
      input.url,
      cancelToken: token,
      options: Options(
        responseType: ResponseType.stream,
        headers: input.headers,
        sendTimeout: input.sendTimeout,
        receiveTimeout: input.receiveTimeout,
        validateStatus: (_) => true,
      ),
    );
  }

  Future<void> _run(
    int id,
    DownloadReceiveRequest input,
    CancelToken token,
  ) async {
    int? latest, sent;
    var outstanding = false;
    void sendProgress({bool terminal = false}) {
      final bytes = latest;
      if (bytes != null && bytes != sent && (!outstanding || terminal)) {
        outstanding = true;
        sent = bytes;
        events.send({'type': 'progress', 'id': id, 'bytes': bytes});
      }
    }

    final throttle = DownloadProgressThrottle(sendProgress);
    // At most one ordinary progress message can queue behind a busy/suspended
    // UI. Keep the latest count here, rather than accumulating root messages.
    _ackProgress = () {
      outstanding = false;
      if (latest != sent) throttle.schedule();
    };
    DownloadReceiveException? failure;
    try {
      await _receiveToFile(input, _request, token, (bytes) {
        final initial = latest == null;
        latest = bytes;
        if (initial) {
          sendProgress();
        } else {
          throttle.schedule();
        }
      });
      _checkCancelled(token);
    } catch (error) {
      failure = token.isCancelled ? _cancelled : _sanitize(error);
    } finally {
      throttle.close();
    }
    sendProgress(terminal: true);
    _ackProgress = null;
    // Clear the slot before replying: a root immediately starting its next
    // track must never see the completed job still occupying the worker.
    _token = null;
    _id = null;
    if (failure == null) {
      events.send({'type': 'done', 'id': id});
    } else {
      _sendError(id, failure);
    }
    if (_closing) _shutdown();
  }

  void _sendError(int id, DownloadReceiveException error) {
    events.send({
      'type': 'error',
      'id': id,
      'message': error.message,
      'statusCode': error.statusCode,
      'transportType': error.transportType?.name,
      'cancelled': error.cancelled,
    });
  }

  void _shutdown() {
    dio.close(force: true);
    commands.close();
  }
}
