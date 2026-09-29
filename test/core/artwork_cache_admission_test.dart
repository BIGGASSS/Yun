import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/artwork_cache.dart';

import 'fakes.dart';

void main() {
  const owner = Account(server: 'https://yun.test', userId: 'a', username: 'a');
  const track = Track(id: 'same/id', title: 'T', revision: 1, hasArtwork: true);
  const revised = Track(
    id: 'same/id',
    title: 'T',
    revision: 2,
    hasArtwork: true,
  );
  const other = Track(id: 'other', title: 'Other', hasArtwork: true);
  const image = [137, 80, 78, 71];
  const waitLimit = Duration(seconds: 5);
  late Directory root;
  late ApiClient api;
  late ArtworkCache cache;
  late List<RequestOptions> requests;

  ArtworkCache open({
    int maxBytes = 64,
    int maxConcurrentRequests = 3,
    int maxPendingRequests = 64,
    List<Track> tracks = const [track, other],
  }) => ArtworkCache(
    api: api,
    account: owner,
    directory: root,
    maxBytes: maxBytes,
    maxConcurrentRequests: maxConcurrentRequests,
    maxPendingRequests: maxPendingRequests,
  )..updateTracks(tracks);

  Future<void> reopen({
    int maxBytes = 64,
    int maxConcurrentRequests = 3,
    int maxPendingRequests = 64,
    List<Track> tracks = const [track, other],
  }) async {
    await cache.close();
    cache = open(
      maxBytes: maxBytes,
      maxConcurrentRequests: maxConcurrentRequests,
      maxPendingRequests: maxPendingRequests,
      tracks: tracks,
    );
  }

  void respond(FutureOr<ResponseBody> Function(RequestOptions) handler) {
    api.dio.httpClientAdapter = FakeAdapter((options, _) {
      requests.add(options);
      return handler(options);
    });
  }

  void serve([List<int> bytes = image]) {
    respond((_) => ResponseBody.fromBytes(bytes, 200));
  }

  void Function() retain(Track value) {
    final release = cache.retain(value);
    expect(release, isNotNull);
    return release!;
  }

  Completer<void> releaseGate() {
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    return release;
  }

  Future<int> diskBytes({bool committedOnly = false}) async {
    if (!await cache.directory.exists()) return 0;
    var total = 0;
    await for (final entry in cache.directory.list(followLinks: false)) {
      if (entry is File && (!committedOnly || entry.path.endsWith('.image'))) {
        total += await entry.length();
      }
    }
    return total;
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yun-artwork-admission-');
    api = ApiClient(dio: Dio(), credentials: MemoryCredentials());
    api.session = SessionCredentials(
      account: owner,
      accessToken: 'a',
      refreshToken: 'r',
      expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
    );
    requests = [];
    cache = open();
    serve();
  });

  tearDown(() async {
    await cache.close();
    await root.delete(recursive: true);
  });

  test('negative budgets are rejected, while zero is valid', () {
    expect(
      () => open(maxBytes: -1),
      throwsA(anyOf(isA<ArgumentError>(), isA<AssertionError>())),
    );
  });

  test(
    'zero budget never requests artwork, even with demand or retry',
    () async {
      await reopen(maxBytes: 0);
      for (var epoch = 0; epoch < 3; epoch++) {
        final release = retain(track);
        for (final background in [false, true]) {
          expect(await cache.get(track, background: background), isNull);
          expect(
            await cache.get(track, background: background, retry: true),
            isNull,
          );
        }
        release();
      }
      expect(await cache.get(track, online: false), isNull);
      expect(await cache.put(track, image), isNull);
      expect(cache.path(track), isNull);
      expect(requests, isEmpty);
      expect(await diskBytes(), 0);
    },
  );

  for (final budget in [4, 6]) {
    test('tiny $budget-byte sweeps stabilize requests and disk usage', () async {
      final tracks = List.generate(
        6,
        (i) => Track(id: 'sweep-$i', title: 'T', hasArtwork: true),
      );
      await reopen(maxBytes: budget, tracks: tracks);
      // No leases: both get modes are opportunistic unless demand is retained.
      for (final value in tracks) {
        expect(await cache.get(value), isNotNull);
        expect(await diskBytes(), lessThanOrEqualTo(budget));
      }
      expect(requests.length, tracks.length);
      final resident = cache.path(tracks.last);
      expect(resident, isNotNull);
      for (var sweep = 0; sweep < 4; sweep++) {
        for (final background in [true, false]) {
          for (final value in tracks) {
            expect(
              await cache.get(value, background: background),
              value.id == tracks.last.id ? resident : isNull,
            );
          }
          expect(requests.length, tracks.length);
          expect(await diskBytes(), image.length);
        }
      }
    });
  }

  for (final background in [true, false]) {
    test(
      'retained resident rejects ${background ? 'background' : 'foreground'} incoming artwork',
      () async {
        await reopen(maxBytes: 6);
        final resident = await cache.put(track, image);
        final release = retain(track);
        expect(await cache.get(other, background: background), isNull);
        expect(requests.length, 1);
        for (final nextBackground in [false, true, false]) {
          expect(await cache.get(other, background: nextBackground), isNull);
          expect(await cache.get(track, online: false), resident);
          expect(await File(resident!).readAsBytes(), image);
          expect(await diskBytes(), image.length);
        }
        expect(requests.length, 1);
        release();
        // Unpinning is neither a refill request nor a new demand epoch.
        expect(await cache.get(other), isNull);
        expect(await diskBytes(), image.length);
        expect(requests.length, 1);
      },
    );
  }

  test(
    'eviction skips protected entries and uses unprotected residents',
    () async {
      const third = Track(id: 'third', title: 'Third', hasArtwork: true);
      const fourth = Track(id: 'fourth', title: 'Fourth', hasArtwork: true);
      await reopen(maxBytes: 8, tracks: [track, other, third, fourth]);
      final protected = await cache.put(track, image);
      final release = retain(track);
      await cache.put(other, image);
      expect(await cache.get(third, background: true), isNotNull);
      expect(cache.path(track), protected);
      expect(cache.path(other), isNull);
      expect(await File(protected!).exists(), isTrue);
      expect(await diskBytes(), 8);
      expect(await cache.get(fourth), isNotNull);
      expect(cache.path(track), protected);
      expect(cache.path(third), isNull);
      expect(await cache.get(other), isNull);
      expect(await cache.get(third, background: true), isNull);
      expect(requests.length, 2);
      expect(await diskBytes(), 8);
      release();
    },
  );

  test(
    'manual puts respect protected residents and the hard byte cap',
    () async {
      await reopen(maxBytes: 6);
      final resident = await cache.put(track, image);
      final release = retain(track);
      expect(await cache.put(other, image), isNull);
      expect(cache.path(track), resident);
      expect(await File(resident!).readAsBytes(), image);
      expect(await diskBytes(), image.length);
      final small = await cache.put(other, [1, 2]);
      expect(small, isNotNull);
      expect(await cache.get(other, online: false), small);
      expect(await cache.get(other, background: true, retry: true), small);
      expect(await diskBytes(), 6);
      expect(requests, isEmpty);
      release();
    },
  );

  for (final manual in [false, true]) {
    test(
      'failed eviction restores the resident without publishing ${manual ? 'a put' : 'a download'}',
      () async {
        await reopen(maxBytes: image.length);
        final resident = await cache.put(track, image);
        expect(resident, isNotNull);
        final deleting = Completer<void>();
        final releaseDelete = releaseGate();
        await IOOverrides.runWithIOOverrides(
          () async {
            final incoming = manual
                ? cache.put(other, image)
                : cache.get(other);
            // Attach the error matcher before releasing the failed unlink.
            final settled = expectLater(
              incoming,
              manual ? throwsA(isA<FileSystemException>()) : completion(isNull),
            );
            await deleting.future.timeout(waitLimit);
            expect(cache.path(track), isNull);
            expect(cache.path(other), isNull);
            expect(await File(resident).exists(), isTrue);
            // A staging partial may exist, but no over-budget committed image.
            expect(await diskBytes(committedOnly: true), image.length);
            releaseDelete.complete();
            await settled.timeout(waitLimit);
            expect(cache.path(track), resident);
            expect(await cache.get(track, online: false), resident);
            expect(await File(resident).readAsBytes(), image);
            expect(cache.path(other), isNull);
            expect(await diskBytes(), image.length);
          },
          _DeleteOverrides(resident!, (file, _) async {
            deleting.complete();
            await releaseDelete.future;
            throw FileSystemException('Simulated unlink failure', file.path);
          }),
        );
        // Restoring the index must also restore its byte accounting: a later
        // successful admission has to evict the resident, not exceed the cap.
        expect(await cache.get(other).timeout(waitLimit), isNotNull);
        expect(cache.path(track), isNull);
        expect(await File(resident).exists(), isFalse);
        expect(await diskBytes(), image.length);
      },
    );
  }

  test('demand acquired during unlink cannot read the victim or lose its retry', () async {
    await reopen(maxBytes: image.length);
    final resident = await cache.put(track, image);
    expect(resident, isNotNull);
    final deleting = Completer<void>();
    final releaseDelete = releaseGate();
    await IOOverrides.runWithIOOverrides(
      () async {
        final incoming = cache.put(other, image);
        await deleting.future.timeout(waitLimit);
        final releaseDemand = retain(track);
        addTearDown(releaseDemand);
        expect(await File(resident).exists(), isTrue);
        expect(cache.path(track), isNull);
        expect(cache.path(other), isNull);
        expect(
          await cache.get(track, online: false).timeout(waitLimit),
          isNull,
        );
        expect(requests, isEmpty);
        releaseDelete.complete();
        expect(await incoming.timeout(waitLimit), isNotNull);
        expect(await File(resident).exists(), isFalse);
        // Delay the fetch until unlink completes so a wrongly reapplied marker
        // cannot be hidden by an already-started download clearing it on store.
        expect(await cache.get(track).timeout(waitLimit), resident);
        expect(await File(resident).readAsBytes(), image);
        expect(cache.path(other), isNull);
        expect(requests.length, 1);
        expect(await diskBytes(), image.length);
      },
      _DeleteOverrides(resident!, (file, recursive) async {
        deleting.complete();
        await releaseDelete.future;
        return file.delete(recursive: recursive);
      }),
    );
  });

  test(
    'startup enforces a shrunken budget even when every resident is demanded',
    () async {
      const third = Track(id: 'third', title: 'Third', hasArtwork: true);
      const tracks = [track, other, third];
      await reopen(tracks: tracks);
      for (final value in tracks) {
        expect(await cache.put(value, image), isNotNull);
      }
      expect(await diskBytes(), image.length * tracks.length);
      await reopen(maxBytes: image.length, tracks: tracks);
      // Acquire every lease before the lazy startup scan begins. Startup still
      // has to evict demanded entries rather than treating protection as a cap.
      for (final value in tracks) {
        addTearDown(retain(value));
      }
      final paths = await Future.wait([
        for (final value in tracks) cache.get(value, online: false),
      ]).timeout(waitLimit);
      // Filesystem timestamp ties need not pick a particular survivor.
      expect(paths.whereType<String>(), hasLength(1));
      expect(tracks.where((value) => cache.path(value) != null), hasLength(1));
      expect(await diskBytes(), image.length);
      expect(requests, isEmpty);
    },
  );

  test(
    'duplicate leases share a denial until every consumer releases',
    () async {
      await reopen(maxBytes: 6);
      await cache.put(track, image);
      final releaseResident = retain(track);
      final releaseFirst = retain(other);
      expect(await cache.get(other), isNull);
      expect(requests.length, 1);
      final releaseSecond = retain(other);
      expect(await cache.get(other), isNull);
      releaseFirst();
      releaseResident();
      final releaseThird = retain(other);
      expect(await cache.get(other), isNull);
      releaseSecond();
      expect(await cache.get(other), isNull);
      expect(requests.length, 1);
      releaseThird();
      expect(await cache.get(other, online: false), isNull);
      expect(await cache.get(other, background: true), isNull);
      expect(await diskBytes(), image.length);
      expect(requests.length, 1);
      final releaseNextEpoch = retain(other);
      expect(await cache.get(other), isNotNull);
      expect(requests.length, 2);
      expect(cache.path(track), isNull);
      expect(await diskBytes(), image.length);
      releaseNextEpoch();
    },
  );

  test(
    'the first retain after eviction allows one new foreground epoch',
    () async {
      await reopen(maxBytes: 4);
      await cache.put(track, image);
      await cache.put(other, image);
      expect(await cache.get(track), isNull);
      expect(requests, isEmpty);
      final release = retain(track);
      expect(await cache.get(track), isNotNull);
      expect(await cache.get(other, background: true), isNull);
      expect(requests.length, 1);
      expect(await diskBytes(), 4);
      release();
    },
  );

  test(
    'explicit retry and a new revision bypass eviction suppression',
    () async {
      await reopen(maxBytes: 4);
      await cache.put(track, image);
      await cache.put(other, image);
      expect(await cache.get(track), isNull);
      expect(requests, isEmpty);
      expect(await cache.get(track, retry: true), isNotNull);
      expect(await cache.get(other), isNull);
      await cache.put(other, image);
      expect(await cache.get(track), isNull);
      cache.updateTracks([revised, other]);
      expect(await cache.get(track, retry: true), isNull);
      expect(await cache.get(revised), isNotNull);
      expect(requests.length, 2);
      expect(requests.last.queryParameters['revision'], revised.revision);
      expect(await diskBytes(), 4);
    },
  );

  test(
    'reopening resets ephemeral denials but preserves local-first reads',
    () async {
      await reopen(maxBytes: 4);
      await cache.put(track, image);
      final resident = await cache.put(other, image);
      expect(await cache.get(track), isNull);
      expect(requests, isEmpty);
      await reopen(maxBytes: 4);
      expect(await cache.get(other, online: false), resident);
      expect(await cache.get(other, retry: true), resident);
      expect(requests, isEmpty);
      expect(await cache.get(track), isNotNull);
      expect(await cache.get(other), isNull);
      expect(requests.length, 1);
      expect(await diskBytes(), 4);
    },
  );

  test(
    'unchanged revisions and metadata updates do not reset denials',
    () async {
      await reopen(maxBytes: 4);
      await cache.put(track, image);
      await cache.put(other, image);
      const renamed = Track(
        id: 'same/id',
        title: 'Renamed',
        artist: 'Changed artist',
        revision: 1,
        hasArtwork: true,
      );
      for (final value in [track, renamed, track]) {
        cache.updateTracks([value, other]);
        expect(await cache.get(value), isNull);
        expect(await cache.get(value, background: true), isNull);
      }
      expect(requests, isEmpty);
      expect(await diskBytes(), 4);
    },
  );

  for (final change in ['removed', 'no artwork']) {
    test('$change tracks prune their admission markers', () async {
      await reopen(maxBytes: 4);
      await cache.put(track, image);
      await cache.put(other, image);
      expect(await cache.get(track), isNull);
      cache.updateTracks([
        other,
        if (change == 'no artwork')
          const Track(id: 'same/id', title: 'T', revision: 1),
      ]);
      expect(cache.retain(track), isNull);
      expect(await cache.get(track, retry: true), isNull);
      cache.updateTracks([track, other]);
      expect(await cache.get(track), isNotNull);
      expect(requests.length, 1);
      expect(await diskBytes(), 4);
    });
  }

  for (final budget in [6, ArtworkCache.maxImageBytes + 8]) {
    final limit = budget < ArtworkCache.maxImageBytes
        ? budget
        : ArtworkCache.maxImageBytes;
    final limitName = budget == 6 ? 'budget' : 'image limit';

    test(
      'advertised oversize above $limitName cancels without awaiting body',
      () async {
        await reopen(maxBytes: budget);
        final cancelled = Completer<void>();
        void markCancelled() {
          if (!cancelled.isCompleted) cancelled.complete();
        }

        // No body is supplied: completing get requires checking the header,
        // rather than draining the response and only then rejecting the bytes.
        final body = StreamController<Uint8List>(onCancel: markCancelled);
        addTearDown(() => unawaited(body.close()));
        respond(
          (_) => ResponseBody(
            body.stream,
            200,
            headers: {
              Headers.contentLengthHeader: ['${limit + 1}'],
            },
            onClose: markCancelled,
          ),
        );
        expect(await cache.get(track).timeout(waitLimit), isNull);
        await cancelled.future.timeout(waitLimit);
        expect(await cache.get(track), isNull);
        expect(requests.length, 1);
        expect(await diskBytes(), 0);
      },
    );

    test('unknown-length streams stop at $limitName and cancel the body', () async {
      await reopen(maxBytes: budget);
      final listening = Completer<void>();
      final cancelled = Completer<void>();
      void markCancelled() {
        if (!cancelled.isCompleted) cancelled.complete();
      }

      final body = StreamController<Uint8List>(
        onListen: listening.complete,
        onCancel: markCancelled,
      );
      addTearDown(() => unawaited(body.close()));
      respond((_) => ResponseBody(body.stream, 200, onClose: markCancelled));
      final pending = cache.get(track);
      await listening.future.timeout(waitLimit);
      body.add(Uint8List(limit - 1));
      body.add(Uint8List(2));
      // Keep the stream open: rejection must happen when the limit is crossed,
      // not after EOF. This also exercises limits spanning multiple chunks.
      expect(await pending.timeout(waitLimit), isNull);
      await cancelled.future.timeout(waitLimit);
      final release = retain(track);
      expect(await cache.get(track), isNull);
      release();
      expect(await cache.get(track, background: true), isNull);
      expect(requests.length, 1);
      expect(await diskBytes(), 0);
    });
  }

  for (final recovery in ['explicit retry', 'new revision']) {
    test('too-large denials survive demand epochs until $recovery', () async {
      await reopen(maxBytes: 6);
      respond(
        (_) => ResponseBody.fromBytes(
          List.filled(7, 1),
          200,
          headers: {
            Headers.contentLengthHeader: ['7'],
          },
        ),
      );
      expect(await cache.get(track), isNull);
      serve();
      for (var epoch = 0; epoch < 3; epoch++) {
        final first = retain(track);
        final second = retain(track);
        expect(await cache.get(track), isNull);
        expect(await cache.get(track, background: true), isNull);
        first();
        second();
      }
      expect(requests.length, 1);
      expect(await diskBytes(), 0);
      final String? stored;
      if (recovery == 'explicit retry') {
        final release = retain(track);
        stored = await cache.get(track, retry: true);
        release();
      } else {
        cache.updateTracks([revised, other]);
        final release = retain(revised);
        stored = await cache.get(revised);
        release();
      }
      expect(stored, isNotNull);
      expect(await File(stored!).readAsBytes(), image);
      expect(requests.length, 2);
      expect(await diskBytes(), image.length);
    });
  }

  test('a response exactly at the advertised budget is admitted', () async {
    await reopen(maxBytes: image.length);
    respond(
      (_) => ResponseBody.fromBytes(
        image,
        200,
        headers: {
          Headers.contentLengthHeader: ['${image.length}'],
        },
      ),
    );
    expect(await cache.get(track), isNotNull);
    expect(await diskBytes(), image.length);
    expect(requests.length, 1);
  });

  test(
    'cached reads bypass a saturated network queue, including retry',
    () async {
      await reopen(maxConcurrentRequests: 1, maxPendingRequests: 1);
      final resident = await cache.put(track, image);
      final started = Completer<void>();
      final release = releaseGate();
      respond((_) async {
        started.complete();
        await release.future;
        return ResponseBody.fromBytes(image, 200);
      });
      final blocked = cache.get(other);
      await started.future.timeout(waitLimit);
      for (final online in [false, true]) {
        for (final background in [false, true]) {
          for (final retry in [false, true]) {
            expect(
              await cache
                  .get(
                    track,
                    online: online,
                    background: background,
                    retry: retry,
                  )
                  .timeout(waitLimit),
              resident,
            );
          }
        }
      }
      expect(requests.length, 1);
      release.complete();
      expect(await blocked, isNotNull);
    },
  );

  for (final denial in ['budget miss', 'too large']) {
    for (final fullQueue in [false, true]) {
      test(
        'known $denial does not ${fullQueue ? 'displace useful queued work' : 'occupy network admission'}',
        () async {
          const activeTrack = Track(
            id: 'active',
            title: 'Active',
            hasArtwork: true,
          );
          const usefulTrack = Track(
            id: 'useful',
            title: 'Useful',
            hasArtwork: true,
          );
          await reopen(
            maxBytes: image.length,
            maxConcurrentRequests: 1,
            maxPendingRequests: 2,
            tracks: [track, other, activeTrack, usefulTrack],
          );
          if (denial == 'budget miss') {
            await cache.put(track, image);
            await cache.put(other, image);
          } else {
            expect(await cache.put(track, [...image, 0]), isNull);
          }
          expect(await cache.get(track), isNull);
          expect(requests, isEmpty);
          final started = Completer<void>();
          final releaseResponse = releaseGate();
          respond((options) async {
            if (options.path.endsWith('/active/artwork')) {
              started.complete();
              await releaseResponse.future;
            }
            return ResponseBody.fromBytes(image, 200);
          });
          final active = cache.get(activeTrack);
          await started.future.timeout(waitLimit);
          final Future<String?> useful;
          final Future<String?> suppressed;
          if (fullQueue) {
            useful = cache.get(usefulTrack, background: true);
            // A suppressed foreground request must not displace this prefetch.
            suppressed = cache.get(track);
          } else {
            suppressed = cache.get(track, background: true);
            // Suppressed prefetch must leave the sole pending slot available.
            useful = cache.get(usefulTrack, background: true);
          }
          expect(requests.length, 1);
          releaseResponse.complete();
          expect(
            await Future.wait([active, useful, suppressed]).timeout(waitLimit),
            [isNotNull, isNotNull, isNull],
          );
          expect(requests.map((request) => request.path), [
            endsWith('/active/artwork'),
            endsWith('/useful/artwork'),
          ]);
          expect(await diskBytes(), image.length);
        },
      );
    }
  }

  test(
    'offline-only misses do not permanently suppress subsequent fetching',
    () async {
      await reopen(maxBytes: 6);
      final release = retain(track);
      expect(await cache.get(track, online: false), isNull);
      expect(await cache.get(track, online: false, background: true), isNull);
      expect(requests, isEmpty);
      final stored = await cache.get(track);
      expect(stored, isNotNull);
      expect(await cache.get(track, online: false), stored);
      expect(requests.length, 1);
      release();
    },
  );

  for (final failure in ['network error', '503', 'truncated']) {
    test('$failure remains retryable within the same demand epoch', () async {
      await reopen(maxBytes: 6);
      final release = retain(track);
      respond((_) {
        switch (failure) {
          case 'network error':
            throw StateError('temporarily offline');
          case '503':
            return ResponseBody.fromBytes([], 503);
          default:
            return ResponseBody.fromBytes(
              image,
              200,
              headers: {
                Headers.contentLengthHeader: ['5'],
              },
            );
        }
      });
      expect(await cache.get(track), isNull);
      expect(await diskBytes(), 0);
      serve();
      expect(await cache.get(track), isNotNull);
      expect(requests.length, 2);
      expect(await diskBytes(), image.length);
      release();
    });
  }

  test('dropped background queue work is retryable without a new lease', () async {
    final candidates = List.generate(
      3,
      (i) => Track(id: 'queued-$i', title: 'T', hasArtwork: true),
    );
    await reopen(
      maxConcurrentRequests: 1,
      maxPendingRequests: 2,
      tracks: [track, ...candidates],
    );
    final started = Completer<void>();
    final release = releaseGate();
    respond((options) async {
      if (options.path.endsWith('/same%2Fid/artwork')) {
        started.complete();
        await release.future;
      }
      return ResponseBody.fromBytes(image, 200);
    });
    final active = cache.get(track);
    await started.future.timeout(waitLimit);
    final pending = [
      for (final value in candidates) cache.get(value, background: true),
    ];
    // Do not assume which queue item is discarded or the remaining start order.
    final dropped = await Future.any([
      for (var i = 0; i < pending.length; i++)
        pending[i].then((path) => (index: i, path: path)),
    ]).timeout(waitLimit);
    expect(dropped.path, isNull);
    expect(requests.length, 1);
    release.complete();
    await Future.wait([active, ...pending]);
    final beforeRetry = requests.length;
    expect(await cache.get(candidates[dropped.index]), isNotNull);
    expect(requests.length, beforeRetry + 1);
  });

  test(
    'stale revision leases and late denials cannot affect fresh artwork',
    () async {
      await reopen(maxBytes: 6);
      final started = Completer<void>();
      final releaseResponse = releaseGate();
      final releaseOldLease = retain(track);
      respond((options) async {
        if (options.queryParameters['revision'] == track.revision &&
            options.path.endsWith('/same%2Fid/artwork')) {
          started.complete();
          await releaseResponse.future;
          return ResponseBody.fromBytes(
            List.filled(7, 1),
            200,
            headers: {
              Headers.contentLengthHeader: ['7'],
            },
          );
        }
        return ResponseBody.fromBytes(image, 200);
      });
      final stale = cache.get(track);
      await started.future.timeout(waitLimit);
      cache.updateTracks([revised, other]);
      expect(cache.retain(track), isNull);
      final releaseFreshLease = retain(revised);
      final fresh = await cache.get(revised);
      expect(fresh, isNotNull);
      releaseOldLease();
      releaseResponse.complete();
      expect(await stale, isNull);
      expect(await cache.get(track, retry: true), isNull);
      expect(await cache.put(track, image), isNull);
      expect(await cache.get(revised, online: false), fresh);
      expect(await cache.get(other, background: true), isNull);
      expect(cache.path(revised), fresh);
      expect(requests.length, 3);
      expect(await diskBytes(), image.length);
      releaseFreshLease();
    },
  );

  test(
    'logout settles late work and invalidates demand and local access',
    () async {
      await reopen(maxBytes: 6);
      final started = Completer<void>();
      final releaseResponse = releaseGate();
      final releaseLease = retain(track);
      respond((_) async {
        started.complete();
        await releaseResponse.future;
        return ResponseBody.fromBytes(image, 200);
      });
      final pending = cache.get(track);
      await started.future.timeout(waitLimit);
      api.session = null;
      final closing = cache.close();
      expect(cache.retain(track), isNull);
      expect(await cache.get(track, retry: true), isNull);
      releaseLease();
      releaseResponse.complete();
      expect(await pending, isNull);
      await closing;
      expect(cache.path(track), isNull);
      expect(await cache.put(track, image), isNull);
      expect(requests.length, 1);
      expect(await diskBytes(), 0);
    },
  );
}

/// Intercepts just the eviction victim; all other filesystem work stays real.
final class _DeleteOverrides extends IOOverrides {
  _DeleteOverrides(this.victimPath, this.onDelete);

  final String victimPath;
  final Future<FileSystemEntity> Function(File file, bool recursive) onDelete;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path == victimPath ? _DeleteFile(file, onDelete) : file;
  }
}

class _DeleteFile implements File {
  _DeleteFile(this.delegate, this.onDelete);

  final File delegate;
  final Future<FileSystemEntity> Function(File file, bool recursive) onDelete;

  @override
  String get path => delegate.path;

  @override
  Future<bool> exists() => delegate.exists();

  @override
  Future<Uint8List> readAsBytes() => delegate.readAsBytes();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      onDelete(delegate, recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected File operation: ${invocation.memberName}',
  );
}
