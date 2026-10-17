import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/ui/stats_screen.dart';
import 'package:yun/ui/theme.dart';

class _TestApp extends AppController {
  _TestApp({this.signedIn = true, this.serverStats})
    : super(enableSystemControls: false, automaticRefresh: false) {
    initialized = true;
    if (signedIn) {
      account = const Account(
        server: 'https://music.example.test',
        userId: 'user',
        username: 'Listener',
      );
    }
  }

  final bool signedIn;
  ServerStats? serverStats;
  int statsRequests = 0;

  final library = <Track>[
    const Track(
      id: 'one',
      title: 'First song',
      artist: 'Artist A',
      album: 'Album A',
      durationMs: 240000,
    ),
  ];

  @override
  List<Track> get tracks => isAuthenticated ? library : [];

  @override
  Track? trackById(String id) =>
      library.where((track) => track.id == id).firstOrNull;

  @override
  Future<ServerStats> loadStats({DateTime? from, DateTime? to}) async {
    statsRequests++;
    final result = serverStats;
    if (result == null) throw StateError('Server unavailable');
    stats = result;
    return result;
  }
}

ServerStats _stats(DateTime now) => ServerStats(
  listenedMs: 5 * 3600000 + 240000,
  playCount: 42,
  topTracks: const [
    StatsItem(
      id: 'one',
      title: 'First song',
      artist: 'Artist A',
      listenedMs: 7200000,
      playCount: 20,
    ),
    StatsItem(
      id: 'missing',
      title: 'Gone song',
      artist: 'Artist B',
      listenedMs: 3600000,
      playCount: 10,
    ),
  ],
  topArtists: const [
    StatsItem(name: 'Artist A', listenedMs: 7200000, playCount: 20),
  ],
  topAlbums: const [
    StatsItem(
      name: 'Album A',
      artist: 'Artist A',
      listenedMs: 5400000,
      playCount: 15,
    ),
  ],
  activity: [
    StatsActivityItem(day: _ordinal(now), listenedMs: 200000, playCount: 1),
    StatsActivityItem(day: _ordinal(now) - 2, listenedMs: 100000, playCount: 0),
  ],
  history: [
    HistoryItem(
      sessionId: 's1',
      trackId: 'one',
      title: 'First song',
      artist: 'Artist A',
      startedAt: now.millisecondsSinceEpoch - 3600000,
      listenedMs: 200000,
      countedPlay: true,
    ),
    HistoryItem(
      sessionId: 's2',
      trackId: 'one',
      title: 'First song',
      artist: 'Artist A',
      startedAt: now.subtract(const Duration(days: 2)).millisecondsSinceEpoch,
      listenedMs: 100000,
      countedPlay: false,
    ),
  ],
);

int _ordinal(DateTime local) =>
    DateTime.utc(local.year, local.month, local.day).millisecondsSinceEpoch ~/
    Duration.millisecondsPerDay;

