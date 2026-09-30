import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/services/playback_engine.dart';
import 'package:yun/ui/app.dart';
import 'package:yun/ui/downloads_screen.dart';
import 'package:yun/ui/player.dart';
import 'package:yun/ui/track_widgets.dart';

import '../core/fakes.dart';
import 'player_test_app.dart';

class _App extends PlayerTestApp {
  _App(super.engine);
  List<Track> library = const [
    Track(id: 'a', title: 'First', sizeBytes: 100),
    Track(id: 'b', title: 'Second', sizeBytes: 100),
  ];
  Set<String> downloaded = const {};
  List<PinSelection> selections = const [];
  final progress = <String, DownloadProgress>{};
  List<UploadJob> uploadJobs = const [];
  bool authenticated = true, offline = false;
  @override
  List<UploadJob> get uploads => uploadJobs;
  @override
  bool get isAuthenticated => authenticated;
  @override
  bool get isOffline => offline;
  int trackReads = 0, downloadedReads = 0;
  void changed() => notifyListeners();
  @override
  List<Track> get tracks {
    trackReads++;
    return library;
  }

  @override
  Set<String> get downloadedTrackIds {
    downloadedReads++;
    return downloaded;
  }

  @override
  List<PinSelection> get pins => selections;
  @override
  bool isPinned(String type, String id) =>
      selections.any((pin) => pin.type == type && pin.id == id);
  @override
  List<Playlist> get playlists => const [];
  @override
  Track? trackById(String id) => library.where((t) => t.id == id).firstOrNull;
  @override
  DownloadProgress downloadProgress(Track track) =>
      progress[track.id] ??
      DownloadProgress(
        trackId: track.id,
        totalBytes: track.sizeBytes,
        status: downloaded.contains(track.id)
            ? DownloadStatus.downloaded
            : DownloadStatus.availableOnline,
      );
}

/// An immutable snapshot that exposes accidental rescans on transfer ticks.
class _UploadSnapshot extends ListBase<UploadJob> {
  _UploadSnapshot(List<String> statuses)
    : _jobs = List.unmodifiable([
        for (var i = 0; i < statuses.length; i++)
          UploadJob(
            id: '$i',
            localPath: '/imports/$i.wav',
            filename: '$i.wav',
            sizeBytes: 100,
            status: statuses[i],
          ),
      ]);

  final List<UploadJob> _jobs;
  int reads = 0;
  @override
  int get length => _jobs.length;
  @override
  set length(int value) => throw UnsupportedError('Immutable snapshot');
  @override
  UploadJob operator [](int index) {
    reads++;
    return _jobs[index];
  }

  @override
  void operator []=(int index, UploadJob value) =>
      throw UnsupportedError('Immutable snapshot');
}

