import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yun/core/data_directory_controller.dart';
import 'package:yun/services/data_directory_store.dart';

// Keep real filesystem operations, intercepting only a write/rename boundary.
final class _FileOverrides extends IOOverrides {
  _FileOverrides({this.beforeWrite, this.beforeRename});
  final Future<void> Function(File file, String value, bool flush)? beforeWrite;
  final Future<void> Function(File file, String destination)? beforeRename;

  @override
  File createFile(String path) => _ObservedFile(super.createFile(path), this);
}

class _ObservedFile implements File {
  _ObservedFile(this.delegate, this.observer);
  final File delegate;
  final _FileOverrides observer;

  @override
  String get path => delegate.path;
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) =>
      delegate.create(recursive: recursive, exclusive: exclusive);
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    await observer.beforeWrite?.call(delegate, contents, flush);
    return delegate.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
  }

  @override
  Future<File> rename(String newPath) async {
    await observer.beforeRename?.call(delegate, newPath);
    return delegate.rename(newPath);
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      delegate.delete(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory sandbox, root;
  late File configuration;
  late FileDataDirectoryStore store;

  FileDataDirectoryStore newStore() =>
      FileDataDirectoryStore(applicationSupportDirectory: () async => root);

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('yun-data-store-test-');
    sandbox = Directory(await sandbox.resolveSymbolicLinks());
    root = Directory(p.join(sandbox.path, 'support', 'app'));
    configuration = File(p.join(root.path, FileDataDirectoryStore.fileName));
    store = newStore();
  });

  tearDown(() => sandbox.delete(recursive: true));

  test(
    'missing configuration creates the support root and returns null',
    () async {
      expect(await root.exists(), isFalse);
      expect(await store.read(), isNull);
      expect(await root.exists(), isTrue);
      expect(await root.list().toList(), isEmpty);
    },
  );

  test('writes also create a missing support root', () async {
    await store.write('first value');
    expect(await newStore().read(), 'first value');
  });

  test(
    'flushed unique same-directory temps atomically replace an existing file',
    () async {
      await store.write('old');
      final unrelated = File('${configuration.path}-interrupted.tmp');
      await unrelated.writeAsString('leave me alone');
      final temporaries = <String>[];
      var previous = 'old';
      var sawFlush = false;
      final observer = _FileOverrides(
        beforeWrite: (temporary, value, flush) async {
          expect(p.dirname(temporary.path), root.path);
          expect(temporary.path, isNot(configuration.path));
          expect(flush, isTrue);
          sawFlush = true;
        },
        beforeRename: (temporary, destination) async {
          expect(sawFlush, isTrue);
          expect(destination, configuration.path);
          expect(await configuration.readAsString(), previous);
          expect(await temporary.readAsString(), isNot(previous));
          temporaries.add(temporary.path);
        },
      );
      for (final value in ['new', 'newer']) {
        sawFlush = false;
        await IOOverrides.runWithIOOverrides(
          () => store.write(value),
          observer,
        );
        expect(await newStore().read(), value);
        previous = value;
      }
      expect(temporaries.toSet(), hasLength(2));
      for (final temporary in temporaries) {
        expect(await File(temporary).exists(), isFalse);
      }
      expect(await unrelated.readAsString(), 'leave me alone');
    },
  );

  for (final phase in ['write', 'rename']) {
    test(
      '$phase failure preserves old config and cleans only its own temp',
      () async {
        await store.write('old');
        final unrelated = File('${configuration.path}-interrupted.tmp');
        await unrelated.writeAsString('keep');
        final failure = FileSystemException('injected $phase failure');
        var intercepted = false;
        final observer = _FileOverrides(
          beforeWrite: (temporary, value, flush) async {
            if (phase != 'write') return;
            intercepted = true;
            await temporary.writeAsString('partial', flush: true);
            throw failure;
          },
          beforeRename: (temporary, destination) async {
            intercepted = true;
            expect(await temporary.readAsString(), 'new');
            throw failure;
          },
        );
        await expectLater(
          IOOverrides.runWithIOOverrides(() => store.write('new'), observer),
          throwsA(same(failure)),
        );
        expect(intercepted, isTrue);
        expect(await newStore().read(), 'old');
        expect(await unrelated.readAsString(), 'keep');
        expect(
          await root.list().map((entry) => entry.path).toList(),
          unorderedEquals([configuration.path, unrelated.path]),
        );
      },
    );
  }

  test(
    'malformed existing content is read exactly and startup fails closed',
    () async {
      await root.create(recursive: true);
      final data = Directory(p.join(sandbox.path, 'data'));
      for (final value in ['', '{bad', 'null', '42', '[]', ' \n{}\n']) {
        await configuration.writeAsString(value);
        expect(await store.read(), value);
        await expectLater(
          DataDirectoryController.open(
            defaultDirectory: () async => data,
            store: store,
          ),
          throwsFormatException,
        );
        expect(await configuration.readAsString(), value);
        expect(await data.exists(), isFalse);
      }
      await configuration.writeAsBytes([0xff]);
      await expectLater(store.read(), throwsA(isA<FileSystemException>()));
      expect(await configuration.readAsBytes(), [0xff]);
    },
  );

  test(
    'inaccessible existing config is not mistaken for first launch',
    () async {
      if (!Platform.isLinux) return;
      await store.write('existing');
      final restricted = await Process.run('chmod', ['000', root.path]);
      expect(restricted.exitCode, 0);
      try {
        // A privileged test runner may bypass mode bits entirely.
        if (await FileSystemEntity.type(
              configuration.path,
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
          return;
        }
        await expectLater(store.read(), throwsA(isA<FileSystemException>()));
      } finally {
        final restored = await Process.run('chmod', ['700', root.path]);
        expect(restored.exitCode, 0);
      }
      expect(await newStore().read(), 'existing');
    },
  );

  test('existing non-file config is not mistaken for first launch', () async {
    await Directory(configuration.path).create(recursive: true);
    await expectLater(store.read(), throwsA(isA<FileSystemException>()));
    await Directory(configuration.path).delete();
    if (!Platform.isWindows) {
      await Link(configuration.path).create(p.join(root.path, 'missing'));
      await expectLater(store.read(), throwsA(isA<FileSystemException>()));
    }
  });

  test(
    'reopening migrates data but keeps config and preferences in app support',
    () async {
      final target = await Directory(p.join(sandbox.path, 'chosen')).create();
      final first = await DataDirectoryController.open(
        defaultDirectory: () async => root,
        store: store,
      );
      addTearDown(first.dispose);
      final preferences = File(p.join(root.path, 'shared_preferences.json'));
      await preferences.writeAsString('unrelated platform-owned preferences');
      final audio = File(p.join(root.path, 'accounts', 'audio'));
      await audio.parent.create(recursive: true);
      await audio.writeAsString('music');
      await first.changeDirectory(target.path);
      final pending = jsonDecode((await newStore().read())!) as Map;
      expect(pending['active'], root.path);
      expect(pending['pending'], target.path);
      final reopened = await DataDirectoryController.open(
        defaultDirectory: () async => root,
        store: newStore(),
      );
      addTearDown(reopened.dispose);
      expect(reopened.error, isNull);
      expect(reopened.currentPath, target.path);
      expect(
        (jsonDecode((await newStore().read())!) as Map)['active'],
        target.path,
      );
      expect(
        await File(p.join(target.path, 'accounts', 'audio')).readAsString(),
        'music',
      );
      expect(await audio.exists(), isFalse);
      expect(
        await preferences.readAsString(),
        'unrelated platform-owned preferences',
      );
      expect(
        await File(p.join(target.path, FileDataDirectoryStore.fileName))
            .exists(),
        isFalse,
      );
      expect(
        await File(p.join(target.path, 'shared_preferences.json')).exists(),
        isFalse,
      );
    },
  );
}
