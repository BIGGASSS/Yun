import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';

import 'fakes.dart';

class _OpeningDatabase extends CacheDatabase {
  _OpeningDatabase(super.file, this.entered, this.release);
  final Completer<void> entered, release;
  bool closed = false;

  @override
  Future<List<Map<String, dynamic>>> list(String kind) async {
    if (kind == 'upload' && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return super.list(kind);
  }

  @override
  Future<void> close() async {
    await super.close();
    closed = true;
  }
}

class _FailingOpeningDatabase extends CacheDatabase {
  _FailingOpeningDatabase(super.file, this.failure);
  final Object failure;
  bool closed = false;

  @override
  Future<List<Map<String, dynamic>>> list(String kind) async {
    if (kind == 'upload') throw failure;
    return super.list(kind);
  }

  @override
  Future<void> close() async {
    await super.close();
    closed = true;
  }
}

const _account = Account(
  server: 'https://yun.test',
  userId: 'user',
  username: 'listener',
);
const _track = Track(id: 't', title: 'Before', revision: 5);
const _playlist = Playlist(id: 'p', name: 'Before', revision: 5);

Map<String, dynamic> _library({
  int cursor = 5,
  bool reset = false,
  bool deleted = false,
}) => {
  'cursor': cursor,
  'reset': reset,
  'tracks': deleted
      ? []
      : [Track(id: 't', title: 'Synced', revision: cursor).toJson()],
  'playlists': deleted
      ? []
      : [Playlist(id: 'p', name: 'Synced', revision: cursor).toJson()],
  'deleted_track_ids': deleted ? ['t'] : [],
  'deleted_playlist_ids': deleted ? ['p'] : [],
};

Future<void> _until(bool Function() done) async {
  await (() async {
    while (!done()) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  })().timeout(const Duration(seconds: 10));
}

void main() {
  late Directory root;
  late MemoryCredentials credentials;
  late Dio dio;
  late AppController app;
  late CacheDatabase db;
  Object? expectedShutdownFailure;

  setUp(() async {
    expectedShutdownFailure = null;
    root = await Directory.systemTemp.createTemp('yun-app-races-');
    credentials = MemoryCredentials();
    await credentials.write(
      ApiClient.sessionKey,
      jsonEncode(
        SessionCredentials(
          account: _account,
          accessToken: 'a',
          refreshToken: 'r',
          expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
        ).toJson(),
      ),
    );
    dio = Dio();
    app = AppController(
      api: ApiClient(dio: dio, credentials: credentials),
      storageDirectory: () async => root,
      databaseFactory: (file) => db = CacheDatabase(file),
      playbackEngine: FakeEngine(),
      enableSystemControls: false,
      automaticRefresh: false,
    );
    dio.httpClientAdapter = FakeAdapter((options, _) {
      if (options.path.endsWith('/library')) {
        return jsonResponse(_library());
      }
      throw StateError('Unexpected request: ${options.method} ${options.path}');
    });
    await app.initialize();
    await app.refresh();
  });

  tearDown(() async {
    if (expectedShutdownFailure == null) {
      await app.shutdown();
    } else {
      await expectLater(app.shutdown(), throwsA(same(expectedShutdownFailure)));
    }
    app.dispose();
    await root.delete(recursive: true);
  });

  for (final mutation in ['metadata', 'artwork', 'create', 'save', 'upload']) {
    for (final deleted in [false, true]) {
      test(
        '$mutation response cannot overwrite synced ${deleted ? 'tombstone' : 'record'}',
        () async {
          final requested = Completer<void>();
          final response = Completer<ResponseBody>();
          dio.httpClientAdapter = FakeAdapter((options, _) {
            if (options.path.endsWith('/library')) {
              return jsonResponse(_library(cursor: 10, deleted: deleted));
            }
            if (options.path.endsWith('/uploads')) {
              return jsonResponse({'id': 'upload', 'offset': 3});
            }
            requested.complete();
            return response.future;
          });
          final isPlaylist = mutation == 'create' || mutation == 'save';
          final result = isPlaylist
              ? const Playlist(id: 'p', name: 'Delayed', revision: 6).toJson()
              : const Track(id: 't', title: 'Delayed', revision: 6).toJson();
          Future<void> mutate() async {
            switch (mutation) {
              case 'metadata':
                await app.updateTrack(_track, {'title': 'Delayed'});
              case 'artwork':
                await app.setArtwork(_track, Uint8List.fromList([1, 2, 3]));
              case 'create':
                await app.createPlaylist('Delayed');
              case 'save':
                await app.savePlaylist(_playlist, name: 'Delayed');
              case 'upload':
                final source = await File('${root.path}/source.wav')
                    .writeAsBytes([1, 2, 3]);
                await app.enqueueUpload(source.path);
                await _until(
                  () => app.uploads.any((job) => job.status == 'done'),
                );
            }
          }

          final operation = mutate();
          await requested.future;
          await app.refresh();
          response.complete(jsonResponse(result));
          await operation;
          expect(
            app.tracks.map((track) => track.revision),
            deleted ? isEmpty : [10],
          );
          expect(
            app.playlists.map((playlist) => playlist.revision),
            deleted ? isEmpty : [10],
          );
          expect(await db.cursor, 10);
          expect(
            (await db.get(
              isPlaylist ? 'playlist' : 'track',
              isPlaylist ? 'p' : 't',
            ))?['revision'],
            deleted ? isNull : 10,
          );
          expect(app.error, isNull);
        },
      );
    }
  }

  for (final mutation in [
    'metadata',
    'artwork',
    'create',
    'save',
    'upload',
    'delete track',
    'delete playlist',
  ]) {
    test('lower-cursor reset fences delayed $mutation response', () async {
      final requested = Completer<void>();
      final response = Completer<ResponseBody>();
      dio.httpClientAdapter = FakeAdapter((options, _) {
        if (options.path.endsWith('/library')) {
          return jsonResponse(_library(cursor: 2, reset: true));
        }
        if (options.path.endsWith('/uploads')) {
          return jsonResponse({'id': 'upload', 'offset': 3});
        }
        requested.complete();
        return response.future;
      });
      Future<void> mutate() async {
        switch (mutation) {
          case 'metadata':
            await app.updateTrack(_track, {'title': 'Delayed'});
          case 'artwork':
            await app.setArtwork(_track, Uint8List.fromList([1, 2, 3]));
          case 'create':
            await app.createPlaylist('Delayed');
          case 'save':
            await app.savePlaylist(_playlist, name: 'Delayed');
          case 'delete track':
            await app.deleteTrack('t');
          case 'delete playlist':
            await app.deletePlaylist(_playlist);
          case 'upload':
            final source = await File('${root.path}/source.wav')
                .writeAsBytes([1, 2, 3]);
            await app.enqueueUpload(source.path);
            await _until(() => app.uploads.any((job) => job.status == 'done'));
        }
      }

      final operation = mutate();
      await requested.future;
      await app.refresh();
      expect(app.tracks.single.revision, 2);
      expect(app.playlists.single.revision, 2);
      response.complete(
        jsonResponse(
          mutation == 'create' || mutation == 'save'
              ? const Playlist(
                  id: 'p',
                  name: 'Old timeline',
                  revision: 6,
                ).toJson()
              : const Track(
                  id: 't',
                  title: 'Old timeline',
                  revision: 6,
                ).toJson(),
        ),
      );
      await operation;
      expect(await db.cursor, 2);
      expect(app.tracks.single.revision, 2);
      expect(app.playlists.single.revision, 2);
      expect((await db.get('track', 't'))!['revision'], 2);
      expect((await db.get('playlist', 'p'))!['revision'], 2);
      expect(app.error, isNull);
      dio.httpClientAdapter = FakeAdapter(
        (options, _) => jsonResponse(
          const Track(id: 't', title: 'New timeline', revision: 3).toJson(),
        ),
      );
      await app.updateTrack(app.tracks.single, {'title': 'New timeline'});
      expect(app.tracks.single.title, 'New timeline');
    });
  }

  for (final kind in ['track', 'playlist']) {
    test(
      'local $kind deletion wins over staged sync and delayed mutation',
      () async {
        final editRequested = Completer<void>();
        final editResponse = Completer<ResponseBody>();
        final syncRequested = Completer<void>();
        final syncResponse = Completer<ResponseBody>();
        dio.httpClientAdapter = FakeAdapter((options, _) {
          if (options.method == 'DELETE') return jsonResponse({});
          if (options.path.endsWith('/library')) {
            syncRequested.complete();
            return syncResponse.future;
          }
          editRequested.complete();
          return editResponse.future;
        });
        final editing = kind == 'track'
            ? app.updateTrack(_track, {'title': 'Delayed'})
            : app.savePlaylist(_playlist, name: 'Delayed');
        await editRequested.future;
        final syncing = app.refresh();
        await syncRequested.future;
        final deleting = kind == 'track'
            ? app.deleteTrack('t')
            : app.deletePlaylist(_playlist);
        final id = kind == 'track' ? 't' : 'p';
        await (() async {
          while (await db.get('deleted_$kind', id) == null) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
          }
        })().timeout(const Duration(seconds: 10));
        // This snapshot was taken before DELETE and still contains the record.
        syncResponse.complete(jsonResponse(_library(cursor: 5, reset: true)));
        await Future.wait([syncing, deleting]);
        editResponse.complete(
          jsonResponse(
            kind == 'track'
                ? const Track(id: 't', title: 'Delayed', revision: 6).toJson()
                : const Playlist(
                    id: 'p',
                    name: 'Delayed',
                    revision: 6,
                  ).toJson(),
          ),
        );
        await editing;
        expect(await db.get(kind, id), isNull);
        expect(kind == 'track' ? app.tracks : app.playlists, isEmpty);
        expect(await db.get('deleted_$kind', id), isNotNull);
        dio.httpClientAdapter = FakeAdapter(
          (options, _) => jsonResponse(_library(cursor: 7, deleted: true)),
        );
        await app.refresh();
        expect(await db.get('deleted_$kind', id), isNull);
        expect(await db.get(kind, id), isNull);
      },
    );
  }

