import 'dart:async';

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
  bool get isAuthenticated => authenticated;
  bool authenticated = true, offline = false, repairing = false;
  int verifyCalls = 0, cancelVerificationCalls = 0, repairCalls = 0;
  DownloadVerificationProgress? verification;

  @override
  bool get isOffline => offline;
  @override
  DownloadVerificationProgress? get verificationProgress => verification;
  @override
  bool get redownloadingCorruptedFiles => repairing;

  void setVerification(DownloadVerificationProgress value) {
    verification = value;
    verificationChanges.notifyListeners();
  }

  @override
  Future<void> verifyDownloads() async {
    verifyCalls++;
    setVerification(_verification(VerificationStatus.preparing));
  }

  @override
  void cancelVerification() {
    cancelVerificationCalls++;
    setVerification(_verification(VerificationStatus.cancelled));
  }

  @override
  Future<void> redownloadCorruptedFiles() async {
    repairCalls++;
    repairing = true;
    verificationChanges.notifyListeners();
  }

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
  ({int completed, int total}) downloadBatchProgress = (completed: 0, total: 0);
  @override
  bool get hasRunningDownloads => progress.values.any(
    (value) =>
        value.status == DownloadStatus.downloading ||
        value.status == DownloadStatus.verifying,
  );
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

  void setProgress(
    String id,
    DownloadStatus status, {
    int received = 0,
    bool repairRequired = false,
  }) {
    final previous = progress[id];
    int group(DownloadStatus? status) => switch (status) {
      DownloadStatus.downloaded => 1,
      DownloadStatus.failed => 2,
      _ => 0,
    };
    if (group(previous?.status) != group(status) ||
        (previous?.repairRequired ?? false) != repairRequired) {
      revision++;
    }
    progress[id] = DownloadProgress(
      trackId: id,
      totalBytes: 100,
      receivedBytes: received,
      status: status,
      error: status == DownloadStatus.failed ? 'Connection lost' : null,
      repairRequired: repairRequired,
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

DownloadVerificationProgress _verification(
  VerificationStatus status, {
  int total = 4,
  int checked = 2,
  int valid = 1,
  int invalid = 1,
  int skipped = 0,
  String? error,
}) => DownloadVerificationProgress(
  status: status,
  totalFiles: total,
  checkedFiles: checked,
  validFiles: valid,
  invalidFiles: invalid,
  skippedFiles: skipped,
  processedBytes: checked * 100,
  totalBytes: total * 100,
  hashedBytes: checked * 100,
  elapsed: const Duration(seconds: 2),
  invalidTrackIds: invalid > 0 ? const ['done'] : const [],
  error: error,
);

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

  Finder completionProgress() => find.byWidgetPredicate(
    (widget) =>
        widget is LinearProgressIndicator &&
        widget.semanticsLabel == 'Offline download completion',
  );

  downloadsTest('hides completion summary when no downloads are running', (
    tester,
  ) async {
    final app = await open(tester);
    // Queued and failed selections are not running jobs.
    expect(completionProgress(), findsNothing);
    expect(find.textContaining('downloads complete'), findsNothing);

    app.setProgress('pending', DownloadStatus.downloaded, received: 100);
    await tester.pumpAndSettle();
    expect(completionProgress(), findsNothing);
    expect(find.textContaining('downloads complete'), findsNothing);

    app.setProgress('failed', DownloadStatus.downloaded, received: 100);
    await tester.pumpAndSettle();
    // All selections are ready, as in the completed-download screenshot.
    expect(completionProgress(), findsNothing);
    expect(find.textContaining('downloads complete'), findsNothing);
    expect(find.text('Finished song'), findsOneWidget);
    expect(find.text('Waiting song'), findsOneWidget);
    expect(find.text('Failed song'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  downloadsTest('completion summary follows running jobs without regrouping', (
    tester,
  ) async {
    final app = await open(tester);
    app.downloadBatchProgress = (completed: 0, total: 1);
    final activity = find.byKey(const PageStorageKey('download-activity'));
    final scroll = tester.widget<CustomScrollView>(activity);

    for (final status in [
      DownloadStatus.downloading,
      DownloadStatus.verifying,
      DownloadStatus.queued,
      DownloadStatus.downloading,
    ]) {
      app.setProgress('pending', status, received: 50);
      await tester.pump();
      final running = status != DownloadStatus.queued;
      expect(completionProgress(), running ? findsOneWidget : findsNothing);
      expect(
        find.text('0/1 downloads complete'),
        running ? findsOneWidget : findsNothing,
      );
      if (running) {
        expect(
          tester.widget<LinearProgressIndicator>(completionProgress()).value,
          0,
        );
      }
      expect(identical(tester.widget(activity), scroll), isTrue);
    }

    final indicator = tester.widget(completionProgress());
    app.setProgress('pending', DownloadStatus.downloading, received: 75);
    await tester.pump();
    expect(identical(tester.widget(completionProgress()), indicator), isTrue);
    expect(identical(tester.widget(activity), scroll), isTrue);

    app.setProgress('pending', DownloadStatus.failed);
    await tester.pumpAndSettle();
    expect(completionProgress(), findsNothing);
    expect(find.textContaining('downloads complete'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  downloadsTest('keeps completion summary while another download is running', (
    tester,
  ) async {
    final app = await open(tester);
    app.downloadBatchProgress = (completed: 0, total: 2);
    app.setProgress('pending', DownloadStatus.downloading, received: 50);
    app.setProgress('failed', DownloadStatus.downloading, received: 50);
    await tester.pump();
    expect(completionProgress(), findsOneWidget);
    expect(find.text('0/2 downloads complete'), findsOneWidget);

    app.downloadBatchProgress = (completed: 1, total: 2);
    app.setProgress('pending', DownloadStatus.downloaded, received: 100);
    await tester.pump();
    expect(completionProgress(), findsOneWidget);
    expect(
      tester.widget<LinearProgressIndicator>(completionProgress()).value,
      1 / 2,
    );
    expect(find.text('1/2 downloads complete'), findsOneWidget);

    app.downloadBatchProgress = (completed: 2, total: 2);
    app.setProgress('failed', DownloadStatus.downloaded, received: 100);
    await tester.pumpAndSettle();
    expect(completionProgress(), findsNothing);
    expect(find.textContaining('downloads complete'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  downloadsTest('505 earlier downloads do not count toward the current task', (
    tester,
  ) async {
    final initial = _DownloadsApp(
      library: List.generate(
        506,
        (i) => Track(id: '$i', title: 'Track $i', sizeBytes: 100),
      ),
      selections: List.generate(506, (i) => PinSelection('track', '$i')),
    );
    initial.localIds = Set.unmodifiable(List.generate(505, (i) => '$i'));
    for (final id in initial.localIds) {
      initial.progress[id] = DownloadProgress(
        trackId: id,
        totalBytes: 100,
        status: DownloadStatus.downloaded,
        historyCleared: true,
      );
    }
    initial.downloadBatchProgress = (completed: 0, total: 1);
    initial.setProgress('505', DownloadStatus.downloading, received: 50);
    await open(tester, initialApp: initial);

    expect(find.text('0/1 downloads complete'), findsOneWidget);
    expect(
      tester.widget<LinearProgressIndicator>(completionProgress()).value,
      0,
    );
    expect(find.text('No completed downloads'), findsOneWidget);
    expect(find.text('Track 505'), findsOneWidget);
    expect(find.textContaining('selected tracks ready'), findsNothing);
    expect(tester.takeException(), isNull);
  });

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

  Finder verifyButton() =>
      find.widgetWithText(OutlinedButton, 'Verify downloads');
  Finder repairButton() =>
      find.widgetWithText(OutlinedButton, 'Redownload corrupted files');

  downloadsTest('verification works offline and cannot be started twice', (
    tester,
  ) async {
    final app = await open(tester);
    app.offline = true;
    app.notifyListeners();
    await tester.pump();
    expect(tester.widget<OutlinedButton>(verifyButton()).onPressed, isNotNull);
    await tester.tap(verifyButton());
    await tester.pump();
    expect(app.verifyCalls, 1);
    expect(find.text('Preparing download verification…'), findsOneWidget);
    expect(
      find.text('Finding downloaded files on this device'),
      findsOneWidget,
    );
    expect(tester.widget<OutlinedButton>(verifyButton()).onPressed, isNull);
    await tester.tap(verifyButton());
    await tester.pump();
    expect(app.verifyCalls, 1);
    await tester.tap(find.text('Cancel verification'));
    await tester.pumpAndSettle();
    expect(app.cancelVerificationCalls, 1);
    expect(find.text('Verification cancelled'), findsOneWidget);
    expect(find.text('Cancel verification'), findsNothing);
    expect(tester.widget<OutlinedButton>(verifyButton()).onPressed, isNotNull);
    await tester.tap(verifyButton());
    await tester.pump();
    expect(app.verifyCalls, 2);
    expect(tester.takeException(), isNull);
  });

  downloadsTest(
    'verification ticks show progress and ETA without rebuilding rows',
    (tester) async {
      final app = await open(tester);
      final scroll = tester.widget<CustomScrollView>(
        find.byKey(const PageStorageKey('download-activity')),
      );
      app.setVerification(_verification(VerificationStatus.running));
      await tester.pump();
      expect(find.text('Verifying downloads'), findsOneWidget);
      expect(
        find.text('2 of 4 files checked · 1 valid · 1 invalid'),
        findsOneWidget,
      );
      expect(
        find.text('200 B of 400 B · About 0:02 remaining'),
        findsOneWidget,
      );
      final indicator = tester.widget<LinearProgressIndicator>(
        find.byWidgetPredicate(
          (widget) =>
              widget is LinearProgressIndicator &&
              widget.semanticsLabel?.startsWith('Download verification') ==
                  true,
        ),
      );
      expect(indicator.value, 0.5);
      expect(
        identical(
          tester.widget(find.byKey(const PageStorageKey('download-activity'))),
          scroll,
        ),
        isTrue,
      );
      app.setVerification(
        _verification(VerificationStatus.running, checked: 3),
      );
      await tester.pump();
      expect(
        identical(
          tester.widget(find.byKey(const PageStorageKey('download-activity'))),
          scroll,
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  downloadsTest(
    'result survives navigation and repairs require an explicit online action',
    (tester) async {
      final app = await open(tester);
      app.offline = true;
      app.setVerification(
        _verification(VerificationStatus.completed, checked: 4, valid: 3),
      );
      await tester.pumpAndSettle();
      expect(find.text('Verification complete'), findsOneWidget);
      expect(app.repairCalls, 0);
      expect(tester.widget<OutlinedButton>(repairButton()).onPressed, isNull);
      expect(
        find.text('Connect to redownload corrupted files'),
        findsOneWidget,
      );
      await tester.pumpWidget(const MaterialApp(home: Text('Other screen')));
      await tester.pumpAndSettle();
      await open(tester, initialApp: app);
      expect(find.text('Verification complete'), findsOneWidget);
      expect(
        find.text('4 of 4 files checked · 3 valid · 1 invalid'),
        findsOneWidget,
      );
      app.offline = false;
      app.notifyListeners();
      await tester.pumpAndSettle();
      await tester.tap(repairButton());
      await tester.pumpAndSettle();
      expect(app.repairCalls, 1);
      expect(find.text('Redownloading…'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(verifyButton()).onPressed, isNull);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Redownloading…'),
            )
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  downloadsTest(
    'empty and failed verification remain readable and signed-out action is disabled',
    (tester) async {
      final app = await open(tester);
      app.setVerification(
        _verification(
          VerificationStatus.completed,
          total: 0,
          checked: 0,
          valid: 0,
          invalid: 0,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No downloaded files to verify'), findsOneWidget);
      expect(repairButton(), findsNothing);
      app.setVerification(
        _verification(
          VerificationStatus.failed,
          skipped: 1,
          error: 'Storage unavailable',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Verification failed'), findsOneWidget);
      expect(find.text('Storage unavailable'), findsOneWidget);
      expect(find.textContaining('1 skipped'), findsOneWidget);
      expect(
        find.text(
          'Skipped files could not be read or changed during the check',
        ),
        findsOneWidget,
      );
      app.authenticated = false;
      app.notifyListeners();
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(verifyButton()).onPressed, isNull);
      expect(find.text('Verification failed'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  downloadsTest(
    'unselected repair-held download has its own explicit repair action',
    (tester) async {
      final initial = _DownloadsApp(
        library: const [
          Track(id: 'legacy', title: 'Legacy download', sizeBytes: 100),
        ],
        selections: const [],
      );
      initial.setProgress(
        'legacy',
        DownloadStatus.failed,
        repairRequired: true,
      );
      final completed = Completer<void>();
      initial.onRedownloadTrack = (_) => completed.future;
      final app = await open(tester, initialApp: initial);

      expect(find.text('Legacy download'), findsOneWidget);
      expect(find.text('Music for wherever you go'), findsNothing);
      expect(find.widgetWithText(TextButton, 'Retry'), findsNothing);
      final repair = find.widgetWithText(OutlinedButton, 'Redownload');
      await tester.tap(repair);
      await tester.pumpAndSettle();
      final busy = find.widgetWithText(OutlinedButton, 'Redownloading…');
      expect(tester.widget<OutlinedButton>(busy).onPressed, isNull);
      await tester.tap(busy);
      expect(app.redownloadedTrackIds, ['legacy']);
      expect(app.retryCalls, 0);

      completed.complete();
      app.setProgress('legacy', DownloadStatus.downloaded, received: 100);
      await tester.pumpAndSettle();
      expect(find.text('Redownload'), findsNothing);
      expect(find.text('No failed downloads'), findsOneWidget);
      expect(find.text('Legacy download'), findsOneWidget);
      expect(app.playback.currentTrack, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  downloadsTest(
    'repair-held rows fit narrow large text and disable redownload offline',
    (tester) async {
      final initial = _DownloadsApp(
        library: const [
          Track(id: 'legacy', title: 'Legacy download', sizeBytes: 100),
        ],
        selections: const [],
      )..offline = true;
      initial.setProgress(
        'legacy',
        DownloadStatus.failed,
        repairRequired: true,
      );
      final app = await open(
        tester,
        initialApp: initial,
        size: const Size(320, 1000),
        textScale: 2,
      );
      final repair = find.widgetWithText(OutlinedButton, 'Redownload');
      await tester.scrollUntilVisible(
        repair,
        100,
        scrollable: activityScroll(),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(repair).onPressed, isNull);
      expect(find.text('Reconnect to redownload'), findsOneWidget);
      await tester.tap(repair);
      expect(app.redownloadedTrackIds, isEmpty);
      expect(tester.takeException(), isNull);

      app.offline = false;
      app.notifyListeners();
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(repair).onPressed, isNotNull);
      expect(find.text('Reconnect to redownload'), findsNothing);
    },
  );

  for (final settings in [
    (const Size(320, 568), 1.0),
    (const Size(320, 1000), 2.0),
  ]) {
    downloadsTest(
      'verification fits ${settings.$1} at text scale ${settings.$2}',
      (tester) async {
        final app = await open(
          tester,
          size: settings.$1,
          textScale: settings.$2,
        );
        app.setVerification(_verification(VerificationStatus.running));
        await tester.pump();
        expect(tester.takeException(), isNull);
        app.setVerification(
          _verification(VerificationStatus.completed, checked: 4, valid: 3),
        );
        await tester.pumpAndSettle();
        expect(find.text('Redownload corrupted files'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
