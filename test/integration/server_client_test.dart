import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/core/listening_tracker.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/transfer_service.dart';

import '../core/fakes.dart';
import 'real_server.dart';

void main() {
  final server = RealServer();
  setUpAll(
    () => server.start([
      'transfers',
      'offline',
      'other',
      'stats',
      'refresh',
      'pages',
    ]),
  );
  tearDownAll(server.close);

  test(
    'real TCP: durable upload resume and Range/If-Range verified download',
    () async {
      final api = await server.login('transfers', const Uuid().v4());
      final root = await Directory.systemTemp.createTemp('yun-transfer-tcp-');
      final db = CacheDatabase.memory();
      final errors = <Object>[];
      final service = TransferService(
        api: api,
        database: db,
        directory: Directory('${root.path}/audio'),
        onChanged: () {},
        onTrack: (t) => db.put('track', t.id, t.toJson()),
        onError: errors.add,
      );
      addTearDown(() async {
        await service.close();
        await db.close();
        api.dio.close(force: true);
        await root.delete(recursive: true);
      });
      final bytes = testWav();
      final source = await File('${root.path}/fixture.wav').writeAsBytes(bytes);
      final remote = await api.json(
        '/uploads',
        method: 'POST',
        data: {'filename': 'fixture.wav', 'size_bytes': bytes.length},
      );
      await api.request(
        '/uploads/${remote['id']}',
        method: 'PATCH',
        data: bytes.sublist(0, 117),
        headers: {
          'Content-Type': 'application/octet-stream',
          'Upload-Offset': '0',
        },
      );
      // Persisted offset is deliberately stale: server committed a lost ACK.
      final job = UploadJob(
        id: const Uuid().v4(),
        localPath: source.path,
        filename: 'fixture.wav',
        sizeBytes: bytes.length,
        remoteId: remote['id'] as String,
      );
      await db.put('upload', job.id, job.toJson());
      await service.runUploads();
      expect(errors, isEmpty);
      expect((await db.get('upload', job.id))!['status'], 'done');
      final track = Track.fromJson((await db.list('track')).single);
      expect(track.durationMs, 4000);
      expect(track.sha256, sha256.convert(bytes).toString());
      await service.directory.create(recursive: true);
      await File('${service.directory.path}/${track.id}.audio.part')
          .writeAsBytes(bytes.sublist(0, 117));
      var sawRange = false;
      api.dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            if (request.path.endsWith('/audio')) {
              expect(request.headers['Range'], 'bytes=117-');
              expect(request.headers['If-Range'], '"${track.sha256}"');
              sawRange = true;
            }
            handler.next(request);
          },
        ),
      );
      await service.reconcile([track], [], [PinSelection('track', track.id)]);
      expect(errors, isEmpty);
      expect(sawRange, isTrue);
      final record = (await db.get('file', track.id))!;
      expect(await File(record['path'] as String).readAsBytes(), bytes);
      expect(
        await File('${service.directory.path}/${track.id}.audio.part').exists(),
        isFalse,
      );
    },
  );

  test('real TCP: client negotiates pagination and merges playlist fragments atomically', () async {
    final api = await server.login('pages', const Uuid().v4());
    final root = await Directory.systemTemp.createTemp('yun-pages-tcp-');
    final app = AppController(
      api: api,
      storageDirectory: () async => root,
      playbackEngine: FakeEngine(),
      automaticRefresh: false,
      enableSystemControls: false,
    );
    addTearDown(() async {
      await app.shutdown();
      app.dispose();
      api.dio.close(force: true);
      await root.delete(recursive: true);
    });
    final (_, track) = await uploadWav(api);
    final playlist = await api.json(
      '/playlists',
      method: 'POST',
      data: {'name': 'Large'},
    );
    final entries = List.generate(
      300,
      (_) => {'id': const Uuid().v4(), 'track_id': track.id},
    );
    final updated = await api.json(
      '/playlists/${playlist['id']}',
      method: 'PUT',
      data: {
        'revision': playlist['revision'],
        'name': 'Large',
        'entries': entries,
      },
    );
    var pages = 0;
    api.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          if (request.path.endsWith('/library')) {
            expect(request.queryParameters['paged'], isTrue);
            pages++;
          }
          handler.next(request);
        },
      ),
    );
    await app.initialize();
    await app.refresh();
    expect(pages, greaterThan(1));
    expect(app.tracks.single.id, track.id);
    expect(app.playlists.single.revision, updated['revision']);
    expect(
      app.playlists.single.entries.map((e) => e.id),
      entries.map((e) => e['id']),
    );
    final snapshot = app.playlists;
    pages = 0;
    await app.refresh();
    expect(pages, 1);
    expect(identical(app.playlists, snapshot), isTrue);
  });

  test('real TCP: tracker events and stats JSON agree; replay never doubles totals', () async {
    final device = const Uuid().v4();
    final api = await server.login('stats', device);
    addTearDown(() => api.dio.close(force: true));
    final (_, track) = await uploadWav(api);
    var mono = 0;
    final base = DateTime.now().subtract(const Duration(minutes: 1));
    final tracker = ListeningTracker(
      deviceId: device,
      newId: () => const Uuid().v4(),
      monotonicMs: () => mono,
      wallNow: () => base.add(Duration(milliseconds: mono)),
    );
    tracker.start(track.id);
    tracker.setActive(true);
    for (var i = 0; i < 3; i++) {
      mono += 1000;
      tracker.tick();
    }
    tracker.setActive(false); // Buffering/paused time is excluded.
    mono += 1000;
    final events = tracker.flush();
    expect(events.single.listenedMs, 3000);
    final body = {'events': events.map((e) => e.toJson()).toList()};
    await api.json('/listening-events', method: 'POST', data: body);
    await api.json('/listening-events', method: 'POST', data: body);
    final stats = ServerStats.fromJson(await api.json('/stats'));
    expect(stats.listenedMs, 3000);
    expect(stats.playCount, 1);
    expect(stats.topTracks.single.id, track.id);
    expect(stats.topTracks.single.listenedMs, 3000);
    expect(stats.topArtists.single.name, '');
    expect(stats.topAlbums.single.artist, '');
    expect(stats.history.single.countedPlay, isTrue);
    expect(stats.history.single.sessionId, events.single.sessionId);
    expect(stats.history.single.trackId, track.id);
  });

  test('real TCP: server-rejected access token refreshes and atomically persists rotation', () async {
    final store = MemoryCredentials();
    final api = await server.login(
      'refresh',
      const Uuid().v4(),
      credentials: store,
    );
    addTearDown(() => api.dio.close(force: true));
    final old = api.session!;
    await server.expireAccessToken(old.accessToken);
    await api.json('/library');
    expect(api.session!.accessToken, isNot(old.accessToken));
    expect(api.session!.refreshToken, isNot(old.refreshToken));
    final saved = SessionCredentials.fromJson(
      jsonDecode((await store.read(ApiClient.sessionKey))!)
          as Map<String, dynamic>,
    );
    expect(saved.refreshToken, api.session!.refreshToken);
    await expectLater(
      api.dio.post<dynamic>(
        '${server.url}/api/v1/auth/refresh',
        data: {'refresh_token': old.refreshToken},
      ),
      throwsA(
        isA<DioException>().having(
          (e) => e.response?.statusCode,
          'status',
          401,
        ),
      ),
    );
  });

  test('real TCP: offline restore plays pinned file despite expiry and isolates signout/account switch', () async {
    final root = await Directory.systemTemp.createTemp('yun-offline-tcp-');
    final store = MemoryCredentials();
    final api = ApiClient(credentials: store);
    final first = AppController(
      api: api,
      storageDirectory: () async => root,
      playbackEngine: FakeEngine(),
      enableSystemControls: false,
      automaticRefresh: false,
    );
    AppController? restored;
    addTearDown(() async {
      await first.shutdown();
      await restored?.shutdown();
      api.dio.close(force: true);
      await root.delete(recursive: true);
    });
    await first.initialize();
    await first.login(server.url, 'offline', RealServer.password);
    final (_, uploaded) = await uploadWav(api);
    await first.refresh();
    final track = first.trackById(uploaded.id)!;
    await first.pinTrack(track.id);
    await eventually(() => first.downloadedTrackIds.contains(track.id));
    final path = first.localPath(track.id)!;
    final old = api.session!;
    await first.shutdown();
    await store.write(
      ApiClient.sessionKey,
      jsonEncode(
        SessionCredentials(
          account: old.account,
          accessToken: old.accessToken,
          refreshToken: old.refreshToken,
          expiresAt: 0,
        ).toJson(),
      ),
    );
    final offlineApi = ApiClient(credentials: store);
    addTearDown(() => offlineApi.dio.close(force: true));
    var offline = true;
    var attemptedRequests = 0;
    offlineApi.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) {
          if (offline) {
            attemptedRequests++;
            handler.reject(
              DioException(
                requestOptions: request,
                type: DioExceptionType.connectionError,
              ),
            );
          } else {
            handler.next(request);
          }
        },
      ),
    );
    final engine = FakeEngine();
    final app = AppController(
      api: offlineApi,
      storageDirectory: () async => root,
      playbackEngine: engine,
      enableSystemControls: false,
      automaticRefresh: false,
    );
    restored = app;
    await app.initialize();
    await app.play(app.tracks.single);
    expect(engine.opened, path);
    expect(attemptedRequests, 0);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await app.playback.pause();
    expect(app.pendingEventCount, greaterThan(0));
    await app.logout();
    expect(app.localPath(track.id), isNull);
    expect(app.tracks, isEmpty);
    expect(await File(path).exists(), isTrue);
    offline = false;
    await app.login(server.url, 'other', RealServer.password);
    expect(app.tracks, isEmpty);
    expect(app.downloadedTrackIds, isEmpty);
    expect(app.pendingEventCount, 0);
    await app.login(server.url, 'offline', RealServer.password);
    expect(app.localPath(track.id), path);
    expect(
      app.pendingEventCount,
      0,
    ); // Real server accepted restored device ID/outbox.
    expect((await app.loadStats()).listenedMs, greaterThan(0));
  });
}