  for (final reset in [false, true]) {
    test(
      'staged sync (reset=$reset) retains a newer published mutation',
      () async {
        final requested = Completer<void>();
        final response = Completer<ResponseBody>();
        dio.httpClientAdapter = FakeAdapter((options, _) {
          if (options.path.endsWith('/library')) {
            requested.complete();
            return response.future;
          }
          return jsonResponse(
            const Track(id: 't', title: 'New mutation', revision: 7).toJson(),
          );
        });
        final syncing = app.refresh();
        await requested.future;
        await app.updateTrack(_track, {'title': 'New mutation'});
        response.complete(
          jsonResponse(_library(cursor: 6, reset: reset, deleted: true)),
        );
        await syncing;
        expect(app.tracks.single.title, 'New mutation');
        expect((await db.get('track', 't'))!['revision'], 7);
        expect(await db.cursor, 6);
      },
    );
  }

  test(
    'record revision rejects out-of-order mutation responses without sync',
    () async {
      final firstRequested = Completer<void>();
      final firstResponse = Completer<ResponseBody>();
      var requests = 0;
      dio.httpClientAdapter = FakeAdapter((options, _) {
        if (++requests == 1) {
          firstRequested.complete();
          return firstResponse.future;
        }
        return jsonResponse(
          const Track(id: 't', title: 'Latest', revision: 7).toJson(),
        );
      });
      final first = app.updateTrack(_track, {'title': 'Older'});
      await firstRequested.future;
      await app.updateTrack(const Track(id: 't', title: 'Older', revision: 6), {
        'title': 'Latest',
      });
      firstResponse.complete(
        jsonResponse(
          const Track(id: 't', title: 'Older', revision: 6).toJson(),
        ),
      );
      await first;
      expect(app.tracks.single.title, 'Latest');
      expect(await db.cursor, 5);
    },
  );