void main() {
  // Fixed clock: day grouping and range buckets are deterministic.
  final now = DateTime(2025, 10, 14, 12);

  Future<void> pump(WidgetTester tester, _TestApp app) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: YunTheme.light(),
        home: Scaffold(
          body: StatsScreen(app: app, now: () => now),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('dashboard shows totals, activity and top tracks', (
    tester,
  ) async {
    final app = _TestApp(serverStats: _stats(now));
    addTearDown(app.dispose);
    await pump(tester, app);

    // Overview cards.
    expect(find.text('Time listened'), findsOneWidget);
    expect(find.text('5 hr 4 min'), findsOneWidget);
    expect(find.text('Plays'), findsOneWidget);
    expect(find.text('42'), findsOneWidget);
    expect(find.text('Top artist'), findsOneWidget);

    // Activity chart with daily buckets for the default all-time range.
    expect(find.text('Activity'), findsOneWidget);

    // Top tracks view is the default; a missing library track still renders.
    expect(find.text('First song'), findsWidgets);
    expect(find.text('Gone song'), findsOneWidget);
    expect(find.text('20 plays'), findsOneWidget);
    expect(app.statsRequests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('activity chart covers server activity beyond capped history', (
    tester,
  ) async {
    final app = _TestApp(
      serverStats: ServerStats(
        listenedMs: 4000000,
        playCount: 4,
        activity: [
          StatsActivityItem(
            day: _ordinal(now) - 120,
            listenedMs: 3600000,
            playCount: 3,
          ),
          StatsActivityItem(
            day: _ordinal(now),
            listenedMs: 400000,
            playCount: 1,
          ),
        ],
      ),
    );
    addTearDown(app.dispose);
    await pump(tester, app);

    // Monthly buckets span Jun-Oct 2025; a history-based chart could only
    // cover the capped recent sessions, and would show the cap caption.
    expect(find.text('Jun'), findsOneWidget);
    expect(find.text('Oct'), findsOneWidget);
    expect(find.text('Based on your 100 most recent sessions.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('view chips switch between rankings and grouped history', (
    tester,
  ) async {
    final app = _TestApp(serverStats: _stats(now));
    addTearDown(app.dispose);
    await pump(tester, app);

    await tester.tap(find.text('Artists'));
    await tester.pumpAndSettle();
    expect(find.text('Artist A'), findsWidgets);

    await tester.tap(find.text('Albums'));
    await tester.pumpAndSettle();
    expect(find.text('Album A'), findsOneWidget);
    expect(find.text('15 plays'), findsOneWidget);

    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
    // 200 s listened of a 240 s track, counted as a play.
    expect(find.text('3:20 of 4:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelling the custom range picker keeps the current range', (
    tester,
  ) async {
    final app = _TestApp(serverStats: _stats(now));
    addTearDown(app.dispose);
    await pump(tester, app);
    expect(app.statsRequests, 1);

    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    final chip = tester.widget<ChoiceChip>(
      find.ancestor(
        of: find.text('All time'),
        matching: find.byType(ChoiceChip),
      ),
    );
    expect(chip.selected, isTrue);
    expect(app.statsRequests, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('load failure offers a retry that recovers', (tester) async {
    final app = _TestApp();
    addTearDown(app.dispose);
    await pump(tester, app);

    expect(find.text('Could not load stats'), findsOneWidget);
    app.serverStats = _stats(now);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Time listened'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed range change never presents previous-range results', (
    tester,
  ) async {
    final app = _TestApp(serverStats: _stats(now));
    addTearDown(app.dispose);
    await pump(tester, app);
    expect(find.text('First song'), findsWidgets);

    app.serverStats = null; // subsequent loads fail
    await tester.tap(find.text('7 days'));
    await tester.pumpAndSettle();

    // All-time results must not remain under the 7 days selection, and the
    // chart must not re-bucket old history against the new range.
    expect(find.text('Could not load stats'), findsOneWidget);
    expect(find.text('First song'), findsNothing);
    expect(find.text('Activity'), findsNothing);

    app.serverStats = _stats(now);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('First song'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-range refresh failure keeps results with an inline error', (
    tester,
  ) async {
    final app = _TestApp(serverStats: _stats(now));
    addTearDown(app.dispose);
    await pump(tester, app);

    app.serverStats = null;
    await tester.tap(find.byTooltip('Refresh listening stats'));
    await tester.pumpAndSettle();

    expect(find.text('First song'), findsWidgets);
    expect(find.text('Could not load stats'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('Server unavailable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'recreated screen does not present cached stats from another range',
    (tester) async {
      final app = _TestApp(serverStats: _stats(now));
      addTearDown(app.dispose);
      await pump(tester, app);

      // Load a non-default range, then recreate the screen as shell
      // navigation does; the controller retains the 7-day snapshot.
      await tester.tap(find.text('7 days'));
      await tester.pumpAndSettle();
      expect(find.text('First song'), findsWidgets);

      app.serverStats = null; // the recreated screen's initial load fails
      // Simulate shell navigation: leaving Stats disposes the screen state,
      // returning recreates it, while the controller retains the snapshot.
      await tester.pumpWidget(
        MaterialApp(
          theme: YunTheme.light(),
          home: const Scaffold(body: SizedBox()),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: YunTheme.light(),
          home: Scaffold(
            body: StatsScreen(app: app, now: () => now),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The untagged 7-day snapshot must never be presented as All time.
      expect(find.text('Could not load stats'), findsOneWidget);
      expect(find.text('First song'), findsNothing);
      expect(find.text('Activity'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('signed out shows the listening story prompt', (tester) async {
    final app = _TestApp(signedIn: false);
    addTearDown(app.dispose);
    await pump(tester, app);

    expect(find.text('Your listening story'), findsOneWidget);
    expect(app.statsRequests, 0);
    expect(tester.takeException(), isNull);
  });
}
