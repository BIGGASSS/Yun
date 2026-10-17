import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:yun/core/data_directory_controller.dart';
import 'package:yun/services/data_directory_picker.dart';
import 'package:yun/services/data_directory_store.dart';
import 'package:yun/ui/app.dart';
import 'package:yun/ui/data_storage_settings.dart';
import 'package:yun/ui/settings_screen.dart';

import '../core/fakes.dart';
import 'player_test_app.dart';

class _MemoryStore implements DataDirectoryStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}

class _Picker extends DataDirectoryPicker {
  String? path;
  Object? error;
  Completer<String?>? pending;
  final initialDirectories = <String?>[];

  @override
  Future<String?> pickDirectory({String? initialDirectory}) async {
    initialDirectories.add(initialDirectory);
    if (error case final failure?) throw failure;
    return pending == null ? path : await pending!.future;
  }
}

class _SettingsApp extends PlayerTestApp {
  _SettingsApp() : super(FakeEngine());

  @override
  int get pendingEventCount => 0;
}

final _choose = find.widgetWithText(OutlinedButton, 'Choose folder');
final _reset = find.widgetWithText(TextButton, 'Use default location');
final _cancelPending = find.widgetWithText(TextButton, 'Cancel pending change');
final _confirm = find.widgetWithText(FilledButton, 'Change on next launch');
const _pendingLabel = 'Restart required · Next data directory';

// A settled frame is not sufficient for real filesystem operations.
Future<void> _waitFor(WidgetTester tester, bool Function() done) async {
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < const Duration(seconds: 10)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pumpAndSettle();
    if (done()) return;
  }
  fail('Data storage UI did not finish its operation');
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

class _Fixture {
  _Fixture(this.tester);

  final WidgetTester tester;
  final picker = _Picker();
  final app = _SettingsApp();
  late Directory sandbox, original, target;
  final store = _MemoryStore();
  late DataDirectoryController controller;

  Map<String, dynamic> get config => jsonDecode(saved) as Map<String, dynamic>;
  String get saved => store.value!;

  Future<void> open({bool longPaths = false}) async {
    final temporary = await Directory.systemTemp.createTemp('yun-storage-ui-');
    sandbox = Directory(await temporary.resolveSymbolicLinks());
    String name(String label) => longPaths
        ? p.joinAll([
            label,
            for (var i = 0; i < 5; i++) '$label-$i-${'long-folder-name-' * 4}',
          ])
        : label;
    original = await directory(name('default'));
    target = await directory(name('selected'));
    controller = await DataDirectoryController.open(
      store: store,
      defaultDirectory: () async => original,
    );
    picker.path = target.path;
  }

  Future<Directory> directory(String relative) =>
      Directory(p.join(sandbox.path, relative)).create(recursive: true);

  Future<File> file(String root, String relative, String body) async {
    final file = File(p.join(root, relative));
    await file.parent.create(recursive: true);
    return file.writeAsString(body, flush: true);
  }

  Future<void> startAtCustomRoot() async {
    await controller.changeDirectory(target.path);
    controller.dispose();
    controller = await DataDirectoryController.open(
      store: store,
      defaultDirectory: () async => original,
    );
    expect(controller.currentPath, target.path);
    expect(controller.error, isNull);
  }

