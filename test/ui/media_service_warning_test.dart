import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/core/playback_controller.dart' show AudioSource;
import 'package:yun/services/playback_engine.dart';
import 'package:yun/services/system_media_controls.dart';
import 'package:yun/ui/app.dart';
import 'package:yun/ui/player.dart';

import '../core/fakes.dart';
import 'player_test_app.dart' show mockDesktopDrop;

const _waiting = EngineState(
  waitingForAudio: true,
  position: Duration(seconds: 12),
  duration: Duration(seconds: 120),
);

class _RecoveringControls implements SystemMediaControls {
  bool fail = true;
  int initializations = 0;
  Completer<void>? recovery;

  @override
  Future<void> initialize(MediaCommands commands) async {
    initializations++;
    if (fail) throw StateError('Media service unavailable');
    await recovery?.future;
  }

  @override
  Future<void> update({
    required Track? track,
    required List<Track> queue,
    required int index,
    required bool playing,
    required bool buffering,
    bool waitingForAudio = false,
    required Duration position,
    required bool shuffle,
    required int repeat,
  }) async {}

  @override
  Future<void> dispose() async {}
}

/// Signed-in downloaded-library snapshot with the real controller, including
/// its normal system-control initialization and explicit playback retry paths.
class _ServiceTestApp extends ChangeNotifier implements AppController {
  _ServiceTestApp(FakeEngine engine, _RecoveringControls controls) {
    playback = PlaybackController(
      engine: engine,
      controls: controls,
      resolveSource: (_, localFirst) async {
        sourceRequests.add(localFirst);
        return const AudioSource('downloaded.audio', local: true);
      },
    );
  }

  final sourceRequests = <bool>[];
  final redownloadedTrackIds = <String>[];
  @override
  late final PlaybackController playback;
  @override
  final downloadChanges = ChangeNotifier();
  @override
  final verificationChanges = ChangeNotifier();
  @override
  final artworkChanges = ChangeNotifier();
  @override
  DownloadVerificationProgress? get verificationProgress => null;
  @override
  bool get redownloadingCorruptedFiles => false;
  @override
  int get downloadSectionsRevision => 0;
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
  VoidCallback? retainArtwork(Track track) => null;
  @override
  String? artworkPath(Track track) => null;
  @override
  bool isPinned(String kind, String id) => kind == 'track' && id == 'one';
  @override
  bool isRedownloadingTrack(String id) => false;
  @override
  Future<void> redownloadTrack(Track track) async {
    redownloadedTrackIds.add(track.id);
  }

  @override
  Future<void> shutdown() => playback.shutdown();

  @override
  void dispose() {
    downloadChanges.dispose();
    verificationChanges.dispose();
    artworkChanges.dispose();
    playback.dispose();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected app operation: ${invocation.memberName}',
  );
}

typedef _TestBody = Future<void> Function(
  WidgetTester tester,
  _ServiceTestApp app,
  FakeEngine engine,
  _RecoveringControls controls,
);

