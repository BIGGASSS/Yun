import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/ui/stats_screen.dart';
import 'package:yun/ui/theme.dart';

HistoryItem _history(
  String sessionId,
  String trackId,
  String title,
  String artist,
  DateTime started,
  int listenedMs,
  bool counted,
) => HistoryItem(
  sessionId: sessionId,
  trackId: trackId,
  title: title,
  artist: artist,
  startedAt: started.millisecondsSinceEpoch,
  listenedMs: listenedMs,
  countedPlay: counted,
);

ServerStats sampleStats() => ServerStats(
  listenedMs: const Duration(hours: 12, minutes: 40).inMilliseconds,
  playCount: 38,
  topTracks: const [
    StatsItem(
      id: 'track-1',
      title: 'First light',
      artist: 'Ada North',
      listenedMs: 4 * 3600000 + 12 * 60000,
      playCount: 14,
    ),
    StatsItem(
      id: 'track-2',
      title: 'Paper boats',
      artist: 'Ada North',
      listenedMs: 2 * 3600000 + 5 * 60000,
      playCount: 9,
    ),
    StatsItem(
      id: 'track-4',
      title: 'Kitchen radio',
      artist: 'Jun Park',
      listenedMs: 0,
      playCount: 0,
    ),
  ],
  topArtists: const [
    StatsItem(
      name: 'Ada North',
      listenedMs: 6 * 3600000 + 17 * 60000,
      playCount: 23,
    ),
    StatsItem(name: '', listenedMs: 60000, playCount: 1),
  ],
  topAlbums: const [
    StatsItem(
      name: 'Window Songs',
      artist: 'Ada North',
      listenedMs: 6 * 3600000,
      playCount: 20,
    ),
    StatsItem(name: '', artist: 'Jun Park', listenedMs: 48000, playCount: 1),
  ],
  history: [
    _history(
      's1',
      'track-1',
      'First light',
      'Ada North',
      DateTime(2026, 10, 16, 8, 12),
      18 * 60000,
      true,
    ),
    _history(
      's2',
      'track-3',
      'Late bus',
      'Mina Cole',
      DateTime(2026, 10, 16, 7, 40),
      6 * 60000,
      false,
    ),
    _history(
      's3',
      'track-2',
      'Paper boats',
      'Ada North',
      DateTime(2026, 10, 15, 21, 5),
      42 * 60000,
      true,
    ),
  ],
);

class _StatsApp extends AppController {
  _StatsApp({this.signedIn = true})
    : super(enableSystemControls: false, automaticRefresh: false) {
    initialized = true;
    if (signedIn) {
      account = const Account(
        server: 'https://music.example.test',
        userId: 'user',
        username: 'Listener',
      );
    }
    pendingEventCount = 3;
  }

  final bool signedIn;
  bool fail = false;
  ServerStats payload = sampleStats();
  int loads = 0;
  DateTime? lastFrom;
  DateTime? lastTo;
  final played = <String>[];

  @override
  Future<ServerStats> loadStats({DateTime? from, DateTime? to}) async {
    loads++;
    lastFrom = from;
    lastTo = to;
    if (fail) throw Exception('Stats unavailable');
    stats = payload;
    notifyListeners();
    return payload;
  }

  @override
  Track? trackById(String id) => switch (id) {
    'track-1' => const Track(
      id: 'track-1',
      title: 'First light',
      artist: 'Ada North',
    ),
    'track-2' => const Track(
      id: 'track-2',
      title: 'Paper boats',
      artist: 'Ada North',
    ),
    _ => null,
  };

