import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/core/playback_controller.dart' show AudioSource;
import 'package:yun/ui/app.dart';

import '../core/fakes.dart';

/// A signed-in app snapshot with real playback over a local [FakeEngine]; no
/// credential store, database, native player, or network is needed.
class PlayerTestApp extends ChangeNotifier implements AppController {
  PlayerTestApp(this.engine)
    : playback = PlaybackController(
        resolveSource: (_, _) async =>
            const AudioSource('fake.audio', local: true),
        engine: engine,
        enableSystemControls: false,
      ) {
    playback.addListener(notifyListeners);
  }

  final FakeEngine engine;

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
  // pull unrelated services into a player widget test.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected app operation: ${invocation.memberName}',
  );
}

/// Mocks the desktop_drop channel used by the app shell's drop region.
void mockDesktopDrop() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('desktop_drop'),
        (_) async => null,
      );
}

typedef PlayerTestBody = Future<void> Function(
  WidgetTester tester,
  PlayerTestApp app,
  FakeEngine engine,
);

/// Drives a [YunApp] test with [PlayerTestApp]. View, platform, and playback
/// cleanup happens in the test body's `finally`: the binding verifies debug
/// variables before `addTearDown` callbacks run, and stream cancellation needs
/// the real zone while the tester is still alive.
void playerTest(
  String description,
  PlayerTestBody body, {
  required TargetPlatform platform,
  Size size = const Size(1200, 800),
  double textScale = 1,
  List<Track> tracks = const [
    Track(id: 'one', title: 'Test track', artist: 'Test artist'),
  ],
}) {
  testWidgets(description, (tester) async {
    final engine = FakeEngine();
    final app = PlayerTestApp(engine);
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    try {
      if (tracks.isNotEmpty) {
        await app.playback.playQueue(tracks);
      }
      await tester.pumpWidget(YunApp(controller: app));
      await tester.pumpAndSettle();
      await body(tester, app, engine);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(app.shutdown);
      expect(engine.controller.isClosed, isTrue);
      app.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
  });
}
