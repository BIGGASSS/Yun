import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/transfer_service.dart';

void main() {
  late CacheDatabase db;
  setUp(() => db = CacheDatabase.memory());
  tearDown(() => db.close());
  test(
    'cursor snapshots are atomic and preserve files, pins, and events',
    () async {
      await db.put('event', 'event', {'id': 'event'});
      await db.put('file', 'old', {'id': 'old', 'path': 'file'});
      await db.put('pin', 'pin', {'type': 'track', 'id': 'old'});
      await db.applyLibrary({
        'cursor': 4,
        'reset': true,
        'tracks': [const Track(id: 'old', title: 'old').toJson()],
        'playlists': [],
      });
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
      expect(await db.get('pin', 'pin'), isNotNull);
    },
  );
  test(
    'incremental tombstones remove library records, not delayed events',
    () async {
      await db.applyLibrary({
        'cursor': 1,
        'reset': true,
        'tracks': [const Track(id: 'a', title: 'A').toJson()],
        'playlists': [],
      });
      await db.put('event', 'event', {'id': 'event', 'track_id': 'a'});
      await db.applyLibrary({
        'cursor': 2,
        'reset': false,
        'deleted_track_ids': ['a'],
        'tracks': [],
        'playlists': [],
      });
      expect(await db.list('track'), isEmpty);
      expect(await db.list('event'), hasLength(1));
      await db.acknowledgeEvents(['other']);
      expect(await db.list('event'), hasLength(1));
      await db.acknowledgeEvents(['event']);
      expect(await db.list('event'), isEmpty);
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
      for (final kind in ['file', 'pin', 'event', 'upload', 'download']) {
        await db.put(kind, 'local', {'id': 'local'});
      }
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
      for (final kind in ['file', 'pin', 'event', 'upload', 'download']) {
        expect(await db.get(kind, 'local'), {'id': 'local'});
      }
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
      },
    );
  }

  test('bad snapshot rolls back cursor and track updates', () async {
    await db.applyLibrary({
      'cursor': 1,
      'reset': true,
      'tracks': [const Track(id: 'a', title: 'A').toJson()],
    });
    await expectLater(
      db.applyLibrary({
        'cursor': 2,
        'reset': true,
        'tracks': [
          {'title': 'invalid missing id'},
        ],
      }),
      throwsA(isA<TypeError>()),
    );
    expect(await db.cursor, 1);
    expect((await db.list('track')).single['id'], 'a');
  });
  final malformedRecords = <String, (String, Map<String, dynamic>)>{
    'track title': ('track', {'title': 42}),
    'track artist': ('track', {'artist': []}),
    'track duration': ('track', {'duration_ms': 'invalid'}),
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
      test(
        'invalid ${malformed.key} rolls back records and cursor (reset=$reset)',
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
  test(
    'overlapping pins reference one file and repeated entries count once',
    () {
      const tracks = [
        Track(id: 'a', title: 'A', album: 'Album', artist: 'Artist'),
        Track(id: 'b', title: 'B', album: 'Album', artist: 'Artist'),
      ];
      const playlists = [
        Playlist(
          id: 'p',
          name: 'P',
          entries: [
            PlaylistEntry(id: '1', trackId: 'a'),
            PlaylistEntry(id: '2', trackId: 'a'),
            PlaylistEntry(id: '3', trackId: 'missing'),
          ],
        ),
      ];
      final pins = [
        const PinSelection('track', 'a'),
        PinSelection('album', albumPinId('Album', 'Artist')),
        const PinSelection('playlist', 'p'),
      ];
      expect(pinReferences(pins, tracks, playlists), {'a': 3, 'b': 1});
      expect(pinReferences(pins.skip(1).toList(), tracks, playlists), {
        'a': 2,
        'b': 1,
      });
      expect(pinReferences([], tracks, playlists), isEmpty);
    },
  );
}
