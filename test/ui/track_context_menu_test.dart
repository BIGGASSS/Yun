import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/ui/track_widgets.dart';

import '../core/fakes.dart';
import 'player_test_app.dart';

const _tracks = [
  Track(id: 'alpha', title: 'Alpha', artist: 'Artist A', bitrateKbps: 320),
  Track(id: 'beta', title: 'Beta', artist: 'Artist B', bitrateKbps: 192),
];

class _TrackApp extends PlayerTestApp {
  _TrackApp(super.engine);

  Account currentAccount = const Account(
    server: 'https://a.test',
    userId: 'a',
    username: 'a',
  );
  @override
  Account get account => currentAccount;
  final deleted = <String>[];
  @override
  Future<void> deleteTrack(String id) async => deleted.add(id);

  final played = <Track>[];
  final playQueues = <List<Track>?>[];
  final queued = <Track>[];
  final pinCalls = <({String id, bool pinned})>[];
  final pinnedIds = <String>{};

  @override
  DownloadProgress downloadProgress(Track track) => DownloadProgress(
    trackId: track.id,
    totalBytes: track.sizeBytes,
    status: DownloadStatus.availableOnline,
  );

  @override
  Future<void> play(Track track, {List<Track>? queue}) async {
    played.add(track);
    playQueues.add(queue);
    final tracks = queue ?? [track];
    await playback.playQueue(
      tracks,
      index: tracks.indexWhere((item) => item.id == track.id),
    );
  }

  @override
  Future<void> queueNext(Track track) async {
    queued.add(track);
    await playback.queueNext(track);
  }

  @override
  bool isPinned(String kind, String id) =>
      kind == 'track' && pinnedIds.contains(id);

  @override
  Future<void> pinTrack(String id, {bool pinned = true}) async {
    pinCalls.add((id: id, pinned: pinned));
    if (pinned) {
      pinnedIds.add(id);
    } else {
      pinnedIds.remove(id);
    }
    notifyListeners();
  }
}

enum _OpeningGesture { secondaryClick, longPress }

Future<Offset> _openMenu(
  WidgetTester tester,
  Track track,
  _OpeningGesture opening,
) async {
  final point =
      tester.getTopLeft(find.widgetWithText(TrackTile, track.title)) +
      const Offset(120, 30);
  if (opening == _OpeningGesture.secondaryClick) {
    await tester.tapAt(
      point,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
  } else {
    await tester.longPressAt(point, kind: PointerDeviceKind.touch);
  }
  await tester.pumpAndSettle();
  return point;
}

void _expectOptions({bool pinned = false}) {
  expect(find.byType(PopupMenuItem<String>), findsNWidgets(5));
  for (final label in [
    'Play next',
    'Add to playlist',
    pinned ? 'Unpin download' : 'Keep offline',
    'Edit metadata & artwork',
    'Delete from library',
  ]) {
    expect(find.text(label), findsOneWidget);
  }
}

Future<void> _dismissMenu(WidgetTester tester) async {
  await tester.tapAt(const Offset(790, 590));
  await tester.pumpAndSettle();
  expect(find.byType(PopupMenuItem<String>), findsNothing);
}

Future<void> _pumpBody(WidgetTester tester, Widget body) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));
  await tester.pumpAndSettle();
}

void _trackTest(
  String description,
  Future<void> Function(WidgetTester, _TrackApp, FakeEngine) body,
) {
  testWidgets(description, (tester) async {
    final engine = FakeEngine();
    final app = _TrackApp(engine);
    try {
      await body(tester, app, engine);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(app.shutdown);
      app.dispose();
    }
  });
}

