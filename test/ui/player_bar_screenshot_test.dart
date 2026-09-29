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
  }) {
    return (tester) async {
      final engine = FakeEngine();
      final app = PlayerTestApp(engine);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      try {
        await app.playback.playQueue(const [
          Track(id: 'one', title: 'Love in 561.3mb', artist: '5_Ya'),
        ]);
        engine.emit(
          EngineState(
            playing: playing,
            position: const Duration(seconds: 73),
            duration: const Duration(seconds: 140),
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
                        PlayerBar(app: app, compact: false, onQueue: () {}),
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
}
