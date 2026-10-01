import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../models/models.dart';

/// A separate database file is opened for every normalized server/user pair.
/// JSON documents keep the cache forward-compatible without generated code.
class CacheDatabase extends GeneratedDatabase {
  CacheDatabase(File file) : super(NativeDatabase.createInBackground(file));
  CacheDatabase.memory() : super(NativeDatabase.memory());
  @override
  int get schemaVersion => 2;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await customStatement(
        'CREATE TABLE documents (kind TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(kind,id))',
      );
      await _createKindIndex();
    },
    onUpgrade: (_, from, _) async {
      if (from < 2) await _createKindIndex();
    },
  );

  // SQLite indexes implicitly end in rowid: a fixed kind can be walked in
  // insertion order without sorting the entire outbox before applying LIMIT.
  Future<void> _createKindIndex() =>
      customStatement('CREATE INDEX documents_kind_order ON documents(kind)');
  Future<void> put(String kind, String id, Map<String, dynamic> value) =>
      customStatement(
        'INSERT INTO documents(kind,id,body) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET body=excluded.body WHERE body<>excluded.body',
        [kind, id, jsonEncode(value)],
      );
  Future<void> remove(String kind, String id) => customStatement(
    'DELETE FROM documents WHERE kind=? AND id=?',
    [kind, id],
  );
  Future<List<Map<String, dynamic>>> list(String kind) async =>
      (await customSelect(
            'SELECT body FROM documents WHERE kind=? ORDER BY rowid',
            variables: [Variable.withString(kind)],
          ).get())
          .map(
            (r) => Map<String, dynamic>.from(
              jsonDecode(r.read<String>('body')) as Map,
            ),
          )
          .toList();

  /// Count without reading or decoding the durable outbox.
  Future<int> eventCount() async => (await customSelect(
    "SELECT COUNT(*) AS count FROM documents WHERE kind='event'",
  ).getSingle()).read<int>('count');

  /// Stable insertion order, bounded in SQL rather than after JSON decoding.
  Future<List<Map<String, dynamic>>> eventBatch({int limit = 500}) async {
    if (limit < 1 || limit > 500) throw RangeError.range(limit, 1, 500);
    final rows = await customSelect(
      "SELECT body FROM documents WHERE kind='event' ORDER BY rowid LIMIT ?",
      variables: [Variable.withInt(limit)],
    ).get();
    return rows
        .map(
          (r) => Map<String, dynamic>.from(
            jsonDecode(r.read<String>('body')) as Map,
          ),
        )
        .toList();
  }

  Future<Map<String, dynamic>?> get(String kind, String id) async {
    final rows = await customSelect(
      'SELECT body FROM documents WHERE kind=? AND id=?',
      variables: [Variable.withString(kind), Variable.withString(id)],
    ).get();
    return rows.isEmpty
        ? null
        : Map<String, dynamic>.from(
            jsonDecode(rows.first.read<String>('body')) as Map,
          );
  }

  Future<int?> get cursor async =>
      (await get('meta', 'cursor'))?['value'] as int?;

  Future<int> get deletionSequence async =>
      (await get('meta', 'deletion_sequence'))?['value'] as int? ?? 0;

  /// A lower-cursor authoritative reset starts a new, incomparable timeline.
  /// Capture this before sending a mutation, not when its response arrives.
  Future<int> get libraryEpoch async =>
      (await get('meta', 'library_epoch'))?['value'] as int? ?? 0;

  /// Mutation revisions share the library's global revision sequence. Compare
  /// inside the same transaction as the write: a sync may have committed while
  /// the HTTP response was in flight, including a tombstone for this ID.
  Future<bool> publishLibraryRecord(
    String kind,
    Map<String, dynamic> record, {
    required int expectedEpoch,
  }) => transaction(() async {
    if (expectedEpoch != await libraryEpoch) return false;
    final id = record['id'] as String;
    final revision = record['revision'] as int;
    final current = await get(kind, id);
    if (revision <= (await cursor ?? -1) ||
        revision <= (current?['revision'] as num? ?? -1) ||
        await get('deleted_$kind', id) != null) {
      return false;
    }
    await put(kind, id, record);
    return true;
  });

  /// DELETE responses have no revision. Keep a durable local barrier until a
  /// snapshot confirms absence; an older staged snapshot must not resurrect it.
  Future<bool> deleteLibraryRecord(
    String kind,
    String id, {
    required int expectedEpoch,
  }) => transaction(() async {
    if (expectedEpoch != await libraryEpoch) return false;
    final sequence = await deletionSequence + 1;
    await put('meta', 'deletion_sequence', {'value': sequence});
    await put('deleted_$kind', id, {'id': id, 'sequence': sequence});
    await remove(kind, id);
    return true;
  });

  /// [confirmedDeletionSequence] is captured before requesting this snapshot,
  /// so it cannot clear barriers created while the request was in flight.
  Future<void> applyLibrary(
    Map<String, dynamic> response, {
    int confirmedDeletionSequence = 0,
  }) => transaction(() async {
    final cursor = response['cursor'] as int;
    if (cursor < (await this.cursor ?? -1)) {
      if (response['reset'] != true) {
        throw const FormatException('Library cursor moved backwards');
      }
      // Revisions and deletion barriers from the old timeline are no longer
      // comparable. Replace them atomically, retaining local-only documents.
      await put('meta', 'library_epoch', {'value': await libraryEpoch + 1});
      await customStatement(
        "DELETE FROM documents WHERE kind IN ('track','playlist','deleted_track','deleted_playlist')",
      );
    }
    for (final key in ['track', 'playlist']) {
      final incomingIds = <String>{};
      for (final dynamic value in response['${key}s'] as List? ?? []) {
        final j = Map<String, dynamic>.from(value as Map);
        // Validate the complete model before committing its JSON and cursor.
        // Keep the original document so unknown fields survive caching.
        final id = key == 'track'
            ? Track.fromJson(j).id
            : Playlist.fromJson(j).id;
        incomingIds.add(id);
        final current = await get(key, id);
        if ((current?['revision'] as num? ?? -1) <=
                (j['revision'] as num? ?? 0) &&
            await get('deleted_$key', id) == null) {
          await put(key, id, j);
        }
      }
      if (response['reset'] == true) {
        // Keep mutations committed after this snapshot was taken.
        for (final current in await list(key)) {
          if (!incomingIds.contains(current['id']) &&
              (current['revision'] as num? ?? 0) <= cursor) {
            await remove(key, current['id'] as String);
          }
        }
        for (final deleted in await list('deleted_$key')) {
          if (!incomingIds.contains(deleted['id']) &&
              (deleted['sequence'] as int) <= confirmedDeletionSequence) {
            await remove('deleted_$key', deleted['id'] as String);
          }
        }
      }
      for (final dynamic id in response['deleted_${key}_ids'] as List? ?? []) {
        final current = await get(key, id as String);
        if ((current?['revision'] as num? ?? -1) <= cursor) {
          await remove(key, id);
        }
        final deleted = await get('deleted_$key', id);
        if (deleted != null &&
            (deleted['sequence'] as int) <= confirmedDeletionSequence) {
          await remove('deleted_$key', id);
        }
      }
    }
    await put('meta', 'cursor', {'value': cursor});
  });
  Future<void> enqueueEvent(ListeningEvent event) =>
      put('event', event.id, event.toJson());
  Future<void> acknowledgeEvents(Iterable<String> ids) => transaction(() async {
    for (final id in ids) {
      await remove('event', id);
    }
  });
}