void main() {
  _trackTest(
    'rebuilt popup cannot dispatch an old selection to a new account',
    (tester, app, engine) async {
      await _pumpBody(tester, TrackTile(app: app, track: _tracks.first));
      await tester.tap(find.byTooltip('Options for Alpha'));
      await tester.pumpAndSettle();
      app.currentAccount = const Account(
        server: 'https://b.test',
        userId: 'b',
        username: 'b',
      );
      await _pumpBody(tester, TrackTile(app: app, track: _tracks.first));
      await tester.tap(find.text('Keep offline'));
      await tester.pumpAndSettle();
      expect(app.pinCalls, isEmpty);
    },
  );

  for (final duringConfirmation in [false, true]) {
    _trackTest(
      'stale track menu cannot act on another account (confirmation=$duringConfirmation)',
      (tester, app, engine) async {
        await _pumpBody(tester, TrackTile(app: app, track: _tracks.first));
        await _openMenu(tester, _tracks.first, _OpeningGesture.secondaryClick);
        if (duringConfirmation) {
          await tester.tap(find.text('Delete from library'));
          await tester.pumpAndSettle();
        }
        app.currentAccount = const Account(
          server: 'https://b.test',
          userId: 'b',
          username: 'b',
        );
        await tester.tap(
          find.text(duringConfirmation ? 'Delete' : 'Keep offline'),
        );
        await tester.pumpAndSettle();
        expect(app.deleted, isEmpty);
        expect(app.pinCalls, isEmpty);
      },
    );
  }
  for (final opening in _OpeningGesture.values) {
    _trackTest(
      '${opening.name} opens anchored track options without activating the row',
      (tester, app, engine) async {
        var customTaps = 0;
        await app.playback.playQueue([_tracks.first]);
        await _pumpBody(
          tester,
          Padding(
            padding: const EdgeInsets.all(40),
            child: ListView(
              children: [
                TrackTile(app: app, track: _tracks.first, queue: _tracks),
                TrackTile(
                  app: app,
                  track: _tracks.last,
                  onTap: () => customTaps++,
                ),
              ],
            ),
          ),
        );

        for (final track in _tracks) {
          final row = find.widgetWithText(TrackTile, track.title);
          final bitrate = find.descendant(
            of: row,
            matching: find.text('· ${track.bitrateKbps} kbps'),
          );
          final availability = find.descendant(
            of: row,
            matching: find.byIcon(Icons.cloud_outlined),
          );
          expect(bitrate, findsOneWidget);
          expect(availability, findsOneWidget);
          final point = await _openMenu(tester, track, opening);
          _expectOptions();
          final menu = tester.getRect(
            find
                .ancestor(
                  of: find.text('Play next'),
                  matching: find.byType(Material),
                )
                .first,
          );
          expect(menu.left, closeTo(point.dx, 1));
          expect(menu.top, closeTo(point.dy, 1));
          expect(app.played, isEmpty);
          expect(customTaps, 0);
          expect(engine.opens, 1);
          await _dismissMenu(tester);
          expect(bitrate, findsOneWidget);
          expect(availability, findsOneWidget);
          expect(app.played, isEmpty);
          expect(customTaps, 0);
          expect(app.queued, isEmpty);
          expect(app.pinCalls, isEmpty);
          expect(app.playback.currentTrack, _tracks.first);
          expect(engine.opens, 1);
        }

        await _openMenu(tester, _tracks.last, opening);
        await tester.tap(find.text('Play next'));
        await tester.pumpAndSettle();
        expect(app.queued, [_tracks.last]);
        expect(
          app.playback.effectiveQueue.map((entry) => entry.track),
          _tracks,
        );

        await _openMenu(tester, _tracks.last, opening);
        await tester.tap(find.text('Keep offline'));
        await tester.pumpAndSettle();
        expect(app.pinCalls, [(id: 'beta', pinned: true)]);
        expect(app.pinnedIds, {'beta'});
        expect(app.played, isEmpty);
        expect(customTaps, 0);
        expect(app.playback.currentTrack, _tracks.first);
        expect(engine.opens, 1);
        expect(find.byType(PopupMenuItem<String>), findsNothing);
      },
    );
  }

  _trackTest('ellipsis retains the same options and pin toggle', (
    tester,
    app,
    engine,
  ) async {
    var taps = 0;
    await _pumpBody(
      tester,
      TrackTile(app: app, track: _tracks.last, onTap: () => taps++),
    );
    await tester.tap(find.byTooltip('Options for Beta'));
    await tester.pumpAndSettle();
    _expectOptions();
    await tester.tap(find.text('Keep offline'));
    await tester.pumpAndSettle();
    expect(app.pinCalls, [(id: 'beta', pinned: true)]);

    await tester.tap(find.byTooltip('Options for Beta'));
    await tester.pumpAndSettle();
    _expectOptions(pinned: true);
    await tester.tap(find.text('Unpin download'));
    await tester.pumpAndSettle();
    expect(app.pinCalls, [
      (id: 'beta', pinned: true),
      (id: 'beta', pinned: false),
    ]);
    expect(app.pinnedIds, isEmpty);
    expect(taps, 0);
    expect(app.played, isEmpty);
    expect(engine.opens, 0);
  });

  _trackTest('ordinary mouse and touch taps still play or invoke onTap', (
    tester,
    app,
    engine,
  ) async {
    var taps = 0;
    await _pumpBody(
      tester,
      ListView(
        children: [
          TrackTile(app: app, track: _tracks.last, queue: _tracks),
          TrackTile(app: app, track: _tracks.first, onTap: () => taps++),
        ],
      ),
    );
    for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
      await tester.tap(find.text('Beta'), kind: kind);
      await tester.pumpAndSettle();
      expect(app.playback.currentTrack, _tracks.last);
      expect(app.playback.isPlaying, isTrue);
      final opens = engine.opens;
      await tester.tap(find.text('Alpha'), kind: kind);
      await tester.pumpAndSettle();
      expect(engine.opens, opens);
      expect(find.byType(PopupMenuItem<String>), findsNothing);
    }
    expect(app.played, [_tracks.last, _tracks.last]);
    expect(app.playQueues, everyElement(same(_tracks)));
    expect(taps, 2);
  });

  _trackTest(
    'context menus do not select; row and checkbox taps still select',
    (tester, app, engine) async {
      var selected = false;
      var taps = 0;
      final selections = <bool?>[];
      await _pumpBody(
        tester,
        StatefulBuilder(
          builder: (context, setState) => TrackTile(
            app: app,
            track: _tracks.last,
            selected: selected,
            onTap: () => taps++,
            onSelectionChanged: (value) {
              selections.add(value);
              setState(() => selected = value!);
            },
          ),
        ),
      );
      for (final opening in _OpeningGesture.values) {
        await _openMenu(tester, _tracks.last, opening);
        _expectOptions();
        expect(selections, isEmpty);
        await _dismissMenu(tester);
        expect(selections, isEmpty);
        expect(selected, isFalse);
      }
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      expect(selected, isTrue);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(selected, isFalse);
      expect(selections, [true, false]);
      expect(taps, 0);
      expect(app.played, isEmpty);
      expect(engine.opens, 0);
    },
  );

  _trackTest('drag scrolling cancels a pending touch long press', (
    tester,
    app,
    engine,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _pumpBody(
      tester,
      ListView(
        controller: scroll,
        children: [
          for (var i = 0; i < 30; i++)
            TrackTile(
              app: app,
              track: Track(id: '$i', title: 'Track $i'),
            ),
        ],
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Track 3')),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump(const Duration(milliseconds: 16));
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump(kLongPressTimeout + kPressTimeout);
    expect(find.byType(PopupMenuItem<String>), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(find.byType(PopupMenuItem<String>), findsNothing);
    expect(app.played, isEmpty);
    expect(engine.opens, 0);
  });
}
