import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/artwork_cache.dart';

import 'fakes.dart';

void main() {
  late Directory root;
  late ApiClient api;
  late ArtworkCache cache;
  const owner = Account(server: 'https://yun.test', userId: 'a', username: 'a');
  const track = Track(id: 'same/id', title: 'T', revision: 1, hasArtwork: true);
  const revised = Track(
    id: 'same/id',
    title: 'T',
    revision: 2,
    hasArtwork: true,
  );
  const bytes = [137, 80, 78, 71];

  void signIn(Account account) {
    api.session = SessionCredentials(
      account: account,
      accessToken: account.userId,
      refreshToken: 'r',
      expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
    );
  }

  ArtworkCache open(Account account, {int maxBytes = 1024 * 1024 * 1024}) =>
      ArtworkCache(
        api: api,
        account: account,
        directory: root,
        maxBytes: maxBytes,
      )..updateTracks([track]);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yun-artwork-');
    api = ApiClient(dio: Dio(), credentials: MemoryCredentials());
    signIn(owner);
    cache = open(owner);
  });
  tearDown(() async {
    await cache.close();
    await root.delete(recursive: true);
  });

  test(
    'authenticated request coalesces and survives offline restart',
    () async {
      var requests = 0;
      api.dio.httpClientAdapter = FakeAdapter((options, _) {
        requests++;
        expect(options.headers['Authorization'], 'Bearer a');
        expect(options.queryParameters['revision'], 1);
        expect(options.path, endsWith('/tracks/same%2Fid/artwork'));
        return ResponseBody.fromBytes(bytes, 200);
      });
      final paths = await Future.wait([cache.get(track), cache.get(track)]);
      expect(requests, 1);
      expect(paths.first, paths.last);
      expect(await File(paths.first!).readAsBytes(), bytes);
      await cache.close();
      cache = open(owner);
      api.session = SessionCredentials(
        account: owner,
        accessToken: 'expired',
        refreshToken: 'expired',
        expiresAt: 0,
      );
      api.dio.httpClientAdapter = FakeAdapter(
        (_, _) => throw StateError('offline'),
      );
      expect(await cache.get(track, online: false), paths.first);
      expect(await cache.get(track), paths.first);
    },
  );

  test(
    'same track ID is isolated by user and server, and locked on close',
    () async {
      final original = await cache.put(track, bytes);
      expect(original, isNotNull);
      for (final account in [
        const Account(server: 'https://yun.test', userId: 'b', username: 'b'),
        const Account(server: 'https://other.test', userId: 'a', username: 'a'),
      ]) {
        signIn(account);
        expect(cache.path(track), isNull);
        final other = open(account);
        expect(await other.get(track, online: false), isNull);
        final otherPath = await other.put(track, [9]);
        expect(otherPath, isNot(original));
        await other.close();
      }
      signIn(owner);
      expect(cache.path(track), original);
      await cache.close();
      expect(cache.path(track), isNull);
      expect(await cache.get(track), isNull);
    },
  );

  test(
    'revision changes, deletion and manual replacement invalidate paths',
    () async {
      final old = await cache.put(track, bytes);
      cache.updateTracks([revised]);
      expect(cache.path(track), isNull);
      expect(await cache.get(revised, online: false), isNull);
      final updated = await cache.put(revised, [1, 2, 3]);
      expect(updated, isNot(old));
      expect(await cache.get(revised, online: false), updated);
      cache.updateTracks([]);
      expect(cache.path(revised), isNull);
    },
  );

  for (final change in ['revision', 'account', 'logout']) {
    test('late artwork cannot publish after $change', () async {
      final started = Completer<void>();
      final release = Completer<void>();
      api.dio.httpClientAdapter = FakeAdapter((_, _) async {
        started.complete();
        await release.future;
        return ResponseBody.fromBytes(bytes, 200);
      });
      final pending = cache.get(track);
      await started.future;
      Future<void>? closing;
      switch (change) {
        case 'revision':
          cache.updateTracks([revised]);
        case 'account':
          signIn(
            const Account(
              server: 'https://yun.test',
              userId: 'b',
              username: 'b',
            ),
          );
        case 'logout':
          closing = cache.close();
      }
      release.complete();
      expect(await pending, isNull);
      await closing;
      expect(cache.path(track), isNull);
      expect(
        await cache.directory.exists()
            ? await cache.directory.list().toList()
            : [],
        isEmpty,
      );
    });
  }

  test('failed and truncated responses are not cached', () async {
    api.dio.httpClientAdapter = FakeAdapter(
      (_, _) => ResponseBody.fromBytes(
        bytes,
        200,
        headers: {
          'content-length': ['100'],
        },
      ),
    );
    expect(await cache.get(track), isNull);
    expect(cache.path(track), isNull);
    api.dio.httpClientAdapter = FakeAdapter(
      (_, _) => jsonResponse({}, status: 401),
    );
    expect(await cache.get(track), isNull);
    expect(cache.path(track), isNull);
  });

  test(
    'cache evicts oldest entries to enforce per-account byte budget',
    () async {
      await cache.close();
      cache = open(owner, maxBytes: 6);
      cache.updateTracks([
        track,
        const Track(id: 'second', title: 'T', hasArtwork: true),
      ]);
      await cache.put(track, bytes);
      const second = Track(id: 'second', title: 'T', hasArtwork: true);
      await cache.put(second, bytes);
      expect(cache.path(track), isNull);
      expect(cache.path(second), isNotNull);
      var size = 0;
      await for (final entry in cache.directory.list()) {
        if (entry is File) size += await entry.length();
      }
      expect(size, lessThanOrEqualTo(6));
    },
  );
}