  @override
  Future<void> play(Track track, {List<Track>? queue}) async {
    played.add(track.id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ListeningStats', () {
    test('ranges match the server window, with an exclusive custom end', () {
      final now = DateTime(2026, 10, 16, 15, 4);
      final week = ListeningStats.window(range: '7 days', now: now);
      expect(week.from, DateTime(2026, 10, 10));
      expect(week.to, isNull);

      final month = ListeningStats.window(
        range: '30 days',
        now: DateTime(2026, 3, 1, 8),
      );
      expect(month.from, DateTime(2026, 1, 31));
      expect(month.to, isNull);

      final custom = ListeningStats.window(
        range: 'Custom',
        custom: DateTimeRange(
          start: DateTime(2026, 1, 31, 5),
          end: DateTime(2026, 1, 31, 18),
        ),
        now: now,
      );
      expect(custom.from, DateTime(2026, 1, 31, 5));
      expect(custom.to, DateTime(2026, 2, 1));

      final all = ListeningStats.window(range: 'All time', now: now);
      expect(all.from, isNull);
      expect(all.to, isNull);
      final missing = ListeningStats.window(range: 'Custom', now: now);
      expect(missing.from, isNull);
      expect(missing.to, isNull);
    });

    test('formats duration, plays, and day groups from server rows', () {
      expect(ListeningStats.duration(12 * 1000), '12s');
      expect(ListeningStats.duration(45 * 60000), '45m');
      expect(ListeningStats.duration(2 * 3600000), '2h');
      expect(ListeningStats.duration(90 * 60000), '1h 30m');
      expect(ListeningStats.perPlay(90 * 60000, 2), '45m per counted play');
      expect(ListeningStats.perPlay(0, 4), isNull);
      expect(ListeningStats.plays(1), '1 play');
      expect(ListeningStats.plays(0), '0 plays');
      expect(ListeningStats.plays(-3), '0 plays');
      expect(ListeningStats.join(['Ada', '', '  ', '1 play']), 'Ada · 1 play');
      expect(ListeningStats.share(0, 0), 0);
      expect(ListeningStats.share(5, 10), 0.5);

      final days = ListeningStats.days(sampleStats().history);
      expect(days, hasLength(2));
      expect(days.first.day, DateTime(2026, 10, 16));
      expect(days.first.entries, hasLength(2));
      expect(days.first.listenedMs, 24 * 60000);
      expect(days.last.entries.single.title, 'Paper boats');
      expect(ListeningStats.clock(DateTime(2026, 10, 16, 8, 12)), '08:12');
    });
  });

