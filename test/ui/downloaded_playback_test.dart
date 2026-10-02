import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/core/playback_controller.dart' show LocalAudioUnavailable;
import 'package:yun/services/playback_engine.dart';
import 'package:yun/ui/player.dart';

import '../core/fakes.dart';
import 'player_test_app.dart';

void main() {
  setUp(mockDesktopDrop);

  const nativeFailure = 'Decoder could not read downloaded file';
  const localFailure = 'Could not play the downloaded audio: $nativeFailure';
  Finder repairButton() => find.widgetWithText(OutlinedButton, 'Redownload');

  for (final layout in [
    (TargetPlatform.linux, const Size(1280, 800), 1.0),
    (TargetPlatform.android, const Size(390, 844), 1.0),
    (TargetPlatform.android, const Size(1200, 800), 1.0),
    (TargetPlatform.linux, const Size(320, 568), 2.0),
  ]) {
    playerTest(
      'download error and repair are visible in ${layout.$1.name} '
      '${layout.$2.width} player at ${layout.$3}x text',
      platform: layout.$1,
      size: layout.$2,
      textScale: layout.$3,
      (tester, app, engine) async {
        engine.emit(const EngineState(error: nativeFailure));
        await tester.pumpAndSettle();

        expect(find.text(nativeFailure), findsOneWidget);
        expect(find.text('Now playing'), findsNothing);
        expect(repairButton(), findsOneWidget);
        expect(
          tester.widget<OutlinedButton>(repairButton()).onPressed,
          isNotNull,
        );
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(app.playback.isBuffering, isFalse);
        expect(engine.opens, 1);
        expect(app.redownloadedTrackIds, isEmpty);
        final bar = tester.getRect(find.byType(PlayerBar));
        final action = tester.getRect(repairButton());
        expect(bar.contains(action.center), isTrue);
        expect(action.right, lessThanOrEqualTo(layout.$2.width));
        expect(action.bottom, lessThanOrEqualTo(layout.$2.height));

        // Quiet native events must not replace the original diagnosis.
        engine.emit(const EngineState());
        await tester.pumpAndSettle();
        expect(find.text(nativeFailure), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  playerTest(
    'explicit repair disables repeated clicks and never starts playback',
    platform: TargetPlatform.linux,
    (tester, app, engine) async {
      final completed = Completer<void>();
      app.onRedownloadTrack = (_) => completed.future;
      engine.emit(const EngineState(error: nativeFailure));
      await tester.pumpAndSettle();
      await tester.tap(repairButton());
      await tester.pumpAndSettle();
      final busyButton = find.widgetWithText(OutlinedButton, 'Redownloading…');
      expect(busyButton, findsOneWidget);
      expect(tester.widget<OutlinedButton>(busyButton).onPressed, isNull);
      await tester.tap(busyButton);
      await tester.pump();
      expect(app.redownloadedTrackIds, ['one']);
      expect(engine.opens, 1);

      completed.complete();
      await tester.pumpAndSettle();
      expect(
        find.text('Downloaded again. Press Play to retry.'),
        findsOneWidget,
      );
      expect(
        tester.widget<OutlinedButton>(repairButton()).onPressed,
        isNotNull,
      );
      expect(app.playback.isPlaying, isFalse);
      expect(engine.opens, 1);

      await tester.tap(find.byTooltip('Play'));
      await tester.pumpAndSettle();
      expect(app.playback.isPlaying, isTrue);
      expect(engine.opens, 2);
      expect(find.text(nativeFailure), findsNothing);
      expect(repairButton(), findsNothing);
    },
  );

  playerTest(
    'repair failure preserves diagnosis and allows another explicit attempt',
    platform: TargetPlatform.linux,
    (tester, app, engine) async {
      app.onRedownloadTrack = (_) async =>
          throw StateError('Server unavailable');
      engine.emit(const EngineState(error: nativeFailure));
      await tester.pumpAndSettle();
      await tester.tap(repairButton());
      await tester.pumpAndSettle();
      expect(find.textContaining('Server unavailable'), findsOneWidget);
      expect(find.text(nativeFailure), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(repairButton()).onPressed,
        isNotNull,
      );
      expect(app.redownloadedTrackIds, ['one']);
      expect(engine.opens, 1);
      expect(app.playback.isPlaying, isFalse);
    },
  );

  playerTest(
    'offline repair stays disabled with explanation and re-enables online',
    platform: TargetPlatform.linux,
    size: const Size(320, 568),
    textScale: 2,
    (tester, app, engine) async {
      app.disconnected = true;
      app.notifyListeners();
      engine.emit(const EngineState(error: nativeFailure));
      await tester.pumpAndSettle();
      expect(find.text('Reconnect to redownload'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(repairButton()).onPressed, isNull);
      await tester.tap(repairButton());
      await tester.pump();
      expect(app.redownloadedTrackIds, isEmpty);
      expect(find.text(nativeFailure), findsOneWidget);
      expect(tester.takeException(), isNull);

      app.disconnected = false;
      app.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Reconnect to redownload'), findsNothing);
      expect(
        tester.widget<OutlinedButton>(repairButton()).onPressed,
        isNotNull,
      );
    },
  );

  playerTest(
    'choosing another track hides stale local error and repair',
    platform: TargetPlatform.android,
    size: const Size(390, 844),
    tracks: const [
      Track(id: 'one', title: 'First track'),
      Track(id: 'two', title: 'Next track'),
    ],
    (tester, app, engine) async {
      engine.emit(const EngineState(error: nativeFailure));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next track'));
      await tester.pumpAndSettle();
      expect(app.playback.currentTrack?.id, 'two');
      expect(find.text(nativeFailure), findsNothing);
      expect(repairButton(), findsNothing);
      expect(app.redownloadedTrackIds, isEmpty);
    },
  );

  playerTest(
    'repair completion does not restore an older track or error after Next',
    platform: TargetPlatform.android,
    size: const Size(390, 844),
    tracks: const [
      Track(id: 'one', title: 'First track'),
      Track(id: 'two', title: 'Next track'),
    ],
    (tester, app, engine) async {
      final completed = Completer<void>();
      app.onRedownloadTrack = (_) => completed.future;
      engine.emit(const EngineState(error: nativeFailure));
      await tester.pumpAndSettle();
      await tester.tap(repairButton());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Next track'));
      await tester.pumpAndSettle();
      expect(app.playback.currentTrack?.id, 'two');
      expect(find.text('Redownloading…'), findsNothing);
      completed.complete();
      await tester.pumpAndSettle();
      expect(app.playback.currentTrack?.id, 'two');
      expect(find.text('Downloaded again. Press Play to retry.'), findsNothing);
      expect(find.text(nativeFailure), findsNothing);
      expect(repairButton(), findsNothing);
      expect(engine.opens, 2);
    },
  );

  playerTest(
    'now playing presents full local error and shared repair control',
    platform: TargetPlatform.android,
    size: const Size(320, 800),
    textScale: 2,
    (tester, app, engine) async {
      engine.emit(const EngineState(error: nativeFailure));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test track'));
      await tester.pumpAndSettle();
      final fullNotice = find.byWidgetPredicate(
        (widget) => widget is PlaybackErrorNotice && !widget.compact,
      );
      final fullError = find.descendant(
        of: fullNotice,
        matching: find.text(localFailure),
      );
      expect(fullError, findsOneWidget);
      expect(tester.widget<Text>(fullError).maxLines, isNull);
      final fullRepair = find.descendant(
        of: fullNotice,
        matching: repairButton(),
      );
      await tester.ensureVisible(fullRepair);
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(fullRepair).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing downloaded file offers explicit repair', (tester) async {
    final engine = FakeEngine();
    final app = PlayerTestApp(
      engine,
      resolveSource: (_, _) async => throw const LocalAudioUnavailable(
        'Downloaded audio is missing from this device. Redownload to repair it.',
      ),
    );
    try {
      await expectLater(
        app.playback.playQueue(const [Track(id: 'missing', title: 'Missing')]),
        throwsA(isA<LocalAudioUnavailable>()),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerBar(app: app, compact: true, onQueue: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Downloaded audio is missing'),
        findsOneWidget,
      );
      expect(repairButton(), findsOneWidget);
      expect(engine.opens, 0);
      expect(app.redownloadedTrackIds, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(app.shutdown);
      app.dispose();
    }
  });
}
