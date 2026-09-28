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
