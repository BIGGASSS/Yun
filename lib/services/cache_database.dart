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
  int get schemaVersion => 1;
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
    },
  );
  Future<void> put(String kind, String id, Map<String, dynamic> value) =>
      customStatement(
        'INSERT INTO documents(kind,id,body) VALUES(?,?,?) ON CONFLICT(kind,id) DO UPDATE SET body=excluded.body',
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
  Future<void> applyLibrary(Map<String, dynamic> response) =>
      transaction(() async {
        if (response['reset'] == true) {
          await customStatement(
            "DELETE FROM documents WHERE kind IN ('track','playlist')",
          );
        }
        for (final key in ['track', 'playlist']) {
          for (final dynamic value in response['${key}s'] as List? ?? []) {
            final j = Map<String, dynamic>.from(value as Map);
            await put(key, j['id'] as String, j);
          }
          for (final dynamic id
              in response['deleted_${key}_ids'] as List? ?? []) {
            await remove(key, id as String);
          }
        }
        await put('meta', 'cursor', {'value': response['cursor']});
      });
  Future<void> enqueueEvent(ListeningEvent event) =>
      put('event', event.id, event.toJson());
  Future<void> acknowledgeEvents(Iterable<String> ids) => transaction(() async {
    for (final id in ids) {
      await remove('event', id);
    }
  });
}
