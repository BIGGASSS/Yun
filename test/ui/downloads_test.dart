import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/ui/downloads_screen.dart';

import '../core/fakes.dart';
import 'player_test_app.dart';

class _DownloadsApp extends PlayerTestApp {
  _DownloadsApp({required this.library, required this.selections})
    : super(FakeEngine());

  final List<Track> library;
  final List<PinSelection> selections;
  final Map<String, DownloadProgress> progress = {};
  Set<String> localIds = const {};
  int revision = 0, clearCalls = 0, retryCalls = 0, trackReads = 0;

  @override
  bool get isAuthenticated => true;
  @override
  List<Track> get tracks => library;
  @override
  List<PinSelection> get pins => selections;
  @override
  List<Playlist> get playlists => const [];
  @override
  Set<String> get downloadedTrackIds => localIds;
  @override
  int get downloadSectionsRevision => revision;
  @override
  bool isPinned(String type, String id) =>
      selections.any((pin) => pin.type == type && pin.id == id);
  @override
  Track? trackById(String id) {
    trackReads++;
    return library.where((t) => t.id == id).firstOrNull;
  }

  @override
  DownloadProgress downloadProgress(Track track) =>
      progress[track.id] ??
      DownloadProgress(
        trackId: track.id,
        totalBytes: track.sizeBytes,
        status: localIds.contains(track.id)
            ? DownloadStatus.downloaded
            : isPinned('track', track.id)
            ? DownloadStatus.queued
            : DownloadStatus.availableOnline,
      );

  void setProgress(String id, DownloadStatus status, {int received = 0}) {
    final previous = progress[id];
    int group(DownloadStatus? status) => switch (status) {
      DownloadStatus.downloaded => 1,
      DownloadStatus.failed => 2,
      _ => 0,
    };
    if (group(previous?.status) != group(status)) revision++;
    progress[id] = DownloadProgress(
      trackId: id,
      totalBytes: 100,
      receivedBytes: received,
      status: status,
      error: status == DownloadStatus.failed ? 'Connection lost' : null,
    );
    if (status == DownloadStatus.downloaded) {
      localIds = Set.unmodifiable({...localIds, id});
    } else if (localIds.contains(id)) {
      localIds = Set.unmodifiable({...localIds}..remove(id));
    }
    downloadChanges.notifyListeners();
  }

  @override
  Future<void> clearDoneDownloads() async {
    clearCalls++;
    for (final id in localIds) {
      progress[id] = DownloadProgress(
        trackId: id,
        totalBytes: 100,
        receivedBytes: 100,
        status: DownloadStatus.downloaded,
        historyCleared: true,
      );
    }
    revision++;
    downloadChanges.notifyListeners();
  }

  @override
  Future<void> retryDownloads() async {
    retryCalls++;
    for (final entry in progress.entries.toList()) {
      if (entry.value.status == DownloadStatus.failed) {
        setProgress(entry.key, DownloadStatus.queued);
      }
    }
  }
}