  for (final transition in ['login', 'logout']) {
    test('shutdown drains pending $transition and remains terminal', () async {
      final requested = Completer<void>();
      final response = Completer<ResponseBody>();
      dio.httpClientAdapter = FakeAdapter((options, _) {
        if (options.path.endsWith('/auth/$transition')) {
          requested.complete();
          return response.future;
        }
        if (options.path.endsWith('/auth/logout')) return jsonResponse({});
        throw StateError('Unexpected request after shutdown');
      });
      final operation = transition == 'login'
          ? app.login(_account.server, 'other', 'password')
          : app.logout();
      await requested.future;
      var closed = false;
      final closing = app.shutdown().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      response.complete(
        jsonResponse(
          transition == 'login'
              ? {
                  'access_token': 'new',
                  'refresh_token': 'r',
                  'expires_at': DateTime.now().millisecondsSinceEpoch + 3600000,
                  'user': {'id': 'other', 'username': 'other'},
                }
              : {},
        ),
      );
      await Future.wait([operation, closing]);
      expect(app.isAuthenticated, isFalse);
      expect(app.tracks, isEmpty);
      expect(() => app.initialize(), throwsStateError);
      expect(
        () => app.login(_account.server, 'other', 'password'),
        throwsStateError,
      );
      expect(() => app.logout(), throwsStateError);
      expect(() => app.createPlaylist('No'), throwsStateError);
    });
  }

