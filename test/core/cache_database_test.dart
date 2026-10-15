import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/cache_database.dart';

void main() {
  late CacheDatabase db;
  setUp(() => db = CacheDatabase.memory());
  tearDown(() => db.close());
  test(
    'cursor resets remove stale direct pins but preserve other local data',
    () async {
      await db.put('event', 'event', {'id': 'event'});
      await db.put('file', 'old', {'id': 'old', 'path': 'file'});
      await db.put('upload', 'upload', {'id': 'upload'});
      await db.put('download', 'old', {'id': 'old'});
      await db.put('pin', 'pin', {'type': 'track', 'id': 'old'});
      await db.put('pin', 'album', {'type': 'album', 'id': 'old'});
      await db.put('pin', 'playlist', {'type': 'playlist', 'id': 'old'});
      await db.applyLibrary({
        'cursor': 4,
        'reset': true,
        'tracks': [const Track(id: 'old', title: 'old').toJson()],
        'playlists': [],
      });
      expect(await db.get('pin', 'pin'), isNotNull);
      await db.applyLibrary({
        'cursor': 5,
        'reset': true,
        'tracks': [const Track(id: 'new', title: 'new').toJson()],
        'playlists': [],
      });
      expect(await db.cursor, 5);
      expect((await db.list('track')).single['id'], 'new');
      expect(await db.get('event', 'event'), isNotNull);
      expect(await db.get('file', 'old'), isNotNull);
      expect(await db.get('upload', 'upload'), isNotNull);
      expect(await db.get('download', 'old'), isNotNull);
      expect(await db.get('pin', 'pin'), isNull);
      expect(await db.get('pin', 'album'), {'type': 'album', 'id': 'old'});
      expect(await db.get('pin', 'playlist'), {
        'type': 'playlist',
        'id': 'old',
      });
    },
  );
  test(
    'incremental tombstones remove direct pins, not other selections or events',
    () async {
      await db.applyLibrary({
        'cursor': 1,
        'reset': true,
        'tracks': [
          const Track(id: 'a', title: 'A').toJson(),
          const Track(id: 'b', title: 'B').toJson(),
        ],
        'playlists': [],
      });
      for (final key in ['pin', 'track:a', '["track","a"]']) {
        await db.put('pin', key, {'type': 'track', 'id': 'a'});
      }
      await db.put('pin', 'track:already-absent', {
        'type': 'track',
        'id': 'already-absent',
      });
      await db.put('pin', 'track:unknown', {'type': 'track', 'id': 'unknown'});
      // Document keys are not authoritative selection IDs.
      await db.put('pin', 'track:looks-deleted', {'type': 'track', 'id': 'b'});
      await db.put('pin', 'album', {'type': 'album', 'id': 'a'});
      await db.put('pin', 'playlist', {'type': 'playlist', 'id': 'a'});
      await db.put('event', 'event', {'id': 'event', 'track_id': 'a'});
      await db.applyLibrary({
        'cursor': 2,
        'reset': false,
        'deleted_track_ids': ['a', 'already-absent', 'looks-deleted'],
        'tracks': [],
        'playlists': [],
      });
      expect((await db.list('track')).single['id'], 'b');
      for (final key in [
        'pin',
        'track:a',
        '["track","a"]',
        'track:already-absent',
      ]) {
        expect(await db.get('pin', key), isNull);
      }
      expect(await db.get('pin', 'track:unknown'), isNotNull);
      expect(await db.get('pin', 'track:looks-deleted'), {
        'type': 'track',
        'id': 'b',
      });
      expect(await db.get('pin', 'album'), {'type': 'album', 'id': 'a'});
      expect(await db.get('pin', 'playlist'), {'type': 'playlist', 'id': 'a'});
      expect(await db.list('event'), hasLength(1));
      await db.acknowledgeEvents(['other']);
      expect(await db.list('event'), hasLength(1));
      await db.acknowledgeEvents(['event']);
      expect(await db.list('event'), isEmpty);
    },
  );
  test('offline reads and no-op deltas do not infer track deletion', () async {
    final pin = {'type': 'track', 'id': 'missing'};
    await db.put('pin', 'pin', pin);
    expect(await db.get('track', 'missing'), isNull);
    expect(await db.list('track'), isEmpty);
    expect(await db.list('pin'), [pin]);
    await db.applyLibrary({
      'cursor': 1,
      'reset': false,
      'tracks': [],
      'playlists': [],
    });
    expect(await db.get('pin', 'pin'), pin);
    await db.applyLibrary({
      'cursor': 2,
      'deleted_track_ids': ['unrelated'],
    });
    expect(await db.get('pin', 'pin'), pin);
  });

  test(
    'full reset sweeps historical pins only after installing tracks',
    () async {
      await db.applyLibrary({'cursor': 1});
      for (final id in ['historical', 'arriving', 'mutation']) {
        await db.put('pin', 'track:$id', {'type': 'track', 'id': id});
      }
      final mutation = const Track(
        id: 'mutation',
        title: 'Concurrent mutation',
        revision: 3,
      ).toJson();
      expect(
        await db.publishLibraryRecord(
          'track',
          mutation,
          expectedEpoch: await db.libraryEpoch,
        ),
        isTrue,
      );
      await db.applyLibrary({
        'cursor': 2,
        'reset': true,
        'tracks': [
          const Track(id: 'arriving', title: 'New', revision: 2).toJson(),
        ],
      });
      expect(await db.get('pin', 'track:historical'), isNull);
      expect(await db.get('pin', 'track:arriving'), {
        'type': 'track',
        'id': 'arriving',
      });
      expect(await db.get('track', 'mutation'), mutation);
      expect(await db.get('pin', 'track:mutation'), {
        'type': 'track',
        'id': 'mutation',
      });
    },
  );

  test('large tombstone deltas prune direct pins in one batch', () async {
    const deletedCount = 1200;
    await db.transaction(() async {
      for (var i = 0; i <= deletedCount; i++) {
        final id = '$i';
        await db.put('track', id, Track(id: id, title: id).toJson());
        await db.put('pin', 'legacy:$id', PinSelection('track', id).toJson());
      }
    });
    await db.applyLibrary({
      'cursor': 1,
      'reset': false,
      'deleted_track_ids': [for (var i = 0; i < deletedCount; i++) '$i'],
    });
    expect(await db.list('pin'), [
      const PinSelection('track', '$deletedCount').toJson(),
    ]);
    expect((await db.list('track')).single['id'], '$deletedCount');
  });

  test('acknowledged track delete removes only its direct pins', () async {
    await db.applyLibrary({
      'cursor': 1,
      'tracks': [const Track(id: 't', title: 'T', revision: 1).toJson()],
      'playlists': [const Playlist(id: 'p', name: 'Empty').toJson()],
    });
    for (final key in ['pin', 'track:t', '["track","t"]']) {
      await db.put('pin', key, {'type': 'track', 'id': 't'});
    }
    await db.put('pin', 'unconfirmed', {'type': 'track', 'id': 'missing'});
    await db.put('pin', 'album', {'type': 'album', 'id': 'Album'});
    await db.put('pin', 'playlist', {'type': 'playlist', 'id': 'p'});
    for (final kind in ['file', 'event', 'upload', 'download']) {
      await db.put(kind, 'local', {'id': 't'});
    }
    final epoch = await db.libraryEpoch;
    expect(
      await db.deleteLibraryRecord('track', 't', expectedEpoch: epoch),
      isTrue,
    );
    expect(await db.get('track', 't'), isNull);
    expect(await db.get('deleted_track', 't'), {'id': 't', 'sequence': 1});
    expect(await db.cursor, 1);
    for (final key in ['pin', 'track:t', '["track","t"]']) {
      expect(await db.get('pin', key), isNull);
    }
    expect(await db.get('pin', 'unconfirmed'), isNotNull);
    expect(await db.get('pin', 'album'), {'type': 'album', 'id': 'Album'});
    expect(await db.get('pin', 'playlist'), {'type': 'playlist', 'id': 'p'});
    for (final kind in ['file', 'event', 'upload', 'download']) {
      expect(await db.get(kind, 'local'), {'id': 't'});
    }
    expect(
      await db.deleteLibraryRecord('playlist', 'p', expectedEpoch: epoch),
      isTrue,
    );
    expect(await db.get('pin', 'playlist'), {'type': 'playlist', 'id': 'p'});
  });

  test(
    'failed pin cleanup rolls back acknowledged delete and its barrier',
    () async {
      final track = const Track(id: 't', title: 'T', revision: 1).toJson();
      await db.applyLibrary({
        'cursor': 1,
        'tracks': [track],
      });
      await db.put('pin', 'pin', {'type': 'track', 'id': 't'});
      await db.customStatement('''
      CREATE TRIGGER reject_pin_deletion BEFORE DELETE ON documents
      WHEN OLD.kind = 'pin'
      BEGIN SELECT RAISE(ABORT, 'reject pin deletion'); END
    ''');
      final epoch = await db.libraryEpoch;
      await expectLater(
        db.deleteLibraryRecord('track', 't', expectedEpoch: epoch),
        throwsA(isA<Exception>()),
      );
      expect(await db.get('track', 't'), track);
      expect(await db.get('pin', 'pin'), {'type': 'track', 'id': 't'});
      expect(await db.get('deleted_track', 't'), isNull);
      expect(await db.deletionSequence, 0);
      expect(await db.cursor, 1);
    },
  );

  for (final reset in [false, true]) {
    test(
      'older tombstone preserves newer track and pin (reset=$reset)',
      () async {
        await db.applyLibrary({
          'cursor': 1,
          'tracks': [const Track(id: 't', title: 'T', revision: 1).toJson()],
        });
        await db.put('pin', 'track:t', {'type': 'track', 'id': 't'});
        final mutation = const Track(
          id: 't',
          title: 'Concurrent mutation',
          revision: 3,
        ).toJson();
        expect(
          await db.publishLibraryRecord(
            'track',
            mutation,
            expectedEpoch: await db.libraryEpoch,
          ),
          isTrue,
        );
        await db.applyLibrary({
          'cursor': 2,
          'reset': reset,
          'tracks': [],
          'deleted_track_ids': ['t'],
        });
        expect(await db.get('track', 't'), mutation);
        expect(await db.get('pin', 'track:t'), {'type': 'track', 'id': 't'});
        expect(await db.cursor, 2);
      },
    );
  }

  test(
    'pin cleanup safely matches JSON string IDs and ignores malformed pins',
    () async {
      const id = r'''a'"?$''';
      await db.applyLibrary({
        'cursor': 1,
        'tracks': [const Track(id: id, title: 'Quoted ID').toJson()],
      });
      await db.put('pin', 'legacy', {'type': 'track', 'id': id});
      await db.put('pin', 'non-string', {'type': 'track', 'id': 42});
      await db.customStatement(
        'INSERT INTO documents(kind,id,body) VALUES(?,?,?)',
        ['pin', 'invalid-json', 'not JSON'],
      );
      await db.applyLibrary({
        'cursor': 2,
        'deleted_track_ids': [id],
      });
      expect(await db.get('pin', 'legacy'), isNull);
      await db.applyLibrary({'cursor': 3, 'reset': true});
      expect(await db.get('pin', 'non-string'), {'type': 'track', 'id': 42});
      final rawPin = await db
          .customSelect(
            "SELECT body FROM documents WHERE kind='pin' AND id='invalid-json'",
          )
          .getSingle();
      expect(rawPin.read<String>('body'), 'not JSON');
    },
  );

  test(
    'lower-cursor reset replaces the old timeline, not local data',
    () async {
      await db.applyLibrary({
        'cursor': 10,
        'tracks': [
          const Track(id: 't', title: 'Old', revision: 10).toJson(),
          const Track(id: 'gone', title: 'Gone', revision: 9).toJson(),
        ],
        'playlists': [
          const Playlist(id: 'p', name: 'Old', revision: 10).toJson(),
        ],
      });
      final oldEpoch = await db.libraryEpoch;
      await db.publishLibraryRecord(
        'track',
        const Track(id: 'newer', title: 'Old mutation', revision: 11).toJson(),
        expectedEpoch: oldEpoch,
      );
      await db.deleteLibraryRecord('track', 't', expectedEpoch: oldEpoch);
      await db.deleteLibraryRecord('playlist', 'p', expectedEpoch: oldEpoch);
      for (final kind in ['file', 'event', 'upload', 'download']) {
        await db.put(kind, 'local', {'id': 'local'});
      }
      for (final id in ['t', 'gone', 'newer', 'historical']) {
        await db.put('pin', 'track:$id', {'type': 'track', 'id': id});
      }
      await db.put('pin', 'album', {'type': 'album', 'id': 'Album'});
      await db.put('pin', 'playlist', {'type': 'playlist', 'id': 'p'});
      final restored = const Track(
        id: 't',
        title: 'Restored',
        revision: 2,
      ).toJson();
      final playlist = const Playlist(
        id: 'p',
        name: 'Restored',
        revision: 2,
      ).toJson();
      await db.applyLibrary({
        'cursor': 2,
        'reset': true,
        'tracks': [restored],
        'playlists': [playlist],
      });
      expect(await db.cursor, 2);
      expect(await db.libraryEpoch, oldEpoch + 1);
      expect(await db.list('track'), [restored]);
      expect(await db.list('playlist'), [playlist]);
      expect(await db.list('deleted_track'), isEmpty);
      expect(await db.list('deleted_playlist'), isEmpty);
      for (final kind in ['file', 'event', 'upload', 'download']) {
        expect(await db.get(kind, 'local'), {'id': 'local'});
      }
      expect(await db.get('pin', 'track:t'), {'type': 'track', 'id': 't'});
      for (final id in ['gone', 'newer', 'historical']) {
        expect(await db.get('pin', 'track:$id'), isNull);
      }
      expect(await db.get('pin', 'album'), {'type': 'album', 'id': 'Album'});
      expect(await db.get('pin', 'playlist'), {'type': 'playlist', 'id': 'p'});
      // Both stale writes and revision-less DELETE responses are fenced.
      expect(
        await db.publishLibraryRecord('track', {
          ...restored,
          'revision': 12,
        }, expectedEpoch: oldEpoch),
        isFalse,
      );
      expect(
        await db.deleteLibraryRecord('playlist', 'p', expectedEpoch: oldEpoch),
        isFalse,
      );
      expect(
        await db.deleteLibraryRecord('track', 't', expectedEpoch: oldEpoch),
        isFalse,
      );
      expect(await db.get('pin', 'track:t'), {'type': 'track', 'id': 't'});
      expect(await db.list('track'), [restored]);
      expect(await db.list('playlist'), [playlist]);
      expect(
        await db.publishLibraryRecord('track', {
          ...restored,
          'revision': 3,
        }, expectedEpoch: await db.libraryEpoch),
        isTrue,
      );
    },
  );

  for (final reset in [false, true]) {
    test(
      'invalid backwards snapshot rolls back timeline (reset=$reset)',
      () async {
        final track = const Track(id: 't', title: 'Old', revision: 10).toJson();
        await db.applyLibrary({
          'cursor': 10,
          'tracks': [track],
        });
        await db.put('pin', 'track:t', {'type': 'track', 'id': 't'});
        await db.put('pin', 'historical', {'type': 'track', 'id': 'missing'});
        await expectLater(
          db.applyLibrary({
            'cursor': 2,
            'reset': reset,
            'tracks': reset
                ? [
                    {'title': 'Missing id'},
                  ]
                : [],
          }),
          throwsA(reset ? isA<TypeError>() : isA<FormatException>()),
        );
        expect(await db.cursor, 10);
        expect(await db.libraryEpoch, 0);
        expect(await db.list('track'), [track]);
        expect(await db.get('pin', 'track:t'), {'type': 'track', 'id': 't'});
        expect(await db.get('pin', 'historical'), {
          'type': 'track',
          'id': 'missing',
        });
      },
    );
  }

  test(
    'cached bitrate survives snapshots, updates, and explicit clearing',
    () async {
      final records = [
        {
          'id': 'legacy',
          'title': 'Legacy',
          'size_bytes': 4800000,
          'duration_ms': 300000,
        },
        {'id': 'unknown', 'title': 'Unknown', 'bitrate_kbps': null},
        const Track(
          id: 'known',
          title: 'Known',
          bitrateKbps: 320,
          sizeBytes: 12000000,
          durationMs: 300000,
        ).toJson(),
      ];
      await db.applyLibrary({'cursor': 1, 'reset': true, 'tracks': records});
      final cached = await db.list('track');
      expect(cached, records);
      expect(cached.first.containsKey('bitrate_kbps'), isFalse);
      expect(cached[1].containsKey('bitrate_kbps'), isTrue);
      final tracks = cached.map(Track.fromJson).toList();
      expect(tracks.map((track) => track.bitrateKbps), [null, null, 320]);
      expect(tracks.map((track) => track.estimatedBitrateKbps), [
        128,
        null,
        320,
      ]);

      for (final (cursor, bitrate) in [(2, 192), (3, null)]) {
        await db.applyLibrary({
          'cursor': cursor,
          'tracks': [
            {...records.last, 'bitrate_kbps': bitrate, 'revision': cursor},
          ],
        });
        final updated = (await db.get('track', 'known'))!;
        expect(updated['bitrate_kbps'], bitrate);
        expect(Track.fromJson(updated).bitrateKbps, bitrate);
        expect(Track.fromJson(updated).estimatedBitrateKbps, 320);
        expect(await db.get('track', 'legacy'), records.first);
        expect(await db.cursor, cursor);
      }
    },
  );

  final malformedRecords = <String, (String, Map<String, dynamic>)>{
    'track title': ('track', {'title': 42}),
    'track artist': ('track', {'artist': []}),
    'track duration': ('track', {'duration_ms': 'invalid'}),
    'track bitrate': ('track', {'bitrate_kbps': '320'}),
    'playlist name': ('playlist', {'name': 42}),
    'playlist revision': ('playlist', {'revision': 'invalid'}),
    'playlist entry id': (
      'playlist',
      {
        'entries': [
          {'id': 42, 'track_id': 'a'},
        ],
      },
    ),
    'playlist entry track id': (
      'playlist',
      {
        'entries': [
          {'id': 'entry', 'track_id': 42},
        ],
      },
    ),
  };
  for (final reset in [false, true]) {
    for (final malformed in malformedRecords.entries) {
      // Field validation is shared by resets and deltas. Keep reset rollback
      // representatives for both models, not a second copy of every field.
      if (reset &&
          malformed.key != 'track title' &&
          malformed.key != 'playlist entry track id') {
        continue;
      }
      test(
        'invalid ${malformed.key} rolls back records, pins and cursor (reset=$reset)',
        () async {
          final track = const Track(id: 'a', title: 'Original').toJson();
          final playlist = const Playlist(
            id: 'p',
            name: 'Original',
            entries: [PlaylistEntry(id: 'entry', trackId: 'a')],
          ).toJson();
          await db.applyLibrary({
            'cursor': 1,
            'tracks': [track],
            'playlists': [playlist],
          });
          await db.put('pin', 'track:a', {'type': 'track', 'id': 'a'});
          await db.put('pin', 'historical', {'type': 'track', 'id': 'missing'});
          final (kind, invalidFields) = malformed.value;
          final tracks = [
            {...track, 'title': 'Updated'},
            const Track(id: 'new', title: 'New').toJson(),
          ];
          final playlists = [
            {...playlist, 'name': 'Updated'},
            const Playlist(id: 'new', name: 'New').toJson(),
          ];
          (kind == 'track' ? tracks : playlists).add({
            ...(kind == 'track' ? track : playlist),
            'id': 'bad',
            ...invalidFields,
          });
          await expectLater(
            db.applyLibrary({
              'cursor': 2,
              'reset': reset,
              'tracks': tracks,
              'playlists': playlists,
              'deleted_track_ids': ['a'],
              'deleted_playlist_ids': ['p'],
            }),
            throwsA(isA<TypeError>()),
          );
          expect(await db.cursor, 1);
          expect(await db.list('track'), [track]);
          expect(await db.list('playlist'), [playlist]);
          expect(await db.get('pin', 'track:a'), {'type': 'track', 'id': 'a'});
          expect(await db.get('pin', 'historical'), {
            'type': 'track',
            'id': 'missing',
          });
        },
      );
    }
  }
  test('invalid cursor rolls back library records', () async {
    final track = const Track(id: 'a', title: 'Original').toJson();
    await db.applyLibrary({
      'cursor': 1,
      'tracks': [track],
    });
    await expectLater(
      db.applyLibrary({
        'cursor': 'invalid',
        'reset': true,
        'tracks': [const Track(id: 'new', title: 'New').toJson()],
      }),
      throwsA(isA<TypeError>()),
    );
    expect(await db.cursor, 1);
    expect(await db.list('track'), [track]);
  });
  test('model validation preserves forward-compatible JSON fields', () async {
    final track = {
      ...const Track(id: 'a', title: 'A').toJson(),
      'future_track_field': {'enabled': true},
    };
    final playlist = {
      ...const Playlist(id: 'p', name: 'P').toJson(),
      'entries': [
        {'id': 'entry', 'track_id': 'a', 'future_entry_field': 42},
      ],
      'future_playlist_field': 'value',
    };
    await db.applyLibrary({
      'cursor': 1,
      'tracks': [track],
      'playlists': [playlist],
    });
    expect(await db.cursor, 1);
    expect(await db.list('track'), [track]);
    expect(await db.list('playlist'), [playlist]);
  });
}
