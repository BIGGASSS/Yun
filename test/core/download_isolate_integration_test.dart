import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
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

const _timeout = Duration(seconds: 10);
const _bufferSize = BufferedDownloadWriter.bufferSize;

Uint8List _bytes(int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 31 + i ~/ 251) % 251));

Track _track(Uint8List bytes, {String id = 't'}) => Track(
  id: id,
  title: id,
  sizeBytes: bytes.length,
  sha256: sha256.convert(bytes).toString(),
);

/// No plugins or real credentials; every storage operation must stay on root.
class _RootCredentials extends MemoryCredentials {
  final owner = Isolate.current;
  int writes = 0;

  @override
  Future<String?> read(String key) {
    expect(Isolate.current, owner);
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) {
    expect(Isolate.current, owner);
    writes++;
    return super.write(key, value);
  }

  @override
  Future<void> delete(String key) {
    expect(Isolate.current, owner);
    return super.delete(key);
  }
}

class _Request {
  _Request(HttpRequest request)
    : path = request.uri.path,
      method = request.method,
      authorization = request.headers.value(HttpHeaders.authorizationHeader),
      range = request.headers.value(HttpHeaders.rangeHeader),
      ifRange = request.headers.value(HttpHeaders.ifRangeHeader),
      port = request.connectionInfo!.remotePort;

  final String path, method;
  final String? authorization, range, ifRange;
  final int port;
}

