import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/ui/player.dart';
import 'package:yun/ui/track_widgets.dart';

import '../core/fakes.dart';
import 'player_test_app.dart';

class _QueueApp extends PlayerTestApp {
  _QueueApp(super.engine);

  @override
  Future<void> queueNext(Track track) => playback.queueNext(track);
}

void main() {
  testWidgets('queue panel shows and highlights exact manual occurrences', (
    tester,
  ) async {
    final app = _QueueApp(FakeEngine());
    const original = Track(id: 'original', title: 'Original');
    const extra = Track(id: 'extra', title: 'Extra');
    try {
      await app.playback.playQueue([original]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QueuePanel(app: app)),
        ),
      );
      await app.playback.queueNextTracks([extra, extra]);
      await tester.pumpAndSettle();
      expect(find.text('Extra'), findsNWidgets(2));
      expect(
        tester
            .widgetList<ListTile>(find.byType(ListTile))
            .map((t) => t.selected),
        [true, false, false],
      );
      await app.playback.next();
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<ListTile>(find.byType(ListTile))
            .map((t) => t.selected),
        [false, true, false],
      );
      await app.playback.next();
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<ListTile>(find.byType(ListTile))
            .map((t) => t.selected),
        [false, false, true],
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(app.shutdown);
      app.dispose();
    }
  });

  testWidgets('queue panel updates when tracks are queued from idle', (
    tester,
  ) async {
    final app = _QueueApp(FakeEngine());
    const extra = Track(id: 'extra', title: 'Extra');
    const pending = Track(id: 'pending', title: 'Pending');
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: QueuePanel(app: app)),
        ),
      );
      expect(find.text('A quiet queue'), findsOneWidget);
      await app.playback.queueNextTracks([extra, pending]);
      await tester.pumpAndSettle();
      expect(find.text('A quiet queue'), findsNothing);
      expect(find.text('Extra'), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
      expect(
        tester
            .widgetList<ListTile>(find.byType(ListTile))
            .map((t) => t.selected),
        [true, false],
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(app.shutdown);
      app.dispose();
    }
  });

  for (final selectManual in [false, true]) {
    testWidgets(
      'queue panel selection preserves pending additions (manual=$selectManual)',
      (tester) async {
        final app = _QueueApp(FakeEngine());
        const original = Track(id: 'original', title: 'Original');
        const later = Track(id: 'later', title: 'Later');
        const extra = Track(id: 'extra', title: 'Extra');
        const pending = Track(id: 'pending', title: 'Pending');
        try {
          await app.playback.playQueue([original, later]);
          await app.playback.queueNextTracks([extra, pending]);
          final target = app.playback.effectiveQueue[selectManual ? 1 : 3];
          final pendingEntry = app.playback.effectiveQueue[2];
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(body: QueuePanel(app: app)),
            ),
          );
          await tester.tap(find.text(selectManual ? 'Extra' : 'Later'));
          await tester.pumpAndSettle();
          expect(
            app.playback.effectiveQueue[app.playback.effectiveIndex],
            same(target),
          );
          expect(app.playback.effectiveQueue, contains(same(pendingEntry)));
          expect(find.text('Pending'), findsOneWidget);
          if (!selectManual) {
            await app.playback.next();
            expect(app.playback.currentTrack, extra);
          }
          await app.playback.next();
          expect(app.playback.currentTrack, pending);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(app.shutdown);
          app.dispose();
        }
      },
    );
  }

  testWidgets(
    'track menu queues repeated selections without interrupting playback',
    (tester) async {
      final app = _QueueApp(FakeEngine());
      const original = Track(id: 'original', title: 'Original');
      const extra = Track(id: 'extra', title: 'Extra');
      try {
        await app.playback.playQueue([original]);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TrackMenu(app: app, track: extra),
            ),
          ),
        );
        for (var i = 0; i < 2; i++) {
          await tester.tap(find.byTooltip('Options for Extra'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Play next'));
          await tester.pumpAndSettle();
        }
        expect(app.playback.currentTrack, original);
        expect(app.playback.effectiveQueue.map((e) => e.track), [
          original,
          extra,
          extra,
        ]);
        await app.playback.next();
        expect(app.playback.currentTrack, extra);
        expect(app.playback.effectiveIndex, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(app.shutdown);
        app.dispose();
      }
    },
  );
}
