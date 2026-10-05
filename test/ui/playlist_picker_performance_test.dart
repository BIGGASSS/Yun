import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/core/collection_settings_controller.dart';
import 'package:yun/ui/playlist_screen.dart';
import 'package:yun/ui/track_widgets.dart';

class _Reads {
  int library = 0, search = 0, sort = 0;
  void reset() => library = search = sort = 0;
}

// Count actual derivation work, rather than timing frames or exposing test-only
// cache hooks. Album/duration are not read by the picker's checkbox rows.
class _MeasuredTrack extends Track {
  _MeasuredTrack(this.reads, String id, String title, int duration)
    : super(id: id, title: title, album: 'Group', durationMs: duration);
  final _Reads reads;
  @override
  String get album {
    reads.search++;
    return super.album;
  }

  @override
  int get durationMs {
    reads.sort++;
    return super.durationMs;
  }
}

class _MeasuredLibrary extends ListBase<Track> {
  _MeasuredLibrary(this.reads, this.items);
  final _Reads reads;
  final List<Track> items;
  @override
  int get length => items.length;
  @override
  set length(int value) => throw UnsupportedError('Immutable snapshot');
  @override
  Track operator [](int index) {
    reads.library++;
    return items[index];
  }

  @override
  void operator []=(int index, Track value) =>
      throw UnsupportedError('Immutable snapshot');
}

class _App extends ChangeNotifier implements AppController {
  @override
  Account? account = const Account(
    server: 'https://music.test',
    userId: 'one',
    username: 'One',
  );
  @override
  bool get isAuthenticated => account != null;
  @override
  List<Track> tracks = [];
  @override
  List<Playlist> playlists = [const Playlist(id: 'mix', name: 'Mix')];
  final saved = <Playlist>[];
  final created = <String>[];
  @override
  bool isPinned(String kind, String id) => false;
  @override
  Track? trackById(String id) =>
      tracks.where((track) => track.id == id).firstOrNull;
  @override
  String newId() => 'entry-${_nextId++}';
  int _nextId = 0;
  @override
  Future<Playlist> savePlaylist(
    Playlist playlist, {
    String? name,
    List<PlaylistEntry>? entries,
  }) async {
    final result = Playlist(
      id: playlist.id,
      name: name ?? playlist.name,
      entries: entries ?? playlist.entries,
    );
    saved.add(result);
    return result;
  }

  @override
  Future<Playlist> createPlaylist(String name) async {
    created.add(name);
    return Playlist(id: 'new', name: name);
  }

  @override
  Future<void> refresh() async => notifyListeners();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected: ${invocation.memberName}');
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _row(String id) => find.byKey(ValueKey('picker-$id'));
List<String> _titles(WidgetTester tester) => tester
    .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
    .map((tile) => (tile.title! as Text).data!)
    .toList();

Future<void> _openPicker(WidgetTester tester, _App app) async {
  final settings = CollectionSettingsController();
  await settings.setTrackSort(
    TrackSortSurface.addTracks,
    TrackSort.duration,
    descending: false,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PlaylistsScreen(app: app, collectionSettings: settings),
      ),
    ),
  );
  await _tap(tester, find.text('Mix'));
  await _tap(tester, find.text('Add tracks'));
}

Future<void> _openChooser(WidgetTester tester, _App app) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => addTracksToPlaylist(context, app, app.tracks),
            child: const Text('Choose'),
          ),
        ),
      ),
    ),
  );
  await _tap(tester, find.text('Choose'));
}

