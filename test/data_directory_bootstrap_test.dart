import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/core/data_directory_controller.dart';
import 'package:yun/main.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/data_directory_store.dart';
import 'package:yun/ui/app.dart';
import 'package:yun/ui/data_storage_settings.dart';

import 'core/fake_desktop_host.dart';
import 'core/fakes.dart';
import 'ui/player_test_app.dart' show mockDesktopDrop;

class _MemoryStore implements DataDirectoryStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    this.value = value;
  }
}

ApiClient _api() =>
    ApiClient(
        credentials: MemoryCredentials(),
        dio: Dio()
          ..httpClientAdapter = FakeAdapter((options, _) {
            throw StateError('Unexpected network request: ${options.uri}');
          }),
      )
      ..session = SessionCredentials(
        account: const Account(
          server: 'https://yun.test',
          userId: 'listener',
          username: 'Listener',
        ),
        accessToken: 'test-access',
        refreshToken: 'test-refresh',
        expiresAt: DateTime.now()
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch,
      );

class _BootstrapApp extends AppController {
  _BootstrapApp({
    required FakeEngine engine,
    required super.storageDirectory,
    required super.databaseFactory,
    required super.playbackSettings,
    required super.savePlaybackSettings,
    required this.beforeInitialize,
  }) : super(
         api: _api(),
         playbackEngine: engine,
         enableSystemControls: false,
         automaticRefresh: false,
       );

  final Future<void> Function(_BootstrapApp) beforeInitialize;
  int initializeCalls = 0;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    await beforeInitialize(this);
    await super.initialize();
  }
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() done,
  String description,
) async {
  // Disk/SQLite may finish after pumpAndSettle sees no scheduled frame.
  final elapsed = Stopwatch()..start();
  while (elapsed.elapsed < const Duration(seconds: 10)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pumpAndSettle();
    if (done()) return;
  }
  fail('Timed out waiting for $description');
}

class _Fixture {
  _Fixture(this.tester);

  final WidgetTester tester;
  late Directory sandbox, original, target;
  final store = _MemoryStore();
  final events = <String>[];
  final apps = <_BootstrapApp>[];
  final engines = <FakeEngine>[];
  final hosts = <FakeDesktopHost>[];
  final databaseFiles = <File>[];
  final databases = <CacheDatabase>[];
  DataDirectoryController? data;
  Completer<void>? storageGate;
  void Function()? beforeConstruct;
  Future<void> Function(_BootstrapApp)? beforeInitialize;

  Map<String, dynamic> get config =>
      jsonDecode(store.value!) as Map<String, dynamic>;

  Future<void> open() async {
    final temporary = await Directory.systemTemp.createTemp(
      'yun-storage-boot-',
    );
    sandbox = Directory(await temporary.resolveSymbolicLinks());
    original = await Directory(p.join(sandbox.path, 'default')).create();
    target = await Directory(p.join(sandbox.path, 'selected')).create();
  }

  Future<DataDirectoryController> openDataDirectory() async {
    events.add('storage:start');
    final controller = await DataDirectoryController.open(
      store: store,
      defaultDirectory: () async => original,
    );
    data = controller;
    events.add('storage:opened');
    await storageGate?.future;
    events.add('storage:ready');
    return controller;
  }

  Future<void> mount({bool resolveStorage = true, bool wait = true}) async {
    await tester.pumpWidget(
      YunBootstrap(
        dataDirectoryFactory: resolveStorage ? openDataDirectory : null,
        updateCheckerFactory: () async => null,
        desktopHostFactory: () {
          final host = FakeDesktopHost(events);
          hosts.add(host);
          return host;
        },
        controllerFactory:
            ({required playbackSettings, required savePlaybackSettings}) {
              events.add('account:construct');
              beforeConstruct?.call();
              final engine = FakeEngine();
              engines.add(engine);
              final app = _BootstrapApp(
                engine: engine,
                playbackSettings: playbackSettings,
                savePlaybackSettings: savePlaybackSettings,
                storageDirectory: () async {
                  events.add('account:storage');
                  return Directory(data?.currentPath ?? original.path);
                },
                databaseFactory: (file) {
                  events.add('account:database');
                  databaseFiles.add(file);
                  final database = CacheDatabase(file);
                  databases.add(database);
                  return database;
                },
                beforeInitialize: (app) async {
                  events.add('account:initialize');
                  expect(app.initialized, isFalse);
                  await beforeInitialize?.call(app);
                },
              );
              apps.add(app);
              return app;
            },
      ),
    );
    if (wait) await readyOrFailed();
  }

  Future<void> readyOrFailed() => _waitFor(
    tester,
    () =>
        find.byType(YunApp).evaluate().isNotEmpty ||
        find.text('Your library could not be opened.').evaluate().isNotEmpty,
    'bootstrap readiness or storage failure',
  );

  Future<void> settings() async {
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
  }

  Future<File> file(String root, String relative, String body) async {
    final file = File(p.join(root, relative));
    await file.parent.create(recursive: true);
    return file.writeAsString(body, flush: true);
  }