void _serviceTest(
  String description,
  _TestBody body, {
  TargetPlatform platform = TargetPlatform.android,
  Size size = const Size(390, 844),
  double textScale = 1,
}) {
  testWidgets(description, (tester) async {
    final engine = FakeEngine();
    final controls = _RecoveringControls();
    final app = _ServiceTestApp(engine, controls);
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    final semantics = tester.ensureSemantics();
    try {
      await app.playback.playQueue(const [
        Track(id: 'one', title: 'Downloaded track', artist: 'Test artist'),
      ]);
      await tester.pumpWidget(YunApp(controller: app));
      await tester.pumpAndSettle();
      await body(tester, app, engine, controls);
      expect(app.redownloadedTrackIds, isEmpty);
      expect(app.sourceRequests, everyElement(isTrue));
      expect(tester.takeException(), isNull);
    } finally {
      if (controls.recovery case final recovery? when !recovery.isCompleted) {
        recovery.complete();
        await tester.pump();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(app.shutdown);
      expect(engine.controller.isClosed, isTrue);
      app.dispose();
      semantics.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
  });
}

Finder _repairButton() => find.widgetWithText(OutlinedButton, 'Redownload');

void _expectWarning(WidgetTester tester, Finder notice, String message) {
  final warning = find.descendant(of: notice, matching: find.text(message));
  expect(warning, findsOneWidget);
  final text = tester.widget<Text>(warning);
  expect(text.semanticsLabel, message);
  expect(
    text.style?.color,
    Theme.of(tester.element(warning)).colorScheme.error,
  );
  expect(
    tester
        .getSemantics(warning)
        .getSemanticsData()
        .flagsCollection
        .isLiveRegion,
    isTrue,
  );
  expect(find.descendant(of: notice, matching: _repairButton()), findsNothing);
}

void main() {
  setUp(mockDesktopDrop);

  for (final layout in [
    (TargetPlatform.android, const Size(390, 844), 1.0),
    (TargetPlatform.android, const Size(320, 568), 2.0),
    (TargetPlatform.iOS, const Size(390, 844), 1.0),
    (TargetPlatform.android, const Size(1200, 800), 1.0),
    (TargetPlatform.linux, const Size(1280, 800), 1.0),
    (TargetPlatform.linux, const Size(320, 568), 2.0),
  ]) {
    _serviceTest(
      'service warning survives playback, pause, and waiting in '
      '${layout.$1.name} ${layout.$2.width} bar at ${layout.$3}x text',
      platform: layout.$1,
      size: layout.$2,
      textScale: layout.$3,
      (tester, app, engine, controls) async {
        final notice = find.byType(PlaybackErrorNotice);
        final message = app.playback.systemMediaControlsError!;
        expect(message, contains('Background playback'));
        expect(message, contains('system media controls unavailable'));
        expect(app.playback.isPlaying, isTrue);
        expect(app.playback.localPlaybackError, isNull);
        expect(engine.opened, 'downloaded.audio');
        expect(engine.opens, 1);
        expect(controls.initializations, 1);
        _expectWarning(tester, notice, message);
        expect(tester.widget<Text>(find.text(message)).maxLines, 3);
        expect(find.textContaining('downloaded audio'), findsNothing);
        final bar = tester.getRect(find.byType(PlayerBar));
        final warning = tester.getRect(find.text(message));
        expect(bar.contains(warning.center), isTrue);
        expect(warning.right, lessThanOrEqualTo(layout.$2.width));
        expect(warning.bottom, lessThanOrEqualTo(layout.$2.height));

        // Pause and another failed explicit Play do not hide the capability loss.
        await tester.tap(find.byTooltip('Pause'));
        await tester.pumpAndSettle();
        expect(app.playback.isPlaying, isFalse);
        _expectWarning(tester, notice, message);
        expect(controls.initializations, 1);
        await tester.tap(find.byTooltip('Play'));
        await tester.pumpAndSettle();
        expect(app.playback.isPlaying, isTrue);
        expect(controls.initializations, 2);
        _expectWarning(tester, notice, message);

        // Waiting has its own neutral status and Pause still cancels it.
        engine.emit(_waiting);
        await tester.pumpAndSettle();
        expect(find.text('Waiting for audio'), findsOneWidget);
        expect(find.byTooltip('Pause'), findsOneWidget);
        _expectWarning(tester, notice, message);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Pause'));
        await tester.pumpAndSettle();
        expect(app.playback.isWaitingForAudio, isFalse);
        expect(find.text('Waiting for audio'), findsNothing);
        expect(find.byTooltip('Play'), findsOneWidget);
        expect(controls.initializations, 2);
        _expectWarning(tester, notice, message);

        // Merely starting a retry must not imply that service recovery succeeded.
        controls.fail = false;
        controls.recovery = Completer<void>();
        await tester.tap(find.byTooltip('Play'));
        await tester.pump();
        expect(controls.initializations, 3);
        expect(app.playback.systemMediaControlsAvailable, isFalse);
        _expectWarning(tester, notice, message);
        controls.recovery!.complete();
        await tester.pumpAndSettle();
        expect(app.playback.systemMediaControlsAvailable, isTrue);
        expect(app.playback.systemMediaControlsError, isNull);
        expect(find.text(message), findsNothing);
        expect(app.playback.isPlaying, isTrue);
        expect(app.playback.position, const Duration(seconds: 12));
        expect(engine.opens, 1);
        expect(_repairButton(), findsNothing);
      },
    );
  }

  _serviceTest(
    'sheet preserves full warning through close, waiting, cancel and recovery',
    size: const Size(320, 800),
    textScale: 2,
    (tester, app, engine, controls) async {
      final message = app.playback.systemMediaControlsError!;
      final sheet = find.byType(BottomSheet);
      Finder inSheet(Finder finder) =>
          find.descendant(of: sheet, matching: finder);
      final fullNotice = find.byWidgetPredicate(
        (widget) => widget is PlaybackErrorNotice && !widget.compact,
      );
      await tester.tap(find.text('Downloaded track'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(fullNotice);
      await tester.pumpAndSettle();
      _expectWarning(tester, fullNotice, message);
      expect(tester.widget<Text>(inSheet(find.text(message))).maxLines, isNull);
      expect(inSheet(find.text('Kept offline')), findsOneWidget);
      expect(inSheet(find.text('Keep offline')), findsNothing);

      engine.emit(_waiting);
      await tester.pumpAndSettle();
      expect(inSheet(find.text('Waiting for audio')), findsOneWidget);
      _expectWarning(tester, fullNotice, message);
      await tester.ensureVisible(find.byTooltip('Close now playing'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close now playing'));
      await tester.pumpAndSettle();
      expect(app.playback.isWaitingForAudio, isTrue);
      _expectWarning(tester, find.byType(PlaybackErrorNotice), message);

      await tester.tap(find.text('Downloaded track'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(inSheet(find.byTooltip('Pause')));
      await tester.pumpAndSettle();
      await tester.tap(inSheet(find.byTooltip('Pause')));
      await tester.pumpAndSettle();
      expect(app.playback.isWaitingForAudio, isFalse);
      expect(find.text('Waiting for audio'), findsNothing);
      await tester.ensureVisible(fullNotice);
      await tester.pumpAndSettle();
      _expectWarning(tester, fullNotice, message);
      expect(controls.initializations, 1);

      controls.fail = false;
      await tester.ensureVisible(inSheet(find.byTooltip('Play')));
      await tester.pumpAndSettle();
      await tester.tap(inSheet(find.byTooltip('Play')));
      await tester.pumpAndSettle();
      expect(app.playback.systemMediaControlsError, isNull);
      expect(find.text(message), findsNothing);
      expect(app.playback.isPlaying, isTrue);
      expect(controls.initializations, 2);
      expect(engine.opens, 1);
      expect(inSheet(find.text('Kept offline')), findsOneWidget);
      expect(_repairButton(), findsNothing);
    },
  );

  _serviceTest(
    'local file error coexists with service warning until each recovers',
    size: const Size(320, 800),
    textScale: 2,
    (tester, app, engine, controls) async {
      final message = app.playback.systemMediaControlsError!;
      const nativeFailure = 'Decoder could not read downloaded file';
      engine.emit(const EngineState(error: nativeFailure));
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(find.text(nativeFailure), findsOneWidget);
      expect(_repairButton(), findsOneWidget);
      expect(app.playback.localPlaybackError, contains(nativeFailure));
      engine.emit(const EngineState());
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(find.text(nativeFailure), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Foreground retry succeeds even while the service still cannot reconnect.
      await tester.tap(find.byTooltip('Play'));
      await tester.pumpAndSettle();
      expect(app.playback.isPlaying, isTrue);
      expect(app.playback.localPlaybackError, isNull);
      expect(find.text(nativeFailure), findsNothing);
      _expectWarning(tester, find.byType(PlaybackErrorNotice), message);
      expect(controls.initializations, 2);
      expect(engine.opens, 2);

      await tester.tap(find.byTooltip('Pause'));
      await tester.pumpAndSettle();
      controls.fail = false;
      await tester.tap(find.byTooltip('Play'));
      await tester.pumpAndSettle();
      expect(app.playback.systemMediaControlsError, isNull);
      expect(find.text(message), findsNothing);
      expect(_repairButton(), findsNothing);
      expect(engine.opens, 2);
    },
  );
}
