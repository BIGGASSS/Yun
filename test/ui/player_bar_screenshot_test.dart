import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart' show Track;
import 'package:yun/core/playback_controller.dart' show RepeatMode;
import 'package:yun/services/playback_engine.dart';
import 'package:yun/ui/player.dart';
import 'package:yun/ui/theme.dart';

import '../core/fakes.dart';
import 'player_test_app.dart';

// Renders the desktop player bar in isolation and pins it to golden images so
// the redesign is reviewable and regressions are visible. Update with:
// fvm flutter test test/ui/player_bar_screenshot_test.dart --update-goldens
void main() {
  const shotKey = ValueKey('player-bar-shot');

  Future<void> Function(WidgetTester) pumpBarForShot({
    required String name,
    required Size size,
    ThemeData? theme,
    double volume = 20,
    bool playing = true,
    bool shuffle = false,
    RepeatMode repeat = RepeatMode.off,
    String? playbackFailure,
    bool compact = false,
    bool offline = false,
    double textScale = 1,
  }) {
    return (tester) async {
      final engine = FakeEngine();
      final app = PlayerTestApp(engine);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      app.disconnected = offline;
      try {
        await app.playback.playQueue(const [
          Track(id: 'one', title: 'Love in 561.3mb', artist: '5_Ya'),
        ]);
        engine.emit(
          EngineState(
            playing: playbackFailure == null && playing,
            position: const Duration(seconds: 73),
            duration: const Duration(seconds: 140),
            error: playbackFailure,
          ),
        );
        await app.playback.setVolume(volume);
        app.playback
          ..setShuffle(shuffle)
          ..setRepeat(repeat);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme ?? YunTheme.dark(),
            home: Scaffold(
              body: Center(
                child: RepaintBoundary(
                  key: shotKey,
                  child: ListenableBuilder(
                    listenable: app,
                    builder: (context, _) =>
                        PlayerBar(app: app, compact: compact, onQueue: () {}),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await expectLater(
          find.byKey(shotKey),
          matchesGoldenFile('goldens/$name.png'),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(app.shutdown);
        app.dispose();
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      }
    };
  }

  testWidgets(
    'wide dark desktop player bar',
    pumpBarForShot(name: 'player_bar_wide_dark', size: const Size(1848, 120)),
  );

  testWidgets(
    'wide light desktop player bar with selected toggles',
    pumpBarForShot(
      name: 'player_bar_wide_light_selected',
      size: const Size(1848, 120),
      theme: YunTheme.light(),
      volume: 65,
      shuffle: true,
      repeat: RepeatMode.one,
    ),
  );

  testWidgets(
    'narrow dark desktop player bar, paused and muted',
    pumpBarForShot(
      name: 'player_bar_narrow_dark',
      size: const Size(840, 120),
      volume: 0,
      playing: false,
    ),
  );

  testWidgets(
    'desktop downloaded playback error and explicit repair',
    pumpBarForShot(
      name: 'player_bar_download_error',
      size: const Size(1280, 250),
      playbackFailure: 'Decoder could not read downloaded file',
    ),
  );

  testWidgets(
    'compact downloaded playback error and explicit repair',
    pumpBarForShot(
      name: 'player_bar_compact_download_error',
      size: const Size(390, 360),
      playbackFailure: 'Decoder could not read downloaded file',
      compact: true,
    ),
  );

  testWidgets(
    'large text offline downloaded playback error and explanation',
    pumpBarForShot(
      name: 'player_bar_offline_download_error_large_text',
      size: const Size(320, 480),
      playbackFailure: 'Decoder could not read downloaded file',
      compact: true,
      offline: true,
      textScale: 2,
    ),
  );
}
