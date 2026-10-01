import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Exercise the plugin's platform mock without adding a production dependency.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/core/collection_settings_controller.dart';
import 'package:yun/core/desktop_controller.dart';
import 'package:yun/main.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/collection_settings_store.dart';
import 'package:yun/services/desktop_settings_store.dart';
import 'package:yun/services/playback_settings_store.dart';
import 'package:yun/ui/app.dart';

import 'core/fake_desktop_host.dart';
import 'core/fakes.dart';
import 'ui/player_test_app.dart' show mockDesktopDrop;

class _CollectionPreferencesStore extends InMemorySharedPreferencesStore {
  _CollectionPreferencesStore() : super.empty();

  bool rejectCollectionWrites = true;
  final failure = PlatformException(code: 'collection_write_failed');

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (rejectCollectionWrites &&
        key == 'flutter.${SharedPreferencesCollectionSettingsStore.key}') {
      throw failure;
    }
    return super.setValue(valueType, key, value);
  }
}

ApiClient _bootstrapApi() =>
    ApiClient(
        credentials: MemoryCredentials(),
        dio: Dio()
          ..httpClientAdapter = FakeAdapter((options, _) {
            throw StateError('Unexpected bootstrap request: ${options.uri}');
          }),
      )
      ..session = SessionCredentials(
        account: const Account(
          server: 'https://yun.test',
          userId: 'user',
          username: 'listener',
        ),
        accessToken: 'test-access',
        refreshToken: 'test-refresh',
        expiresAt: DateTime.now()
            .add(const Duration(days: 1))
            .millisecondsSinceEpoch,
      );

/// Credentials, storage and the engine are isolated. Playback and the entire
/// orderly shutdown remain real; a gate exposes the native-exit ordering.
class _BootstrapApp extends AppController {
  _BootstrapApp({
    required FakeEngine engine,
    required super.storageDirectory,
    required super.playbackSettings,
    required super.savePlaybackSettings,
    required this.events,
    this.failStartup = false,
  }) : super(
         api: _bootstrapApi(),
         playbackEngine: engine,
         enableSystemControls: false,
         automaticRefresh: false,
       );

  final List<String> events;
  final bool failStartup;
  final shutdownStarted = Completer<void>();
  Completer<void>? shutdownGate;
  Future<void>? _shutdown;
  int initializeCalls = 0;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    if (failStartup) throw StateError('fixture startup failure');
    await super.initialize();
  }

  @override
  Future<void> shutdown() => _shutdown ??= () async {
    events.add('shutdown:start');
    shutdownStarted.complete();
    await shutdownGate?.future;
    await super.shutdown();
    events.add('shutdown:done');
  }();
}

class _Fixture {
  _Fixture(this.tester, {this.failStartup = false});

  final WidgetTester tester;
  final bool failStartup;
  final apps = <_BootstrapApp>[];
  final engines = <FakeEngine>[];
  final hosts = <FakeDesktopHost>[];
  final events = <String>[];
  Directory? storage;

  _BootstrapApp get app => apps.last;
  FakeEngine get engine => engines.last;
  FakeDesktopHost get host => hosts.last;
  DesktopController get desktop =>
      tester.widget<YunApp>(find.byType(YunApp)).desktop!;

  Future<void> mount() async {
    storage ??= await Directory.systemTemp.createTemp('yun-bootstrap-test-');
    await tester.pumpWidget(
      YunBootstrap(
        desktopHostFactory: () {
          final host = FakeDesktopHost(events);
          hosts.add(host);
          return host;
        },
        controllerFactory:
            ({required playbackSettings, required savePlaybackSettings}) {
              final engine = FakeEngine();
              engines.add(engine);
              final app = _BootstrapApp(
                engine: engine,
                storageDirectory: () async => storage!,
                playbackSettings: playbackSettings,
                savePlaybackSettings: savePlaybackSettings,
                events: events,
                failStartup: failStartup,
              );
              apps.add(app);
              return app;
            },
      ),
    );
    // Native/settings futures can finish after pumpAndSettle observes no
    // scheduled frame. Yield real time until bootstrap has built its result.
    for (var i = 0; i < 100; i++) {
      await Future<void>.delayed(Duration.zero);
      await tester.pumpAndSettle();
      if (find.byType(YunApp).evaluate().isNotEmpty ||
          find
              .text('Your library could not be opened.')
              .evaluate()
              .isNotEmpty) {
        return;
      }
    }
    fail('Bootstrap did not finish opening');
  }

  Future<void> unmount() async {
    await app.shutdown();
    await tester.pumpWidget(const SizedBox.shrink());
  }

