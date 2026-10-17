import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../services/data_directory_store.dart';

/// Device-local storage selection. Await [open] BEFORE opening any account DB,
/// and give AppController Directory(currentPath) as its storageDirectory.
/// Changes only save a pending selection: migration happens on the next open.
///
/// Requires exclusive access to the managed trees during startup (including no
/// second app process). Filesystem work is asynchronous; SQLite work runs in an
/// isolate. Only accounts/ and artwork/ are migrated; reserved .yun-data-* files
/// track root identity and recovery. Unrelated destination files and the
/// platform's preference files are never migrated. The standalone configuration
/// stays in system application support, regardless of the selected data root.
/// The default store flushes and atomically replaces that configuration before
/// source cleanup. Process kills are recoverable, but portable directory fsync
/// (and thus a full power-loss transaction) is not promised. A crash before
/// journaling can leave a tiny unreferenced stage; copying has not started yet.
class DataDirectoryController extends ChangeNotifier {
  DataDirectoryController._(this._store, this._config, this.defaultPath);

  final DataDirectoryStore _store;
  _Configuration _config;
  final String defaultPath;
  String get currentPath => _config.active;
  String? get pendingPath => _config.pending;
  bool get restartRequired => pendingPath != null;
  bool get isSaving => _operations != 0;
  String? get error => _error;
  String? _error;
  int _operations = 0;
  bool _disposed = false;
  Future<void> _tail = Future.value();

  /// A missing/replaced recorded root or malformed configuration throws, without
  /// creating a replacement root. First launch durably records a root identity
  /// before returning control to account storage. Legacy configurations can be
  /// adopted only with an existing identity or nonempty managed data: an empty
  /// unmarked mountpoint cannot be distinguished from a disconnected disk.
  /// Migration failures instead retain the durable selection/pending change and
  /// expose [error], without making [flush] block shutdown.
  static Future<DataDirectoryController> open({
    Future<Directory> Function()? defaultDirectory,
    DataDirectoryStore? store,
  }) async {
    store ??= FileDataDirectoryStore();
    final saved = await store.read();
    final config = saved == null ? null : _Configuration.decode(saved);
    final directory =
        await (defaultDirectory ?? getApplicationSupportDirectory)();
    if (!p.isAbsolute(directory.path)) {
      throw const FormatException('Default data directory must be absolute');
    }
    // Only a first-ever launch may create its active root. Never recreate a
    // recorded source: a disconnected disk must not look like an empty library.
    if (config == null) await directory.create(recursive: true);
    final defaultPath = await directory.exists()
        ? p.normalize(await directory.resolveSymbolicLinks())
        : p.normalize(directory.path);
    final controller = DataDirectoryController._(
      store,
      config ?? _Configuration(defaultPath, null),
      defaultPath,
    );
    await _checkRoot(controller.currentPath);
    if (controller._config.identity == null) {
      var identity = await _readRootIdentity(controller.currentPath);
      if (identity == null) {
        if (config != null && !await _hasManagedData(controller.currentPath)) {
          throw FileSystemException(
            'Cannot identify an empty recorded data directory',
            controller.currentPath,
          );
        }
        identity = await _initializeRootIdentity(controller.currentPath);
      }
      // Marker first, configuration second, account storage last. If this write
      // fails/crashes, retry adopts the already-atomically-installed marker.
      await controller._persist(
        _Configuration(
          controller.currentPath,
          identity,
          pending: controller.pendingPath,
          journal: controller._config.journal,
        ),
      );
    } else {
      await _checkIdentity(
        controller.currentPath,
        controller._config.identity!,
      );
    }
    try {
      final journal = controller._config.journal;
      if (journal != null) {
        if (controller.currentPath == journal.target) {
          await controller._finishCommitted(journal);
        } else {
          await _rollback(journal);
          await controller._persist(
            _Configuration(
              controller.currentPath,
              controller._config.identity,
              pending: controller.pendingPath,
            ),
          );
        }
      }
      if (controller.pendingPath != null) await controller._migrate();
    } catch (e) {
      // Startup work has already left a durable pending selection/journal for
      // retry. Report it without latching a failed *selection write* in flush:
      // the user must be able to quit without first cancelling a migration.
      controller._error = e.toString();
    }
    return controller;
  }