void main() {
  testWidgets('picker reuses each derivation independently of selection', (
    tester,
  ) async {
    final reads = _Reads();
    final app = _App();
    addTearDown(app.dispose);
    app.tracks = _MeasuredLibrary(reads, [
      _MeasuredTrack(reads, 'z', 'Zulu', 3),
      _MeasuredTrack(reads, 'a', 'Alpha', 2),
      _MeasuredTrack(reads, 'b', 'Beta', 1),
    ]);
    await _openPicker(tester, app);
    expect(_titles(tester), ['Beta', 'Alpha', 'Zulu']);
    expect(reads.search, greaterThanOrEqualTo(3));
    expect(reads.sort, greaterThan(0));

    reads.reset();
    await _tap(tester, _row('a'));
    await _tap(tester, _row('a'));
    await _tap(tester, find.text('Select all').last);
    await _tap(tester, find.text('Deselect all').last);
    await _tap(tester, find.text('Select all').last);
    await _tap(tester, find.text('Clear selection').last);
    app.refresh(); // Unrelated notifications also reuse cached snapshots.
    await tester.pumpAndSettle();
    expect((reads.library, reads.search, reads.sort), (0, 0, 0));

    await _tap(tester, find.byTooltip('Sort descending').last);
    expect(_titles(tester), ['Zulu', 'Alpha', 'Beta']);
    expect((reads.library, reads.search), (0, 0));
    expect(reads.sort, greaterThan(0));

    reads.reset();
    await tester.enterText(find.byType(TextField), '  bEtA  ');
    await tester.pumpAndSettle();
    expect(_titles(tester), ['Beta']);
    expect(reads.library, 0);
    expect(reads.search, 3);
    await _tap(tester, _row('b'));
    expect(find.text('Add 1'), findsOneWidget);
    reads.reset();
    await tester.enterText(find.byType(TextField), 'BETA');
    await tester.pumpAndSettle();
    expect((reads.library, reads.search, reads.sort), (0, 0, 0));

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(_row('b')).value, isTrue);
    reads.reset();
    await _tap(tester, find.byTooltip('Sort by').last);
    await _tap(tester, find.text('Title').last);
    expect(_titles(tester), ['Zulu', 'Beta', 'Alpha']);
    expect((reads.library, reads.search), (0, 0));
    await _tap(tester, find.text('Cancel'));
    expect(app.saved, isEmpty);
  });

  testWidgets('picker invalidates snapshots, membership and account scope', (
    tester,
  ) async {
    final app = _App();
    addTearDown(app.dispose);
    app.tracks = const [
      Track(id: 'a', title: 'Alpha', durationMs: 1),
      Track(id: 'b', title: 'Beta', durationMs: 2),
    ];
    await _openPicker(tester, app);
    await _tap(tester, _row('a'));
    await _tap(tester, _row('b'));

    app.tracks = const [Track(id: 'b', title: 'Renamed', durationMs: 2)];
    app.refresh();
    await tester.pumpAndSettle();
    expect(_titles(tester), ['Renamed']);
    expect(find.text('Add 1'), findsOneWidget);

    // Replacement with the same ID and revision must still change eligibility.
    app.playlists = const [
      Playlist(
        id: 'mix',
        name: 'Mix',
        entries: [PlaylistEntry(id: 'entry', trackId: 'b')],
      ),
    ];
    app.refresh();
    await tester.pumpAndSettle();
    expect(_row('b'), findsNothing);
    expect(find.text('Add 0'), findsOneWidget);

    app.playlists = const [Playlist(id: 'mix', name: 'Mix')];
    app.refresh();
    await tester.pumpAndSettle();
    await _tap(tester, _row('b'));
    app.account = const Account(
      server: 'https://other.test',
      userId: 'one',
      username: 'One',
    );
    app.refresh();
    await tester.pumpAndSettle();
    expect(find.text('Account changed; reopen this playlist'), findsOneWidget);
    expect(find.text('Add 0'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Add 0'))
          .onPressed,
      isNull,
    );
    expect(app.saved, isEmpty);
  });

  testWidgets('playlist chooser builds lazily and selects a distant playlist', (
    tester,
  ) async {
    final app = _App();
    addTearDown(app.dispose);
    app.tracks = const [Track(id: 'a', title: 'Alpha')];
    app.playlists = List.generate(
      1000,
      (i) => Playlist(id: '$i', name: 'Playlist $i'),
    );
    await _openChooser(tester, app);
    expect(find.byType(SimpleDialogOption).evaluate().length, lessThan(30));
    expect(find.text('Playlist 999'), findsNothing);
    final list = tester.widget<ListView>(find.byType(ListView));
    expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());
    expect(list.shrinkWrap, isFalse);
    expect(
      tester.getSize(find.byType(ListView)).height,
      lessThanOrEqualTo(360),
    );
    expect(find.text('＋ New playlist').hitTestable(), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('playlist-choice-999')),
      2000,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 100,
    );
    await _tap(tester, find.text('Playlist 999'));
    expect(app.saved.single.id, '999');
    expect(app.saved.single.entries.single.trackId, 'a');
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty chooser fits a small window and can create or cancel', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = _App();
    addTearDown(app.dispose);
    app.tracks = const [Track(id: 'a', title: 'Alpha')];
    app.playlists = [];
    await _openChooser(tester, app);
    expect(find.byType(SimpleDialogOption), findsNothing);
    await _tap(tester, find.text('Cancel'));
    expect(app.saved, isEmpty);
    await _tap(tester, find.text('Choose'));
    await _tap(tester, find.text('＋ New playlist'));
    await tester.enterText(find.byType(TextField), 'New mix');
    await _tap(tester, find.text('Save'));
    expect(app.created, ['New mix']);
    expect(app.saved.single.entries.single.trackId, 'a');
    expect(tester.takeException(), isNull);
  });
}