  Future<void> size(WidgetTester tester, Size value) async {
    tester.view.physicalSize = value;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> show(WidgetTester tester, _StatsApp app) async {
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: YunTheme.dark(),
        home: Scaffold(body: StatsScreen(app: app)),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('history, rankings, playback, and ranges use loaded stats', (
    tester,
  ) async {
    final app = _StatsApp();
    await size(tester, const Size(1100, 800));
    await show(tester, app);

    expect(app.loads, 1);
    expect(app.lastFrom, isNull);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'All time'))
          .selected,
      isTrue,
    );
    expect(find.text('12h 40m').hitTestable(), findsOneWidget);
    expect(find.text('38').hitTestable(), findsOneWidget);
    expect(find.text('20m per counted play'), findsOneWidget);
    expect(find.textContaining('3 listening segments'), findsOneWidget);
    expect(find.text('2026-10-16'), findsOneWidget);
    expect(find.text('08:12'), findsOneWidget);
    expect(find.textContaining('Partial listen'), findsOneWidget);
    expect(find.text('24m'), findsOneWidget);

    await tester.tap(find.byTooltip('Play First light'));
    await tester.pump();
    expect(app.played, ['track-1']);

    await tester.tap(find.widgetWithText(Tab, 'Tracks'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.textContaining('14 plays'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Listening share 100 percent for this track'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Listening share 0 percent for this track'),
      findsOneWidget,
    );
    await tester.tap(find.text('Paper boats').hitTestable());
    await tester.pump();
    expect(app.played, ['track-1', 'track-2']);

    await tester.tap(find.widgetWithText(Tab, 'Artists'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Unknown artist'), findsOneWidget);
    expect(find.text('1 play'), findsOneWidget);

    await tester.tap(find.widgetWithText(Tab, 'Albums'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Unknown album'), findsOneWidget);
    expect(find.textContaining('Jun Park').hitTestable(), findsWidgets);

    await tester.tap(find.widgetWithText(ChoiceChip, '7 days'));
    await tester.pump();
    await tester.pump();
    final today = DateTime.now();
    expect(
      app.lastFrom,
      DateTime(
        today.year,
        today.month,
        today.day,
      ).subtract(const Duration(days: 6)),
    );
    expect(app.lastTo, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed refresh keeps the last stats and can be retried', (
    tester,
  ) async {
    final app = _StatsApp();
    await size(tester, const Size(900, 700));
    await show(tester, app);
    app.fail = true;
    await tester.tap(find.byTooltip('Refresh listening stats'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Stats unavailable'), findsOneWidget);
    expect(find.text('First light'), findsOneWidget);

    app.fail = false;
    await tester.tap(find.widgetWithText(TextButton, 'Try again'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Stats unavailable'), findsNothing);
    expect(find.text('12h 40m'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a failed range change does not present the previous totals as the new range',
    (tester) async {
      final app = _StatsApp();
      await size(tester, const Size(900, 700));
      await show(tester, app);
      expect(find.text('12h 40m'), findsOneWidget);
      expect(find.text('First light'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'All time'))
            .selected,
        isTrue,
      );

      app.fail = true;
      await tester.tap(find.widgetWithText(ChoiceChip, '7 days'));
      await tester.pump();
      await tester.pump();

      final today = DateTime.now();
      expect(
        app.lastFrom,
        DateTime(
          today.year,
          today.month,
          today.day,
        ).subtract(const Duration(days: 6)),
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '7 days'))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'All time'))
            .selected,
        isFalse,
      );
      expect(find.text('12h 40m'), findsNothing);
      expect(find.text('38'), findsNothing);
      expect(find.text('First light'), findsNothing);
      expect(find.text('Stats did not load'), findsOneWidget);
      expect(find.textContaining('Stats unavailable'), findsOneWidget);

      app.fail = false;
      app.payload = ServerStats(
        listenedMs: 5 * 60000,
        playCount: 2,
        history: [
          _history(
            'week',
            'track-9',
            'Week only',
            'Ada North',
            DateTime(2026, 10, 16, 9),
            5 * 60000,
            true,
          ),
        ],
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Week only'), findsOneWidget);
      expect(find.text('5m'), findsWidgets);
      expect(find.text('12h 40m'), findsNothing);
      expect(find.text('First light'), findsNothing);
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '7 days'))
            .selected,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the first load failure offers another try', (tester) async {
    final app = _StatsApp()..fail = true;
    await size(tester, const Size(900, 700));
    await show(tester, app);
    expect(find.text('Stats did not load'), findsOneWidget);
    expect(find.text('First light'), findsNothing);

    app.fail = false;
    await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
    await tester.pump();
    await tester.pump();
    expect(find.text('First light'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty period keeps the totals and explains the list', (
    tester,
  ) async {
    final app = _StatsApp()..payload = const ServerStats();
    await size(tester, const Size(800, 700));
    await show(tester, app);
    expect(find.text('0s'), findsOneWidget);
    expect(find.text('0'), findsOneWidget);
    expect(find.text('per counted play'), findsNothing);
    expect(find.text('Nothing in this period'), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, 'Artists'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Nothing in this period'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('signed out listening stats lead to the server form', (
    tester,
  ) async {
    final app = _StatsApp(signedIn: false);
    var connects = 0;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: YunTheme.light(),
        home: Scaffold(
          body: StatsScreen(app: app, onSignIn: () => connects++),
        ),
      ),
    );
    await tester.pump();
    expect(app.loads, 0);
    expect(find.text('Your listening story'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Connect to server'));
    await tester.pump();
    expect(connects, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stats stay readable on a narrow large-text layout', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.4;
    addTearDown(() {
      tester.platformDispatcher.textScaleFactorTestValue = 1;
    });
    final app = _StatsApp();
    await size(tester, const Size(390, 844));
    await show(tester, app);
    expect(find.text('12h 40m'), findsOneWidget);
    await tester.ensureVisible(find.text('12h 40m'));
    await tester.tap(find.widgetWithText(Tab, 'Tracks'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('First light').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('capped lists say they are the latest server page', (
    tester,
  ) async {
    final tracks = [
      for (var index = 0; index < ListeningStats.rankingCap; index++)
        StatsItem(
          id: 't$index',
          title: 'Track $index',
          artist: 'Artist',
          listenedMs: (ListeningStats.rankingCap - index) * 1000,
          playCount: 1,
        ),
    ];
    final history = [
      for (var index = 0; index < ListeningStats.historyCap; index++)
        _history(
          'h$index',
          't$index',
          'Session $index',
          'Artist',
          DateTime(2026, 10, 16, 12).subtract(Duration(minutes: index)),
          1000,
          true,
        ),
    ];
    final app = _StatsApp()
      ..payload = ServerStats(
        listenedMs: 1000,
        playCount: 1,
        topTracks: tracks,
        history: history,
      );
    await size(tester, const Size(800, 700));
    await show(tester, app);
    expect(
      find.text('Latest ${ListeningStats.historyCap} sessions in this period.'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(Tab, 'Tracks'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      find.text('Top ${ListeningStats.rankingCap} by time listened.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
