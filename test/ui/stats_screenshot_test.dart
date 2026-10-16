import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/ui/stats_screen.dart';
import 'package:yun/ui/theme.dart';

/// Goldens ship in the repo and double as PR evidence, so render them with
/// the SDK's real text/icon fonts instead of the tofu test font.
Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) {
    throw StateError('FLUTTER_ROOT is required to load golden test fonts');
  }
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<ByteData> bytes(String name) async {
    final data = await File('$dir/$name').readAsBytes();
    return data.buffer.asByteData(data.offsetInBytes, data.lengthInBytes);
  }

  final text = FontLoader('Roboto')..addFont(bytes('Roboto-Regular.ttf'));
  final icons = FontLoader('MaterialIcons')
    ..addFont(bytes('MaterialIcons-Regular.otf'));
  await Future.wait([text.load(), icons.load()]);
}

ThemeData _theme(ThemeData base) => base.copyWith(
  textTheme: base.textTheme.apply(fontFamily: 'Roboto'),
  primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'Roboto'),
);

class _ShotApp extends AppController {
  _ShotApp(this.serverStats)
    : super(enableSystemControls: false, automaticRefresh: false) {
    initialized = true;
    account = const Account(
      server: 'https://music.example.test',
      userId: 'user',
      username: 'Listener',
    );
  }

  final ServerStats serverStats;

  final library = <Track>[
    for (var i = 0; i < 12; i++)
      Track(
        id: 'track-$i',
        title: 'Track $i',
        artist: i.isEven ? 'The Midnight' : 'Kavinsky',
        album: i.isEven ? 'Endless Summer' : 'OutRun',
        durationMs: 220000 + i * 9000,
      ),
  ];

  @override
  List<Track> get tracks => isAuthenticated ? library : [];

  @override
  Track? trackById(String id) =>
      library.where((track) => track.id == id).firstOrNull;

  @override
  Future<ServerStats> loadStats({DateTime? from, DateTime? to}) async {
    stats = serverStats;
    return serverStats;
  }
}

ServerStats _richStats(DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  return ServerStats(
    listenedMs: 67 * 3600000 + 1230000,
    playCount: 1284,
    topTracks: const [
      StatsItem(
        id: 'track-0',
        title: 'Sunset',
        artist: 'The Midnight',
        listenedMs: 3200000,
        playCount: 54,
      ),
      StatsItem(
        id: 'track-2',
        title: 'Days of Thunder',
        artist: 'The Midnight',
        listenedMs: 2600000,
        playCount: 41,
      ),
      StatsItem(
        id: 'track-1',
        title: 'Nightcall',
        artist: 'Kavinsky',
        listenedMs: 1900000,
        playCount: 33,
      ),
      StatsItem(
        id: 'track-4',
        title: 'Kids',
        artist: 'The Midnight',
        listenedMs: 1200000,
        playCount: 21,
      ),
      StatsItem(
        id: 'track-3',
        title: 'Odd Look',
        artist: 'Kavinsky',
        listenedMs: 800000,
        playCount: 12,
      ),
    ],
    topArtists: const [
      StatsItem(name: 'The Midnight', listenedMs: 8400000, playCount: 132),
      StatsItem(name: 'Kavinsky', listenedMs: 5100000, playCount: 87),
      StatsItem(name: 'Gunship', listenedMs: 3300000, playCount: 54),
    ],
    topAlbums: const [
      StatsItem(
        name: 'Endless Summer',
        artist: 'The Midnight',
        listenedMs: 6100000,
        playCount: 98,
      ),
      StatsItem(
        name: 'OutRun',
        artist: 'Kavinsky',
        listenedMs: 4200000,
        playCount: 76,
      ),
    ],
    history: [
      for (var day = 0; day < 30; day++)
        for (var session = 0; session < (day * 7 + 3) % 4; session++)
          HistoryItem(
            sessionId: 's-$day-$session',
            trackId: 'track-${(day + session) % 12}',
            title: 'Track ${(day + session) % 12}',
            artist: (day + session).isEven ? 'The Midnight' : 'Kavinsky',
            startedAt: today
                .subtract(Duration(days: 29 - day))
                .add(Duration(hours: 8 + session * 3, minutes: session * 17))
                .millisecondsSinceEpoch,
            listenedMs: 140000 + (day * session * 97777) % 220000,
            countedPlay: session.isEven,
          ),
    ],
  );
}

void main() {
  setUpAll(_loadFonts);

  Future<void> shot(
    WidgetTester tester, {
    required String name,
    required Size size,
    required ThemeData theme,
  }) async {
    final now = DateTime(2025, 10, 14, 12);
    final app = _ShotApp(_richStats(now));
    addTearDown(app.dispose);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(theme),
        home: Scaffold(
          body: StatsScreen(app: app, now: () => now),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(StatsScreen),
      matchesGoldenFile('goldens/stats_$name.png'),
    );
  }

  testWidgets('stats wide light', (tester) async {
    await shot(
      tester,
      name: 'wide_light',
      size: const Size(1200, 900),
      theme: YunTheme.light(),
    );
  });

  testWidgets('stats wide dark', (tester) async {
    await shot(
      tester,
      name: 'wide_dark',
      size: const Size(1200, 900),
      theme: YunTheme.dark(),
    );
  });

  testWidgets('stats narrow light', (tester) async {
    await shot(
      tester,
      name: 'narrow_light',
      size: const Size(390, 844),
      theme: YunTheme.light(),
    );
  });

  testWidgets('stats narrow history dark', (tester) async {
    final now = DateTime(2025, 10, 14, 12);
    final app = _ShotApp(_richStats(now));
    addTearDown(app.dispose);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(YunTheme.dark()),
        home: Scaffold(
          body: StatsScreen(app: app, now: () => now),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('History'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -700));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(StatsScreen),
      matchesGoldenFile('goldens/stats_narrow_history_dark.png'),
    );
  });
}
