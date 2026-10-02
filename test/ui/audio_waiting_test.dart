import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/services/playback_engine.dart';
import 'package:yun/ui/player.dart';
import 'package:yun/ui/player_icons.dart';

import '../core/fakes.dart';
import 'player_test_app.dart';

const _waiting = EngineState(
  waitingForAudio: true,
  position: Duration(seconds: 12),
  duration: Duration(seconds: 120),
);

void main() {
  setUp(mockDesktopDrop);

  Finder repairButton() => find.widgetWithText(OutlinedButton, 'Redownload');

  void expectWaitingNotice(WidgetTester tester, Finder notice) {
    final text = find.descendant(
      of: notice,
      matching: find.text('Waiting for audio'),
    );
    expect(text, findsOneWidget);
    final widget = tester.widget<Text>(text);
    final theme = Theme.of(tester.element(text));
    expect(widget.style?.color, theme.colorScheme.onSurfaceVariant);
    expect(widget.style?.color, isNot(theme.colorScheme.error));
    expect(widget.semanticsLabel, 'Waiting for audio');
    expect(
      tester.getSemantics(text).getSemanticsData().flagsCollection.isLiveRegion,
      isTrue,
    );
    expect(repairButton(), findsNothing);
    expect(find.textContaining('downloaded audio'), findsNothing);
  }

  for (final layout in [
    (TargetPlatform.android, const Size(390, 844), 1.0),
    (TargetPlatform.android, const Size(320, 568), 2.0),
    (TargetPlatform.iOS, const Size(390, 844), 1.0),
    (TargetPlatform.android, const Size(1200, 800), 1.0),
    (TargetPlatform.linux, const Size(1280, 800), 1.0),
    (TargetPlatform.linux, const Size(320, 568), 2.0),
  ]) {
    playerTest(
      'waiting offers repeatable Pause cancellation in ${layout.$1.name} '
      '${layout.$2.width} player at ${layout.$3}x text',
      platform: layout.$1,
      size: layout.$2,
      textScale: layout.$3,
      (tester, app, engine) async {
        final semantics = tester.ensureSemantics();
        try {
          for (var attempt = 0; attempt < 2; attempt++) {
            engine.emit(_waiting);
            await tester.pumpAndSettle();

            expect(app.playback.isPlaying, isFalse);
            expect(app.playback.isWaitingForAudio, isTrue);
            expect(app.playback.isBuffering, isFalse);
            expect(app.playback.error, isNull);
            expectWaitingNotice(tester, find.byType(PlaybackErrorNotice));
            expect(find.byTooltip('Pause'), findsOneWidget);
            expect(find.byTooltip('Play'), findsNothing);
            if (layout.$1 == TargetPlatform.linux && layout.$2.width >= 840) {
              expect(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is PlayerIcon && widget.glyph == PlayerGlyph.pause,
                ),
                findsOneWidget,
              );
            } else {
              expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
            }
            final bar = tester.getRect(find.byType(PlayerBar));
            final notice = tester.getRect(find.text('Waiting for audio'));
            expect(bar.contains(notice.center), isTrue);
            expect(notice.right, lessThanOrEqualTo(layout.$2.width));
            expect(notice.bottom, lessThanOrEqualTo(layout.$2.height));
            expect(tester.takeException(), isNull);

            await tester.tap(find.byTooltip('Pause'));
            await tester.pumpAndSettle();
            expect(app.playback.isWaitingForAudio, isFalse);
            expect(app.playback.isPlaying, isFalse);
            expect(find.text('Waiting for audio'), findsNothing);
            expect(find.byTooltip('Play'), findsOneWidget);
            expect(repairButton(), findsNothing);

            await tester.tap(find.byTooltip('Play'));
            await tester.pumpAndSettle();
            expect(app.playback.isPlaying, isTrue);
            expect(app.playback.isWaitingForAudio, isFalse);
            expect(app.playback.position, const Duration(seconds: 12));
            expect(find.text('Waiting for audio'), findsNothing);
            expect(find.byTooltip('Pause'), findsOneWidget);
            expect(engine.opens, 1);
            expect(app.redownloadedTrackIds, isEmpty);
          }

          // Regaining focus replaces the status without requiring any tap.
          engine.emit(_waiting);
          await tester.pumpAndSettle();
          engine.emit(
            const EngineState(
              playing: true,
              position: Duration(seconds: 12),
              duration: Duration(seconds: 120),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Waiting for audio'), findsNothing);
          expect(find.byTooltip('Pause'), findsOneWidget);
          expect(app.playback.isPlaying, isTrue);
          expect(app.playback.error, isNull);

          // A system Stop also removes the pending status and selected track.
          engine.emit(_waiting);
          await tester.pumpAndSettle();
          await app.playback.stop();
          await tester.pumpAndSettle();
          expect(app.playback.isWaitingForAudio, isFalse);
          expect(find.text('Waiting for audio'), findsNothing);
          expect(repairButton(), findsNothing);
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  playerTest(
    'now playing wait and cancel survives closing and reopening at large text',
    platform: TargetPlatform.android,
    size: const Size(320, 800),
    textScale: 2,
    (tester, app, engine) async {
      final semantics = tester.ensureSemantics();
      final sheet = find.byType(BottomSheet);
      Finder inSheet(Finder finder) =>
          find.descendant(of: sheet, matching: finder);
      final fullNotice = find.byWidgetPredicate(
        (widget) => widget is PlaybackErrorNotice && !widget.compact,
      );
      try {
        engine.emit(_waiting);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Test track'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(fullNotice);
        await tester.pumpAndSettle();
        expectWaitingNotice(tester, fullNotice);
        expect(
          tester.widget<Text>(inSheet(find.text('Waiting for audio'))).maxLines,
          isNull,
        );
        expect(inSheet(find.byIcon(Icons.pause_rounded)), findsOneWidget);
        await tester.ensureVisible(inSheet(find.byTooltip('Pause')));
        await tester.pumpAndSettle();
        await tester.tap(inSheet(find.byTooltip('Pause')));
        await tester.pumpAndSettle();
        expect(app.playback.isPlaying, isFalse);
        expect(app.playback.isWaitingForAudio, isFalse);
        expect(find.text('Waiting for audio'), findsNothing);
        expect(inSheet(find.byTooltip('Play')), findsOneWidget);

        await tester.tap(inSheet(find.byTooltip('Play')));
        await tester.pumpAndSettle();
        expect(app.playback.isPlaying, isTrue);
        expect(app.playback.position, const Duration(seconds: 12));
        engine.emit(_waiting);
        await tester.pumpAndSettle();
        await tester.ensureVisible(fullNotice);
        await tester.pumpAndSettle();
        expectWaitingNotice(tester, fullNotice);

        // Dismissing the sheet does not cancel an intentional pending Play.
        await tester.ensureVisible(find.byTooltip('Close now playing'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Close now playing'));
        await tester.pumpAndSettle();
        expect(sheet, findsNothing);
        expect(app.playback.isWaitingForAudio, isTrue);
        expectWaitingNotice(tester, find.byType(PlaybackErrorNotice));
        await tester.tap(find.byTooltip('Pause'));
        await tester.pumpAndSettle();
        expect(app.playback.isWaitingForAudio, isFalse);
        await tester.tap(find.text('Test track'));
        await tester.pumpAndSettle();
        expect(find.text('Waiting for audio'), findsNothing);
        expect(inSheet(find.byTooltip('Play')), findsOneWidget);
        expect(repairButton(), findsNothing);
        expect(app.redownloadedTrackIds, isEmpty);
        expect(engine.opens, 1);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('waiting notice independently observes waiting state', (
    tester,
  ) async {
    final engine = FakeEngine();
    final app = PlayerTestApp(engine);
    try {
      await app.playback.playQueue(const [
        Track(id: 'one', title: 'Test track'),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PlaybackErrorNotice(app: app, compact: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Waiting for audio'), findsNothing);

      engine.emit(_waiting);
      await tester.pumpAndSettle();
      expect(find.text('Waiting for audio'), findsOneWidget);
      await app.playback.pause();
      await tester.pumpAndSettle();
      expect(find.text('Waiting for audio'), findsNothing);
      engine.emit(_waiting);
      await tester.pumpAndSettle();
      expect(find.text('Waiting for audio'), findsOneWidget);
      await app.playback.stop();
      await tester.pumpAndSettle();
      expect(find.text('Waiting for audio'), findsNothing);
      expect(repairButton(), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(app.shutdown);
      app.dispose();
    }
  });
}