  Future<void> unmount() async {
    if (apps.isNotEmpty) await apps.last.shutdown();
    await tester.pumpWidget(const SizedBox.shrink());
    data = null; // The bootstrap owns and disposes its storage controller.
  }

  Future<void> dispose() async {
    for (final app in apps) {
      await app.shutdown();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await sandbox.delete(recursive: true);
  }
}

Future<void> _withBootstrap(
  WidgetTester tester,
  Future<void> Function(_Fixture) body, {
  TargetPlatform platform = TargetPlatform.linux,
}) async {
  // Keep creation, real IO, controller queues, and shutdown in one async zone.
  await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({});
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    final fixture = _Fixture(tester);
    try {
      await fixture.open();
      await body(fixture);
      expect(tester.takeException(), isNull);
      for (final engine in fixture.engines) {
        expect(engine.initializations, 0);
        expect(engine.opens, 0);
      }
    } finally {
      final gate = fixture.storageGate;
      if (gate != null && !gate.isCompleted) gate.complete();
      await fixture.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
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
    'storage resolves before account construction/initialization and reaches settings',
    (tester) async {
      await _withBootstrap(tester, (fixture) async {
        final gate = fixture.storageGate = Completer<void>();
        fixture.beforeConstruct = () {
          expect(fixture.events, contains('storage:ready'));
          expect(fixture.config['active'], fixture.original.path);
          expect(fixture.config['activeIdentity'], isA<String>());
        };
        fixture.beforeInitialize = (app) async {
          expect(fixture.data!.currentPath, fixture.original.path);
          expect(fixture.databaseFiles, isEmpty);
          expect(
            await File(p.join(fixture.original.path, '.yun-data-root'))
                .exists(),
            isTrue,
          );
        };
        await fixture.mount(wait: false);
        await _waitFor(
          tester,
          () => fixture.events.contains('storage:opened'),
          'the gated data-directory factory',
        );
        expect(find.text('Opening your library…'), findsOneWidget);
        expect(fixture.apps, isEmpty);
        expect(fixture.hosts, isEmpty);
        expect(fixture.databaseFiles, isEmpty);
        expect(find.byType(YunApp), findsNothing);

        gate.complete();
        await fixture.readyOrFailed();
        expect(fixture.apps, hasLength(1));
        expect(fixture.apps.single.initializeCalls, 1);
        expect(fixture.apps.single.initialized, isTrue);
        expect(fixture.apps.single.isAuthenticated, isTrue);
        expect(
          fixture.events.where(
            (event) =>
                event.startsWith('storage:') || event.startsWith('account:'),
          ),
          [
            'storage:start',
            'storage:opened',
            'storage:ready',
            'account:construct',
            'account:initialize',
            'account:storage',
            'account:database',
          ],
        );
        expect(fixture.databaseFiles, hasLength(1));
        expect(
          p.isWithin(fixture.original.path, fixture.databaseFiles.single.path),
          isTrue,
        );
        final yun = tester.widget<YunApp>(find.byType(YunApp));
        expect(yun.dataDirectory, same(fixture.data));
        expect(yun.directoryPicker, isNotNull);
        await fixture.settings();
        final storage = tester.widget<DataStorageSettings>(
          find.byType(DataStorageSettings),
        );
        expect(storage.controller, same(yun.dataDirectory));
        expect(storage.picker, same(yun.directoryPicker));
        expect(find.text('Current data directory'), findsOneWidget);
        expect(find.text(fixture.original.path), findsOneWidget);
      });
    },
  );

  testWidgets(
    'custom account factory alone bypasses platform storage selection',
    (tester) async {
      const channel = MethodChannel('yun/data_directory');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        throw PlatformException(code: 'must_not_access_native_storage');
      });
      try {
        await _withBootstrap(tester, (fixture) async {
          // Even corrupt storage configuration must be irrelevant to a custom
          // account factory unless an explicit storage factory is supplied.
          fixture.store.value = '{broken';
          await fixture.mount(resolveStorage: false);
          expect(find.byType(YunApp), findsOneWidget);
          expect(fixture.apps.single.initialized, isTrue);
          expect(calls, isEmpty);
          expect(
            fixture.events.where((e) => e.startsWith('storage:')),
            isEmpty,
          );
          expect(fixture.data, isNull);
          expect(
            tester.widget<YunApp>(find.byType(YunApp)).dataDirectory,
            isNull,
          );
          await fixture.settings();
          expect(find.text('Appearance'), findsOneWidget);
          expect(find.byType(DataStorageSettings), findsNothing);
          expect(fixture.store.value, '{broken');
        }, platform: TargetPlatform.macOS);
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
      }
    },
  );

  for (final failure in ['malformed configuration', 'disconnected root']) {
    testWidgets('storage $failure prevents account construction and DB open', (
      tester,
    ) async {
      await _withBootstrap(tester, (fixture) async {
        if (failure == 'malformed configuration') {
          fixture.store.value = '{broken';
        } else {
          final data = await DataDirectoryController.open(
            store: fixture.store,
            defaultDirectory: () async => fixture.original,
          );
          data.dispose();
          await fixture.original.delete(recursive: true);
        }
        final saved = fixture.store.value;
        await fixture.mount();
        expect(find.text('Your library could not be opened.'), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);
        expect(
          find.textContaining(
            failure == 'malformed configuration'
                ? 'FormatException'
                : 'FileSystemException',
          ),
          findsOneWidget,
        );
        expect(find.byType(YunApp), findsNothing);
        expect(fixture.apps, isEmpty);
        expect(fixture.engines, isEmpty);
        expect(fixture.hosts, isEmpty);
        expect(fixture.databaseFiles, isEmpty);
        expect(fixture.events, ['storage:start']);
        expect(fixture.store.value, saved);
        if (failure == 'disconnected root') {
          expect(await fixture.original.exists(), isFalse);
        }
      });
    });
  }

  testWidgets('a rejected storage selection does not block orderly quit', (
    tester,
  ) async {
    await _withBootstrap(tester, (fixture) async {
      await fixture.mount();
      final data = fixture.data!;
      final saved = fixture.store.value;
      await expectLater(
        data.changeDirectory('relative/folder'),
        throwsA(isA<FormatException>()),
      );
      expect(data.error, isNotNull);
      expect(data.currentPath, fixture.original.path);
      expect(data.pendingPath, isNull);
      expect(fixture.store.value, saved);

      final desktop = tester.widget<YunApp>(find.byType(YunApp)).desktop!;
      // Bootstrap's exit preflight flushes the data-directory queue even after
      // the rejected edit. No cancellation or successful selection is needed.
      await desktop.quit();
      expect(desktop.error, isNull);
      expect(fixture.engines.single.controller.isClosed, isTrue);
      expect(fixture.events, containsAllInOrder(['dispose', 'exit']));
      expect(fixture.store.value, saved);
    });
  });

  testWidgets(
    'restart migrates persisted storage before account initialization',
    (tester) async {
      await _withBootstrap(tester, (fixture) async {
        await fixture.mount();
        expect(find.byType(YunApp), findsOneWidget);
        final accountDirectory = fixture.databaseFiles.single.parent;
        final audioRelative = p.relative(
          p.join(accountDirectory.path, 'audio', 'offline.bin'),
          from: fixture.original.path,
        );
        final uploadRelative = p.relative(
          p.join(accountDirectory.path, 'imports', 'pending.flac'),
          from: fixture.original.path,
        );
        final payloads = {
          audioRelative: 'offline audio',
          uploadRelative: 'pending upload',
          p.join('artwork', 'cover.bin'): 'cached artwork',
        };
        for (final entry in payloads.entries) {
          await fixture.file(fixture.original.path, entry.key, entry.value);
        }
        await fixture.databases.single.put('meta', 'storage-integration', {
          'value': 'survives restart',
        });
        await fixture.data!.changeDirectory(fixture.target.path);
        expect(fixture.data!.currentPath, fixture.original.path);
        expect(fixture.config['pending'], fixture.target.path);
        expect(await fixture.target.list().isEmpty, isTrue);
        for (final entry in payloads.entries) {
          expect(
            await File(p.join(fixture.original.path, entry.key)).readAsString(),
            entry.value,
          );
        }
        await fixture.unmount();
        expect(fixture.engines.first.controller.isClosed, isTrue);
        // Reuse the same store: this launch must consume the durable choice.
        fixture.events.clear();
        fixture.beforeInitialize = (app) async {
          expect(fixture.data!.currentPath, fixture.target.path);
          expect(fixture.data!.pendingPath, isNull);
          expect(fixture.data!.error, isNull);
          expect(fixture.config['active'], fixture.target.path);
          expect(fixture.config.containsKey('pending'), isFalse);
          expect(fixture.databaseFiles, hasLength(1));
          for (final entry in payloads.entries) {
            expect(
              await File(p.join(fixture.target.path, entry.key)).readAsString(),
              entry.value,
            );
            expect(
              await File(p.join(fixture.original.path, entry.key)).exists(),
              isFalse,
            );
          }
        };
        await fixture.mount();
        expect(find.byType(YunApp), findsOneWidget);
        expect(fixture.apps, hasLength(2));
        expect(fixture.apps.last.initializeCalls, 1);
        expect(fixture.apps.last.initialized, isTrue);
        expect(fixture.databaseFiles, hasLength(2));
        expect(
          p.isWithin(fixture.target.path, fixture.databaseFiles.last.path),
          isTrue,
        );
        expect(
          await fixture.databases.last.get('meta', 'storage-integration'),
          {'value': 'survives restart'},
        );
        expect(
          fixture.events.indexOf('storage:ready'),
          lessThan(fixture.events.indexOf('account:initialize')),
        );
        await fixture.settings();
        expect(
          tester
              .widget<DataStorageSettings>(find.byType(DataStorageSettings))
              .controller,
          same(fixture.data),
        );
        expect(find.text(fixture.target.path), findsOneWidget);
        expect(
          find.text('Restart required · Next data directory'),
          findsNothing,
        );
      });
    },
  );
}
