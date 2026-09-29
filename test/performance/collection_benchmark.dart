// Run explicitly: flutter test test/performance/collection_benchmark.dart
// Synthetic component benchmark, not device frame or disk-throughput timing.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';

import '../core/fakes.dart';

class CountingDatabase extends CacheDatabase {
  CountingDatabase() : super.memory();
  final writes = <String, int>{};
  @override
  Future<void> put(String kind, String id, Map<String, dynamic> value) {
    writes.update(kind, (n) => n + 1, ifAbsent: () => 1);
    return super.put(kind, id, value);
  }
}

double medianMs(int Function() action, int expected) {
  final timings = <double>[];
  for (var i = 0; i < 5; i++) {
    final sw = Stopwatch()..start();
    final result = action();
    sw.stop();
    expect(result, expected);
    if (i >= 2) timings.add(sw.elapsedMicroseconds / 1000);
  }
  timings.sort();
  return timings[1];
}

void main() {
  test('synthetic production controller scaling (not a frame benchmark)', () async {
    for (final n in [1000, 5000, 10000]) {
      final d = n ~/ 2;
      final root = await Directory.systemTemp.createTemp('yun-audit-');
      final audio = await File('${root.path}/fixture.audio').writeAsBytes([1]);
      final db = CountingDatabase();
      final credentials = MemoryCredentials();
      const account = Account(
        server: 'https://yun.test',
        userId: 'audit',
        username: 'audit',
      );
      await credentials.write(
        ApiClient.sessionKey,
        jsonEncode(
          const SessionCredentials(
            account: account,
            accessToken: 'unused',
            refreshToken: 'unused',
            expiresAt: 0,
          ).toJson(),
        ),
      );
      await db.transaction(() async {
        for (var i = 0; i < n; i++) {
          final track = Track(
            id: 't$i',
            title: 'Track ${i.toString().padLeft(5, '0')}',
          );
          await db.put('track', track.id, track.toJson());
          if (i < d) {
            await db.put('file', track.id, {
              'id': track.id,
              'path': audio.path,
              'sha256': '',
              'references': 1,
            });
            await db.put('pin', track.id, {'id': track.id, 'type': 'track'});
          }
        }
      });
      final app = AppController(
        api: ApiClient(credentials: credentials),
        storageDirectory: () async => root,
        databaseFactory: (_) => db,
        playbackEngine: FakeEngine(),
        enableSystemControls: false,
        automaticRefresh: false,
      );
      try {
        await app.initialize();
        final before = medianMs(
          () => app.tracks
              .where(
                (t) => Set<String>.of(app.downloadedTrackIds).contains(t.id),
              )
              .length,
          d,
        );
        final current = medianMs(
          () => app.tracks
              .where((t) => app.downloadedTrackIds.contains(t.id))
              .length,
          d,
        );
        final after = medianMs(() {
          final ids = app.downloadedTrackIds;
          return app.tracks.where((t) => ids.contains(t.id)).length;
        }, d);
        final ids = List.generate(1000, (i) => 't${n - 1 - i}');
        final lookup = medianMs(
          () => ids.where((id) => app.trackById(id) != null).length,
          ids.length,
        );
        final indexed = medianMs(() {
          final index = {for (final t in app.tracks) t.id: t};
          return ids.where((id) => index[id] != null).length;
        }, ids.length);
        stdout.writeln(
          'BENCH N=$n D=$d copy_per_track_ms=$before current_filter_ms=$current capture_once_ms=$after playlist_1000_lookup_ms=$lookup build_map_and_lookup_ms=$indexed',
        );
        // The initial pass establishes persistent status for seeded files.
        await app.retryDownloads();
        db.writes.clear();
        await app.retryDownloads();
        expect(db.writes, isEmpty);
        stdout.writeln(
          'BENCH unchanged_reconcile D=$d database_puts=${db.writes}',
        );
      } finally {
        await app.shutdown();
        app.dispose();
        await root.delete(recursive: true);
      }
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