void main() {
  _DownloadsApp? openApp;
  const library = [
    Track(id: 'done', title: 'Finished song', sizeBytes: 100),
    Track(id: 'unpinned', title: 'Other local song', sizeBytes: 100),
    Track(id: 'pending', title: 'Waiting song', sizeBytes: 100),
    Track(id: 'failed', title: 'Failed song', sizeBytes: 100),
    Track(id: 'online', title: 'Online song', sizeBytes: 100),
  ];

  Future<_DownloadsApp> open(
    WidgetTester tester, {
    Size size = const Size(1000, 1000),
    double textScale = 1,
    _DownloadsApp? initialApp,
  }) async {
    final app =
        initialApp ??
        _DownloadsApp(
          library: library,
          selections: const [
            PinSelection('track', 'done'),
            PinSelection('track', 'pending'),
            PinSelection('track', 'failed'),
          ],
        );
    openApp = app;
    if (initialApp == null) {
      app.localIds = const {'done', 'unpinned'};
      app.setProgress('failed', DownloadStatus.failed);
    }
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DownloadsScreen(app: app)),
      ),
    );
    await tester.pumpAndSettle();
    return app;
  }

  void downloadsTest(
    String description,
    Future<void> Function(WidgetTester) body,
  ) => testWidgets(description, (tester) async {
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      final app = openApp;
      if (app != null) {
        await tester.runAsync(app.shutdown);
        app.dispose();
      }
      openApp = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
  });

  Finder activityScroll() => find.descendant(
    of: find.byKey(const PageStorageKey('download-activity')),
    matching: find.byType(Scrollable),
  );

  Future<double> position(WidgetTester tester, String text) async {
    final scroll = activityScroll();
    tester.state<ScrollableState>(scroll).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(find.text(text), 100, scrollable: scroll);
    return tester.getTopLeft(find.text(text)).dy +
        tester.state<ScrollableState>(scroll).position.pixels;
  }

  Finder clearButton() => find.widgetWithText(TextButton, 'Clear All');

  downloadsTest('separates Done, Pending, Failed and lists every local track', (
    tester,
  ) async {
    await open(tester);
    var previous = double.negativeInfinity;
    for (final text in [
      'Done',
      'Finished song',
      'Other local song',
      'Pending',
      'Waiting song',
      'Failed',
      'Failed song',
    ]) {
      final y = await position(tester, text);
      expect(y, greaterThan(previous));
      previous = y;
    }
    expect(find.text('Online song'), findsNothing);
    await tester.tap(find.text('On this device'));
    await tester.pumpAndSettle();
    expect(find.text('Finished song'), findsOneWidget);
    expect(find.text('Other local song'), findsOneWidget);
    expect(find.text('Waiting song'), findsNothing);
    expect(find.text('Failed song'), findsNothing);
    expect(find.text('Online song'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  downloadsTest('Clear All keeps device tracks and offline selections', (
    tester,
  ) async {
    final app = await open(tester);
    final selected = List.of(app.pins);
    final downloaded = app.downloadedTrackIds;
    await tester.tap(clearButton());
    await tester.pumpAndSettle();
    expect(app.clearCalls, 1);
    expect(app.pins, selected);
    expect(app.downloadedTrackIds, downloaded);
    expect(find.text('No completed downloads'), findsOneWidget);
    expect(find.text('Finished song'), findsNothing);
    expect(find.text('Other local song'), findsNothing);
    expect(find.text('Waiting song'), findsOneWidget);
    expect(find.text('Failed song'), findsOneWidget);
    expect(tester.widget<TextButton>(clearButton()).onPressed, isNull);
    await tester.tap(find.text('On this device'));
    await tester.pumpAndSettle();
    expect(find.text('Finished song'), findsOneWidget);
    expect(find.text('Other local song'), findsOneWidget);
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    app.setProgress('pending', DownloadStatus.downloaded, received: 100);
    await tester.pumpAndSettle();
    expect(find.text('Waiting song'), findsOneWidget);
    expect(tester.widget<TextButton>(clearButton()).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  downloadsTest('narrow transfer notifications regroup failures and retries', (
    tester,
  ) async {
    final app = await open(tester);
    app.setProgress('pending', DownloadStatus.failed);
    await tester.pumpAndSettle();
    expect(find.text('No pending downloads'), findsOneWidget);
    expect(
      await position(tester, 'Waiting song'),
      greaterThan(await position(tester, 'Failed')),
    );
    await position(tester, 'Retry');
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(app.retryCalls, 1);
    expect(find.text('No failed downloads'), findsOneWidget);
    expect(
      await position(tester, 'Waiting song'),
      greaterThan(await position(tester, 'Pending')),
    );
    expect(tester.takeException(), isNull);
  });

  downloadsTest('offline selections stay lazy across download rebuilds', (
    tester,
  ) async {
    final app = _DownloadsApp(
      library: List.generate(
        5000,
        (i) => Track(id: '$i', title: 'Pinned song $i', sizeBytes: 100),
      ),
      selections: List.generate(5000, (i) => PinSelection('track', '$i')),
    );
    await open(tester, initialApp: app);
    await tester.tap(find.text('On this device'));
    await tester.pumpAndSettle();
    final device = find.byKey(const PageStorageKey('device-downloads'));
    final rows = find.descendant(
      of: device,
      matching: find.byTooltip('Remove offline selection'),
    );
    expect(find.text('5000 selections'), findsOneWidget);
    expect(rows, findsNothing);
    expect(app.trackReads, 0);

    await tester.tap(find.text('Manage offline selections'));
    await tester.pumpAndSettle();
    expect(rows.evaluate().length, inExclusiveRange(0, 40));
    expect(app.trackReads, inExclusiveRange(0, 40));
    expect(find.text('Pinned song 4999'), findsNothing);

    // Byte updates do not rebuild the screen or resolve selection names.
    final beforeTick = tester.widget<CustomScrollView>(device);
    app.trackReads = 0;
    app.setProgress('0', DownloadStatus.downloading, received: 50);
    await tester.pump();
    expect(identical(tester.widget(device), beforeTick), isTrue);
    expect(app.trackReads, 0);

    // Completion and failure regroup activity and rebuild the device tab,
    // but keep the selection section expanded and only build viewport rows.
    for (final status in [DownloadStatus.downloaded, DownloadStatus.failed]) {
      final beforeChange = tester.widget<CustomScrollView>(device);
      app.trackReads = 0;
      app.setProgress('0', status, received: 100);
      await tester.pumpAndSettle();
      expect(identical(tester.widget(device), beforeChange), isFalse);
      expect(rows.evaluate().length, inExclusiveRange(0, 40));
      expect(app.trackReads, inExclusiveRange(0, 40));
    }

    final scroll = find.descendant(
      of: device,
      matching: find.byType(Scrollable),
    );
    app.trackReads = 0;
    await tester.scrollUntilVisible(
      find.text('Pinned song 60'),
      500,
      scrollable: scroll,
    );
    expect(find.text('Pinned song 60'), findsOneWidget);
    expect(rows.evaluate().length, inExclusiveRange(0, 40));
    expect(app.trackReads, inExclusiveRange(0, 300));
    expect(find.text('Pinned song 4999'), findsNothing);

    tester.state<ScrollableState>(scroll).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage offline selections'));
    await tester.pumpAndSettle();
    expect(rows, findsNothing);
    app.trackReads = 0;
    app.setProgress('0', DownloadStatus.downloaded, received: 100);
    await tester.pumpAndSettle();
    expect(rows, findsNothing);
    expect(app.trackReads, 0);
    expect(find.text('Pinned song 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  downloadsTest('fits a narrow screen with large text in both submenus', (
    tester,
  ) async {
    await open(tester, size: const Size(320, 1000), textScale: 2);
    await position(tester, 'Retry');
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('On this device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('On this device'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manage offline selections'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
