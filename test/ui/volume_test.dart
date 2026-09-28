import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/core/playback_controller.dart' show AudioSource;
import 'package:yun/ui/app.dart';

import '../core/fakes.dart';

// Use real playback with a local fake source and a signed-in UI snapshot;
// no credential store, database, native player, or network is needed.
class _VolumeApp extends ChangeNotifier implements AppController {
  _VolumeApp(FakeEngine engine)
    : playback = PlaybackController(
        resolveSource: (_, _) async =>
            const AudioSource('fake.audio', local: true),
        engine: engine,
        enableSystemControls: false,
      ) {
    playback.addListener(notifyListeners);
  }

  @override
  final PlaybackController playback;
  @override
  bool get initialized => true;
  @override
  bool get busy => false;
  @override
  bool get isOffline => false;
  @override
  bool get isAuthenticated => true;
  @override
  Account get account => const Account(
    server: 'https://music.example.test',
    userId: 'user',
    username: 'Listener',
  );
  @override
  String? get error => null;
  @override
  List<Track> get tracks => const [];
  @override
  List<UploadJob> get uploads => const [];
  @override
  Future<String?> getArtwork(Track track) async => null;
  @override
  String? artworkPath(Track track) => null;
  @override
  bool isPinned(String kind, String id) => false;

  @override
  Future<void> shutdown() => playback.shutdown();

  @override
  void dispose() {
    playback.removeListener(notifyListeners);
    playback.dispose();
    super.dispose();
  }

  // Any unexpected account/database operation should fail rather than silently
  // pull unrelated services into a volume widget test.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected app operation: ${invocation.memberName}',
  );
}

void main() {
  final slider = find.byKey(const ValueKey('playback-volume-slider'));
  late FakeEngine engine;
  late _VolumeApp app;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('desktop_drop'),
          (_) async => null,
        );
  });

  void volumeTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      // Create playback in the widget's zone so its operation queue can be
      // driven by pumps, not in setUp's outer asynchronous zone.
      engine = FakeEngine();
      app = _VolumeApp(engine);
      try {
        await body(tester);
      } finally {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          // Stream subscription cancellation can return a future from outside
          // FakeAsync. Await cleanup in the real zone after draining UI work;
          // pumping alone cannot complete that external future.
          await tester.runAsync(app.shutdown);
          expect(engine.controller.isClosed, isTrue);
        } finally {
          app.dispose();
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });
  }

  Future<void> mount(
    WidgetTester tester,
    TargetPlatform platform, {
    Size size = const Size(1200, 800),
    double textScale = 1,
    bool playing = true,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    if (playing) {
      await app.playback.playQueue([
        const Track(id: 'one', title: 'Test track', artist: 'Test artist'),
      ]);
    }
    await tester.pumpWidget(YunApp(controller: app));
    await tester.pumpAndSettle();
  }

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    volumeTest('${platform.name} slider and mute control native volume', (
      tester,
    ) async {
      await mount(tester, platform);
      expect(slider, findsOneWidget);
      expect(engine.volumeCalls, isEmpty);
      tester.widget<Slider>(slider).onChanged!(37);
      await tester.pumpAndSettle();
      expect(engine.volume, 37);
      expect(tester.widget<Slider>(slider).value, 37);
      expect(
        tester.widget<Slider>(slider).semanticFormatterCallback!(37),
        '37%',
      );
      await tester.tap(find.byTooltip('Mute'));
      await tester.pumpAndSettle();
      expect(engine.volume, 0);
      expect(tester.widget<Slider>(slider).value, 0);
      await tester.tap(find.byTooltip('Unmute'));
      await tester.pumpAndSettle();
      expect(engine.volume, 37);
      expect(engine.volumeCalls, [37, 0, 37]);
      expect(tester.takeException(), isNull);
    });
  }

  volumeTest('idle desktop volume stays lazy and slider supports keyboard', (
    tester,
  ) async {
    await mount(tester, TargetPlatform.linux, playing: false);
    await tester.tap(slider);
    await tester.pumpAndSettle();
    final before = app.playback.volume;
    final focus = tester
        .widget<FocusableActionDetector>(
          find.descendant(
            of: slider,
            matching: find.byType(FocusableActionDetector),
          ),
        )
        .focusNode!;
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(app.playback.volume, lessThan(before));
    expect(engine.initializations, 0);
    expect(engine.volumeCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  volumeTest('desktop bar fits at its narrowest expanded breakpoint', (
    tester,
  ) async {
    await mount(
      tester,
      TargetPlatform.windows,
      size: const Size(840, 800),
      textScale: 1.5,
    );
    expect(slider, findsOneWidget);
    expect(find.byTooltip('Show queue'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  volumeTest(
    'compact desktop volume dialog fits narrow windows and large text',
    (tester) async {
      await mount(
        tester,
        TargetPlatform.linux,
        size: const Size(320, 568),
        textScale: 2,
      );
      expect(slider, findsNothing);
      await tester.tap(find.byTooltip('Volume'));
      await tester.pumpAndSettle();
      expect(slider, findsOneWidget);
      tester.widget<Slider>(slider).onChanged!(24);
      await tester.pumpAndSettle();
      expect(engine.volume, 24);
      await tester.tap(find.byTooltip('Mute'));
      await tester.pumpAndSettle();
      expect(engine.volume, 0);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(slider, findsNothing);
      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  volumeTest('now playing exposes the same desktop volume', (tester) async {
    await mount(tester, TargetPlatform.macOS, size: const Size(600, 800));
    await tester.tap(find.text('Test track'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(slider);
    tester.widget<Slider>(slider).onChanged!(19);
    await tester.pumpAndSettle();
    expect(app.playback.volume, 19);
    expect(engine.volume, 19);
    await tester.tap(find.byTooltip('Close now playing'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Volume'));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(slider).value, 19);
    expect(tester.takeException(), isNull);
  });

  volumeTest('native volume failure is reported without a false slider value', (
    tester,
  ) async {
    await mount(tester, TargetPlatform.linux);
    engine.onSetVolume = (_) async => throw StateError('Volume unavailable');
    tester.widget<Slider>(slider).onChanged!(20);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(slider).value, 100);
    expect(find.textContaining('Volume unavailable'), findsOneWidget);
    expect(engine.volume, 100);
    expect(tester.takeException(), isNull);
  });

  for (final width in [390.0, 1400.0]) {
    volumeTest('Android at width $width keeps its existing controls', (
      tester,
    ) async {
      await mount(tester, TargetPlatform.android, size: Size(width, 844));
      expect(slider, findsNothing);
      expect(find.byTooltip('Volume'), findsNothing);
      expect(find.byTooltip('Mute'), findsNothing);
      await tester.tap(find.text('Test track'));
      await tester.pumpAndSettle();
      expect(slider, findsNothing);
      expect(find.byTooltip('Mute'), findsNothing);
      expect(engine.volumeCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
