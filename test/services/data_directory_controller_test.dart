import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:yun/core/data_directory_controller.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/data_directory_store.dart';

class _MemoryStore implements DataDirectoryStore {
  String? value;
  Future<void> Function(Map<String, dynamic>)? beforeWrite;
  final writes = <Map<String, dynamic>>[];

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String next) async {
    final config = jsonDecode(next) as Map<String, dynamic>;
    writes.add(config);
    await beforeWrite?.call(config);
    value = next;
  }
}

/// Interrupt deletion after some children are gone, as a process crash could.
/// No production hooks are needed; all other directory operations are real IO.
final class _DeleteOverrides extends IOOverrides {
  _DeleteOverrides(this.beforeDelete);
  final Future<void> Function(String path, bool recursive) beforeDelete;

  @override
  Directory createDirectory(String path) =>
      _ObservedDirectory(super.createDirectory(path), beforeDelete);
}

class _ObservedDirectory implements Directory {
  _ObservedDirectory(this.delegate, this.beforeDelete);
  final Directory delegate;
  final Future<void> Function(String path, bool recursive) beforeDelete;

  @override
  String get path => delegate.path;
  @override
  Future<bool> exists() => delegate.exists();
  @override
  Future<String> resolveSymbolicLinks() => delegate.resolveSymbolicLinks();
  @override
  Future<Directory> create({bool recursive = false}) =>
      delegate.create(recursive: recursive);
  @override
  Future<Directory> createTemp([String? prefix]) => delegate.createTemp(prefix);
  @override
  Future<Directory> rename(String newPath) => delegate.rename(newPath);
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => delegate.list(recursive: recursive, followLinks: followLinks);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    await beforeDelete(path, recursive);
    return delegate.delete(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const rootMarker = '.yun-data-root';
  final throwsFileSystemException = throwsA(isA<FileSystemException>());
  late Directory sandbox, original, target;
  late _MemoryStore configurationStore;
  final controllers = <DataDirectoryController>[];

  Future<DataDirectoryController> open() async {
    final controller = await DataDirectoryController.open(
      store: configurationStore,
      defaultDirectory: () async => original,
    );
    controllers.add(controller);
    return controller;
  }

  Future<Directory> directory(String path) =>
      Directory(path).create(recursive: true);
  Future<File> file(String path, [String body = 'music']) async {
    await directory(p.dirname(path));
    return File(path).writeAsString(body, flush: true);
  }

  Map<String, dynamic> config() =>
      jsonDecode(configurationStore.value!) as Map<String, dynamic>;

  _MemoryStore interceptWrites() {
    configurationStore.writes.clear();
    return configurationStore;
  }

  Future<List<String>> targetEntries() => target
      .list()
      .map((entry) => p.basename(entry.path))
      .where((name) => name != rootMarker)
      .toList();

  Future<void> noStagingArtifacts() async {
    expect(
      await target.list().map((entry) => p.basename(entry.path)).toList(),
      isNot(contains(startsWith('.yun-data-migration-'))),
    );
  }

  setUp(() async {
    configurationStore = _MemoryStore();
    sandbox = await Directory.systemTemp.createTemp('yun-data-directory-test-');
    sandbox = Directory(await sandbox.resolveSymbolicLinks());
    original = await directory(p.join(sandbox.path, 'default'));
    target = await directory(p.join(sandbox.path, 'chosen'));
  });

  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
    }
    controllers.clear();
    await sandbox.delete(recursive: true);
  });

  test(
    'first launch creates default; selection is pending, never a live move',
    () async {
      await original.delete();
      final controller = await open();
      expect(await original.exists(), isTrue);
      expect(controller.currentPath, original.path);
      expect(controller.defaultPath, original.path);
      expect(controller.pendingPath, isNull);
      expect(controller.restartRequired, isFalse);
      expect(controller.isSaving, isFalse);
      expect(controller.error, isNull);
      expect(configurationStore.writes, hasLength(1));
      final identity = config()['activeIdentity'];
      expect(
        await File(p.join(original.path, rootMarker)).readAsString(),
        identity,
      );
      expect(config(), {
        'version': 1,
        'active': original.path,
        'activeIdentity': identity,
      });
      final audio = await file(
        p.join(original.path, 'accounts', 'one', 'audio', 't.audio'),
      );
      final changing = controller.changeDirectory(target.path);
      expect(controller.isSaving, isTrue);
      expect(controller.pendingPath, isNull);
      await changing;
      await controller.flush();
      expect(controller.currentPath, original.path);
      expect(controller.pendingPath, target.path);
      expect(controller.restartRequired, isTrue);
      expect(await audio.exists(), isTrue);
      expect(await target.list().toList(), isEmpty);
      expect(config(), {
        'version': 1,
        'active': original.path,
        'activeIdentity': identity,
        'pending': target.path,
      });
      final restarted = await open();
      expect(restarted.currentPath, target.path);
      expect(restarted.pendingPath, isNull);
      expect(restarted.error, isNull);
      expect(
        await File(p.join(target.path, 'accounts', 'one', 'audio', 't.audio'))
            .readAsString(),
        'music',
      );
      expect(await audio.exists(), isFalse);
      expect(await original.exists(), isTrue);
      await noStagingArtifacts();
    },
  );

  test('migrates every account, partial, spool, artwork; rewrites SQLite owned paths only', () async {
    final external = await file(p.join(sandbox.path, 'external.flac'));
    await file(
      p.join(original.path, 'shared_preferences.json'),
      'preferences stay here',
    );
    await file(p.join(target.path, 'personal.txt'), 'do not overwrite');
    final oldTime = DateTime.fromMillisecondsSinceEpoch(1700000123456);
    for (final account in ['one', 'two']) {
      final root = p.join(original.path, 'accounts', account);
      final audio = await file(p.join(root, 'audio', 't.audio'));
      await file(p.join(root, 'audio', 't.audio.part'), 'partial');
      final upload = await file(
        p.join(root, 'imports', 'job.source'),
        'upload',
      );
      await upload.setLastModified(oldTime);
      await file(
        p.join(root, 'imports', 'incomplete.source.part'),
        'upload partial',
      );
      final database = CacheDatabase(File(p.join(root, 'cache.sqlite')));
      try {
        await database.put('file', 't', {'path': audio.path, 'unknown': 42});
        await database.put('file', 'external', {'path': external.path});
        await database.put('file', 'unmanaged', {
          'path': p.join(original.path, 'shared_preferences.json'),
        });
        await database.put('upload', 'owned', {
          'local_path': upload.path,
          'owned_source': true,
          'modified_at_ms': oldTime.millisecondsSinceEpoch,
          'offset': 3,
        });
        await database.put('upload', 'external', {
          'local_path': external.path,
          'owned_source': false,
        });
        await database.put('upload', 'legacy-inside', {
          'local_path': upload.path,
        });
        await database.put('upload', 'outside-owned', {
          'local_path': external.path,
          'owned_source': true,
        });
        await database.put('pin', 'pin', {'type': 'track', 'id': 't'});
        await database.put('event', 'event', {
          'id': 'event',
          'listened_ms': 1500,
        });
        await database.put('download', 't', {'received_bytes': 123});
      } finally {
        await database.close();
      }
    }
    await file(
      p.join(original.path, 'artwork', 'hash', 'cover.image'),
      'artwork',
    );
    await (await open()).changeDirectory(target.path);
    final restarted = await open();
    expect(restarted.error, isNull);
    expect(restarted.currentPath, target.path);
    for (final account in ['one', 'two']) {
      final oldRoot = p.join(original.path, 'accounts', account);
      final root = p.join(target.path, 'accounts', account);
      final database = CacheDatabase(File(p.join(root, 'cache.sqlite')));
      try {
        expect(await database.get('file', 't'), {
          'path': p.join(root, 'audio', 't.audio'),
          'unknown': 42,
        });
        expect(
          (await database.get('file', 'external'))!['path'],
          external.path,
        );
        expect(
          (await database.get('file', 'unmanaged'))!['path'],
          p.join(original.path, 'shared_preferences.json'),
        );
        final upload = (await database.get('upload', 'owned'))!;
        expect(upload['local_path'], p.join(root, 'imports', 'job.source'));
        expect(upload['modified_at_ms'], oldTime.millisecondsSinceEpoch);
        expect(upload['offset'], 3);
        expect(
          (await File(
            upload['local_path'] as String,
          ).stat()).modified.millisecondsSinceEpoch,
          oldTime.millisecondsSinceEpoch,
        );
        expect(
          (await database.get('upload', 'external'))!['local_path'],
          external.path,
        );
        expect(
          (await database.get('upload', 'legacy-inside'))!['local_path'],
          p.join(oldRoot, 'imports', 'job.source'),
        );
        expect(
          (await database.get('upload', 'outside-owned'))!['local_path'],
          external.path,
        );
        expect(await database.list('pin'), [
          {'type': 'track', 'id': 't'},
        ]);
        expect(await database.eventCount(), 1);
        expect(await database.get('download', 't'), {'received_bytes': 123});
      } finally {
        await database.close();
      }
      expect(
        await File(p.join(root, 'audio', 't.audio.part')).readAsString(),
        'partial',
      );
      expect(
        await File(p.join(root, 'imports', 'incomplete.source.part'))
            .readAsString(),
        'upload partial',
      );
    }
    expect(
      await File(p.join(target.path, 'artwork', 'hash', 'cover.image'))
          .readAsString(),
      'artwork',
    );
    expect(
      await File(p.join(target.path, 'personal.txt')).readAsString(),
      'do not overwrite',
    );
    expect(
      await File(p.join(original.path, 'shared_preferences.json'))
          .readAsString(),
      'preferences stay here',
    );
    expect(
      await File(p.join(target.path, 'shared_preferences.json')).exists(),
      isFalse,
    );
    expect(await external.readAsString(), 'music');
    // Non-owned upload originals remain untouched even inside a managed tree.
    for (final account in ['one', 'two']) {
      final root = p.join(original.path, 'accounts', account);
      expect(
        await File(p.join(root, 'imports', 'job.source')).readAsString(),
        'upload',
      );
      expect(await File(p.join(root, 'cache.sqlite')).exists(), isFalse);
      expect(await Directory(p.join(root, 'audio')).exists(), isFalse);
    }
    expect(
      await original.list().map((e) => p.basename(e.path)).toList(),
      unorderedEquals([rootMarker, 'shared_preferences.json', 'accounts']),
    );
    await noStagingArtifacts();
  });

  test('copies committed SQLite WAL contents before rebasing', () async {
    final root = await directory(p.join(original.path, 'accounts', 'wal'));
    final path = p.join(root.path, 'cache.sqlite');
    final db = sqlite3.open(path);
    late List<int> main, wal;
    try {
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('PRAGMA wal_autocheckpoint=0');
      db.execute(
        'CREATE TABLE documents(kind TEXT, id TEXT, body TEXT, PRIMARY KEY(kind,id))',
      );
      db.execute('PRAGMA user_version=2');
      db.execute('INSERT INTO documents VALUES(?,?,?)', [
        'file',
        't',
        jsonEncode({'path': p.join(root.path, 'audio', 't.audio')}),
      ]);
      main = await File(path).readAsBytes();
      wal = await File('$path-wal').readAsBytes();
    } finally {
      db.close();
    }
    // Reconstruct the on-disk state of a process that exited without checkpoint.
    await File(path).writeAsBytes(main);
    await File('$path-wal').writeAsBytes(wal);
    await file(p.join(root.path, 'audio', 't.audio'));
    await (await open()).changeDirectory(target.path);
    final restarted = await open();
    expect(restarted.error, isNull);
    final copied = CacheDatabase(
      File(p.join(target.path, 'accounts', 'wal', 'cache.sqlite')),
    );
    try {
      expect(
        (await copied.get('file', 't'))!['path'],
        p.join(target.path, 'accounts', 'wal', 'audio', 't.audio'),
      );
    } finally {
      await copied.close();
    }
  });

  test('invalid, missing, nested and managed-collision directories do not change selection', () async {
    final controller = await open();
    final child = await directory(p.join(original.path, 'nested'));
    final notDirectory = await file(p.join(sandbox.path, 'file'));
    final saved = configurationStore.value;
    for (final path in [
      'relative',
      '',
      p.join(sandbox.path, 'missing'),
      child.path,
      sandbox.path,
      notDirectory.path,
    ]) {
      await expectLater(controller.changeDirectory(path), throwsA(anything));
      expect(controller.currentPath, original.path);
      expect(controller.pendingPath, isNull);
      expect(controller.error, isNotNull);
      expect(configurationStore.value, saved);
    }
    for (final name in ['accounts', 'artwork']) {
      final collision = await directory(p.join(target.path, name));
      await expectLater(
        controller.changeDirectory(target.path),
        throwsFileSystemException,
      );
      expect(await collision.exists(), isTrue);
      await collision.delete();
      final collisionFile = await file(p.join(target.path, name), 'user file');
      await expectLater(
        controller.changeDirectory(target.path),
        throwsFileSystemException,
      );
      expect(await collisionFile.readAsString(), 'user file');
      await collisionFile.delete();
    }
    await controller.flush(); // invalid edits must not trap application exit
    await controller.changeDirectory(target.path);
    expect(controller.error, isNull);
    expect(controller.pendingPath, target.path);
  });

  test(
    'probes actual writes and leaves no artifacts in a read-only directory',
    () async {
      if (!Platform.isLinux) return;
      final controller = await open();
      await expectLater(
        controller.changeDirectory('/proc'),
        throwsFileSystemException,
      );
      expect(controller.pendingPath, isNull);
    },
  );

  test(
    'same directory and aliases are no-ops; other symlinks are unsafe',
    () async {
      if (Platform.isWindows) return;
      final controller = await open();
      final saved = configurationStore.value;
      final alias = Link(p.join(sandbox.path, 'alias'));
      await alias.create(original.path);
      await controller.changeDirectory(p.join(original.path, '.'));
      await controller.changeDirectory(alias.path);
      expect(configurationStore.value, saved);
      await controller.changeDirectory(target.path);
      await controller.changeDirectory(alias.path);
      expect(controller.pendingPath, target.path);
      final otherAlias = Link(p.join(sandbox.path, 'other-alias'));
      await otherAlias.create(target.path);
      await expectLater(
        controller.changeDirectory(otherAlias.path),
        throwsFileSystemException,
      );
      final child = await directory(p.join(target.path, 'child'));
      await expectLater(
        controller.changeDirectory(
          p.join(otherAlias.path, p.basename(child.path)),
        ),
        throwsFileSystemException,
      );
    },
  );

  test(
    'cancel and default reset are durable without moving the running root',
    () async {
      await file(p.join(original.path, 'accounts', 'one', 'audio', 't.audio'));
      final controller = await open();
      await controller.changeDirectory(target.path);
      await controller.cancelChange();
      expect(controller.restartRequired, isFalse);
      expect((await open()).currentPath, original.path);
      await controller.changeDirectory(target.path);
      await controller.useDefaultDirectory();
      expect(controller.pendingPath, isNull);
      await controller.changeDirectory(target.path);
      final moved = await open();
      expect(moved.currentPath, target.path);
      await moved.useDefaultDirectory();
      expect(moved.currentPath, target.path);
      expect(moved.pendingPath, original.path);
      expect(
        await Directory(p.join(original.path, 'accounts')).exists(),
        isFalse,
      );
      final restored = await open();
      expect(restored.error, isNull);
      expect(restored.currentPath, original.path);
      expect(restored.pendingPath, isNull);
      expect(
        await File(p.join(original.path, 'accounts', 'one', 'audio', 't.audio'))
            .exists(),
        isTrue,
      );
      expect(
        await Directory(p.join(target.path, 'accounts')).exists(),
        isFalse,
      );
    },
  );

  test('a corrupt database rolls back completely, retains pending and supports cancel/change', () async {
    final source = await file(
      p.join(original.path, 'accounts', 'bad', 'cache.sqlite'),
      'not a database',
    );
    await file(p.join(original.path, 'artwork', 'cover.image'));
    final controller = await open();
    await controller.changeDirectory(target.path);
    final failed = await open();
    expect(failed.currentPath, original.path);
    expect(failed.pendingPath, target.path);
    expect(failed.error, isNotNull);
    expect(await source.readAsString(), 'not a database');
    expect(await targetEntries(), isEmpty);
    await failed.flush(); // handled migration errors must not prevent quitting
    expect(config()['pending'], target.path);
    await failed.cancelChange();
    expect(failed.error, isNull);
    expect(failed.pendingPath, isNull);
    final other = await directory(p.join(sandbox.path, 'other'));
    await failed.changeDirectory(other.path);
    expect(failed.pendingPath, other.path);
  });

  test('symlinks anywhere in managed data fail safely without touching their target', () async {
    if (Platform.isWindows) return;
    final external = await file(p.join(sandbox.path, 'external'));
    final root = await directory(p.join(original.path, 'accounts', 'one'));
    final link = Link(p.join(root.path, 'link'));
    await link.create(external.path);
    await (await open()).changeDirectory(target.path);
    final failed = await open();
    expect(failed.currentPath, original.path);
    expect(failed.error, contains('Symlinks'));
    expect(await external.readAsString(), 'music');
    expect(await targetEntries(), isEmpty);
    await link.delete();
    expect((await open()).currentPath, target.path);
  });

  test('revalidates pending destination and never overwrites a newly added managed tree', () async {
    await file(p.join(original.path, 'accounts', 'one', 'audio'));
    await (await open()).changeDirectory(target.path);
    final user = await file(
      p.join(target.path, 'accounts', 'user.txt'),
      'user',
    );
    final failed = await open();
    expect(failed.currentPath, original.path);
    expect(failed.pendingPath, target.path);
    expect(failed.error, contains('already contains accounts'));
    expect(await user.readAsString(), 'user');
    await failed.cancelChange();
    expect(await user.readAsString(), 'user');
  });

  test(
    'failed configuration writes preserve durable and observable selection',
    () async {
      final controller = await open();
      final initialized = configurationStore.value;
      final store = interceptWrites();
      store.beforeWrite = (_) async =>
          throw StateError('configuration write failed');
      await expectLater(
        controller.changeDirectory(target.path),
        throwsStateError,
      );
      expect(controller.pendingPath, isNull);
      expect(controller.currentPath, original.path);
      expect(controller.isSaving, isFalse);
      expect(configurationStore.value, initialized);
      await controller
          .flush(); // rejected edits must never trap application exit
      store.beforeWrite = null;
      await controller.changeDirectory(target.path);
      final saved = configurationStore.value;
      store.beforeWrite = (_) async =>
          throw StateError('configuration write failed');
      await expectLater(controller.cancelChange(), throwsStateError);
      expect(controller.pendingPath, target.path);
      expect(configurationStore.value, saved);
      store.beforeWrite = null;
      await controller.cancelChange();
      await controller.flush();
      expect(controller.error, isNull);
      expect(controller.restartRequired, isFalse);
    },
  );

  test('failed journal persistence leaves managed data untouched', () async {
    final source = await file(
      p.join(original.path, 'accounts', 'one', 'audio'),
    );
    await (await open()).changeDirectory(target.path);
    final store = interceptWrites();
    store.beforeWrite = (value) async {
      if (value.containsKey('migration')) {
        throw StateError('journal write failed');
      }
    };
    final failed = await open();
    expect(failed.currentPath, original.path);
    expect(failed.pendingPath, target.path);
    expect(failed.error, isNotNull);
    expect(await source.exists(), isTrue);
    expect(await targetEntries(), isEmpty);
    expect(config().containsKey('migration'), isFalse);
  });

  test(
    'failed durable switch rolls back installed trees and can retry',
    () async {
      final source = await file(
        p.join(original.path, 'accounts', 'one', 'audio'),
      );
      await file(p.join(original.path, 'artwork', 'cover.image'));
      await file(p.join(target.path, 'user.txt'), 'user');
      await (await open()).changeDirectory(target.path);
      final store = interceptWrites();
      var sawInstalled = false;
      store.beforeWrite = (value) async {
        if (value['active'] == target.path) {
          sawInstalled = await File(
            p.join(target.path, 'accounts', 'one', 'audio'),
          ).exists();
          expect(
            await source.exists(),
            isTrue,
            reason: 'source survives until configuration commit',
          );
          throw StateError('commit failed');
        }
      };
      final failed = await open();
      expect(sawInstalled, isTrue);
      expect(failed.currentPath, original.path);
      expect(failed.pendingPath, target.path);
      expect(failed.error, isNotNull);
      expect(config()['active'], original.path);
      expect(await source.readAsString(), 'music');
      expect(await targetEntries(), ['user.txt']);
      store.beforeWrite = null;
      final retried = await open();
      expect(retried.error, isNull);
      expect(retried.currentPath, target.path);
      await noStagingArtifacts();
    },
  );

  test(
    'failed cancellation leaves the durable pending selection intact',
    () async {
      final controller = await open();
      await controller.changeDirectory(target.path);
      final saved = configurationStore.value;
      final store = interceptWrites();
      store.beforeWrite = (_) async =>
          throw StateError('configuration write interrupted');
      await expectLater(controller.cancelChange(), throwsStateError);
      expect(controller.pendingPath, target.path);
      expect(configurationStore.value, saved);
      expect(controller.isSaving, isFalse);
      store.beforeWrite = null;
      await controller.cancelChange();
      await controller.flush();
    },
  );

  test(
    'rejected rollback-journal removal remains recoverable and cancellable',
    () async {
      final source = await file(
        p.join(original.path, 'accounts', 'one', 'audio'),
      );
      await (await open()).changeDirectory(target.path);
      final store = interceptWrites();
      store.beforeWrite = (value) async {
        if (value['active'] != original.path ||
            !value.containsKey('migration')) {
          throw StateError('commit or rollback-journal removal failed');
        }
      };
      final failed = await open();
      expect(failed.currentPath, original.path);
      expect(failed.pendingPath, target.path);
      expect(failed.error, isNotNull);
      expect(config().containsKey('migration'), isTrue);
      expect(await source.exists(), isTrue);
      expect(await targetEntries(), isEmpty);
      // Reconstruct a still-owned partial install: cancel must only save the
      // selection, not perform filesystem recovery while accounts are running.
      final journal = config()['migration'];
      await file(
        p.join(target.path, 'accounts', '.yun-data-owner'),
        jsonEncode(journal),
      );
      final partial = await file(p.join(target.path, 'accounts', 'partial'));
      store.beforeWrite = null;
      await failed.cancelChange();
      expect(config().containsKey('migration'), isTrue);
      expect(failed.pendingPath, isNull);
      expect(await partial.exists(), isTrue);
      expect((await open()).currentPath, original.path);
      expect(config().containsKey('migration'), isFalse);
      expect(await partial.exists(), isFalse);
    },
  );

  test('a rejected final cleanup write cannot undo a durable switch', () async {
    final source = await file(
      p.join(original.path, 'accounts', 'one', 'audio'),
    );
    await (await open()).changeDirectory(target.path);
    final store = interceptWrites();
    store.beforeWrite = (value) async {
      if (value['active'] == target.path && !value.containsKey('migration')) {
        throw StateError('final cleanup write failed');
      }
    };
    final committed = await open();
    expect(committed.currentPath, target.path);
    expect(committed.pendingPath, isNull);
    expect(committed.error, isNotNull);
    expect(config()['active'], target.path);
    expect(config().containsKey('migration'), isTrue);
    expect(await source.exists(), isFalse);
    final newSourceFile = await file(
      p.join(original.path, 'accounts', 'new-user-file'),
      'keep',
    );
    final third = await directory(p.join(sandbox.path, 'third'));
    await committed.changeDirectory(third.path);
    expect(config().containsKey('migration'), isTrue);
    expect(config()['pending'], third.path);
    expect(committed.currentPath, target.path);
    expect(
      await File(p.join(target.path, 'accounts', 'one', 'audio')).exists(),
      isTrue,
    );
    store.beforeWrite = null;
    final restarted = await open();
    expect(restarted.currentPath, third.path);
    expect(restarted.error, isNull);
    expect(config().containsKey('migration'), isFalse);
    expect(await newSourceFile.readAsString(), 'keep');
    await noStagingArtifacts();
  });

  test('serialization keeps committed getters unchanged until durable, and flush follows queued edits', () async {
    final controller = await open();
    final third = await directory(p.join(sandbox.path, 'third'));
    final store = interceptWrites();
    final saved = configurationStore.value;
    final entered = Completer<void>();
    final release = Completer<void>();
    store.beforeWrite = (_) async {
      if (!entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    final first = controller.changeDirectory(target.path);
    await entered.future;
    final flushing = controller.flush();
    final second = controller.changeDirectory(third.path);
    final cancel = controller.cancelChange();
    expect(controller.isSaving, isTrue);
    expect(controller.pendingPath, isNull);
    expect(store.writes, hasLength(1));
    expect(configurationStore.value, saved);
    release.complete();
    await Future.wait([first, second, cancel, flushing]);
    expect(store.writes.map((value) => value['pending']).toList(), [
      target.path,
      third.path,
      null,
    ]);
    expect(controller.isSaving, isFalse);
    expect(controller.pendingPath, isNull);
    expect(controller.currentPath, original.path);
    expect(config()['active'], original.path);
  });

  test(
    'missing recorded source fails closed, including the former default',
    () async {
      await (await open()).changeDirectory(target.path);
      await original.delete(recursive: true);
      await expectLater(open(), throwsFileSystemException);
      expect(await original.exists(), isFalse);
      expect(await target.list().toList(), isEmpty);
      expect(config()['active'], original.path);
      expect(config()['pending'], target.path);
    },
  );

  test(
    'initial identity persistence must succeed before exposing account storage',
    () async {
      final store = interceptWrites();
      String? identity;
      for (final message in [
        'initial write rejected',
        'initial write interrupted',
      ]) {
        store.beforeWrite = (_) async => throw StateError(message);
        await expectLater(open(), throwsStateError);
        expect(configurationStore.value, isNull);
        expect(
          await Directory(p.join(original.path, 'accounts')).exists(),
          isFalse,
        );
        final marker = await File(p.join(original.path, rootMarker))
            .readAsString();
        identity ??= marker;
        expect(
          marker,
          identity,
          reason: 'retry must adopt the completed marker',
        );
      }
      store.beforeWrite = null;
      final initialized = await open();
      expect(initialized.error, isNull);
      expect(config()['activeIdentity'], identity);
      expect((await open()).currentPath, original.path);
    },
  );

  test(
    'a torn initial temporary marker is never used as an identity',
    () async {
      final temporary = await file(
        p.join(original.path, '$rootMarker-interrupted.tmp'),
        'incomplete',
      );
      final platformPreferences = await file(
        p.join(original.path, 'shared_preferences.json'),
        'platform-owned',
      );
      await open();
      final identity = config()['activeIdentity'] as String;
      expect(identity, hasLength(36));
      expect(
        await File(p.join(original.path, rootMarker)).readAsString(),
        identity,
      );
      expect(await temporary.readAsString(), 'incomplete');
      expect(await platformPreferences.readAsString(), 'platform-owned');
    },
  );

  for (final pending in [false, true]) {
    test('an empty unmounted source fails closed (pending=$pending)', () async {
      final controller = await open();
      final audio = await file(p.join(original.path, 'accounts', 'audio'));
      if (pending) await controller.changeDirectory(target.path);
      final saved = configurationStore.value;
      final offline = p.join(sandbox.path, 'offline');
      await original.rename(offline);
      await original.create(); // mountpoint itself still exists after unmount
      await expectLater(open(), throwsFileSystemException);
      expect(configurationStore.value, saved);
      expect(await original.list().toList(), isEmpty);
      expect(
        await File(p.join(offline, 'accounts', p.basename(audio.path)))
            .readAsString(),
        'music',
      );
      expect(await target.list().toList(), isEmpty);
      await original.delete();
      await Directory(offline).rename(original.path);
      final recovered = await open();
      expect(recovered.error, isNull);
      expect(recovered.currentPath, pending ? target.path : original.path);
    });
  }

  test('missing, changed, invalid and symlinked recorded identities are never repaired', () async {
    await open();
    final saved = configurationStore.value;
    final marker = File(p.join(original.path, rootMarker));
    final identity = await marker.readAsString();
    await marker.delete();
    await expectLater(open(), throwsFileSystemException);
    expect(await marker.exists(), isFalse);
    for (final body in ['11111111-1111-4111-8111-111111111111', 'partial']) {
      await marker.writeAsString(body);
      await expectLater(open(), throwsFileSystemException);
      expect(await marker.readAsString(), body);
    }
    if (!Platform.isWindows) {
      await marker.delete();
      final external = await file(
        p.join(sandbox.path, 'external-marker'),
        identity,
      );
      await Link(marker.path).create(external.path);
      await expectLater(open(), throwsFileSystemException);
      expect(await external.readAsString(), identity);
    }
    expect(configurationStore.value, saved);
  });

  test(
    'legacy nonempty roots are adopted durably before a pending migration',
    () async {
      final audio = await file(p.join(original.path, 'accounts', 'audio'));
      final legacy = jsonEncode({
        'version': 1,
        'active': original.path,
        'pending': target.path,
      });
      await configurationStore.write(legacy);
      final store = interceptWrites();
      store.beforeWrite = (_) async =>
          throw StateError('configuration write failed');
      await expectLater(open(), throwsStateError);
      expect(configurationStore.value, legacy);
      expect(await audio.readAsString(), 'music');
      expect(await target.list().toList(), isEmpty);
      expect(store.writes.single.containsKey('migration'), isFalse);
      expect(store.writes.single['activeIdentity'], isNotNull);
      store.beforeWrite = null;
      final recovered = await open();
      expect(recovered.error, isNull);
      expect(recovered.currentPath, target.path);
      expect(
        await File(p.join(target.path, rootMarker)).readAsString(),
        config()['activeIdentity'],
      );
    },
  );

  test(
    'empty markerless legacy roots cannot be blessed as a mounted source',
    () async {
      await directory(p.join(original.path, 'accounts'));
      final legacy = jsonEncode({'version': 1, 'active': original.path});
      await configurationStore.write(legacy);
      await expectLater(open(), throwsFileSystemException);
      expect(configurationStore.value, legacy);
      expect(await File(p.join(original.path, rootMarker)).exists(), isFalse);
    },
  );

  test(
    'malformed active configuration fails closed without rewriting the store',
    () async {
      for (final saved in <String>[
        '42',
        '',
        '{bad',
        '[]',
        jsonEncode({'version': 2, 'active': original.path}),
        jsonEncode({'version': 1, 'active': 'relative'}),
        jsonEncode({
          'version': 1,
          'active': original.path,
          'activeIdentity': null,
        }),
        jsonEncode({
          'version': 1,
          'active': original.path,
          'activeIdentity': 'partial',
        }),
        jsonEncode({
          'version': 1,
          'active': original.path,
          'activeIdentity': '11111111-1111-4111-8111-111111111111',
          'migration': {
            'source': original.path,
            'target': target.path,
            'stage': '.yun-data-migration-mismatched-identity',
            'names': <String>[],
            'sourceIdentity': '22222222-2222-4222-8222-222222222222',
            'targetIdentity': '33333333-3333-4333-8333-333333333333',
          },
        }),
      ]) {
        configurationStore.value = saved;
        await expectLater(open(), throwsFormatException);
        expect(configurationStore.value, saved);
      }
    },
  );

  test('malformed pending path retains original root, exposes error, can be canceled', () async {
    await open(); // a legacy config may adopt an already established marker
    await configurationStore.write(
      jsonEncode({
        'version': 1,
        'active': original.path,
        'pending': 'relative',
      }),
    );
    final failed = await open();
    expect(failed.currentPath, original.path);
    expect(failed.pendingPath, 'relative');
    expect(failed.error, isNotNull);
    await failed.cancelChange();
    expect(failed.pendingPath, isNull);
    expect(failed.error, isNull);
  });

  test('startup journal recovery rolls back an interrupted partial install before retrying', () async {
    await file(
      p.join(original.path, 'accounts', 'one', 'audio'),
      'complete source',
    );
    await file(p.join(original.path, 'artwork', 'cover.image'), 'artwork');
    final journal = {
      'source': original.path,
      'target': target.path,
      'stage': '.yun-data-migration-test-owned',
      'names': ['accounts', 'artwork'],
    };
    final owner = jsonEncode(journal);
    final stage = await directory(
      p.join(target.path, journal['stage'] as String),
    );
    await file(p.join(stage.path, '.yun-data-owner'), owner);
    await file(p.join(stage.path, 'artwork', '.yun-data-owner'), owner);
    await file(p.join(target.path, 'accounts', '.yun-data-owner'), owner);
    await file(
      p.join(target.path, 'accounts', 'one', 'audio'),
      'interrupted partial copy',
    );
    await file(p.join(target.path, 'user.txt'), 'user');
    await configurationStore.write(
      jsonEncode({
        'version': 1,
        'active': original.path,
        'pending': target.path,
        'migration': journal,
      }),
    );
    final recovered = await open();
    expect(recovered.error, isNull);
    expect(recovered.currentPath, target.path);
    expect(
      await File(p.join(target.path, 'accounts', 'one', 'audio'))
          .readAsString(),
      'complete source',
    );
    expect(
      await File(p.join(target.path, 'artwork', 'cover.image')).readAsString(),
      'artwork',
    );
    expect(await File(p.join(target.path, 'user.txt')).readAsString(), 'user');
    await noStagingArtifacts();
  });

  for (final replacement in ['missing', 'symlink', 'empty']) {
    test('rollback retains its journal while target is $replacement', () async {
      if (replacement == 'symlink' && Platform.isWindows) return;
      await open();
      final source = await file(p.join(original.path, 'accounts', 'audio'));
      const targetIdentity = '22222222-2222-4222-8222-222222222222';
      await file(p.join(target.path, rootMarker), targetIdentity);
      final journal = {
        'source': original.path,
        'target': target.path,
        'stage': '.yun-data-migration-offline',
        'names': ['accounts'],
        'sourceIdentity': config()['activeIdentity'],
        'targetIdentity': targetIdentity,
      };
      await file(
        p.join(target.path, 'accounts', '.yun-data-owner'),
        jsonEncode(journal),
      );
      await file(p.join(target.path, 'accounts', 'partial'), 'partial install');
      await configurationStore.write(
        jsonEncode({...config(), 'migration': journal}),
      );
      final saved = configurationStore.value;
      final offline = p.join(sandbox.path, 'offline-target');
      await target.rename(offline);
      if (replacement == 'symlink') await Link(target.path).create(offline);
      if (replacement == 'empty') await target.create();
      final failed = await open();
      expect(failed.currentPath, original.path);
      expect(failed.error, contains('Incomplete migration rollback'));
      expect(configurationStore.value, saved);
      expect(
        await File(p.join(offline, 'accounts', 'partial')).readAsString(),
        'partial install',
      );
      await failed
          .flush(); // already-durable recovery failures do not trap quit
      await failed.cancelChange();
      expect(
        config()['migration'],
        journal,
        reason: 'cancel is not filesystem recovery',
      );
      if (replacement == 'symlink') await Link(target.path).delete();
      if (replacement == 'empty') await target.delete();
      await Directory(offline).rename(target.path);
      final recovered = await open();
      expect(recovered.error, isNull);
      expect(config().containsKey('migration'), isFalse);
      expect(await source.readAsString(), 'music');
      expect(await targetEntries(), isEmpty);
    });
  }

  test(
    'a target disappearing during failed commit retains the rollback journal',
    () async {
      final audio = await file(p.join(original.path, 'accounts', 'audio'));
      await (await open()).changeDirectory(target.path);
      final store = interceptWrites();
      final offline = p.join(sandbox.path, 'offline-target');
      store.beforeWrite = (value) async {
        if (value['active'] == target.path) {
          await target.rename(offline);
          throw StateError('commit failed');
        }
      };
      final failed = await open();
      expect(failed.error, contains('Incomplete migration rollback'));
      expect(config()['active'], original.path);
      expect(config().containsKey('migration'), isTrue);
      expect(await audio.exists(), isTrue);
      expect(
        await File(p.join(offline, 'accounts', '.yun-data-owner')).exists(),
        isTrue,
      );
      store.beforeWrite = null;
      await Directory(offline).rename(target.path);
      final recovered = await open();
      expect(recovered.error, isNull);
      expect(recovered.currentPath, target.path);
      expect(
        await File(p.join(target.path, 'accounts', 'audio')).readAsString(),
        'music',
      );
      await noStagingArtifacts();
    },
  );

  test('interrupted rollback deletion keeps outer ownership after nested marker loss', () async {
    final audio = await file(p.join(original.path, 'accounts', 'audio'));
    await (await open()).changeDirectory(target.path);
    final store = interceptWrites();
    store.beforeWrite = (value) async {
      if (value['active'] == target.path) throw StateError('commit failed');
    };
    var interrupted = false;
    final failed = await IOOverrides.runWithIOOverrides(
      open,
      _DeleteOverrides((path, recursive) async {
        if (!recursive || p.basename(path) != '.rollback-accounts') return;
        interrupted = true;
        expect(
          await File(p.join(p.dirname(path), '.yun-data-owner')).exists(),
          isTrue,
        );
        await File(p.join(path, '.yun-data-owner')).delete();
        // Simulate the problematic deletion ordering: nested ownership is gone,
        // but some installed content remains when the process stops.
        throw FileSystemException('interrupted recursive deletion', path);
      }),
    );
    expect(interrupted, isTrue, reason: failed.error);
    expect(failed.error, contains('interrupted recursive deletion'));
    final journal = config()['migration'] as Map<String, dynamic>;
    final stage = p.join(target.path, journal['stage'] as String);
    expect(
      await File(p.join(stage, '.yun-data-owner')).readAsString(),
      jsonEncode(journal),
    );
    expect(await Directory(p.join(target.path, 'accounts')).exists(), isFalse);
    expect(
      await File(p.join(stage, '.rollback-accounts', '.yun-data-owner'))
          .exists(),
      isFalse,
    );
    expect(
      await File(p.join(stage, '.rollback-accounts', 'audio')).exists(),
      isTrue,
    );
    expect(await audio.exists(), isTrue);
    store.beforeWrite = null;
    final recovered = await open();
    expect(recovered.error, isNull);
    expect(recovered.currentPath, target.path);
    expect(
      await File(p.join(target.path, 'accounts', 'audio')).readAsString(),
      'music',
    );
    await noStagingArtifacts();
  });

  test('crash after last ownership marker removal leaves only a recoverable empty stage', () async {
    await file(p.join(original.path, 'accounts', 'audio'));
    await (await open()).changeDirectory(target.path);
    final store = interceptWrites();
    store.beforeWrite = (value) async {
      if (value['active'] == target.path) throw StateError('commit failed');
    };
    var interrupted = false;
    final failed = await IOOverrides.runWithIOOverrides(
      open,
      _DeleteOverrides((path, recursive) async {
        if (recursive || !p.basename(path).startsWith('.yun-data-migration-')) {
          return;
        }
        interrupted = true;
        expect(await Directory(path).list().toList(), isEmpty);
        throw FileSystemException('interrupted final rmdir', path);
      }),
    );
    expect(interrupted, isTrue);
    expect(failed.error, contains('interrupted final rmdir'));
    final stage = p.join(target.path, config()['migration']['stage'] as String);
    expect(await Directory(stage).list().toList(), isEmpty);
    store.beforeWrite = null;
    await failed.cancelChange();
    expect(config().containsKey('migration'), isTrue);
    final recovered = await open();
    expect(recovered.error, isNull);
    expect(recovered.currentPath, original.path);
    expect(config().containsKey('migration'), isFalse);
    await noStagingArtifacts();
  });

  test('committed staging cleanup also keeps its owner until all children are gone', () async {
    await file(p.join(original.path, 'accounts', 'audio'));
    await (await open()).changeDirectory(target.path);
    final store = interceptWrites();
    store.beforeWrite = (value) async {
      if (value['active'] == target.path && value.containsKey('migration')) {
        final stage = p.join(
          target.path,
          value['migration']['stage'] as String,
        );
        await file(
          p.join(stage, 'leftover', '.yun-data-owner'),
          'nested owner',
        );
        await file(p.join(stage, 'leftover', 'partial'), 'partial');
      }
    };
    var interrupted = false;
    final committed = await IOOverrides.runWithIOOverrides(
      open,
      _DeleteOverrides((path, recursive) async {
        if (!recursive || p.basename(path) != 'leftover') return;
        interrupted = true;
        await File(p.join(path, '.yun-data-owner')).delete();
        throw FileSystemException('interrupted committed cleanup', path);
      }),
    );
    expect(interrupted, isTrue, reason: committed.error);
    expect(committed.currentPath, target.path);
    expect(committed.error, contains('interrupted committed cleanup'));
    final stage = p.join(target.path, config()['migration']['stage'] as String);
    expect(await File(p.join(stage, '.yun-data-owner')).exists(), isTrue);
    expect(await File(p.join(stage, 'leftover', 'partial')).exists(), isTrue);
    await committed.flush();
    store.beforeWrite = null;
    final recovered = await open();
    expect(recovered.error, isNull);
    expect(config().containsKey('migration'), isFalse);
    expect(
      await File(p.join(target.path, 'accounts', 'audio')).readAsString(),
      'music',
    );
    await noStagingArtifacts();
  });

  test(
    'committed journal recovery removes only unchanged copied source entries',
    () async {
      final copied = await file(
        p.join(original.path, 'accounts', 'one', 'copied'),
        'original',
      );
      final changed = await file(
        p.join(original.path, 'accounts', 'one', 'changed'),
        'old',
      );
      final copiedStat = await copied.stat();
      final changedStat = await changed.stat();
      final manifest = [
        {'path': 'accounts', 'directory': true},
        {'path': p.join('accounts', 'one'), 'directory': true},
        {
          'path': p.join('accounts', 'one', 'copied'),
          'size': copiedStat.size,
          'modified': copiedStat.modified.microsecondsSinceEpoch,
        },
        {
          'path': p.join('accounts', 'one', 'changed'),
          'size': changedStat.size,
          'modified': changedStat.modified.microsecondsSinceEpoch,
        },
      ];
      await changed.writeAsString('new user content');
      final added = await file(
        p.join(original.path, 'accounts', 'one', 'added'),
        'new',
      );
      final journal = {
        'source': original.path,
        'target': target.path,
        'stage': '.yun-data-migration-committed',
        'names': ['accounts'],
      };
      final stage = p.join(target.path, journal['stage'] as String);
      await file(p.join(stage, '.yun-data-owner'), jsonEncode(journal));
      await file(p.join(stage, 'source-manifest.json'), jsonEncode(manifest));
      await file(
        p.join(target.path, 'accounts', '.yun-data-owner'),
        jsonEncode(journal),
      );
      await file(p.join(target.path, 'accounts', 'one', 'copied'), 'original');
      await file(p.join(target.path, 'accounts', 'one', 'changed'), 'old');
      await configurationStore.write(
        jsonEncode({'version': 1, 'active': target.path, 'migration': journal}),
      );
      final recovered = await open();
      expect(recovered.currentPath, target.path);
      expect(recovered.error, isNull);
      expect(await copied.exists(), isFalse);
      expect(await changed.readAsString(), 'new user content');
      expect(await added.readAsString(), 'new');
      expect(
        await File(p.join(target.path, 'accounts', 'one', 'changed'))
            .readAsString(),
        'old',
      );
      expect(config().containsKey('migration'), isFalse);
      await noStagingArtifacts();
    },
  );

  test('committed cleanup never deletes matching files on a replacement source disk', () async {
    await open();
    final sourceIdentity = config()['activeIdentity'] as String;
    const targetIdentity = '22222222-2222-4222-8222-222222222222';
    const replacementIdentity = '33333333-3333-4333-8333-333333333333';
    final copied = await file(p.join(original.path, 'accounts', 'copied'));
    final stat = await copied.stat();
    final journal = {
      'source': original.path,
      'target': target.path,
      'stage': '.yun-data-migration-replaced-source',
      'names': ['accounts'],
      'sourceIdentity': sourceIdentity,
      'targetIdentity': targetIdentity,
    };
    final owner = jsonEncode(journal);
    final stage = p.join(target.path, journal['stage'] as String);
    await file(p.join(target.path, rootMarker), targetIdentity);
    await file(p.join(target.path, 'accounts', 'copied'));
    await file(p.join(target.path, 'accounts', '.yun-data-owner'), owner);
    await file(p.join(stage, '.yun-data-owner'), owner);
    await file(
      p.join(stage, 'source-manifest.json'),
      jsonEncode([
        {'path': 'accounts', 'directory': true},
        {
          'path': p.join('accounts', 'copied'),
          'size': stat.size,
          'modified': stat.modified.microsecondsSinceEpoch,
        },
      ]),
    );
    await configurationStore.write(
      jsonEncode({
        'version': 1,
        'active': target.path,
        'activeIdentity': targetIdentity,
        'migration': journal,
      }),
    );
    final offline = p.join(sandbox.path, 'offline-source');
    await original.rename(offline);
    final replacement = await file(copied.path);
    await replacement.setLastModified(stat.modified);
    await file(p.join(original.path, rootMarker), replacementIdentity);
    final recovered = await open();
    expect(recovered.error, isNull);
    expect(recovered.currentPath, target.path);
    expect(await replacement.readAsString(), 'music');
    expect(
      await File(p.join(original.path, rootMarker)).readAsString(),
      replacementIdentity,
    );
    expect(
      await File(p.join(offline, 'accounts', 'copied')).readAsString(),
      'music',
    );
    expect(config().containsKey('migration'), isFalse);
    await noStagingArtifacts();
  });

  test(
    'stale journal never deletes unowned destination data, even on cancel',
    () async {
      await open();
      final journal = {
        'source': original.path,
        'target': target.path,
        'stage': '.yun-data-migration-stale',
        'names': ['accounts'],
      };
      final user = await file(
        p.join(target.path, 'accounts', 'user'),
        'not owned',
      );
      await file(
        p.join(target.path, journal['stage'] as String, 'user'),
        'also not owned',
      );
      await configurationStore.write(
        jsonEncode({
          'version': 1,
          'active': original.path,
          'pending': target.path,
          'migration': journal,
        }),
      );
      final failed = await open();
      expect(failed.currentPath, original.path);
      expect(failed.error, isNotNull);
      await failed.cancelChange();
      expect(await user.readAsString(), 'not owned');
      expect(
        await File(p.join(target.path, journal['stage'] as String, 'user'))
            .readAsString(),
        'also not owned',
      );
    },
  );
}