void main() {
  setUp(mockDesktopDrop);

  testWidgets('upload badge selects counts from upload-only notifications', (
    tester,
  ) async {
    final app = _App(FakeEngine());
    var broadNotifications = 0;
    app.addListener(() => broadNotifications++);
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    final button = find.widgetWithIcon(IconButton, Icons.cloud_upload_outlined);
    final badge = find.descendant(of: button, matching: find.byType(Badge));

    void expectCount(int count) {
      expect(
        tester.widget<IconButton>(button).tooltip,
        count == 0
            ? 'Show uploads'
            : 'Uploads, $count active or needing attention',
      );
      final widget = tester.widget<Badge>(badge);
      expect(widget.isLabelVisible, count > 0);
      expect((widget.label! as Text).data, '$count');
    }

    Future<void> uploadsChanged(List<String> statuses, int count) async {
      app.uploadJobs = _UploadSnapshot(statuses);
      app.downloadChanges.notifyListeners();
      await tester.pump();
      expectCount(count);
    }

    try {
      await tester.pumpWidget(YunApp(controller: app));
      await tester.pumpAndSettle();
      final shell = tester.widget(find.byType(Scaffold));
      final heading = tester.widget(find.text('Library').last);
      final trackReads = app.trackReads;
      expectCount(0);
      // Enqueue and each active/attention status arrive only on the narrow bus.
      await uploadsChanged(['queued'], 1);
      final oneActive = tester.widget(button);
      for (final status in ['uploading', 'completing', 'failed']) {
        await uploadsChanged([status], 1);
        expect(identical(tester.widget(button), oneActive), isTrue);
      }
      await uploadsChanged([
        'queued',
        'uploading',
        'completing',
        'failed',
        'done',
        'cancelled',
      ], 4);
      final snapshot = app.uploadJobs as _UploadSnapshot;
      expect(snapshot.reads, snapshot.length);
      final fourActive = tester.widget(button);
      for (var i = 0; i < 20; i++) {
        app.downloadChanges.notifyListeners();
        await tester.pump();
      }
      expect(snapshot.reads, snapshot.length);
      expect(identical(tester.widget(button), fourActive), isTrue);
      await uploadsChanged(['done', 'cancelled'], 0);
      await uploadsChanged(['queued', 'cancelled'], 1);
      await uploadsChanged([], 0);
      expect(broadNotifications, 0);
      expect(app.trackReads, trackReads);
      expect(identical(tester.widget(find.byType(Scaffold)), shell), isTrue);
      expect(
        identical(tester.widget(find.text('Library').last), heading),
        isTrue,
      );

      // Broad account/connectivity updates must still control the status bar.
      app.offline = true;
      app.changed();
      await tester.pump();
      expect(find.text('Offline'), findsOneWidget);
      expectCount(0);
      app.authenticated = false;
      app.changed();
      await tester.pump();
      expect(button, findsNothing);
      expect(find.text('Offline'), findsNothing);
      expect(find.text('Connect'), findsWidgets);
      app.uploadJobs = _UploadSnapshot(['failed']);
      app.authenticated = true;
      app.changed();
      await tester.pump();
      expectCount(1);
      expect(find.text('Offline'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(app.shutdown);
      app.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });

  testWidgets(
    'playback and transfer ticks do not rebuild the shell/library rows',
    (tester) async {
      final engine = FakeEngine();
      final app = _App(engine);
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      try {
        await app.playback.playQueue(app.library);
        await tester.pumpWidget(YunApp(controller: app));
        await tester.pumpAndSettle();
        final heading = tester.widget(find.text('Library').last);
        final row = find.descendant(
          of: find.byType(TrackTile).first,
          matching: find.byType(ListTile),
        );
        final tile = tester.widget<ListTile>(row);
        final second = tester.widget<ListTile>(
          find.descendant(
            of: find.byType(TrackTile).last,
            matching: find.byType(ListTile),
          ),
        );
        final reads = app.trackReads;
        engine.emit(
          const EngineState(
            playing: true,
            position: Duration(seconds: 12),
            duration: Duration(minutes: 2),
          ),
        );
        await tester.pump();
        expect(app.trackReads, reads);
        expect(
          identical(tester.widget(find.text('Library').last), heading),
          isTrue,
        );
        expect(identical(tester.widget(row), tile), isTrue);
        app.progress['a'] = const DownloadProgress(
          trackId: 'a',
          totalBytes: 100,
          receivedBytes: 42,
          status: DownloadStatus.downloading,
        );
        app.downloadChanges.notifyListeners();
        await tester.pump();
        expect(app.trackReads, reads);
        expect(identical(tester.widget(row), tile), isTrue);
        expect(find.textContaining('Downloading · 42 B'), findsOneWidget);
        expect(
          identical(
            tester.widget(
              find.descendant(
                of: find.byType(TrackTile).last,
                matching: find.byType(ListTile),
              ),
            ),
            second,
          ),
          isTrue,
        );
        await app.playback.next();
        await tester.pump();
        expect(tester.widget<ListTile>(row).selected, isFalse);
        expect(
          tester
              .widget<ListTile>(
                find.descendant(
                  of: find.byType(TrackTile).last,
                  matching: find.byType(ListTile),
                ),
              )
              .selected,
          isTrue,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(app.shutdown);
        app.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
  );

  testWidgets('standalone download labels follow broad pin/cache changes', (
    tester,
  ) async {
    final app = _App(FakeEngine());
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TrackTile(app: app, track: app.library.first),
          ),
        ),
      );
      expect(find.textContaining('Available online'), findsOneWidget);
      // Pin/cache snapshots arrive on the app notifier, not byte progress.
      app.progress['a'] = const DownloadProgress(
        trackId: 'a',
        totalBytes: 100,
        status: DownloadStatus.queued,
      );
      app.changed();
      await tester.pump();
      expect(find.textContaining('Queued ·'), findsOneWidget);
      app.progress.clear();
      app.changed();
      await tester.pump();
      expect(find.textContaining('Available online'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(app.shutdown);
      app.dispose();
    }
  });

  testWidgets('now playing follows pin changes without playback ticks', (
    tester,
  ) async {
    final app = _App(FakeEngine());
    try {
      await app.playback.playQueue(app.library);
      await app.playback.pause();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showNowPlaying(context, app),
                child: const Text('Open player'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open player'));
      await tester.pumpAndSettle();
      expect(find.text('Keep offline'), findsOneWidget);
      app.selections = const [PinSelection('track', 'a')];
      app.changed();
      await tester.pump();
      expect(find.text('Kept offline'), findsOneWidget);
      expect(find.text('Keep offline'), findsNothing);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(app.shutdown);
      app.dispose();
    }
  });

  testWidgets(
    'queue ignores position ticks but follows queue and index changes',
    (tester) async {
      final engine = FakeEngine();
      final app = _App(engine);
      try {
        await app.playback.playQueue(app.library);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: QueuePanel(app: app)),
          ),
        );
        final list = tester.widget<ListView>(find.byType(ListView));
        engine.emit(
          const EngineState(playing: true, position: Duration(seconds: 5)),
        );
        await tester.pump();
        expect(identical(tester.widget(find.byType(ListView)), list), isTrue);
        await app.playback.next();
        await tester.pump();
        expect(
          tester
              .widgetList<ListTile>(find.byType(ListTile))
              .map((t) => t.selected),
          [false, true],
        );
        await app.playback.stop();
        await tester.pump();
        expect(find.text('A quiet queue'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(app.shutdown);
        app.dispose();
      }
    },
  );

  testWidgets(
    'Downloads captures IDs once and progress only updates indicators',
    (tester) async {
      final app = _App(FakeEngine());
      app.library = List.generate(
        5000,
        (i) => Track(id: '$i', title: 'Track $i', sizeBytes: 100),
      );
      app.downloaded = Set.unmodifiable(List.generate(2500, (i) => '$i'));
      // Cleared history is still part of the full device inventory. Keeping
      // those rows in the device submenu lets this test observe a pending row.
      for (var i = 0; i < 2500; i++) {
        app.progress['$i'] = DownloadProgress(
          trackId: '$i',
          totalBytes: 100,
          receivedBytes: 100,
          status: DownloadStatus.downloaded,
          historyCleared: true,
        );
      }
      app.selections = const [PinSelection('track', '2500')];
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: DownloadsScreen(app: app)),
          ),
        );
        await tester.pumpAndSettle();
        // One selector read plus one captured build snapshot, not 5,000 copies.
        expect(app.downloadedReads, lessThanOrEqualTo(3));
        final scroll = tester.widget<CustomScrollView>(
          find.byType(CustomScrollView),
        );
        app.progress['2500'] = const DownloadProgress(
          trackId: '2500',
          totalBytes: 100,
          receivedBytes: 50,
          status: DownloadStatus.downloading,
        );
        app.downloadChanges.notifyListeners();
        await tester.pump();
        expect(
          identical(tester.widget(find.byType(CustomScrollView)), scroll),
          isTrue,
        );
        expect(find.textContaining('Downloading · 50 B'), findsOneWidget);
        app.downloaded = Set.unmodifiable({...app.downloaded, '2500'});
        app.progress.remove('2500');
        app.downloadChanges.notifyListeners();
        await tester.pump();
        expect(find.text('1 of 1 selected tracks ready'), findsOneWidget);
        expect(find.textContaining('2501 tracks'), findsOneWidget);
        expect(find.textContaining('Downloading ·'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(app.shutdown);
        app.dispose();
      }
    },
  );
}