  Future<void> dispose() async {
    for (final app in apps) {
      final gate = app.shutdownGate;
      if (gate != null && !gate.isCompleted) gate.complete();
      await app.shutdown();
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await storage?.delete(recursive: true);
  }
}

Future<void> _withBootstrap(
  WidgetTester tester,
  TargetPlatform platform,
  Future<void> Function(_Fixture) test, {
  Map<String, Object> preferences = const {},
  bool failStartup = false,
}) async {
  // Construction, controller queues and teardown must share a real async zone.
  // Creating stream/queue futures in fake time and only draining in runAsync
  // strands their continuations.
  await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues(preferences);
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    final fixture = _Fixture(tester, failStartup: failStartup);
    try {
      await fixture.mount();
      await test(fixture);
      expect(tester.takeException(), isNull);
    } finally {
      await fixture.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}

Future<void> _startFakePlayback(_Fixture fixture) async {
  // Resolve through the real, authenticated AppController. FakeEngine opens
  // the resulting source without accessing the network or a native player.
  await fixture.app.playback.playQueue(const [Track(id: 'a', title: 'A')]);
  expect(fixture.engine.opened, 'https://yun.test/api/v1/tracks/a/audio');
  expect(fixture.app.playback.error, isNull);
  expect(fixture.app.playback.isPlaying, isTrue);
  expect(fixture.engine.controller.isClosed, isFalse);
}

Future<Map<dynamic, dynamic>> _requestFrameworkExit() async {
  const codec = JSONMethodCodec();
  final response = Completer<Map<dynamic, dynamic>>();
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        SystemChannels.platform.name,
        codec.encodeMethodCall(
          const MethodCall('System.requestAppExit', {'type': 'cancelable'}),
        ),
        (data) => response.complete(codec.decodeEnvelope(data!) as Map),
      );
  return response.future;
}

void _expectShutdownBeforeDetach(_Fixture fixture, {required bool nativeExit}) {
  expect(fixture.engine.controller.isClosed, isTrue);
  expect(fixture.engine.calls, contains('stop'));
  expect(
    fixture.events.where(
      (event) => const [
        'shutdown:start',
        'shutdown:done',
        'dispose',
        'exit',
      ].contains(event),
    ),
    ['shutdown:start', 'shutdown:done', 'dispose', if (nativeExit) 'exit'],
  );
}

void main() {
  setUp(mockDesktopDrop);

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    testWidgets(
      '${platform.name}: close preference persists across bootstrap remounts',
      (tester) async {
        await _withBootstrap(tester, platform, (fixture) async {
          expect(fixture.hosts, hasLength(1));
          expect(fixture.app.initializeCalls, 1);
          expect(fixture.desktop.closeBehavior, DesktopCloseBehavior.quit);
          await fixture.desktop.setCloseBehavior(
            DesktopCloseBehavior.minimizeToTray,
          );
          await fixture.unmount();
          final oldDesktopHost = fixture.host;
          await fixture.mount();
          expect(fixture.hosts, hasLength(2));
          expect(identical(oldDesktopHost, fixture.host), isFalse);
          expect(
            fixture.desktop.closeBehavior,
            DesktopCloseBehavior.minimizeToTray,
          );
          expect(fixture.app.initializeCalls, 1);
          expect(fixture.engine.initializations, 0);

          await _startFakePlayback(fixture);
          final playback = fixture.app.playback;
          await playback.setVolume(27);
          playback.setShuffle(true);
          playback.setRepeat(RepeatMode.all);
          final engineCalls = List<String>.of(fixture.engine.calls);
          // These native window events are distinct from Flutter application quit
          // requests (including those forwarded by the Windows runner bridge).
          fixture.host.onClose!();
          await fixture.desktop.requestWindowClose();
          expect(fixture.host.visible, isFalse);
          expect(fixture.desktop.isHidden, isTrue);
          expect(fixture.app.shutdownStarted.isCompleted, isFalse);
          expect(fixture.engine.controller.isClosed, isFalse);
          expect(fixture.engine.calls, engineCalls);
          expect(playback.isPlaying, isTrue);
          expect(playback.queue.map((track) => track.id), ['a']);
          expect(playback.currentTrack?.id, 'a');
          final saved = await SharedPreferencesPlaybackSettingsStore(
            await SharedPreferences.getInstance(),
          ).read();
          expect(saved.volume, 27);
          expect(saved.shuffle, isTrue);
          expect(saved.repeatMode, RepeatMode.all);
          // Hiding has not disposed playback: controls still operate while hidden.
          await playback.pause();
          expect(playback.isPlaying, isFalse);
          await playback.play();
          expect(playback.isPlaying, isTrue);
          fixture.host.onShow!();
          await fixture.desktop.showWindow();
          expect(fixture.host.visible, isTrue);
          expect(fixture.desktop.isHidden, isFalse);

          await fixture.desktop.setCloseBehavior(DesktopCloseBehavior.quit);
          await fixture.unmount();
          await fixture.mount();
          expect(fixture.desktop.closeBehavior, DesktopCloseBehavior.quit);
        });
      },
    );

    testWidgets(
      '${platform.name}: default native close awaits full app shutdown before exit',
      (tester) async {
        await _withBootstrap(tester, platform, (fixture) async {
          await _startFakePlayback(fixture);
          fixture.app.shutdownGate = Completer<void>();
          fixture.host.onClose!();
          final closing = fixture.desktop.requestWindowClose();
          await fixture.app.shutdownStarted.future;
          expect(fixture.engine.controller.isClosed, isFalse);
          expect(fixture.events, isNot(contains('exit')));
          expect(fixture.events, isNot(contains('dispose')));
          fixture.app.shutdownGate!.complete();
          await closing;
          _expectShutdownBeforeDetach(fixture, nativeExit: true);
          expect(fixture.events, isNot(contains('hide')));
        });
      },
    );

    testWidgets(
      '${platform.name}: native Quit bypasses minimize and awaits shutdown',
      (tester) async {
        await _withBootstrap(
          tester,
          platform,
          (fixture) async {
            await _startFakePlayback(fixture);
            fixture.app.shutdownGate = Completer<void>();
            fixture.host.onQuit!();
            await fixture.app.shutdownStarted.future;
            expect(fixture.events, isNot(contains('exit')));
            expect(fixture.engine.controller.isClosed, isFalse);
            fixture.app.shutdownGate!.complete();
            await fixture.desktop.quit();
            _expectShutdownBeforeDetach(fixture, nativeExit: true);
            expect(fixture.events, isNot(contains('hide')));
          },
          preferences: {
            SharedPreferencesDesktopSettingsStore.closeBehaviorKey:
                'minimizeToTray',
          },
        );
      },
    );

    testWidgets(
      '${platform.name}: Flutter application exit ignores close-to-tray',
      (tester) async {
        await _withBootstrap(
          tester,
          platform,
          (fixture) async {
            expect(
              fixture.desktop.closeBehavior,
              DesktopCloseBehavior.minimizeToTray,
            );
            await _startFakePlayback(fixture);
            fixture.app.shutdownGate = Completer<void>();
            var responded = false;
            final response = _requestFrameworkExit().then((value) {
              responded = true;
              return value;
            });
            await fixture.app.shutdownStarted.future;
            expect(responded, isFalse);
            expect(fixture.engine.controller.isClosed, isFalse);
            expect(fixture.events, isNot(contains('dispose')));
            fixture.app.shutdownGate!.complete();
            expect(await response, {'response': 'exit'});
            _expectShutdownBeforeDetach(fixture, nativeExit: false);
            expect(fixture.events, isNot(contains('hide')));
            // Flutter owns this exit; do not request a second native application exit.
            expect(fixture.events, isNot(contains('exit')));
          },
          preferences: {
            SharedPreferencesDesktopSettingsStore.closeBehaviorKey:
                'minimizeToTray',
          },
        );
      },
    );
  }