  Future<void> mount({
    bool settingsScreen = false,
    bool appRoute = false,
  }) async {
    await tester.pumpWidget(
      appRoute
          ? YunApp(
              controller: app,
              dataDirectory: controller,
              directoryPicker: picker,
            )
          : MaterialApp(
              home: Scaffold(
                body: settingsScreen
                    ? SettingsScreen(
                        app: app,
                        dataDirectory: controller,
                        directoryPicker: picker,
                        themeMode: ThemeMode.light,
                        onThemeChanged: (_) {},
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: DataStorageSettings(
                          controller: controller,
                          picker: picker,
                        ),
                      ),
              ),
            ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> idle() => _waitFor(
    tester,
    () => find.text('Choosing or saving…').evaluate().isEmpty,
  );

  Future<void> chooseAndConfirm() async {
    await _tap(tester, _choose);
    expect(find.text('Change data directory?'), findsOneWidget);
    await _tap(tester, _confirm);
    await idle();
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await app.shutdown();
    app.dispose();
    controller.dispose();
    await sandbox.delete(recursive: true);
  }
}

Future<void> _withStorage(
  WidgetTester tester,
  Future<void> Function(_Fixture) body, {
  bool narrow = false,
}) async {
  // Construct queues, perform all IO, and drain shutdown in the same real zone.
  await tester.runAsync(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    tester.view.physicalSize = narrow
        ? const Size(320, 900)
        : const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = narrow ? 2 : 1;
    final fixture = _Fixture(tester);
    try {
      await fixture.open(longPaths: narrow);
      await body(fixture);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
  });
}

void main() {
  setUp(() {
    mockDesktopDrop();
    PackageInfo.setMockInitialValues(
      appName: 'Yun',
      packageName: 'test.yun',
      version: '0.2.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets(
    'picker cancellation keeps the current directory and stored configuration',
    (tester) async {
      await _withStorage(tester, (fixture) async {
        fixture.picker.path = null;
        final saved = fixture.saved;
        await fixture.mount();
        expect(find.text('Current data directory'), findsOneWidget);
        expect(find.text(fixture.original.path), findsOneWidget);
        expect(find.text(_pendingLabel), findsNothing);
        expect(tester.widget<TextButton>(_reset).onPressed, isNull);

        await _tap(tester, _choose);
        await fixture.idle();
        expect(fixture.picker.initialDirectories, [fixture.original.path]);
        expect(find.byType(AlertDialog), findsNothing);
        expect(fixture.controller.currentPath, fixture.original.path);
        expect(fixture.controller.pendingPath, isNull);
        expect(fixture.saved, saved);
        expect(tester.widget<OutlinedButton>(_choose).onPressed, isNotNull);
      });
    },
  );

  testWidgets('cancelling confirmation does not replace a pending selection', (
    tester,
  ) async {
    await _withStorage(tester, (fixture) async {
      await fixture.controller.changeDirectory(fixture.target.path);
      final other = await fixture.directory('other');
      fixture.picker.path = other.path;
      final saved = fixture.saved;
      await fixture.mount();
      await _tap(tester, _choose);
      expect(fixture.picker.initialDirectories, [fixture.target.path]);
      expect(find.text(other.path), findsOneWidget);
      await _tap(tester, find.widgetWithText(TextButton, 'Cancel'));
      await fixture.idle();
      expect(fixture.saved, saved);
      expect(fixture.controller.currentPath, fixture.original.path);
      expect(fixture.controller.pendingPath, fixture.target.path);
      expect(find.text(_pendingLabel), findsOneWidget);
      expect(find.text(fixture.target.path), findsOneWidget);
      expect(await other.list().isEmpty, isTrue);
    });
  });

  testWidgets(
    'confirmation saves next-launch storage without moving live data',
    (tester) async {
      await _withStorage(tester, (fixture) async {
        final audio = await fixture.file(
          fixture.original.path,
          'accounts/listener/audio/song.bin',
          'downloaded audio',
        );
        final artwork = await fixture.file(
          fixture.original.path,
          'artwork/cover.bin',
          'cached artwork',
        );
        await fixture.mount();
        await _tap(tester, _choose);
        expect(
          find.text('On the next launch, Yun will move its local data to:'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Keep both locations connected'),
          findsOneWidget,
        );
        expect(fixture.controller.pendingPath, isNull);
        await _tap(tester, _confirm);
        await fixture.idle();

        expect(fixture.controller.currentPath, fixture.original.path);
        expect(fixture.controller.pendingPath, fixture.target.path);
        expect(fixture.controller.restartRequired, isTrue);
        expect(fixture.config['active'], fixture.original.path);
        expect(fixture.config['pending'], fixture.target.path);
        expect(find.text('Current data directory'), findsOneWidget);
        expect(find.text(fixture.original.path), findsOneWidget);
        expect(find.text(_pendingLabel), findsOneWidget);
        expect(find.text(fixture.target.path), findsOneWidget);
        expect(await audio.readAsString(), 'downloaded audio');
        expect(await artwork.readAsString(), 'cached artwork');
        expect(await fixture.target.list().isEmpty, isTrue);
        expect(_cancelPending, findsOneWidget);
      });
    },
  );

  testWidgets('cancel pending change removes only the next-launch selection', (
    tester,
  ) async {
    await _withStorage(tester, (fixture) async {
      await fixture.controller.changeDirectory(fixture.target.path);
      await fixture.mount();
      await _tap(tester, _cancelPending);
      await fixture.idle();
      expect(fixture.controller.currentPath, fixture.original.path);
      expect(fixture.controller.pendingPath, isNull);
      expect(fixture.config.containsKey('pending'), isFalse);
      expect(find.text(_pendingLabel), findsNothing);
      expect(find.text(fixture.target.path), findsNothing);
      expect(_cancelPending, findsNothing);
      expect(tester.widget<TextButton>(_reset).onPressed, isNull);
      expect(await fixture.target.list().isEmpty, isTrue);
    });
  });

  testWidgets('reset at the default location cancels a pending move directly', (
    tester,
  ) async {
    await _withStorage(tester, (fixture) async {
      await fixture.controller.changeDirectory(fixture.target.path);
      await fixture.mount();
      await _tap(tester, _reset);
      await fixture.idle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(fixture.picker.initialDirectories, isEmpty);
      expect(fixture.controller.currentPath, fixture.original.path);
      expect(fixture.controller.pendingPath, isNull);
      expect(fixture.config.containsKey('pending'), isFalse);
    });
  });

  testWidgets('reset from custom storage requires confirmation and a restart', (
    tester,
  ) async {
    await _withStorage(tester, (fixture) async {
      await fixture.startAtCustomRoot();
      final audio = await fixture.file(
        fixture.target.path,
        'accounts/listener/audio/song.bin',
        'keep running here',
      );
      final saved = fixture.saved;
      await fixture.mount();
      await _tap(tester, _reset);
      expect(find.text(fixture.original.path), findsOneWidget);
      await _tap(tester, find.widgetWithText(TextButton, 'Cancel'));
      await fixture.idle();
      expect(fixture.saved, saved);

      await _tap(tester, _reset);
      await _tap(tester, _confirm);
      await fixture.idle();
      expect(fixture.picker.initialDirectories, isEmpty);
      expect(fixture.controller.currentPath, fixture.target.path);
      expect(fixture.controller.pendingPath, fixture.original.path);
      expect(fixture.config['active'], fixture.target.path);
      expect(fixture.config['pending'], fixture.original.path);
      expect(find.text(_pendingLabel), findsOneWidget);
      expect(await audio.readAsString(), 'keep running here');
      expect(
        await Directory(p.join(fixture.original.path, 'accounts')).exists(),
        isFalse,
      );
    });
  });

  for (final invalid in [
    'relative',
    'missing',
    'file',
    'overlap',
    'accounts',
    'artwork',
  ]) {
    testWidgets('invalid picker directory ($invalid) fails inline', (
      tester,
    ) async {
      await _withStorage(tester, (fixture) async {
        final String path;
        final String message;
        switch (invalid) {
          case 'relative':
            path = 'relative/folder';
            message = 'Choose an absolute directory path';
          case 'missing':
            path = p.join(fixture.sandbox.path, 'does-not-exist');
            message = 'does-not-exist';
          case 'file':
            path = (await fixture.file(
              fixture.sandbox.path,
              'not-a-directory',
              'unrelated file',
            )).path;
            message = 'not-a-directory';
          case 'overlap':
            path = (await Directory(
              p.join(fixture.original.path, 'nested'),
            ).create()).path;
            message = 'Source and destination directories must not overlap';
          default:
            await Directory(p.join(fixture.target.path, invalid)).create();
            path = fixture.target.path;
            message = 'Destination already contains $invalid';
        }
        fixture.picker.path = path;
        final saved = fixture.saved;
        await fixture.mount();
        await fixture.chooseAndConfirm();
        final error = find.textContaining('Could not change data directory.');
        expect(error, findsOneWidget);
        expect(find.textContaining(message), findsOneWidget);
        expect(
          tester
              .widget<Semantics>(
                find
                    .ancestor(of: error, matching: find.byType(Semantics))
                    .first,
              )
              .properties
              .liveRegion,
          isTrue,
        );
        expect(fixture.controller.currentPath, fixture.original.path);
        expect(fixture.controller.pendingPath, isNull);
        expect(fixture.saved, saved);
        expect(find.text(_pendingLabel), findsNothing);
        expect(tester.widget<OutlinedButton>(_choose).onPressed, isNotNull);
        expect(find.byType(SnackBar), findsNothing);
        await fixture.controller.flush();
        expect(fixture.saved, saved);
      });
    });
  }

  testWidgets(
    'a platform picker exception is inline and leaves storage intact',
    (tester) async {
      await _withStorage(tester, (fixture) async {
        fixture.picker.error = PlatformException(
          code: 'picker_unavailable',
          message: 'Folder picker unavailable',
        );
        final saved = fixture.saved;
        await fixture.mount();
        await _tap(tester, _choose);
        await fixture.idle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(
          find.textContaining('Could not change data directory.'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Folder picker unavailable'),
          findsOneWidget,
        );
        expect(fixture.saved, saved);
        expect(fixture.controller.error, isNull);
        expect(tester.widget<OutlinedButton>(_choose).onPressed, isNotNull);
      });
    },
  );

  testWidgets('all storage actions are disabled while the picker is pending', (
    tester,
  ) async {
    await _withStorage(tester, (fixture) async {
      await fixture.controller.changeDirectory(fixture.target.path);
      final saved = fixture.saved;
      final pending = fixture.picker.pending = Completer<String?>();
      await fixture.mount();
      try {
        await _tap(tester, _choose);
        expect(find.text('Choosing or saving…'), findsOneWidget);
        expect(tester.widget<OutlinedButton>(_choose).onPressed, isNull);
        expect(tester.widget<TextButton>(_reset).onPressed, isNull);
        expect(tester.widget<TextButton>(_cancelPending).onPressed, isNull);
        await tester.tap(_choose);
        await tester.pumpAndSettle();
        expect(fixture.picker.initialDirectories, [fixture.target.path]);
        expect(fixture.saved, saved);
      } finally {
        pending.complete(null);
        await fixture.idle();
      }
      expect(tester.widget<OutlinedButton>(_choose).onPressed, isNotNull);
      expect(tester.widget<TextButton>(_reset).onPressed, isNotNull);
      expect(tester.widget<TextButton>(_cancelPending).onPressed, isNotNull);
      expect(fixture.controller.pendingPath, fixture.target.path);
    });
  });

  testWidgets(
    '320px at 2x text scrolls long current and pending paths safely',
    (tester) async {
      await _withStorage(tester, (fixture) async {
        await fixture.controller.changeDirectory(fixture.target.path);
        await fixture.mount(settingsScreen: true);
        final scrollable = find
            .descendant(
              of: find.byType(SettingsScreen),
              matching: find.byType(Scrollable),
            )
            .first;
        expect(
          tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
          greaterThan(0),
        );
        for (final finder in [
          find.text(fixture.original.path),
          find.text(_pendingLabel),
          find.text(fixture.target.path),
          _choose,
        ]) {
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await _tap(tester, _choose);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text(fixture.target.path), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        await _tap(tester, find.widgetWithText(TextButton, 'Cancel'));
        await fixture.idle();
        await _tap(tester, _cancelPending);
        await fixture.idle();
        expect(fixture.controller.pendingPath, isNull);
        expect(find.text(_pendingLabel), findsNothing);
      }, narrow: true);
    },
  );

  testWidgets('YunApp settings navigation preserves the pending selection', (
    tester,
  ) async {
    await _withStorage(tester, (fixture) async {
      await fixture.mount(appRoute: true);
      await _tap(tester, find.byIcon(Icons.settings_outlined));
      final storage = tester.widget<DataStorageSettings>(
        find.byType(DataStorageSettings),
      );
      expect(storage.controller, same(fixture.controller));
      expect(storage.picker, same(fixture.picker));
      await fixture.chooseAndConfirm();
      final saved = fixture.saved;
      await _tap(tester, find.byIcon(Icons.library_music_outlined));
      expect(find.byType(DataStorageSettings), findsNothing);
      await _tap(tester, find.byIcon(Icons.settings_outlined));
      expect(
        tester
            .widget<DataStorageSettings>(find.byType(DataStorageSettings))
            .controller,
        same(fixture.controller),
      );
      expect(find.text(fixture.original.path), findsOneWidget);
      expect(find.text(fixture.target.path), findsOneWidget);
      expect(find.text(_pendingLabel), findsOneWidget);
      expect(fixture.saved, saved);
      expect(fixture.picker.initialDirectories, [fixture.original.path]);
    });
  });
}
