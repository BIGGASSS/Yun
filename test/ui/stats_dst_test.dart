import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/ui/stats_screen.dart';
import 'package:yun/ui/theme.dart';

// Stats date math must be calendar-based, not elapsed-duration-based: local
// midnights across a DST transition are 23 or 25 hours apart. These tests
// pass in any timezone, and become load-bearing regressions when the process
// timezone observes DST — CI additionally runs this file with
// TZ=America/New_York (see .github/workflows/ci.yml).
class _DstApp extends AppController {
  _DstApp(this._stats)
    : super(enableSystemControls: false, automaticRefresh: false) {
    initialized = true;
    account = const Account(
      server: 'https://music.example.test',
      userId: 'user',
      username: 'Listener',
    );
  }

  final ServerStats _stats;

  @override
  Future<ServerStats> loadStats({DateTime? from, DateTime? to}) async {
    stats = _stats;
    return _stats;
  }
}

void main() {
  Future<void> pump(WidgetTester tester, _DstApp app, DateTime now) async {
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

  testWidgets('spring forward: seven calendar days and correct day labels', (
    tester,
  ) async {
    // America/New_York springs forward on March 8, 2026: that local midnight
    // is 23 hours after the previous one.
    final now = DateTime(2026, 3, 10, 12);
    final app = _DstApp(
      ServerStats(
        history: [
          HistoryItem(
            sessionId: 'a',
            trackId: 't',
            title: 'Newer',
            artist: 'A',
            startedAt: DateTime(2026, 3, 9, 9).millisecondsSinceEpoch,
            listenedMs: 300000,
            countedPlay: true,
          ),
          HistoryItem(
            sessionId: 'b',
            trackId: 't',
            title: 'Older',
            artist: 'A',
            startedAt: DateTime(2026, 3, 8, 9).millisecondsSinceEpoch,
            listenedMs: 240000,
            countedPlay: true,
          ),
        ],
      ),
    );
    addTearDown(app.dispose);
    await pump(tester, app, now);

    await tester.tap(find.text('7 days'));
    await tester.pumpAndSettle();

    // Mar 4–Mar 10 are seven calendar days: Wed Thu Fri Sat Sun Mon Tue.
    // Elapsed 24-hour math yields six buckets ending on Mon.
    expect(find.text('Tue'), findsOneWidget);

    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    // Mar 9 is Yesterday; Mar 8 must not collapse into it across the 23-hour
    // day — it is two calendar days back, i.e. Sunday.
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('Sunday'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fall back: each calendar day appears exactly once', (
    tester,
  ) async {
    // America/New_York falls back on November 1, 2026: that local midnight is
    // 25 hours after the previous one, and 24-hour stepping repeats a date.
    final now = DateTime(2026, 11, 3, 12);
    final app = _DstApp(const ServerStats());
    addTearDown(app.dispose);
    await pump(tester, app, now);

    await tester.tap(find.text('7 days'));
    await tester.pumpAndSettle();

    // Oct 28–Nov 3 are Wed Thu Fri Sat Sun Mon Tue, each once.
    expect(find.text('Sun'), findsOneWidget);
    expect(find.text('Mon'), findsOneWidget);
    expect(find.text('Tue'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