  for (final exit in ['native', 'framework']) {
    for (final recovery in ['none', 'before', 'after']) {
      final recoverBeforeExit = recovery == 'before';
      testWidgets(
        'collection save failure with $recovery recovery on $exit application exit',
        (tester) async {
          await _withBootstrap(tester, TargetPlatform.linux, (fixture) async {
            await _startFakePlayback(fixture);
            final engineCalls = List<String>.of(fixture.engine.calls);
            final desktop = fixture.desktop;
            final settings = tester
                .widget<YunApp>(find.byType(YunApp))
                .collectionSettings!;
            final original = SharedPreferencesStorePlatform.instance;
            final store = _CollectionPreferencesStore();
            SharedPreferencesStorePlatform.instance = store;
            addTearDown(
              () => SharedPreferencesStorePlatform.instance = original,
            );

            await expectLater(
              settings.setTrackSort(
                TrackSortSurface.library,
                TrackSort.duration,
                descending: true,
              ),
              throwsA(same(store.failure)),
            );
            // The failed write is already settled before shutdown starts.
            expect(desktop.error, isNull);

            Future<void> recover() async {
              store.rejectCollectionWrites = false;
              await settings.setPlaylistSort(
                PlaylistSort.count,
                descending: true,
              );
              await settings.flushSettings();
              final preferences = await SharedPreferences.getInstance();
              await preferences.reload();
              final saved = await SharedPreferencesCollectionSettingsStore(
                preferences,
              ).read();
              // A later successful snapshot includes the previously failed edit.
              expect(
                saved.trackSort(TrackSortSurface.library).sort,
                TrackSort.duration,
              );
              expect(
                saved.trackSort(TrackSortSurface.library).descending,
                isTrue,
              );
              expect(saved.playlists.sort, PlaylistSort.count);
            }

            if (recoverBeforeExit) await recover();

            if (exit == 'native') {
              fixture.host.onClose!();
              await desktop.requestWindowClose();
            } else {
              expect(await _requestFrameworkExit(), {
                'response': recoverBeforeExit ? 'exit' : 'cancel',
              });
            }

            if (recoverBeforeExit) {
              _expectShutdownBeforeDetach(
                fixture,
                nativeExit: exit == 'native',
              );
              expect(desktop.error, isNull);
            } else {
              // Bootstrap must surface the failure at the desktop boundary,
              // without starting controller shutdown or releasing the host.
              expect(desktop.error, isNotNull);
              expect(desktop.isQuitting, isFalse);
              expect(fixture.host.visible, isTrue);
              expect(fixture.app.shutdownStarted.isCompleted, isFalse);
              expect(fixture.engine.controller.isClosed, isFalse);
              expect(fixture.engine.calls, engineCalls);
              expect(fixture.app.playback.isPlaying, isTrue);
              await expectLater(
                settings.flushSettings(),
                throwsA(same(store.failure)),
              );
              expect(
                fixture.events,
                isNot(
                  anyElement(
                    isIn([
                      'shutdown:start',
                      'shutdown:done',
                      'dispose',
                      'exit',
                    ]),
                  ),
                ),
              );
              if (recovery == 'after') {
                await recover();
                desktop.clearError();
                expect(desktop.canMinimize, isTrue);
                if (exit == 'native') {
                  fixture.host.onClose!();
                  await desktop.requestWindowClose();
                } else {
                  expect(await _requestFrameworkExit(), {'response': 'exit'});
                }
                _expectShutdownBeforeDetach(
                  fixture,
                  nativeExit: exit == 'native',
                );
                expect(desktop.error, isNull);
              }
            }
          });
        },
      );
    }
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      '${platform.name}: wide bootstrap never constructs a desktop host',
      (tester) async {
        await _withBootstrap(
          tester,
          platform,
          (fixture) async {
            expect(fixture.hosts, isEmpty);
            expect(fixture.events, isEmpty);
            expect(fixture.app.initializeCalls, 1);
            expect(tester.widget<YunApp>(find.byType(YunApp)).desktop, isNull);
            expect(await _requestFrameworkExit(), {'response': 'exit'});
            expect(fixture.engine.controller.isClosed, isTrue);
            expect(fixture.events, ['shutdown:start', 'shutdown:done']);
          },
          preferences: {
            SharedPreferencesDesktopSettingsStore.closeBehaviorKey:
                'minimizeToTray',
          },
        );
      },
    );
  }

  for (final exit in ['native', 'framework', 'both']) {
    testWidgets('startup Retry keeps shutdown interception for $exit exit', (
      tester,
    ) async {
      await _withBootstrap(
        tester,
        TargetPlatform.linux,
        (fixture) async {
          expect(
            find.text('Your library could not be opened.'),
            findsOneWidget,
          );
          final oldApp = fixture.app;
          final oldHost = fixture.host;
          oldApp.shutdownGate = Completer<void>();
          await tester.tap(find.text('Retry'));
          await oldApp.shutdownStarted.future;
          await tester.pumpAndSettle();
          expect(find.text('Opening your library…'), findsOneWidget);
          expect(fixture.apps, hasLength(1));
          expect(fixture.hosts, hasLength(1));
          expect(fixture.events, isNot(contains('dispose')));

          if (exit != 'framework') oldHost.onQuit!();
          var responded = false;
          final response = exit == 'native'
              ? null
              : _requestFrameworkExit().then((value) {
                  responded = true;
                  return value;
                });
          // Let competing quit requests run while Retry owns the gated core
          // shutdown. Neither native nor framework exit may bypass it.
          await Future<void>.delayed(Duration.zero);
          await tester.pumpAndSettle();
          expect(responded, isFalse);
          expect(fixture.engine.controller.isClosed, isFalse);
          expect(fixture.events, isNot(contains('exit')));
          expect(fixture.events, isNot(contains('dispose')));
          expect(fixture.apps, hasLength(1));
          expect(fixture.hosts, hasLength(1));

          oldApp.shutdownGate!.complete();
          await oldApp.shutdown();
          if (response != null) {
            expect(await response, {'response': 'exit'});
          }
          final boundary = exit == 'framework' ? 'dispose' : 'exit';
          for (var i = 0; i < 100 && !fixture.events.contains(boundary); i++) {
            await Future<void>.delayed(Duration.zero);
          }
          await tester.pumpAndSettle();
          _expectShutdownBeforeDetach(fixture, nativeExit: exit != 'framework');
          // Retry must notice that the old desktop is quitting, not replace
          // the application underneath an already-authorized exit.
          expect(fixture.apps, hasLength(1));
          expect(fixture.hosts, hasLength(1));
          expect(fixture.events, isNot(contains('show')));
          expect(fixture.events, isNot(contains('hide')));
        },
        failStartup: true,
        preferences: {
          SharedPreferencesDesktopSettingsStore.closeBehaviorKey:
              'minimizeToTray',
        },
      );
    });
  }

  testWidgets('startup Retry restores hidden window before replacing desktop', (
    tester,
  ) async {
    await _withBootstrap(
      tester,
      TargetPlatform.linux,
      (fixture) async {
        final oldApp = fixture.app;
        final oldHost = fixture.host;
        final oldEngine = fixture.engine;
        oldApp.shutdownGate = Completer<void>();
        await tester.tap(find.text('Retry'));
        await oldApp.shutdownStarted.future;
        oldHost.onClose!();
        for (var i = 0; i < 100 && oldHost.visible; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(oldHost.visible, isFalse);
        expect(oldEngine.controller.isClosed, isFalse);
        expect(fixture.events, isNot(contains('dispose')));
        expect(fixture.apps, hasLength(1));
        expect(fixture.hosts, hasLength(1));
        oldHost.before = (operation) async {
          if (operation == 'dispose') {
            expect(oldHost.visible, isTrue);
            expect(oldEngine.controller.isClosed, isTrue);
            expect(fixture.apps, hasLength(1));
          }
        };

        oldApp.shutdownGate!.complete();
        await oldApp.shutdown();
        for (var i = 0; i < 100; i++) {
          await Future<void>.delayed(Duration.zero);
          await tester.pumpAndSettle();
          if (fixture.apps.length == 2 &&
              find
                  .text('Your library could not be opened.')
                  .evaluate()
                  .isNotEmpty) {
            break;
          }
        }
        expect(fixture.apps, hasLength(2));
        expect(fixture.hosts, hasLength(2));
        expect(fixture.app.initializeCalls, 1);
        expect(oldHost.visible, isTrue);
        expect(
          fixture.events.where(
            (event) => const [
              'shutdown:start',
              'shutdown:done',
              'hide',
              'show',
              'dispose',
              'exit',
            ].contains(event),
          ),
          ['shutdown:start', 'hide', 'shutdown:done', 'show', 'dispose'],
        );
      },
      failStartup: true,
      preferences: {
        SharedPreferencesDesktopSettingsStore.closeBehaviorKey:
            'minimizeToTray',
      },
    );
  });

  testWidgets('startup failure still offers Quit Yun and awaits shutdown', (
    tester,
  ) async {
    await _withBootstrap(
      tester,
      TargetPlatform.linux,
      (fixture) async {
        expect(find.text('Your library could not be opened.'), findsOneWidget);
        expect(find.textContaining('fixture startup failure'), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);
        expect(find.byType(YunApp), findsNothing);
        fixture.app.shutdownGate = Completer<void>();
        await tester.tap(find.text('Quit Yun'));
        await fixture.app.shutdownStarted.future;
        expect(fixture.events, isNot(contains('exit')));
        fixture.app.shutdownGate!.complete();
        await fixture.app.shutdown();
        // The UI callback is deliberately void; observe the fake native boundary.
        for (var i = 0; i < 100 && !fixture.events.contains('exit'); i++) {
          await Future<void>.delayed(Duration.zero);
        }
        _expectShutdownBeforeDetach(fixture, nativeExit: true);
        expect(fixture.events, isNot(contains('hide')));
      },
      failStartup: true,
      preferences: {
        SharedPreferencesDesktopSettingsStore.closeBehaviorKey:
            'minimizeToTray',
      },
    );
  });
}
