import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/core/playback_controller.dart' show LocalAudioUnavailable;
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/playback_engine.dart';
import 'package:yun/services/transfer_service.dart';

import 'fakes.dart';

class CountingDatabase extends CacheDatabase {
  CountingDatabase() : super.memory();
  CountingDatabase.file(super.file);
  final reads = <String, int>{};
  final puts = <String, int>{};
  final eventAttempts = <Map<String, dynamic>>[];
  bool closed = false;
  bool failEvents = false;
  Future<void> Function(String)? afterRead;

  @override
  Future<List<Map<String, dynamic>>> list(String kind) async {
    reads.update(kind, (n) => n + 1, ifAbsent: () => 1);
    final result = await super.list(kind);
    await afterRead?.call(kind);
    return result;
  }

  @override
  Future<void> put(String kind, String id, Map<String, dynamic> value) {
    puts.update(kind, (n) => n + 1, ifAbsent: () => 1);
    if (kind == 'event') {
      eventAttempts.add(Map.of(value));
      if (closed) throw StateError('write after close');
      if (failEvents) throw StateError('checkpoint failed');
    }
    return super.put(kind, id, value);
  }

  @override
  Future<void> close() async {
    closed = true;
    await super.close();
  }
}

void main() {
  late Directory root;
  late CountingDatabase db;
  late ApiClient api;
  late FakeEngine engine;
  AppController? app;
  var monotonicMs = 0;
  const track = Track(id: 't', title: 'Track', sizeBytes: 3);

  setUp(() async {
    monotonicMs = 0;
    root = await Directory.systemTemp.createTemp('yun-performance-');
    db = CountingDatabase();
    engine = FakeEngine();
    final credentials = MemoryCredentials();
    await credentials.write(
      ApiClient.sessionKey,
      jsonEncode(
        SessionCredentials(
          account: const Account(
            server: 'https://yun.test',
            userId: 'u',
            username: 'u',
          ),
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
        ).toJson(),
      ),
    );
    api = ApiClient(dio: Dio(), credentials: credentials);
    api.dio.httpClientAdapter = FakeAdapter((options, _) {
      if (options.path.endsWith('/library')) {
        return jsonResponse({'cursor': 5, 'reset': false});
      }
      return jsonResponse({'acknowledged_ids': []});
    });
    await db.applyLibrary({
      'cursor': 5,
      'reset': true,
      'tracks': [track.toJson()],
    });
    app = null;
  });
  tearDown(() async {
    if (app != null) {
      try {
        await app!.shutdown();
      } catch (_) {}
      app!.dispose();
    } else {
      await db.close();
    }
    await root.delete(recursive: true);
  });
  Future<AppController> open() async {
    final value = app = AppController(
      api: api,
      storageDirectory: () async => root,
      databaseFactory: (_) => db,
      playbackEngine: engine,
      listeningMonotonicMs: () => monotonicMs,
      enableSystemControls: false,
      automaticRefresh: false,
    );
    await value.initialize();
    return value;
  }

  test(
    'stable immutable snapshots, indexed lookup, no-op sync reads no library',
    () async {
      final value = await open();
      final tracks = value.tracks, playlists = value.playlists;
      final downloads = value.downloadedTrackIds;
      expect(identical(tracks, value.tracks), isTrue);
      expect(identical(value.uploads, value.uploads), isTrue);
      expect(identical(value.pins, value.pins), isTrue);
      expect(() => tracks.clear(), throwsUnsupportedError);
      expect(() => downloads.add('other'), throwsUnsupportedError);
      expect(value.trackById('t'), same(tracks.single));
      expect(value.trackById('unknown'), isNull);
      db.reads.clear();
      db.puts.clear();
      await value.refresh();
      expect(value.tracks, same(tracks));
      expect(value.playlists, same(playlists));
      expect(value.downloadedTrackIds, same(downloads));
      expect(db.reads['track'], isNull);
      expect(db.reads['event'], isNull);
      expect(db.puts['meta'], isNull);
    },
  );

  test(
    'local availability is cached, then validated at playback open',
    () async {
      final file = await File('${root.path}/cached.audio')
          .writeAsBytes([1, 2, 3]);
      final cachedTrack = Track(
        id: track.id,
        title: track.title,
        sizeBytes: track.sizeBytes,
        sha256: sha256.convert([1, 2, 3]).toString(),
      );
      await db.put('track', cachedTrack.id, cachedTrack.toJson());
      await db.put('file', 't', {
        'id': 't',
        'sha256': cachedTrack.sha256,
        'path': file.path,
      });
      final value = await open();
      await file.delete();
      expect(value.localPath('t'), file.path);
      await expectLater(
        value.play(cachedTrack),
        throwsA(isA<LocalAudioUnavailable>()),
      );
      expect(engine.opened, isNull);
      expect(
        value.playback.localPlaybackError,
        contains('missing or unavailable'),
      );
      expect(value.localPath('t'), isNull);
      expect(value.downloadedTrackIds, isEmpty);
    },
  );

  test('playback ticks do not forward to the app notifier', () async {
    final value = await open();
    var notifications = 0;
    value.addListener(() => notifications++);
    await value.play(track);
    engine.emit(
      const EngineState(playing: true, position: Duration(seconds: 1)),
    );
    expect(notifications, 0);
  });

  test('SQL outbox count and batches do not decode beyond the limit', () async {
    await db.transaction(() async {
      for (var i = 0; i < 1200; i++) {
        await db.put('event', '$i', {'id': '$i'});
      }
    });
    // Malformed data past the first batch proves it is not decoded to count
    // or to fetch the bounded batch.
    await db.customStatement(
      "UPDATE documents SET body='invalid json' WHERE kind='event' AND id='1199'",
    );
    expect(await db.eventCount(), 1200);
    final first = await db.eventBatch();
    expect(first, hasLength(500));
    expect(first.first['id'], '0');
    expect(first.last['id'], '499');
    await db.acknowledgeEvents(first.map((e) => e['id'] as String));
    expect(await db.eventCount(), 700);
    expect((await db.eventBatch()).first['id'], '500');
    await expectLater(db.eventBatch(limit: 501), throwsRangeError);
  });

  test('v1 cache upgrades to indexed insertion-order outbox walks', () async {
    final file = File('${root.path}/v1.sqlite');
    final old = CacheDatabase(file);
    await old.put('event', 'e', {'id': 'e'});
    await old.customStatement('DROP INDEX documents_kind_order');
    await old.customStatement('PRAGMA user_version=1');
    await old.close();
    final upgraded = CacheDatabase(file);
    try {
      expect((await upgraded.eventBatch()).single['id'], 'e');
      final plan = await upgraded
          .customSelect(
            "EXPLAIN QUERY PLAN SELECT body FROM documents WHERE kind='event' ORDER BY rowid LIMIT 500",
          )
          .get();
      final details = plan.map((r) => r.read<String>('detail')).join(' ');
      expect(details, contains('documents_kind_order'));
      expect(details, isNot(contains('TEMP B-TREE')));
    } finally {
      await upgraded.close();
    }
  });

  test('identical database puts do not issue an SQLite row update', () async {
    final json = {'id': 'x', 'value': 1};
    await db.put('test', 'x', json);
    await db.put('test', 'x', json);
    final row = await db.customSelect('SELECT changes() AS count').getSingle();
    expect(row.read<int>('count'), 0);
  });

  test(
    'unchanged reconciliation performs zero puts and notifications',
    () async {
      final file = await File('${root.path}/cached.audio')
          .writeAsBytes([1, 2, 3]);
      const count = 1000;
      final hash = sha256.convert([1, 2, 3]).toString();
      final tracks = List.generate(
        count,
        (i) => Track(id: '$i', title: '$i', sizeBytes: 3, sha256: hash),
      );
      final pins = List.generate(count, (i) => PinSelection('track', '$i'));
      await db.transaction(() async {
        for (final t in tracks) {
          await db.put('track', t.id, t.toJson());
          await db.put('file', t.id, {
            'id': t.id,
            'path': file.path,
            'sha256': hash,
            'references': 1,
          });
          await db.put(
            'download',
            t.id,
            DownloadProgress(
              trackId: t.id,
              totalBytes: 3,
              receivedBytes: 3,
              status: DownloadStatus.downloaded,
            ).toJson(),
          );
        }
      });
      var notifications = 0;
      final transfers = TransferService(
        api: api,
        database: db,
        directory: root,
        onChanged: () => notifications++,
        onDownloadChanged: () => notifications++,
        onFilesChanged: () => notifications++,
        onTrack: (_) async {},
        onError: (e) => fail('$e'),
      );
      await transfers.restoreDownloads();
      db.puts.clear();
      await transfers.reconcile(tracks, [], pins);
      expect(db.puts, isEmpty);
      expect(notifications, 0);
      await transfers.close();
    },
  );

  test('bursts of full reload requests share one trailing snapshot', () async {
    final value = await open();
    final entered = Completer<void>(), release = Completer<void>();
    db.reads.clear();
    db.puts.clear();
    db.afterRead = (kind) async {
      if (kind == 'track' && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    var id = 0;
    api.dio.httpClientAdapter = FakeAdapter(
      (_, _) => jsonResponse({
        'id': '${id++}',
        'name': 'Playlist',
        // Server mutations advance the global library revision (cursor=5).
        'revision': 5 + id,
        'entries': [],
      }),
    );
    final first = value.createPlaylist('Playlist');
    await entered.future;
    final rest = List.generate(15, (_) => value.createPlaylist('Playlist'));
    while ((db.puts['playlist'] ?? 0) < 16) {
      await Future<void>.delayed(Duration.zero);
    }
    await db.get('playlist', '15');
    release.complete();
    await Future.wait([first, ...rest]);
    expect(db.reads['track'], 2);
    expect(value.playlists, hasLength(16));
  });

  test('download chunks notify narrowly without loading the library', () async {
    final bytes = [1, 2, 3];
    final downloaded = Track(
      id: 't',
      title: 'Track',
      sizeBytes: 3,
      sha256: sha256.convert(bytes).toString(),
    );
    await db.put('track', 't', downloaded.toJson());
    await db.put('pin', 't', const PinSelection('track', 't').toJson());
    final value = await open();
    final delivered = Completer<void>(), release = Completer<void>();
    Stream<Uint8List> stream() async* {
      yield Uint8List.fromList([1]);
      delivered.complete();
      await release.future;
      yield Uint8List.fromList([2, 3]);
    }

    api.dio.httpClientAdapter = FakeAdapter(
      (_, _) => ResponseBody(stream(), 200),
    );
    var broad = 0, narrow = 0;
    value.addListener(() => broad++);
    value.downloadChanges.addListener(() => narrow++);
    db.reads.clear();
    final snapshot = value.tracks;
    final operation = value.retryDownloads();
    await delivered.future;
    release.complete();
    await operation;
    expect(db.reads['track'], isNull);
    expect(db.reads['playlist'], isNull);
    expect(db.reads['event'], isNull);
    expect(value.tracks, same(snapshot));
    expect(broad, 0);
    expect(narrow, greaterThan(0));
  });

  test(
    'no-op refresh retries failed pins without reloading library snapshots',
    () async {
      final bytes = [1, 2, 3];
      final pinned = Track(
        id: 't',
        title: 'Track',
        sizeBytes: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      );
      await db.put('track', pinned.id, pinned.toJson());
      await db.put('pin', 't', const PinSelection('track', 't').toJson());
      var audioRequests = 0;
      api.dio.httpClientAdapter = FakeAdapter((options, _) {
        if (options.path.endsWith('/library')) {
          return jsonResponse({'cursor': 5, 'reset': false});
        }
        audioRequests++;
        return audioRequests == 1
            ? jsonResponse({}, status: 503)
            : ResponseBody.fromBytes(bytes, 200);
      });
      final value = await open();
      await value.retryDownloads();
      expect(value.downloadProgress(pinned).status, DownloadStatus.failed);
      final snapshot = value.tracks;
      db.reads.clear();
      final downloaded = Completer<void>();
      void changed() {
        if (value.localPath(pinned.id) != null && !downloaded.isCompleted) {
          downloaded.complete();
        }
      }

      value.downloadChanges.addListener(changed);
      try {
        await value.refresh();
        await downloaded.future.timeout(const Duration(seconds: 5));
      } finally {
        value.downloadChanges.removeListener(changed);
      }
      expect(audioRequests, 2);
      expect(value.tracks, same(snapshot));
      expect(db.reads['track'], isNull);
      expect(db.reads['playlist'], isNull);
      expect(value.downloadProgress(pinned).status, DownloadStatus.downloaded);
    },
  );

  test('upload chunks refresh only uploads and narrowly notify', () async {
    final value = await open();
    final completedChunks = Completer<void>(), release = Completer<void>();
    var offset = 0;
    api.dio.httpClientAdapter = FakeAdapter((options, bytes) async {
      if (options.path.endsWith('/uploads')) {
        return jsonResponse({'id': 'remote', 'offset': 0});
      }
      if (options.path.endsWith('/complete')) {
        completedChunks.complete();
        await release.future;
        return jsonResponse(track.toJson());
      }
      offset += bytes.length;
      return jsonResponse({'offset': offset});
    });
    final file = await File('${root.path}/source.wav')
        .writeAsBytes(List.filled(9 * 1024 * 1024, 1));
    var broad = 0, narrow = 0;
    value.addListener(() => broad++);
    value.downloadChanges.addListener(() => narrow++);
    db.reads.clear();
    final snapshot = value.tracks;
    await value.enqueueUpload(file.path);
    await completedChunks.future;
    try {
      expect(db.reads['track'], isNull);
      expect(db.reads['playlist'], isNull);
      expect(db.reads['file'], isNull);
      expect(db.reads['event'], isNull);
      expect(value.tracks, same(snapshot));
      expect(broad, 0);
      expect(narrow, greaterThan(0));
    } finally {
      release.complete();
    }
  });

  test('pagination merges playlist fragments and commits only the complete snapshot', () async {
    final secondPage = Completer<void>(), release = Completer<void>();
    api.dio.httpClientAdapter = FakeAdapter((options, _) async {
      expect(options.queryParameters['cursor'], 5);
      final second = options.queryParameters['page_token'] != null;
      if (second) {
        expect(options.queryParameters['page_token'], 'next');
        secondPage.complete();
        await release.future;
      }
      return jsonResponse({
        'cursor': 8,
        'reset': true,
        'tracks': second
            ? [const Track(id: 'b', title: 'B').toJson()]
            : [const Track(id: 'a', title: 'A').toJson()],
        'playlists': [
          {
            'id': 'p',
            'name': 'Mix',
            'revision': 8,
            'entries': [
              {'id': second ? 'e2' : 'e1', 'track_id': second ? 'b' : 'a'},
            ],
          },
        ],
        if (!second) 'next_page_token': 'next',
      });
    });
    final value = await open();
    final refresh = value.refresh();
    await secondPage.future;
    expect(await db.cursor, 5);
    expect(value.tracks.single.id, 't');
    release.complete();
    await refresh;
    expect(await db.cursor, 8);
    expect(value.tracks.map((t) => t.id), ['a', 'b']);
    expect(value.playlists.single.entries.map((e) => e.id), ['e1', 'e2']);
  });

  test(
    '409 discards partial pages and restarts using the original cursor',
    () async {
      var walks = 0;
      api.dio.httpClientAdapter = FakeAdapter((options, _) {
        expect(options.queryParameters['cursor'], 5);
        if (options.queryParameters['page_token'] == null) {
          walks++;
          return jsonResponse({
            'cursor': walks + 5,
            'reset': true,
            'tracks': [Track(id: 'walk$walks', title: 'Walk').toJson()],
            'next_page_token': 'next',
          });
        }
        if (walks < 3) return jsonResponse({}, status: 409);
        return jsonResponse({'cursor': 8, 'reset': true});
      });
      final value = await open();
      await value.refresh();
      expect(walks, 3);
      expect(value.tracks.single.id, 'walk3');
      expect(await db.cursor, 8);
    },
  );

  test('pagination rejects empty continuations instead of walking unbounded tokens', () async {
    var calls = 0;
    api.dio.httpClientAdapter = FakeAdapter((_, _) {
      calls++;
      return jsonResponse({
        'cursor': 8,
        'reset': true,
        'next_page_token': 'next$calls',
      });
    });
    final value = await open();
    await expectLater(value.refresh(), throwsFormatException);
    expect(calls, 1);
    expect(await db.cursor, 5);
    expect(value.tracks.single.id, 't');
  });

  for (final failure in [
    'conflict',
    'token',
    'revision',
    'reset',
    'fragment',
    'entry',
  ]) {
    test(
      'pagination rejects $failure without applying partial state',
      () async {
        var calls = 0;
        api.dio.httpClientAdapter = FakeAdapter((options, _) {
          calls++;
          if (failure == 'conflict') return jsonResponse({}, status: 409);
          final second = options.queryParameters['page_token'] != null;
          return jsonResponse({
            'cursor': second && failure == 'revision' ? 9 : 8,
            'reset': !(second && failure == 'reset'),
            'playlists': [
              {
                'id': 'p',
                'revision': 8,
                'name': second && failure == 'fragment' ? 'Different' : 'Mix',
                'entries': [
                  {
                    'id': second && failure != 'entry' ? 'e2' : 'e1',
                    'track_id': 't',
                  },
                ],
              },
            ],
            if (!second || failure == 'token') 'next_page_token': 'next',
          });
        });
        final value = await open();
        await expectLater(value.refresh(), throwsA(anything));
        expect(calls, failure == 'conflict' ? 3 : 2);
        expect(await db.cursor, 5);
        expect(value.tracks.single.id, 't');
        expect(await db.list('playlist'), isEmpty);
      },
    );
  }

  test(
    'logout clears credentials even when its final checkpoint fails',
    () async {
      final value = await open();
      await value.play(track);
      engine.emit(
        const EngineState(playing: true, position: Duration(seconds: 5)),
      );
      monotonicMs += 1000;
      db.failEvents = true;
      await expectLater(value.logout(), throwsStateError);
      expect(db.closed, isTrue);
      expect(value.isAuthenticated, isFalse);
      expect(api.session, isNull);
      expect(await api.credentials.read(ApiClient.sessionKey), isNull);
    },
  );

  test('failed logout quarantines events across users and servers until the original account returns', () async {
    await db.close();
    final databases = <CountingDatabase>[];
    final paths = <String>[];
    final uploads = <({String server, String user, List<dynamic> events})>[];
    api.dio.httpClientAdapter = FakeAdapter((options, bytes) {
      if (options.path.endsWith('/auth/login')) {
        final request = jsonDecode(utf8.decode(bytes)) as Map;
        final username = request['username'] as String;
        return jsonResponse({
          'user': {
            'id': username == 'other' ? 'other' : 'u',
            'username': username,
          },
          'access_token': 'a',
          'refresh_token': 'r',
          'expires_at': DateTime.now().millisecondsSinceEpoch + 3600000,
        });
      }
      if (options.path.endsWith('/library')) {
        return jsonResponse({'cursor': 5, 'reset': false});
      }
      if (options.path.endsWith('/listening-events')) {
        uploads.add((
          server: api.session!.account.server,
          user: api.session!.account.userId,
          events: (jsonDecode(utf8.decode(bytes)) as Map)['events'] as List,
        ));
      }
      // Keep every submitted event durable, exercising partial/unacked outbox
      // semantics independently of the in-memory quarantine.
      return jsonResponse({'acknowledged_ids': []});
    });
    final value = app = AppController(
      api: api,
      storageDirectory: () async => root,
      databaseFactory: (file) {
        paths.add(file.path);
        final next = CountingDatabase.file(file);
        databases.add(next);
        return db = next;
      },
      playbackEngine: engine,
      listeningMonotonicMs: () => monotonicMs,
      enableSystemControls: false,
      automaticRefresh: false,
    );
    await value.initialize();
    await value.play(track);
    monotonicMs += 1000;
    db.failEvents = true;
    final originalDb = db;
    await expectLater(value.logout(), throwsStateError);
    expect(originalDb.closed, isTrue);
    expect(value.isAuthenticated, isFalse);
    expect(api.session, isNull);
    expect(await api.credentials.read(ApiClient.sessionKey), isNull);
    final originalEvent = originalDb.eventAttempts.first;
    final attempts = originalDb.eventAttempts.length;
    await value.playback.checkpoint();
    await value.playback.checkpoint();
    expect(originalDb.eventAttempts, hasLength(attempts));

    for (final next in [
      (server: 'https://yun.test', username: 'other'),
      (server: 'https://elsewhere.test', username: 'u'),
    ]) {
      await value.login(next.server, next.username, 'password');
      expect(await db.eventCount(), 0);
      expect(value.pendingEventCount, 0);
      expect(db.eventAttempts, isEmpty);
      await value.playback.checkpoint();
      expect(db.eventAttempts, isEmpty);
      // Other accounts still record normally, even with identical track IDs.
      await value.play(track);
      monotonicMs += 1000;
      await value.playback.checkpoint();
      expect(await db.eventCount(), 1);
      expect(db.eventAttempts.single['id'], isNot(originalEvent['id']));
      await value.flushOutbox();
      expect(await db.eventCount(), 1);
      expect(uploads.last.events.single['id'], db.eventAttempts.single['id']);
      await value.logout();
      expect(db.closed, isTrue);
    }
    expect(paths.toSet(), hasLength(3));
    expect(originalDb.eventAttempts, hasLength(attempts));

    // URL normalization and stable user ID (not display username) determine
    // the scope. Returning to the original DB retries the exact segment/ID.
    await value.login(' https://yun.test/// ', 'renamed', 'password');
    expect(paths.last, paths.first);
    expect(db, isNot(same(originalDb)));
    expect(db.eventAttempts, [originalEvent]);
    expect(await db.eventBatch(), [originalEvent]);
    expect(value.pendingEventCount, 1);
    expect(uploads.last.server, 'https://yun.test');
    expect(uploads.last.user, 'u');
    expect(uploads.last.events, [originalEvent]);
    expect(
      uploads
          .take(2)
          .expand((upload) => upload.events)
          .every((event) => event['id'] != originalEvent['id']),
      isTrue,
    );
    await value.playback.checkpoint();
    expect(db.eventAttempts, hasLength(1));

    // Once enqueued, the normal durable outbox owns the event. Reopening does
    // not enqueue it again, and an unacknowledged segment is still on disk.
    await value.logout();
    await value.login('https://yun.test/', 'u', 'password');
    expect(db.eventAttempts, isEmpty);
    expect(await db.eventBatch(), [originalEvent]);
    expect(
      databases.take(databases.length - 1).every((db) => db.closed),
      isTrue,
    );
  });

  test(
    'shutdown closes database and engine even if final checkpoint fails',
    () async {
      final value = await open();
      await value.play(track);
      engine.emit(
        const EngineState(playing: true, position: Duration(seconds: 5)),
      );
      monotonicMs += 1000;
      db.failEvents = true;
      await expectLater(value.shutdown(), throwsStateError);
      expect(db.closed, isTrue);
      expect(engine.controller.isClosed, isTrue);
      expect(value.isAuthenticated, isFalse);
    },
  );
}