  for (final transition in ['login', 'logout']) {
    test('$transition drains an account-locked paged refresh', () async {
      final requested = Completer<void>();
      final response = Completer<ResponseBody>();
      var libraryRequests = 0;
      dio.httpClientAdapter = FakeAdapter((options, _) {
        if (options.path.endsWith('/library')) {
          if (++libraryRequests == 1) {
            requested.complete();
            return response.future;
          }
          return jsonResponse(_library());
        }
        if (options.path.endsWith('/auth/logout')) return jsonResponse({});
        if (options.path.endsWith('/auth/login')) {
          return jsonResponse({
            'access_token': 'new',
            'refresh_token': 'r',
            'expires_at': DateTime.now().millisecondsSinceEpoch + 3600000,
            'user': {'id': 'other', 'username': 'other'},
          });
        }
        throw StateError('Unexpected request');
      });
      final refreshing = app.refresh();
      await requested.future;
      final changing = transition == 'login'
          ? app.login(_account.server, 'other', 'password')
          : app.logout();
      response.complete(
        jsonResponse({..._library(), 'next_page_token': 'next'}),
      );
      await Future.wait([refreshing, changing]);
      expect(app.isAuthenticated, transition == 'login');
      expect(app.account?.userId, transition == 'login' ? 'other' : null);
      expect(app.error, isNull);
      expect(libraryRequests, transition == 'login' ? 2 : 1);
    });
  }

  for (final failureKind in ['network', 'parsing']) {
    test(
      'logout does not swallow draining refresh $failureKind failures',
      () async {
        final requested = Completer<void>();
        final response = Completer<ResponseBody>();
        dio.httpClientAdapter = FakeAdapter((options, _) {
          if (options.path.endsWith('/library')) {
            requested.complete();
            return response.future;
          }
          return jsonResponse({});
        });
        final refreshing = app.refresh();
        await requested.future;
        final changing = app.logout();
        final matcher = failureKind == 'network'
            ? isA<DioException>()
            : isA<TypeError>();
        final checks = Future.wait([
          expectLater(refreshing, throwsA(matcher)),
          expectLater(changing, throwsA(matcher)),
        ]);
        if (failureKind == 'network') {
          response.completeError(
            DioException(
              requestOptions: RequestOptions(path: '/library'),
              type: DioExceptionType.connectionError,
            ),
          );
        } else {
          // ApiClient.json casts this to a map before cancellation is checked.
          response.complete(jsonResponse([]));
        }
        await checks;
        expect(app.isAuthenticated, isFalse);
        expect(await credentials.read(ApiClient.sessionKey), isNull);
      },
    );
  }

  test(
    'logout after partial initialization failure still closes and erases',
    () async {
      await app.shutdown();
      app.dispose();
      final failure = StateError('Cannot restore uploads');
      late _FailingOpeningDatabase opening;
      app = AppController(
        api: ApiClient(dio: dio, credentials: credentials),
        storageDirectory: () async => root,
        databaseFactory: (file) =>
            opening = _FailingOpeningDatabase(file, failure),
        playbackEngine: FakeEngine(),
        enableSystemControls: false,
        automaticRefresh: false,
      );
      dio.httpClientAdapter = FakeAdapter((options, _) => jsonResponse({}));
      await expectLater(app.initialize(), throwsA(same(failure)));
      expect(app.isAuthenticated, isTrue);
      expect(opening.closed, isFalse);
      await expectLater(app.logout(), throwsA(same(failure)));
      expect(opening.closed, isTrue);
      expect(app.isAuthenticated, isFalse);
      expect(app.tracks, isEmpty);
      expect(app.busy, isFalse);
      expect(await credentials.read(ApiClient.sessionKey), isNull);
      expect(() => app.createPlaylist('No'), throwsStateError);
      expectedShutdownFailure = failure;
    },
  );

  test('shutdown immediately after logout still clears credentials', () async {
    dio.httpClientAdapter = FakeAdapter((options, _) => jsonResponse({}));
    final logout = app.logout();
    await Future.wait([logout, app.shutdown()]);
    expect(await credentials.read(ApiClient.sessionKey), isNull);
    expect(app.isAuthenticated, isFalse);
  });

  test(
    'shutdown during initialization drains login without opening resources',
    () async {
      await app.shutdown();
      app.dispose();
      final directory = Completer<Directory>();
      var databasesOpened = 0;
      app = AppController(
        api: ApiClient(dio: dio, credentials: credentials),
        storageDirectory: () => directory.future,
        databaseFactory: (file) {
          databasesOpened++;
          return CacheDatabase(file);
        },
        playbackEngine: FakeEngine(),
        enableSystemControls: false,
        automaticRefresh: true,
      );
      final login = app.login(_account.server, 'other', 'password');
      var closed = false;
      final closing = app.shutdown().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      directory.complete(root);
      await Future.wait([login, closing]);
      expect(databasesOpened, 0);
      expect(app.isAuthenticated, isFalse);
      expect(app.initialized, isFalse);
    },
  );

