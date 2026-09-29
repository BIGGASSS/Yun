import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/main.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/playback_settings_store.dart';

import 'core/fakes.dart';
import 'ui/player_test_app.dart' show mockDesktopDrop;

/// Keep the real AppController -> PlaybackController wiring, without opening
/// host storage, secure credentials, a database, or a native audio player.
class _BootstrapApp extends AppController {
  _BootstrapApp({
    required FakeEngine engine,
    required super.playbackSettings,
    required super.savePlaybackSettings,
    required this.onInitialize,
  }) : super(
         api: ApiClient(credentials: MemoryCredentials()),
         playbackEngine: engine,
         enableSystemControls: false,
         automaticRefresh: false,
       );

  final void Function(_BootstrapApp) onInitialize;
  int initializeCalls = 0;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    onInitialize(this);
    initialized = true;
  }
}

void _expectRestored(
  _BootstrapApp app,
  FakeEngine engine,
  PlaybackSettings settings,
) {
  expect(app.playback.volume, settings.volume ?? 100);
  expect(app.playback.isMuted, settings.volume == 0);
  expect(app.playback.shuffle, settings.shuffle);
  expect(app.playback.repeatMode, settings.repeatMode);
  expect(app.playback.queue, isEmpty);
  expect(app.playback.currentTrack, isNull);
  expect(app.playback.isPlaying, isFalse);
  expect(engine.initializations, 0);
  expect(engine.opens, 0);
  expect(engine.volumeCalls, isEmpty);
}

Future<void> _initializeAudio(_BootstrapApp app) async {
  // The real controller initializes its engine before resolving the source.
  // Source resolution must refuse access because this fixture deliberately has
  // no signed-in account/cache. No network or host storage should be consulted.
  await expectLater(
    app.playback.playQueue(const [Track(id: 'a', title: 'A')]),
    throwsA(
      isA<StateError>().having((e) => e.message, 'message', 'Sign in required'),
    ),
  );
}

void main() {
  setUp(mockDesktopDrop);

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    testWidgets(
      '${platform.name}: bootstrap restores before initialize and survives remount',
      (tester) async {
        // Keep construction, settings queues and stream shutdown in one real
        // async zone. Moving only shutdown into runAsync can strand futures
        // created earlier in the widget test's fake clock zone.
        await tester.runAsync(() async {
          const seed = PlaybackSettings(
            volume: 36.5,
            lastPositiveVolume: 36.5,
            shuffle: true,
            repeatMode: RepeatMode.all,
          );
          SharedPreferences.setMockInitialValues({
            SharedPreferencesPlaybackSettingsStore.key: jsonEncode(
              seed.toJson(),
            ),
          });
          debugDefaultTargetPlatformOverride = platform;
          tester.view.physicalSize = const Size(1200, 800);
          tester.view.devicePixelRatio = 1;
          final desktop = platform != TargetPlatform.android;
          final apps = <_BootstrapApp>[];
          final engines = <FakeEngine>[];
          final received = <PlaybackSettings>[];
          var expected = PlaybackSettings(
            volume: desktop ? 36.5 : null,
            lastPositiveVolume: desktop ? 36.5 : 100,
            shuffle: true,
            repeatMode: RepeatMode.all,
          );
          Widget bootstrap() => YunBootstrap(
            controllerFactory:
                ({required playbackSettings, required savePlaybackSettings}) {
                  expect(playbackSettings.toJson(), expected.toJson());
                  received.add(playbackSettings);
                  final engine = FakeEngine()..volume = 63;
                  engines.add(engine);
                  final app = _BootstrapApp(
                    engine: engine,
                    playbackSettings: playbackSettings,
                    savePlaybackSettings: savePlaybackSettings,
                    onInitialize: (app) {
                      // Assert inside initialize, not only after bootstrap settles:
                      // applying settings after initialize would be too late.
                      expect(app.initialized, isFalse);
                      _expectRestored(app, engine, expected);
                    },
                  );
                  expect(app.initializeCalls, 0);
                  _expectRestored(app, engine, expected);
                  apps.add(app);
                  return app;
                },
          );

          try {
            await tester.pumpWidget(bootstrap());
            await tester.pumpAndSettle();
            expect(apps, hasLength(1));
            expect(apps.first.initializeCalls, 1);
            expect(apps.first.initialized, isTrue);
            expect(tester.takeException(), isNull);
            _expectRestored(apps.first, engines.first, expected);
            await _initializeAudio(apps.first);
            expect(engines.first.initializations, 1);
            expect(engines.first.volumeCalls, desktop ? [36.5] : isEmpty);
            expect(engines.first.volume, desktop ? 36.5 : 63);

            // All writes go through the callback supplied by production bootstrap.
            await apps.first.playback.setVolume(24.75);
            await apps.first.playback.toggleMute();
            apps.first.playback.setShuffle(false);
            apps.first.playback.setRepeat(RepeatMode.one);
            await apps.first.playback.flushSettings();
            final store = SharedPreferencesPlaybackSettingsStore(
              await SharedPreferences.getInstance(),
            );
            expect(
              (await store.read()).toJson(),
              const PlaybackSettings(
                volume: 0,
                lastPositiveVolume: 24.75,
                repeatMode: RepeatMode.one,
              ).toJson(),
            );

            // Drain in the real zone before unmount initiates disposal in the
            // fake clock zone, then fully remove the old bootstrap State.
            // Do not reseed preferences: the second bootstrap must see the writes.
            await apps.first.shutdown();
            await tester.pumpWidget(const SizedBox.shrink());
            expect(engines.first.controller.isClosed, isTrue);
            expected = PlaybackSettings(
              volume: desktop ? 0 : null,
              lastPositiveVolume: desktop ? 24.75 : 100,
              repeatMode: RepeatMode.one,
            );
            await tester.pumpWidget(bootstrap());
            await tester.pumpAndSettle();
            expect(apps, hasLength(2));
            expect(identical(apps.first, apps.last), isFalse);
            expect(received.last.toJson(), expected.toJson());
            expect(apps.last.initializeCalls, 1);
            _expectRestored(apps.last, engines.last, expected);
            await _initializeAudio(apps.last);
            expect(engines.last.volumeCalls, desktop ? [0] : isEmpty);
            expect(engines.last.volume, desktop ? 0 : 63);
            if (desktop) {
              await apps.last.playback.toggleMute();
              expect(apps.last.playback.volume, 24.75);
              expect(engines.last.volume, 24.75);
            }
            expect(tester.takeException(), isNull);
          } finally {
            for (final app in apps) {
              await app.shutdown();
            }
            await tester.pumpWidget(const SizedBox.shrink());
            debugDefaultTargetPlatformOverride = null;
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          }
        });
      },
    );
  }
}