  /// Select an existing, writable absolute directory. Same-root aliases are a
  /// no-op (they do not cancel a different pending change). Throws on failure;
  /// failed writes never change the observable durable selection.
  Future<void> changeDirectory(String path) => _enqueue(() => _select(path));

  /// Select the platform default, or cancel a pending move away from it.
  Future<void> useDefaultDirectory() => _enqueue(() async {
    if (p.equals(currentPath, defaultPath)) {
      await _cancel();
    } else {
      await Directory(defaultPath).create(recursive: true);
      await _select(defaultPath);
    }
  });

  Future<void> cancelChange() => _enqueue(_cancel);

  /// Wait for all queued edits, including edits enqueued while waiting.
  /// Rejected selections leave the durable configuration unchanged and report
  /// errors to their caller; they must not trap the user in the running app.
  Future<void> flush() async {
    Future<void> tail;
    do {
      tail = _tail;
      await tail;
    } while (!identical(tail, _tail));
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    if (_disposed) return Future.error(StateError('Controller is disposed'));
    _operations++;
    final result = _tail.then((_) async {
      try {
        await operation();
        _error = null;
      } catch (e) {
        _error = e.toString();
        rethrow;
      } finally {
        _operations--;
        _notify();
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _notify();
    return result;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _persist(_Configuration next) async {
    await _store.write(next.encode());
    _config = next;
  }

  Future<void> _select(String path) async {
    final selected = await _selection(path, currentPath);
    if (p.equals(selected, currentPath) || selected == pendingPath) return;
    // Journal recovery, like migration, belongs exclusively to open(). Even
    // cleanup of ownership markers must not touch a running account tree.
    await _persist(
      _Configuration(
        currentPath,
        _config.identity,
        pending: selected,
        journal: _config.journal,
      ),
    );
  }

  Future<void> _cancel() async {
    if (pendingPath != null) {
      await _persist(
        _Configuration(currentPath, _config.identity, journal: _config.journal),
      );
    }
  }

  Future<void> _migrate() async {
    final source = currentPath;
    final sourceIdentity = _config.identity!;
    await _checkIdentity(source, sourceIdentity);
    final target = await _selection(pendingPath!, source);
    if (p.equals(source, target)) {
      await _persist(_Configuration(source, sourceIdentity));
      return;
    }
    final names = <String>[];
    for (final name in _managed) {
      final type = await _type(p.join(source, name));
      if (type == FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.directory) {
        throw FileSystemException('Managed source must be a directory', name);
      }
      names.add(name);
    }
    final targetIdentity = await _initializeRootIdentity(target);
    final stage = await Directory(target).createTemp(_stagePrefix);
    final journal = _Journal(
      source,
      target,
      p.basename(stage.path),
      names,
      sourceIdentity: sourceIdentity,
      targetIdentity: targetIdentity,
    );
    try {
      await File(p.join(stage.path, _owner))
          .writeAsString(journal.owner, flush: true);
      // Journal is durable before copying or installing ANY managed directory.
      await _persist(
        _Configuration(
          source,
          sourceIdentity,
          pending: target,
          journal: journal,
        ),
      );
      final manifest = <Map<String, Object>>[];
      for (final name in names) {
        await _copyTree(source, stage.path, name, manifest);
        await File(p.join(stage.path, name, _owner))
            .writeAsString(journal.owner, flush: true);
      }
      // A copied WAL is opened with its DB in isolation; checkpointing here
      // retains committed WAL contents without ever opening the source DB.
      final stagePath = stage.path;
      final retained = await Isolate.run(
        () => _rebaseDatabases(stagePath, source, target),
      );
      // Even a legacy external upload inside the managed tree is not ours to
      // delete. Its original path remains valid after the switch.
      manifest.removeWhere((entry) => retained.contains(entry['path']));
      await File(p.join(stage.path, _manifest)).writeAsString(
        await Isolate.run(() => jsonEncode(manifest)),
        flush: true,
      );
      for (final name in names) {
        final installed = p.join(target, name);
        if (await _type(installed) != FileSystemEntityType.notFound) {
          throw FileSystemException(
            'Destination already contains $name',
            target,
          );
        }
        await Directory(p.join(stage.path, name)).rename(installed);
      }
      await _checkIdentity(source, sourceIdentity);
      await _checkIdentity(target, targetIdentity);
      // The only commit point. The source is still entirely untouched.
      await _persist(_Configuration(target, targetIdentity, journal: journal));
    } catch (_) {
      await _rollback(journal);
      // Keeping an obsolete journal is safe if even this config write fails;
      // recovery is idempotent and will not remove unmarked user directories.
      if (_config.journal != null) {
        try {
          await _persist(
            _Configuration(source, sourceIdentity, pending: target),
          );
        } catch (_) {}
      }
      rethrow;
    }
    // Cleanup failure cannot undo a durable switch. Retry via the saved journal
    // next startup, before any pending subsequent migration.
    await _finishCommitted(journal);
  }

  Future<void> _finishCommitted(_Journal journal) async {
    await _cleanupCommitted(journal);
    await _persist(
      _Configuration(currentPath, _config.identity, pending: pendingPath),
    );
  }
}

const _managed = ['accounts', 'artwork'];
const _stagePrefix = '.yun-data-migration-';
const _owner = '.yun-data-owner';
const _rootMarker = '.yun-data-root';
const _quarantinePrefix = '.rollback-';
const _manifest = 'source-manifest.json';

class _Configuration {
  const _Configuration(
    this.active,
    this.identity, {
    this.pending,
    this.journal,
  });
  final String active;
  final String? identity;
  final String? pending;
  final _Journal? journal;

  String encode() => jsonEncode({
    'version': 1,
    'active': active,
    if (identity != null) 'activeIdentity': identity,
    if (pending != null) 'pending': pending,
    if (journal != null) 'migration': journal!.toJson(),
  });

  static _Configuration decode(String saved) {
    try {
      final json = jsonDecode(saved) as Map<String, dynamic>;
      final active = json['active'] as String;
      final identity = json['activeIdentity'] as String?;
      final pending = json['pending'] as String?;
      if (json['version'] != 1 ||
          !_absolute(active) ||
          p.normalize(active) != active ||
          (json.containsKey('activeIdentity') && !_validIdentity(identity))) {
        throw const FormatException();
      }
      final journal = json['migration'] == null
          ? null
          : _Journal.fromJson(json['migration'] as Map<String, dynamic>);
      // Pending edits may replace/cancel a selection after failed recovery;
      // ownership of the older interrupted operation remains journaled.
      if (journal != null) {
        if (active != journal.source && active != journal.target) {
          throw const FormatException();
        }
        final journalIdentity = active == journal.source
            ? journal.sourceIdentity
            : journal.targetIdentity;
        if (journalIdentity != null && identity != journalIdentity) {
          throw const FormatException();
        }
      }
      return _Configuration(
        active,
        identity,
        pending: pending,
        journal: journal,
      );
    } catch (_) {
      throw const FormatException('Invalid saved data directory configuration');
    }
  }
}

class _Journal {
  const _Journal(
    this.source,
    this.target,
    this.stage,
    this.names, {
    this.sourceIdentity,
    this.targetIdentity,
  });
  final String source, target, stage;
  final String? sourceIdentity, targetIdentity;
  final List<String> names;
  String get stagePath => p.join(target, stage);
  String get owner => jsonEncode(toJson());
  Map<String, Object> toJson() => {
    'source': source,
    'target': target,
    'stage': stage,
    'names': names,
    'sourceIdentity': ?sourceIdentity,
    'targetIdentity': ?targetIdentity,
  };

  factory _Journal.fromJson(Map<String, dynamic> json) {
    final source = json['source'] as String;
    final target = json['target'] as String;
    final stage = json['stage'] as String;
    final names = (json['names'] as List).cast<String>();
    final sourceIdentity = json['sourceIdentity'] as String?;
    final targetIdentity = json['targetIdentity'] as String?;
    if ((json.containsKey('sourceIdentity') &&
            !_validIdentity(sourceIdentity)) ||
        (json.containsKey('targetIdentity') &&
            !_validIdentity(targetIdentity)) ||
        !_absolute(source) ||
        !_absolute(target) ||
        p.normalize(source) != source ||
        p.normalize(target) != target ||
        _overlap(source, target) ||
        !stage.startsWith(_stagePrefix) ||
        p.basename(stage) != stage ||
        names.toSet().length != names.length ||
        names.any((name) => !_managed.contains(name))) {
      throw const FormatException('Invalid migration journal');
    }
    return _Journal(
      source,
      target,
      stage,
      names,
      sourceIdentity: sourceIdentity,
      targetIdentity: targetIdentity,
    );
  }
}

bool _absolute(String path) =>
    path.isNotEmpty && !path.contains('\u0000') && p.isAbsolute(path);
bool _overlap(String a, String b) =>
    p.equals(a, b) || p.isWithin(a, b) || p.isWithin(b, a);
Future<FileSystemEntityType> _type(String path) =>
    FileSystemEntity.type(path, followLinks: false);

/// Check every component, not just the final entry (including junctions that
/// resolve to a different canonical path). Default provider paths are resolved
/// once before this check, since e.g. macOS /var can itself be an alias.
Future<void> _checkRoot(String path) async {
  if (!_absolute(path)) {
    throw const FormatException('Data directory must be absolute');
  }
  var component = p.normalize(path);
  while (true) {
    if (await _type(component) != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Directory is missing or contains a symlink',
        component,
      );
    }
    final parent = p.dirname(component);
    if (parent == component) break;
    component = parent;
  }
  if (!p.equals(
    p.normalize(await Directory(path).resolveSymbolicLinks()),
    p.normalize(path),
  )) {
    throw FileSystemException('Directory contains an unsafe alias', path);
  }
}

bool _validIdentity(String? value) =>
    value != null &&
    value.length == 36 &&
    RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(value);

Future<String?> _readRootIdentity(String root) async {
  final path = p.join(root, _rootMarker);
  final type = await _type(path);
  if (type == FileSystemEntityType.notFound) return null;
  if (type == FileSystemEntityType.file) {
    final identity = await File(path).readAsString();
    if (_validIdentity(identity)) return identity;
  }
  throw FileSystemException('Invalid data directory identity marker', path);
}

Future<void> _checkIdentity(String root, String identity) async {
  await _checkRoot(root);
  if (await _readRootIdentity(root) != identity) {
    throw FileSystemException(
      'Data directory identity is missing or changed',
      root,
    );
  }
}

Future<String> _initializeRootIdentity(String root) async {
  await _checkRoot(root);
  final existing = await _readRootIdentity(root);
  if (existing != null) return existing;
  final identity = const Uuid().v4();
  final temporary = File(p.join(root, '$_rootMarker-$identity.tmp'));
  try {
    // An interrupted write may leave an unreferenced reserved temp file, never
    // a partial marker that a later startup might mistake for an identity.
    await temporary.writeAsString(identity, flush: true);
    await temporary.rename(p.join(root, _rootMarker));
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
  return identity;
}

Future<bool> _hasManagedData(String root) async {
  for (final name in _managed) {
    final path = p.join(root, name);
    if (await _type(path) == FileSystemEntityType.directory) {
      await _checkRoot(path);
      if (!await Directory(path).list(followLinks: false).isEmpty) return true;
    }
  }
  return false;
}

Future<String> _selection(String path, String source) async {
  if (!_absolute(path)) {
    throw const FormatException('Choose an absolute directory path');
  }
  final normalized = p.normalize(path);
  // Resolve aliases to the running root as no-ops, but never migrate through
  // symlinks to some other directory.
  final selected = p.normalize(
    await Directory(normalized).resolveSymbolicLinks(),
  );
  if (p.equals(selected, source)) return source;
  await _checkRoot(normalized);
  if (_overlap(source, selected)) {
    throw const FormatException(
      'Source and destination directories must not overlap',
    );
  }
  for (final name in _managed) {
    if (await _type(p.join(selected, name)) != FileSystemEntityType.notFound) {
      throw FileSystemException('Destination already contains $name', selected);
    }
  }
  final probe = await Directory(selected).createTemp('.yun-write-probe-');
  try {
    await File(p.join(probe.path, 'probe')).writeAsBytes([1], flush: true);
  } finally {
    await probe.delete(recursive: true);
  }
  return selected;
}

Future<void> _copyTree(
  String source,
  String stage,
  String relative,
  List<Map<String, Object>> manifest,
) async {
  final from = p.join(source, relative);
  final to = p.join(stage, relative);
  final type = await _type(from);
  if (p.basename(relative) == _owner) {
    throw FileSystemException('Reserved migration marker in source', from);
  }
  if (type == FileSystemEntityType.directory) {
    // Also reject directory junctions/reparse points reported as directories.
    await _checkRoot(from);
    await Directory(to).create();
    manifest.add({'path': relative, 'directory': true});
    await for (final entry in Directory(from).list(followLinks: false)) {
      await _copyTree(
        source,
        stage,
        p.join(relative, p.basename(entry.path)),
        manifest,
      );
    }
  } else if (type == FileSystemEntityType.file) {
    final stat = await File(from).stat();
    final copy = await File(from).copy(to);
    final handle = await copy.open(mode: FileMode.append);
    try {
      await handle.flush();
    } finally {
      await handle.close();
    }
    // Upload validation compares modified_at_ms, not just byte length.
    await copy.setLastModified(stat.modified);
    final copiedStat = await copy.stat();
    if (copiedStat.size != stat.size ||
        copiedStat.modified.millisecondsSinceEpoch !=
            stat.modified.millisecondsSinceEpoch) {
      throw FileSystemException(
        'Destination cannot preserve file metadata',
        to,
      );
    }
    final after = await File(from).stat();
    if (stat.size != after.size || stat.modified != after.modified) {
      throw FileSystemException('Source changed during migration', from);
    }
    manifest.add({
      'path': relative,
      'size': stat.size,
      'modified': stat.modified.microsecondsSinceEpoch,
    });
  } else {
    throw FileSystemException(
      'Symlinks and special files cannot be migrated',
      from,
    );
  }
}

Set<String> _rebaseDatabases(String stage, String source, String target) {
  final retained = <String>{};
  final accounts = Directory(p.join(stage, 'accounts'));
  if (!accounts.existsSync()) return retained;
  for (final file in accounts.listSync(recursive: true, followLinks: false)) {
    if (file is! File || p.basename(file.path) != 'cache.sqlite') continue;
    final db = sqlite3.open(file.path, mode: OpenMode.readWrite);
    try {
      if (db
          .select('PRAGMA quick_check')
          .any((row) => row.values.first != 'ok')) {
        throw FileSystemException('Invalid account database', file.path);
      }
      db.execute('BEGIN IMMEDIATE');
      try {
        final update = db.prepare(
          'UPDATE documents SET body=? WHERE kind=? AND id=?',
        );
        try {
          for (final row in db.select(
            "SELECT kind,id,body FROM documents WHERE kind IN ('file','upload')",
          )) {
            final body =
                jsonDecode(row['body'] as String) as Map<String, dynamic>;
            final kind = row['kind'] as String;
            final key = kind == 'file' ? 'path' : 'local_path';
            final old = body[key];
            if (old is! String) continue;
            final relative = _managedRelative(source, old);
            if (relative == null) continue;
            if (kind == 'upload' && body['owned_source'] != true) {
              retained.add(relative);
              continue;
            }
            body[key] = p.join(target, relative);
            update.execute([jsonEncode(body), kind, row['id']]);
          }
        } finally {
          update.close();
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
      db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      db.execute('PRAGMA journal_mode=DELETE');
    } finally {
      db.close();
    }
  }
  return retained;
}

String? _managedRelative(String source, String path) {
  if (!_absolute(path)) return null;
  var normalized = p.normalize(path);
  bool within() =>
      _managed.any((name) => p.isWithin(p.join(source, name), normalized));
  if (!within()) {
    // Older app versions may have stored a path_provider alias (e.g. /var
    // rather than /private/var). Only resolve existing files, never guess.
    try {
      normalized = File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return null;
    }
  }
  return within() ? p.relative(normalized, from: source) : null;
}

Future<bool> _owned(String path, _Journal journal) async {
  if (await _type(path) != FileSystemEntityType.directory) return false;
  final marker = p.join(path, _owner);
  return await _type(marker) == FileSystemEntityType.file &&
      await File(marker).readAsString() == journal.owner;
}

Future<void> _checkJournalRoot(String root, String? identity) =>
    identity == null ? _checkRoot(root) : _checkIdentity(root, identity);

Future<void> _rollback(_Journal journal) async {
  // Failure MUST propagate: otherwise callers discard the only recovery journal
  // while the offline/aliased target can still contain owned installed trees.
  try {
    await _checkJournalRoot(journal.target, journal.targetIdentity);
  } on FileSystemException catch (error) {
    throw FileSystemException(
      'Incomplete migration rollback: $error',
      journal.target,
    );
  }
  for (final name in journal.names) {
    final path = p.join(journal.target, name);
    if (!await _owned(path, journal)) continue;
    await _ensureOwnedStage(journal);
    final quarantine = p.join(journal.stagePath, '$_quarantinePrefix$name');
    // All stage contents belong to this operation. Its root owner remains even
    // if recursive deletion removes a nested/per-install owner before crashing.
    await _deleteEntry(quarantine);
    await Directory(path).rename(quarantine);
  }
  await _removeStage(journal);
}

Future<void> _ensureOwnedStage(_Journal journal) async {
  if (await _owned(journal.stagePath, journal)) return;
  await _removeStage(journal); // permits only a missing or empty unmarked stage
  final temporary = await Directory(journal.target).createTemp(_stagePrefix);
  await File(p.join(temporary.path, _owner))
      .writeAsString(journal.owner, flush: true);
  // Install an already marked directory so a crash cannot leave an unmarked,
  // partially populated quarantine. An unreferenced small temp is harmless.
  await temporary.rename(journal.stagePath);
}

Future<void> _deleteEntry(String path) async {
  final type = await _type(path);
  if (type == FileSystemEntityType.directory) {
    await Directory(path).delete(recursive: true);
  } else if (type == FileSystemEntityType.link) {
    await Link(path).delete();
  } else if (type != FileSystemEntityType.notFound) {
    await File(path).delete();
  }
}

Future<void> _removeStage(_Journal journal) async {
  final path = journal.stagePath;
  final type = await _type(path);
  if (type == FileSystemEntityType.notFound) return;
  if (await _owned(path, journal)) {
    await for (final entry in Directory(path).list(followLinks: false)) {
      if (p.basename(entry.path) != _owner) await _deleteEntry(entry.path);
    }
    // Never recursively delete the owning root: preserve evidence until every
    // child is gone. The journal lives outside this directory throughout.
    await File(p.join(path, _owner)).delete();
  } else if (type != FileSystemEntityType.directory ||
      !await Directory(path).list(followLinks: false).isEmpty) {
    throw FileSystemException(
      'Incomplete cleanup: staging directory is not owned',
      path,
    );
  }
  // A crash after removing the marker leaves only an empty directory. A retry
  // may safely remove that directory nonrecursively, never unmarked contents.
  await Directory(path).delete();
}

Future<void> _cleanupCommitted(_Journal journal) async {
  await _checkJournalRoot(journal.target, journal.targetIdentity);
  if (await _owned(journal.stagePath, journal)) {
    // Remove only copied source entries, never its root or unrelated preferences.
    // Preserve new/changed files if another writer violated startup exclusivity.
    try {
      await _checkJournalRoot(journal.source, journal.sourceIdentity);
      final entries = jsonDecode(
        await File(p.join(journal.stagePath, _manifest)).readAsString(),
      ) as List;
      for (final dynamic entry in entries.reversed) {
        final relative = entry['path'] as String;
        if (p.isAbsolute(relative) ||
            p.normalize(relative) != relative ||
            !_managed.contains(p.split(relative).first)) {
          continue;
        }
        final path = p.join(journal.source, relative);
        try {
          await _checkRoot(p.dirname(path));
          final type = await _type(path);
          if (entry['directory'] == true) {
            if (type == FileSystemEntityType.directory) {
              await Directory(path).delete();
            }
          } else if (type == FileSystemEntityType.file) {
            final stat = await File(path).stat();
            if (stat.size == entry['size'] &&
                stat.modified.microsecondsSinceEpoch == entry['modified']) {
              await File(path).delete();
            }
          }
        } on FileSystemException {
          // Missing, changed, or nonempty entries are deliberately retained.
        }
      }
    } on FileSystemException {
      // Source cleanup is best effort; a disconnected old disk is not fatal.
    }
  }
  for (final name in journal.names) {
    final path = p.join(journal.target, name);
    if (await _owned(path, journal)) await File(p.join(path, _owner)).delete();
  }
  await _removeStage(journal);
}
