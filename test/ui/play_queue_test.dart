import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart' show Track;
import 'package:yun/services/playback_engine.dart';
import 'package:yun/ui/player.dart';
import 'package:yun/ui/theme.dart';

import '../core/fakes.dart';
import 'player_test_app.dart';

void main() {
  const tracks = [
    Track(id: 'a', title: 'First', artist: 'Artist A'),
    Track(id: 'b', title: 'Second', artist: 'Artist B'),
    Track(id: 'c', title: 'Third', artist: 'Artist C'),
    Track(id: 'd', title: 'Fourth', artist: 'Artist D'),
    Track(id: 'e', title: 'Fifth', artist: 'Artist E'),
  ];

  Future<void> showQueue(WidgetTester tester, PlayerTestApp app) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: YunTheme.light(),
        home: Scaffold(body: QueuePanel(app: app)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> closeQueue(WidgetTester tester, PlayerTestApp app) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(app.shutdown);
    app.dispose();
  }

  testWidgets('opening a long queue reveals the current position', (
    tester,
  ) async {
    final app = PlayerTestApp(FakeEngine());
    final longQueue = List.generate(
      1000,
      (index) => Track(id: '$index', title: 'Track $index', artist: 'Artist'),
    );
    try {
      await app.playback.playQueue(longQueue, index: 840);
      await showQueue(tester, app);
      expect(find.text('Playing 841 of 1000'), findsOneWidget);
      expect(find.text('Track 840'), findsOneWidget);
      expect(find.text('Now playing'), findsOneWidget);
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.controller!.offset, greaterThan(60000));
      expect(
        tester
            .widgetList<ListTile>(find.byType(ListTile))
            .singleWhere((tile) => tile.selected)
            .title,
        isA<Text>().having((text) => text.data, 'title', 'Track 840'),
      );
      await app.playback.next();
      await tester.pumpAndSettle();
      expect(find.text('Playing 842 of 1000'), findsOneWidget);
      expect(find.text('Track 841'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await closeQueue(tester, app);
    }
  });

  testWidgets('queue follows actual shuffle order and selected occurrence', (
    tester,
  ) async {
    final app = PlayerTestApp(FakeEngine(), random: Random(7));
    try {
      await app.playback.playQueue(tracks, index: 1);
      await showQueue(tester, app);
      app.playback.setShuffle(true);
      await tester.pumpAndSettle();
      final snapshot = app.playback.effectiveQueue;
      final currentIndex = app.playback.effectiveIndex;
      expect(
        find.text('Playing ${currentIndex + 1} of 5 · Shuffled'),
        findsOneWidget,
      );
      expect(
        tester
            .widgetList<ListTile>(find.byType(ListTile))
            .map((tile) => (tile.title! as Text).data),
        snapshot.map((entry) => entry.track.title),
      );
      final next = snapshot[currentIndex + 1];
      await tester.tap(find.byKey(ObjectKey(next)));
      await tester.pumpAndSettle();
      expect(app.playback.currentTrack, same(next.track));
      expect(app.playback.shuffle, isTrue);
      expect(
        app.playback.effectiveQueue[app.playback.effectiveIndex],
        same(next),
      );
      expect(
        tester.widget<ListTile>(find.byKey(ObjectKey(next))).selected,
        isTrue,
      );
    } finally {
      await closeQueue(tester, app);
    }
  });

  testWidgets('manual duplicates appear as separate queued occurrences', (
    tester,
  ) async {
    final app = PlayerTestApp(FakeEngine());
    try {
      await app.playback.playQueue(tracks.sublist(0, 2));
      await showQueue(tester, app);
      await app.playback.queueNext(tracks.first);
      await app.playback.queueNext(tracks.first);
      await tester.pumpAndSettle();
      expect(find.text('Playing 1 of 4'), findsOneWidget);
      expect(find.text('Queued next'), findsNWidgets(2));
      final manual = app.playback.effectiveQueue
          .where((entry) => entry.isManuallyQueued)
          .toList();
      expect(manual, hasLength(2));
      expect(find.byKey(ObjectKey(manual.first)), findsOneWidget);
      expect(find.byKey(ObjectKey(manual.last)), findsOneWidget);
      await tester.tap(find.byKey(ObjectKey(manual.last)));
      await tester.pumpAndSettle();
      expect(
        app.playback.effectiveQueue[app.playback.effectiveIndex],
        same(manual.last),
      );
      expect(
        tester.widget<ListTile>(find.byKey(ObjectKey(manual.last))).selected,
        isTrue,
      );
      expect(find.text('Now playing'), findsOneWidget);
    } finally {
      await closeQueue(tester, app);
    }
  });

  testWidgets('manual additions and shuffle rebuild while ticks keep scroll', (
    tester,
  ) async {
    final engine = FakeEngine();
    final app = PlayerTestApp(engine);
    try {
      await app.playback.playQueue(tracks);
      await showQueue(tester, app);
      final list = tester.widget<ListView>(find.byType(ListView));
      engine.emit(
        const EngineState(playing: true, position: Duration(seconds: 4)),
      );
      await tester.pump();
      expect(tester.widget<ListView>(find.byType(ListView)), same(list));
      await app.playback.queueNext(
        const Track(id: 'x', title: 'Requested song', artist: 'Guest'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Requested song'), findsOneWidget);
      expect(find.text('Queued next'), findsOneWidget);
      app.playback.setShuffle(true);
      await tester.pumpAndSettle();
      expect(find.text('Playing 1 of 6 · Shuffled'), findsOneWidget);
      await app.playback.next();
      await tester.pumpAndSettle();
      expect(find.text('Playing 2 of 6 · Shuffled'), findsOneWidget);
      expect(find.text('Queued next'), findsNothing);
      expect(
        tester
            .widgetList<ListTile>(find.byType(ListTile))
            .singleWhere((tile) => tile.selected)
            .title,
        isA<Text>().having((text) => text.data, 'title', 'Requested song'),
      );
      await app.playback.stop();
      await tester.pumpAndSettle();
      expect(find.text('A quiet queue'), findsOneWidget);
    } finally {
      await closeQueue(tester, app);
    }
  });

  for (final scale in [2.5, 3.0]) {
    testWidgets('current queue indicator supports ${scale}x text', (
      tester,
    ) async {
      final app = PlayerTestApp(FakeEngine());
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      try {
        await app.playback.playQueue(tracks);
        await app.playback.queueNext(tracks.last);
        await showQueue(tester, app);
        expect(find.text('1'), findsOneWidget);
        expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
        expect(find.text('Now playing'), findsOneWidget);
        expect(find.text('Queued next'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await app.playback.next();
        await tester.pumpAndSettle();
        expect(find.text('Playing 2 of 6'), findsOneWidget);
        expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
        expect(find.text('Now playing'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await closeQueue(tester, app);
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      }
    });
  }

  testWidgets('queue supports narrow screens and large text', (tester) async {
    final app = PlayerTestApp(FakeEngine());
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    try {
      await app.playback.playQueue(tracks);
      await app.playback.queueNext(tracks.last);
      await showQueue(tester, app);
      expect(find.text('Now playing'), findsOneWidget);
      expect(find.text('Queued next'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await closeQueue(tester, app);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
  });
}