Future<void> _until(bool Function() predicate, String description) async {
  final watch = Stopwatch()..start();
  while (!predicate()) {
    if (watch.elapsed > _timeout) throw StateError('Timed out: $description');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late HttpServer server;
  late Directory directory;
  late CacheDatabase db;
  late ApiClient api;
  late TransferService transfers;
  late _RootCredentials credentials;
  late Future<void> Function(HttpRequest) serve;
  late List<_Request> requests;
  late List<String> rootRequests;
  late List<Object> errors, serverErrors;
  late List<String> published, downloaded;
  late List<DownloadProgress> observed;
  late List<Completer<void>> gates;
  late List<Socket> sockets;
  late int notifications;

  String getServer() => 'http://127.0.0.1:${server.port}';
  File audio(String id) => File('${directory.path}/$id.audio');
  File partial(String id) => File('${directory.path}/$id.audio.part');
  SessionCredentials session({String user = 'old', bool expired = false}) =>
      SessionCredentials(
        account: Account(server: getServer(), userId: user, username: user),
        accessToken: '$user-access',
        refreshToken: '$user-refresh',
        expiresAt:
            DateTime.now().millisecondsSinceEpoch + (expired ? -1000 : 3600000),
      );
  Completer<void> gate() {
    final value = Completer<void>();
    gates.add(value);
    return value;
  }

  Future<void> reconcile(List<Track> tracks, {List<Track>? selected}) =>
      transfers
          .reconcile(tracks, [], [
            for (final track in selected ?? tracks)
              PinSelection('track', track.id),
          ])
          .timeout(_timeout);

  Future<void> sendAudio(
    HttpRequest request,
    Track track,
    List<int> bytes, {
    int status = 200,
    String? range,
    String? etag,
  }) async {
    final response = request.response;
    response.statusCode = status;
    response.headers.set(HttpHeaders.etagHeader, etag ?? '"${track.sha256}"');
    if (range != null) response.headers.set('content-range', range);
    response.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  Future<void> refresh(HttpRequest request) async {
    expect(request.uri.path, '/api/v1/auth/refresh');
    expect(request.method, 'POST');
    expect(jsonDecode(await utf8.decoder.bind(request).join()), {
      'refresh_token': 'old-refresh',
    });
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'access_token': 'rotated-access',
        'refresh_token': 'rotated-refresh',
        'expires_at': DateTime.now().millisecondsSinceEpoch + 3600000,
      }),
    );
    await request.response.close();
  }

  Future<void> expectUnpublished(String id) async {
    expect(await db.get('file', id), isNull);
    expect(await audio(id).exists(), isFalse);
    expect(published, isNot(contains(id)));
    expect(downloaded, isNot(contains(id)));
  }

  Future<void> expectDownloaded(Track track, Uint8List bytes) async {
    final progress = transfers.progressFor(track.id)!;
    expect(progress.status, DownloadStatus.downloaded);
    expect(progress.receivedBytes, bytes.length);
    final actual = await audio(track.id).readAsBytes();
    expect(actual, orderedEquals(bytes));
    expect(sha256.convert(actual).toString(), track.sha256);
    expect(await partial(track.id).exists(), isFalse);
    final record = (await db.get('file', track.id))!;
    expect(record['sha256'], track.sha256);
    expect(record['path'], audio(track.id).path);
    expect(published.where((id) => id == track.id), hasLength(1));
    expect(downloaded.where((id) => id == track.id), hasLength(1));
  }

  Future<void> expectQuiet() async {
    final count = notifications;
    await Future<void>.delayed(DownloadProgressThrottle.interval * 3);
    expect(notifications, count, reason: 'No stale worker/progress messages');
  }

  TransferService createTransfers() => TransferService(
    api: api,
    database: db,
    directory: directory,
    onChanged: () {},
    onTrack: (track) => db.put('track', track.id, track.toJson()),
    onError: errors.add,
    onFileChanged: (id, record) {
      if (record != null) published.add(id);
    },
    onDownloaded: (track) async => downloaded.add(track.id),
    onDownloadChanged: () {
      notifications++;
      final progress = transfers.progressFor('t');
      if (progress != null) observed.add(progress);
    },
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('yun-isolate-tcp-');
    db = CacheDatabase.memory();
    requests = [];
    rootRequests = [];
    errors = [];
    serverErrors = [];
    published = [];
    downloaded = [];
    observed = [];
    gates = [];
    sockets = [];
    notifications = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serve = (request) async {
      throw StateError('Unexpected request: ${request.uri}');
    };
    server.listen((request) async {
      requests.add(_Request(request));
      try {
        await serve(request);
      } catch (error) {
        serverErrors.add(error);
        await request.response.close().catchError((Object _) {});
      }
    });
    credentials = _RootCredentials();
    // Deliberately do NOT inject Dio, a receiver, or a verification worker.
    api = ApiClient(credentials: credentials)..session = session();
    expect(api.usesDefaultTransport, isTrue);
    api.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          rootRequests.add(options.uri.path);
          handler.next(options);
        },
      ),
    );
    transfers = createTransfers();
  });

  tearDown(() async {
    // Release test-controlled server handlers even when an assertion fails.
    for (final pending in gates) {
      if (!pending.isCompleted) pending.complete();
    }
    try {
      await transfers.close().timeout(_timeout);
    } finally {
      api.dio.close(force: true);
      for (final socket in sockets) {
        socket.destroy();
      }
      await server.close(force: true);
      await db.close();
      await directory.delete(recursive: true);
    }
    expect(serverErrors, isEmpty);
    // Root Dio can refresh credentials, but must never receive audio bytes.
    expect(rootRequests.where((path) => path.endsWith('/audio')), isEmpty);
  });

  test('large production download verifies exact bytes and reuses worker TCP connection', () async {
    final bytes = _bytes(3 * 1024 * 1024 + 137);
    final track = _track(bytes);
    final otherBytes = _bytes(2 * _bufferSize + 17);
    final other = _track(otherBytes, id: 'other');
    serve = (request) => request.uri.path.endsWith('/t/audio')
        ? sendAudio(request, track, bytes)
        : sendAudio(request, other, otherBytes);

    await reconcile([track]);
    await expectDownloaded(track, bytes);
    await reconcile([track, other]);
    await expectDownloaded(other, otherBytes);
    expect(errors, isEmpty);
    expect(requests.map((r) => r.path), [
      '/api/v1/tracks/t/audio',
      '/api/v1/tracks/other/audio',
    ]);
    expect(
      requests.map((r) => r.port).toSet(),
      hasLength(1),
      reason: 'A persistent worker keeps its native HTTP client across jobs',
    );
    expect(
      requests.every((r) => r.authorization == 'Bearer old-access'),
      isTrue,
    );
    expect(requests.every((r) => r.method == 'GET' && r.range == null), isTrue);
    expect(observed.map((p) => p.status), contains(DownloadStatus.verifying));
    expect(credentials.writes, 0);
    await expectQuiet();
  });

  for (final failure in ['connection error', 'short EOF']) {
    for (final restart in [false, true]) {
      test(
        '$failure keeps durable prefix; retry ${restart ? '200 restarts' : '206 resumes'}',
        () async {
          final bytes = _bytes(3 * _bufferSize + 173);
          final track = _track(bytes);
          final prefix = _bufferSize + 61;
          final disconnect = gate();
          serve = (request) async {
            if (requests.length == 1) {
              if (failure == 'connection error') {
                // A real truncated Content-Length response, not an injected
                // Stream error. Wait until the worker accepted the exact prefix.
                final socket = await request.response.detachSocket(
                  writeHeaders: false,
                );
                sockets.add(socket);
                socket.add(
                  ascii.encode(
                    'HTTP/1.1 200 OK\r\nContent-Length: ${bytes.length}\r\n'
                    'ETag: "${track.sha256}"\r\nConnection: close\r\n\r\n',
                  ),
                );
                socket.add(Uint8List.sublistView(bytes, 0, prefix));
                await socket.flush();
                await disconnect.future;
                socket.destroy();
              } else {
                await sendAudio(request, track, bytes.sublist(0, prefix));
              }
            } else {
              await sendAudio(
                request,
                track,
                restart ? bytes : bytes.sublist(prefix),
                status: restart ? 200 : 206,
                range: restart
                    ? null
                    : 'bytes $prefix-${bytes.length - 1}/${bytes.length}',
              );
            }
          };
          final running = reconcile([track]);
          if (failure == 'connection error') {
            await _until(
              () => transfers.progressFor('t')?.receivedBytes == prefix,
              'worker accepts prefix before socket failure',
            );
            disconnect.complete();
          }
          await running;
          expect(requests, hasLength(1), reason: 'No implicit transport retry');
          expect(errors, hasLength(1));
          expect(transfers.progressFor('t')!.status, DownloadStatus.failed);
          expect(transfers.progressFor('t')!.receivedBytes, prefix);
          expect(await partial('t').readAsBytes(), bytes.sublist(0, prefix));
          expect((await db.get('download', 't'))!['received_bytes'], prefix);
          await expectUnpublished('t');
          await expectQuiet();

          await reconcile([track]);
          expect(requests, hasLength(2));
          expect(requests.last.range, 'bytes=$prefix-');
          expect(requests.last.ifRange, '"${track.sha256}"');
          expect(errors, hasLength(1));
          await expectDownloaded(track, bytes);
        },
      );
    }
  }

  for (final invalid in ['etag', 'range', 'missing range']) {
    test('invalid $invalid rejects headers without touching resumable bytes', () async {
      final bytes = _bytes(_bufferSize + 97);
      final track = _track(bytes);
      const prefix = 43;
      await partial('t').writeAsBytes(bytes.sublist(0, prefix));
      serve = (request) => sendAudio(
        request,
        track,
        bytes.sublist(prefix),
        status: 206,
        etag: invalid == 'etag' ? '"wrong-identity"' : null,
        range: invalid == 'missing range'
            ? null
            : 'bytes ${invalid == 'range' ? prefix + 1 : prefix}-${bytes.length - 1}/${bytes.length}',
      );
      await reconcile([track]);
      expect(requests.single.range, 'bytes=$prefix-');
      expect(errors, hasLength(1));
      expect(
        errors.single.toString(),
        contains(
          invalid == 'etag'
              ? 'checksum identity changed'
              : 'Invalid resume response',
        ),
      );
      expect(transfers.progressFor('t')!.status, DownloadStatus.failed);
      expect(await partial('t').readAsBytes(), bytes.sublist(0, prefix));
      await expectUnpublished('t');
      await expectQuiet();
    });
  }

  test(
    'checksum failure never publishes audio and does not block the next track',
    () async {
      final bytes = _bytes(2 * _bufferSize + 41);
      final track = _track(bytes);
      final corrupt = Uint8List.fromList(bytes)..[123] ^= 0xff;
      final other = _track(bytes, id: 'other');
      serve = (request) => sendAudio(
        request,
        track,
        request.uri.path.endsWith('/t/audio') ? corrupt : bytes,
      );
      await reconcile([track, other]);
      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('checksum mismatch'));
      expect(observed.map((p) => p.status), contains(DownloadStatus.verifying));
      expect(
        observed.map((p) => p.status),
        isNot(contains(DownloadStatus.downloaded)),
      );
      expect(transfers.progressFor('t')!.status, DownloadStatus.failed);
      expect(await partial('t').exists(), isFalse);
      await expectUnpublished('t');
      await expectDownloaded(other, bytes);
      await expectQuiet();
    },
  );

  for (final action in ['close', 'unpin']) {
    for (final stall in ['headers', 'body']) {
      test(
        '$action interrupts stalled TCP $stall; later selection has no stale progress',
        () async {
          final bytes = _bytes(2 * _bufferSize + 101);
          final track = _track(bytes);
          final otherBytes = _bytes(29);
          final other = _track(otherBytes, id: 'other');
          final arrived = gate();
          final release = gate();
          var first = true;
          serve = (request) async {
            if (first) {
              first = false;
              if (stall == 'body') {
                request.response.contentLength = bytes.length;
                request.response.add(bytes.sublist(0, _bufferSize + 73));
                await request.response.flush();
              }
              arrived.complete();
              // Neither headers nor EOF are supplied to unblock cancellation.
              await release.future;
              // The peer has cancelled; closing a truncated response can throw.
              await request.response.close().catchError((Object _) {});
            } else if (request.uri.path.endsWith('/other/audio')) {
              await sendAudio(request, other, otherBytes);
            } else {
              // A close preserves a durable prefix; a server may ignore Range.
              await sendAudio(request, track, bytes);
            }
          };
          final running = reconcile([track, other]);
          await arrived.future.timeout(_timeout);
          if (stall == 'body') {
            await _until(
              () =>
                  transfers.progressFor('t')?.receivedBytes == _bufferSize + 73,
              'worker consumes stalled response tail',
            );
            expect(await partial('t').length(), _bufferSize);
          }
          if (action == 'close') {
            await Future.wait([transfers.close(), running]).timeout(_timeout);
            expect(transfers.hasRunningDownloads, isFalse);
            expect(requests, hasLength(1));
            await expectUnpublished('t');
            expect(
              transfers.progressFor('t')!.receivedBytes,
              stall == 'body' ? _bufferSize : 0,
            );
            if (stall == 'body') {
              expect(
                await partial('t').readAsBytes(),
                bytes.sublist(0, _bufferSize),
              );
            }
            await expectQuiet();
            // A closed service is terminal. A later account/service lifetime
            // restores only durable bytes and starts its own default worker.
            transfers = createTransfers();
            await transfers.restoreDownloads();
            await reconcile([track, other]);
            expect(
              requests[1].range,
              stall == 'body' ? 'bytes=$_bufferSize-' : isNull,
            );
            await expectDownloaded(track, bytes);
            await expectDownloaded(other, otherBytes);
            await expectQuiet();
          } else {
            await Future.wait([
              running,
              reconcile([track, other], selected: [other]),
            ]).timeout(_timeout);
            expect(transfers.progressFor('t'), isNull);
            expect(await partial('t').exists(), isFalse);
            expect(await db.get('download', 't'), isNull);
            await expectUnpublished('t');
            await expectDownloaded(other, otherBytes);
            await expectQuiet();
            await reconcile([track, other]);
            expect(requests.last.range, isNull);
            await expectDownloaded(track, bytes);
            expect(
              transfers.progressFor('other')!.receivedBytes,
              otherBytes.length,
            );
            await expectQuiet();
          }
          expect(errors, isEmpty);
          // Only now release the old server handler: it cannot have enabled the
          // worker cancellation, subsequent download, or same-track reselection.
          release.complete();
          await expectQuiet();
        },
      );
    }
  }

  for (final expired in [true, false]) {
    test(
      '${expired ? 'expired headers' : 'worker 401'} refreshes only on root and retries with persisted credentials',
      () async {
        final bytes = _bytes(_bufferSize + 31);
        final track = _track(bytes);
        api.session = session(expired: expired);
        const prefix = 43;
        await partial('t').writeAsBytes(bytes.sublist(0, prefix));
        serve = (request) async {
          if (request.uri.path.endsWith('/auth/refresh')) {
            await refresh(request);
          } else if (request.headers.value('authorization') ==
              'Bearer old-access') {
            request.response.statusCode = 401;
            // An error page ETag must not be treated as audio identity.
            request.response.headers.set('etag', '"unauthorized-page"');
            await request.response.close();
          } else {
            expect(credentials.writes, 1);
            final saved =
                jsonDecode(credentials.values[ApiClient.sessionKey]!) as Map;
            expect(saved['access_token'], 'rotated-access');
            expect(saved['refresh_token'], 'rotated-refresh');
            await sendAudio(
              request,
              track,
              bytes.sublist(prefix),
              status: 206,
              range: 'bytes $prefix-${bytes.length - 1}/${bytes.length}',
            );
          }
        };
        await reconcile([track]);
        await expectDownloaded(track, bytes);
        expect(errors, isEmpty);
        expect(rootRequests, ['/api/v1/auth/refresh']);
        expect(credentials.writes, 1);
        expect(
          requests
              .where((r) => r.path.endsWith('/audio'))
              .map((r) => r.authorization),
          [if (!expired) 'Bearer old-access', 'Bearer rotated-access'],
        );
        for (final request in requests.where(
          (r) => r.path.endsWith('/audio'),
        )) {
          expect(request.range, 'bytes=$prefix-');
          expect(request.ifRange, '"${track.sha256}"');
        }
        await expectQuiet();
      },
    );
  }

  test(
    'repeated worker 401 refreshes once and reports one terminal failure',
    () async {
      final track = _track(_bytes(39));
      serve = (request) async {
        if (request.uri.path.endsWith('/auth/refresh')) {
          await refresh(request);
        } else {
          request.response.statusCode = 401;
          await request.response.close();
        }
      };
      await reconcile([track]);
      expect(rootRequests, ['/api/v1/auth/refresh']);
      expect(
        requests
            .where((r) => r.path.endsWith('/audio'))
            .map((r) => r.authorization),
        ['Bearer old-access', 'Bearer rotated-access'],
      );
      expect(errors, hasLength(1));
      expect(errors.single.toString(), contains('401'));
      expect(errors.single.toString(), isNot(contains('access')));
      expect(transfers.progressFor('t')!.status, DownloadStatus.failed);
      await expectUnpublished('t');
      await expectQuiet();
    },
  );

  test(
    'account replacement during refresh cannot restore the old login',
    () async {
      final track = _track(_bytes(39));
      final refreshArrived = gate();
      final rotate = gate();
      serve = (request) async {
        if (request.uri.path.endsWith('/auth/refresh')) {
          refreshArrived.complete();
          await rotate.future;
          await refresh(request);
        } else {
          request.response.statusCode = 401;
          await request.response.close();
        }
      };
      final running = reconcile([track]);
      await refreshArrived.future.timeout(_timeout);
      api.session = session(user: 'new');
      rotate.complete();
      await running;
      expect(api.session!.account.userId, 'new');
      expect(credentials.writes, 0);
      expect(requests.where((r) => r.path.endsWith('/audio')), hasLength(1));
      expect(errors.single.toString(), contains('Session changed'));
      await expectUnpublished('t');
      await expectQuiet();
    },
  );

  test('account switch at shared refresh completion never retries with the new login', () async {
    final track = _track(_bytes(39));
    final audioArrived = gate();
    final unauthorized = gate();
    final refreshArrived = gate();
    final rotate = gate();
    serve = (request) async {
      if (request.uri.path.endsWith('/auth/refresh')) {
        refreshArrived.complete();
        await rotate.future;
        await refresh(request);
      } else {
        if (!audioArrived.isCompleted) audioArrived.complete();
        await unauthorized.future;
        request.response.statusCode = 401;
        await request.response.close();
      }
    };
    final running = reconcile([track]);
    await audioArrived.future.timeout(_timeout);
    // Join a refresh already in flight, as happens with concurrent API calls.
    // Register the account replacement before the download joins its future.
    final switched = api.refreshToken().then(
      (_) => api.session = session(user: 'new'),
    );
    await refreshArrived.future.timeout(_timeout);
    unauthorized.complete();
    rotate.complete();
    await switched.timeout(_timeout);
    await running;
    expect(api.session!.account.userId, 'new');
    expect(requests.where((r) => r.path.endsWith('/audio')), hasLength(1));
    expect(
      requests.any((r) => r.authorization == 'Bearer new-access'),
      isFalse,
    );
    expect(rootRequests, ['/api/v1/auth/refresh']);
    expect(errors, hasLength(1));
    expect(errors.single.toString(), contains('Session changed'));
    await expectUnpublished('t');
    await expectQuiet();
  });
}