  test(
    'a reset staged before local deletion cannot clear its barrier',
    () async {
      final requested = Completer<void>();
      final response = Completer<ResponseBody>();
      dio.httpClientAdapter = FakeAdapter((options, _) {
        if (options.path.endsWith('/library')) {
          requested.complete();
          return response.future;
        }
        return jsonResponse({});
      });
      final syncing = app.refresh();
      await requested.future;
      // The record was created after the snapshot, and its create response is
      // still delayed. Deleting it must survive the older reset's omission.
      await app.deletePlaylist(
        const Playlist(id: 'new', name: 'New', revision: 8),
      );
      response.complete(jsonResponse(_library(cursor: 6, reset: true)));
      await syncing;
      expect(await db.get('deleted_playlist', 'new'), isNotNull);
      expect(
        await db.publishLibraryRecord(
          'playlist',
          const Playlist(id: 'new', name: 'Delayed', revision: 8).toJson(),
          expectedEpoch: await db.libraryEpoch,
        ),
        isFalse,
      );
      expect(await db.get('playlist', 'new'), isNull);
      dio.httpClientAdapter = FakeAdapter(
        (options, _) => jsonResponse(_library(cursor: 9, reset: true)),
      );
      await app.refresh();
      expect(await db.get('deleted_playlist', 'new'), isNull);
    },
  );

  test(
    'mutation publication compares cursor after a queued sync transaction',
    () async {
      final requested = Completer<void>();
      final response = Completer<ResponseBody>();
      dio.httpClientAdapter = FakeAdapter((options, _) {
        requested.complete();
        return response.future;
      });
      var mutationCompleted = false;
      final mutation = app.updateTrack(_track, {'title': 'Delayed'}).then((_) {
        mutationCompleted = true;
      });
      // Epoch capture reads the database before sending the request, so let it
      // finish before occupying the transaction queue.
      await requested.future;
      final entered = Completer<void>();
      final release = Completer<void>();
      final holding = db.transaction(() async {
        entered.complete();
        await release.future;
        await db.applyLibrary(_library(cursor: 10, deleted: true));
      });
      await entered.future;
      try {
        response.complete(
          jsonResponse(
            const Track(id: 't', title: 'Delayed', revision: 6).toJson(),
          ),
        );
        // The response is ready, but publication must wait behind the sync and
        // compare against its committed cursor, not the request-time cursor.
        await Future<void>.delayed(Duration.zero);
        expect(mutationCompleted, isFalse);
      } finally {
        release.complete();
      }
      await Future.wait([holding, mutation]);
      expect(await db.get('track', 't'), isNull);
      expect(await db.cursor, 10);
    },
  );

  test('shutdown drains partially opened account resources', () async {
    await app.shutdown();
    app.dispose();
    final entered = Completer<void>();
    final release = Completer<void>();
    late _OpeningDatabase opening;
    app = AppController(
      api: ApiClient(dio: dio, credentials: credentials),
      storageDirectory: () async => root,
      databaseFactory: (file) =>
          opening = _OpeningDatabase(file, entered, release),
      playbackEngine: FakeEngine(),
      enableSystemControls: false,
      automaticRefresh: true,
    );
    final initializing = app.initialize();
    await entered.future;
    var closed = false;
    final closing = app.shutdown().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    expect(opening.closed, isFalse);
    release.complete();
    await Future.wait([initializing, closing]);
    expect(opening.closed, isTrue);
    expect(app.isAuthenticated, isFalse);
    expect(app.initialized, isFalse);
  });

  test('shutdown prevents delayed mutation publication', () async {
    final requested = Completer<void>();
    final response = Completer<ResponseBody>();
    dio.httpClientAdapter = FakeAdapter((options, _) {
      requested.complete();
      return response.future;
    });
    final mutation = app.updateTrack(_track, {'title': 'After shutdown'});
    await requested.future;
    final closing = app.shutdown();
    response.complete(
      jsonResponse(
        const Track(id: 't', title: 'After shutdown', revision: 6).toJson(),
      ),
    );
    await Future.wait([mutation, closing]);
    expect(app.tracks, isEmpty);
    expect(app.isAuthenticated, isFalse);
    final files = await root
        .list(recursive: true)
        .where((entry) => entry.path.endsWith('cache.sqlite'))
        .toList();
    final reopened = CacheDatabase(File(files.single.path));
    try {
      expect((await reopened.get('track', 't'))!['revision'], 5);
    } finally {
      await reopened.close();
    }
  });
}
