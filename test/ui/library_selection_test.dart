import 'dart:math';

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/core/playback_controller.dart' show AudioSource;
import 'package:yun/ui/collection_controls.dart';
import 'package:yun/ui/library_screen.dart';
import 'package:yun/ui/track_widgets.dart';

import '../core/fakes.dart';

const _tracks = [
  Track(
    id: 'zulu',
    title: 'Zulu',
    artist: 'Zebra',
    album: 'Collection',
    discNumber: 1,
    trackNumber: 1,
    durationMs: 100,
    createdAt: 10,
  ),
  Track(
    id: 'alpha',
    title: 'Alpha',
    artist: 'Zebra',
    album: 'Collection',
    discNumber: 1,
    trackNumber: 2,
    durationMs: 300,
    createdAt: 30,
  ),
  Track(
    id: 'coda',
    title: 'Coda',
    artist: 'Zebra',
    album: 'Collection',
    discNumber: 2,
    trackNumber: 1,
    durationMs: 400,
    createdAt: 20,
  ),
  Track(
    id: 'bravo',
    title: 'Bravo',
    artist: 'Aardvark',
    album: 'Other',
    discNumber: 1,
    trackNumber: 1,
    durationMs: 200,
    createdAt: 40,
  ),
];

// Always choose a non-first start for multi-track queues, without relying on
// the implementation of seeded Random or on shuffle's other random draws.
class _LastRandom implements Random {
  @override
  int nextInt(int max) => max - 1;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected random operation');
}

class _LibraryApp extends ChangeNotifier implements AppController {
  _LibraryApp() {
    playback = PlaybackController(
      resolveSource: (_, _) async =>
          const AudioSource('fake.audio', local: true),
      engine: engine,
      random: _LastRandom(),
      enableSystemControls: false,
    );
  }

  @override
  final downloadChanges = ChangeNotifier();
  @override
  final artworkChanges = ChangeNotifier();
  final engine = FakeEngine();
  @override
  late final PlaybackController playback;
  @override
  bool isAuthenticated = true;
  @override
  bool get busy => false;
  @override
  Future<String?> getArtwork(Track track) async => null;
  @override
  String? artworkPath(Track track) => null;
  @override
  bool isPinned(String kind, String id) => pinned.contains(id);
  @override
  Future<void> shutdown() => playback.shutdown();

  @override
  void dispose() {
    downloadChanges.dispose();
    artworkChanges.dispose();
    playback.dispose();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected app operation: ${invocation.memberName}',
  );

  List<Track> library = [..._tracks];
  final pinned = <String>[];
  final deleted = <String>[];
  bool offline = false;
  String userId = 'user';
  int _nextId = 0;
  List<Playlist> lists = const [
    Playlist(
      id: 'mix',
      name: 'My mix',
      entries: [PlaylistEntry(id: 'existing', trackId: 'alpha')],
    ),
  ];

  @override
  Account? get account => isAuthenticated
      ? Account(
          server: 'https://music.example.test',
          userId: userId,
          username: 'Listener',
        )
      : null;
  @override
  bool get isOffline => offline;
  @override
  List<Track> get tracks => library;
  @override
  List<Playlist> get playlists => lists;
  @override
  String newId() => 'entry-${_nextId++}';
  @override
  DownloadProgress downloadProgress(Track track) => DownloadProgress(
    trackId: track.id,
    totalBytes: 0,
    status: DownloadStatus.availableOnline,
  );
  @override
  Future<void> play(Track track, {List<Track>? queue}) =>
      playback.playQueue(queue ?? [track], index: queue?.indexOf(track) ?? 0);
  @override
  Future<void> pinTrack(String id, {bool pinned = true}) async {
    if (pinned) this.pinned.add(id);
  }

  @override
  Future<void> deleteTrack(String id) async {
    deleted.add(id);
    library = library.where((track) => track.id != id).toList();
    notifyListeners();
  }

  @override
  Future<Playlist> savePlaylist(
    Playlist playlist, {
    String? name,
    List<PlaylistEntry>? entries,
  }) async {
    final updated = Playlist(
      id: playlist.id,
      name: name ?? playlist.name,
      entries: entries ?? playlist.entries,
    );
    lists = [updated];
    notifyListeners();
    return updated;
  }

  void update() => notifyListeners();
}

typedef _Body = Future<void> Function(WidgetTester tester, _LibraryApp app);

void _libraryTest(
  String name,
  _Body body, {
  Size size = const Size(1000, 1400),
  double scale = 1,
}) {
  testWidgets(name, (tester) async {
    final app = _LibraryApp();
    final focus = FocusNode();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryScreen(
              app: app,
              searchFocus: focus,
              onUpload: () {},
              onSignIn: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await body(tester, app);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(app.shutdown);
      app.dispose();
      focus.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
  });
}

List<String> _visibleIds(WidgetTester tester) => tester
    .widgetList<TrackTile>(find.byType(TrackTile))
    .map((tile) => tile.track.id)
    .toList();

List<String> _selectedIds(WidgetTester tester) => tester
    .widgetList<TrackTile>(find.byType(TrackTile))
    .where((tile) => tile.selected == true)
    .map((tile) => tile.track.id)
    .toList();

Future<void> _tap(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label).last);
  // Scrolling updates the offset before the sliver has laid out its children.
  await tester.pumpAndSettle();
  expect(find.text(label).last.hitTestable(), findsOneWidget);
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _sort(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('Sort by'));
  await tester.pumpAndSettle();
  await _tap(tester, label);
}

Future<void> _selectAll(WidgetTester tester) async {
  await _tap(tester, 'Select tracks');
  await _tap(tester, 'Select all');
}

void main() {
  _libraryTest('Play queues the filtered tracks in the current sort order', (
    tester,
    app,
  ) async {
    await tester.enterText(find.byType(TextField), 'Collection');
    await tester.pumpAndSettle();
    await _sort(tester, 'Duration');
    await tester.tap(find.byTooltip('Sort descending'));
    await tester.pumpAndSettle();
    await _tap(tester, 'Play');
    expect(app.playback.queue.map((track) => track.id), [
      'coda',
      'alpha',
      'zulu',
    ]);
    expect(app.playback.currentTrack?.id, 'coda');
    expect(app.playback.isPlaying, isTrue);
  });

  _libraryTest(
    'Play is disabled for no matches, an empty library or sign-out',
    (tester, app) async {
      FilledButton playButton() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Play'),
      );
      expect(playButton().onPressed, isNotNull);
      await tester.enterText(find.byType(TextField), 'no matching songs');
      await tester.pumpAndSettle();
      expect(playButton().onPressed, isNull);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(playButton().onPressed, isNotNull);

      app.library = [];
      app.update();
      await tester.pumpAndSettle();
      expect(playButton().onPressed, isNull);

      // Retain tracks to ensure authentication, not emptiness, disables Play.
      app.library = [..._tracks];
      app.isAuthenticated = false;
      app.update();
      await tester.pumpAndSettle();
      expect(playButton().onPressed, isNull);
      expect(app.playback.queue, isEmpty);
    },
  );

  for (final action in ['Play', 'Play all', 'Play selected']) {
    _libraryTest(
      '$action honors shuffle and settings; row taps stay explicit',
      (tester, app) async {
        app.playback.setShuffle(true);
        app.playback.setRepeat(RepeatMode.one);
        await app.playback.setVolume(37);
        await tester.pumpAndSettle();
        await _tap(tester, 'Albums');
        await _tap(tester, 'Collection');
        await _sort(tester, 'Duration');
        await tester.tap(find.byTooltip('Sort descending'));
        await tester.pumpAndSettle();
        if (action == 'Play selected') {
          await _selectAll(tester);
          await _tap(tester, 'Alpha');
        }
        if (action == 'Play all') {
          await tester.tap(find.byTooltip(action));
          await tester.pumpAndSettle();
        } else {
          await _tap(tester, action);
        }
        expect(app.playback.queue.map((track) => track.id), [
          'coda',
          if (action != 'Play selected') 'alpha',
          'zulu',
        ]);
        expect(app.playback.currentTrack?.id, 'zulu');
        expect(app.playback.shuffle, isTrue);
        expect(app.playback.repeatMode, RepeatMode.one);
        expect(app.playback.volume, 37);
        expect(app.engine.volume, 37);
        expect(app.playback.isPlaying, isTrue);

        if (action == 'Play selected') await _tap(tester, 'Done selecting');
        // Neither an explicit nonzero index nor an explicit zero may randomize.
        for (final title in ['Alpha', 'Coda']) {
          await _tap(tester, title);
          expect(app.playback.currentTrack?.title, title);
          expect(app.playback.queue.map((track) => track.id), [
            'coda',
            'alpha',
            'zulu',
          ]);
          expect(app.playback.shuffle, isTrue);
          expect(app.playback.repeatMode, RepeatMode.one);
          expect(app.playback.volume, 37);
          expect(app.engine.volume, 37);
        }
      },
    );
  }

  _libraryTest('select all includes filtered tracks outside the viewport', (
    tester,
    app,
  ) async {
    app.library = [
      for (var i = 0; i < 60; i++)
        Track(
          id: 'track-$i',
          title: 'Track $i',
          album: i.isEven ? 'Keep' : 'Other',
        ),
    ];
    app.update();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep');
    await tester.pumpAndSettle();
    await _selectAll(tester);
    expect(
      tester
          .widget<SelectionControls>(find.byType(SelectionControls))
          .selectedCount,
      30,
    );
    expect(find.byType(TrackTile).evaluate().length, lessThan(30));
    await _tap(tester, 'Keep selected offline');
    expect(app.pinned.toSet(), {for (var i = 0; i < 60; i += 2) 'track-$i'});
  });

  _libraryTest('select all and clear are scoped to the current search', (
    tester,
    app,
  ) async {
    await tester.enterText(find.byType(TextField), 'Collection');
    await tester.pumpAndSettle();
    await _selectAll(tester);
    expect(_selectedIds(tester), ['alpha', 'coda', 'zulu']);
    expect(
      tester
          .widget<SelectionControls>(find.byType(SelectionControls))
          .allSelected,
      isTrue,
    );
    await _tap(tester, 'Deselect all');
    expect(_selectedIds(tester), isEmpty);
    expect(find.text('Select all'), findsOneWidget);
    await _tap(tester, 'Select all');
    expect(_selectedIds(tester), ['alpha', 'coda', 'zulu']);
    await _tap(tester, 'Clear selection');
    expect(_selectedIds(tester), isEmpty);
    expect(
      tester
          .widget<SelectionControls>(find.byType(SelectionControls))
          .selectedCount,
      0,
    );

    await _tap(tester, 'Select all');
    await tester.enterText(find.byType(TextField), 'Alpha');
    await tester.pumpAndSettle();
    expect(_selectedIds(tester), ['alpha']);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(_visibleIds(tester), ['alpha', 'bravo', 'coda', 'zulu']);
    expect(_selectedIds(tester), [
      'alpha',
    ], reason: 'Hidden selections must not return');
  });

  _libraryTest(
    'checkboxes and row taps toggle without playing; done restores playback',
    (tester, app) async {
      await _tap(tester, 'Select tracks');
      final alpha = find.byKey(const ValueKey('alpha'));
      await tester.tap(
        find.descendant(of: alpha, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      expect(_selectedIds(tester), ['alpha']);
      await _tap(tester, 'Coda');
      expect(_selectedIds(tester), ['alpha', 'coda']);
      expect(app.playback.currentTrack, isNull);
      await _tap(tester, 'Alpha');
      expect(_selectedIds(tester), ['coda']);
      await _tap(tester, 'Done selecting');
      expect(find.byType(Checkbox), findsNothing);
      await _tap(tester, 'Bravo');
      expect(app.playback.currentTrack?.id, 'bravo');
      expect(app.playback.queue.map((track) => track.id), [
        'alpha',
        'bravo',
        'coda',
        'zulu',
      ]);
    },
  );

  _libraryTest(
    'sort fields and direction reorder tracks while selection follows IDs',
    (tester, app) async {
      expect(_visibleIds(tester), ['alpha', 'bravo', 'coda', 'zulu']);
      await _tap(tester, 'Select tracks');
      await _tap(tester, 'Coda');
      await _sort(tester, 'Duration');
      expect(_visibleIds(tester), ['zulu', 'bravo', 'alpha', 'coda']);
      expect(_selectedIds(tester), ['coda']);
      await tester.tap(find.byTooltip('Sort descending'));
      await tester.pumpAndSettle();
      expect(_visibleIds(tester), ['coda', 'alpha', 'bravo', 'zulu']);
      await tester.tap(find.byTooltip('Sort ascending'));
      await tester.pumpAndSettle();
      await _sort(tester, 'Date added');
      expect(_visibleIds(tester), ['zulu', 'coda', 'alpha', 'bravo']);
      await _sort(tester, 'Artist');
      expect(_visibleIds(tester).first, 'bravo');
      await _sort(tester, 'Album');
      expect(_visibleIds(tester).last, 'bravo');
      await _sort(tester, 'Title');
      expect(_visibleIds(tester), ['alpha', 'bravo', 'coda', 'zulu']);
      expect(_selectedIds(tester), ['coda']);
    },
  );

  _libraryTest('play selected queues only selected tracks in displayed order', (
    tester,
    app,
  ) async {
    await _tap(tester, 'Select tracks');
    await _tap(tester, 'Alpha');
    await _tap(tester, 'Zulu');
    await _sort(tester, 'Duration');
    await _tap(tester, 'Play selected');
    expect(app.playback.currentTrack?.id, 'zulu');
    expect(app.playback.queue.map((track) => track.id), ['zulu', 'alpha']);
  });

  _libraryTest(
    'bulk offline and playlist actions use selected tracks and deduplicate',
    (tester, app) async {
      await tester.enterText(find.byType(TextField), 'Collection');
      await tester.pumpAndSettle();
      await _selectAll(tester);
      await _tap(tester, 'Keep selected offline');
      expect(app.pinned, ['alpha', 'coda', 'zulu']);
      await _tap(tester, 'Add selected to playlist');
      await _tap(tester, 'My mix');
      expect(app.playlists.single.entries.map((entry) => entry.trackId), [
        'alpha',
        'coda',
        'zulu',
      ]);
      expect(app.playlists.single.entries.first.id, 'existing');
      await _tap(tester, 'Add selected to playlist');
      await _tap(tester, 'My mix');
      expect(app.playlists.single.entries.map((entry) => entry.trackId), [
        'alpha',
        'coda',
        'zulu',
      ]);
    },
  );

  for (final rebuild in [false, true]) {
    _libraryTest(
      'account switch during add-to-playlist cannot write (rebuild: $rebuild)',
      (tester, app) async {
        await _selectAll(tester);
        await _tap(tester, 'Add selected to playlist');
        final original = app.playlists.single;
        app.userId = 'other-user';
        app.update();
        if (rebuild) await tester.pumpAndSettle();
        // Tap directly so the false case exercises the guard before rebuild.
        await tester.tap(find.text('My mix'));
        await tester.pumpAndSettle();
        expect(app.playlists.single, same(original));
        expect(find.byType(SelectionControls), findsNothing);
      },
    );
  }

  _libraryTest(
    'album defaults to disc/track order; select all is scoped to album detail',
    (tester, app) async {
      await _tap(tester, 'Albums');
      expect(find.byType(SelectionControls), findsNothing);
      await _tap(tester, 'Collection');
      expect(_visibleIds(tester), ['zulu', 'alpha', 'coda']);
      await tester.tap(find.byTooltip('Play all'));
      await tester.pumpAndSettle();
      expect(app.playback.queue.map((track) => track.id), [
        'zulu',
        'alpha',
        'coda',
      ]);
      await _selectAll(tester);
      expect(_selectedIds(tester), ['zulu', 'alpha', 'coda']);
      await _sort(tester, 'Title');
      expect(_selectedIds(tester), ['alpha', 'coda', 'zulu']);
      await tester.enterText(find.byType(TextField), 'Zulu');
      await tester.pumpAndSettle();
      expect(_visibleIds(tester), ['zulu']);
      expect(_selectedIds(tester), ['zulu']);
      expect(find.byTooltip('Back to albums'), findsOneWidget);
      await _tap(tester, 'Play selected');
      expect(app.playback.queue.map((track) => track.id), ['zulu']);
    },
  );

  _libraryTest(
    'artist detail selects only its filtered tracks and leaving clears selection',
    (tester, app) async {
      await _selectAll(tester);
      await _tap(tester, 'Artists');
      await _tap(tester, 'Zebra');
      await _selectAll(tester);
      expect(_selectedIds(tester), ['alpha', 'coda', 'zulu']);
      await tester.enterText(find.byType(TextField), 'Coda');
      await tester.pumpAndSettle();
      expect(_selectedIds(tester), ['coda']);
      await tester.tap(find.byTooltip('Back to artists'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      await _tap(tester, 'Aardvark');
      await _tap(tester, 'Select tracks');
      expect(_selectedIds(tester), isEmpty);
    },
  );

  _libraryTest(
    'delete requires confirmation and never deletes hidden selections',
    (tester, app) async {
      await _selectAll(tester);
      await tester.enterText(find.byType(TextField), 'Collection');
      await tester.pumpAndSettle();
      await _tap(tester, 'Delete selected');
      expect(find.text('Delete 3 selected tracks?'), findsOneWidget);
      expect(app.deleted, isEmpty);
      await _tap(tester, 'Cancel');
      expect(app.deleted, isEmpty);
      expect(_selectedIds(tester), ['alpha', 'coda', 'zulu']);
      await _tap(tester, 'Delete selected');
      await _tap(tester, 'Delete');
      expect(app.deleted, ['alpha', 'coda', 'zulu']);
      expect(app.tracks.map((track) => track.id), ['bravo']);
      expect(
        tester
            .widget<SelectionControls>(find.byType(SelectionControls))
            .selectedCount,
        0,
      );
    },
  );

  _libraryTest(
    'stale IDs and account changes clear selection even when IDs overlap',
    (tester, app) async {
      await _selectAll(tester);
      app.library = app.library.where((track) => track.id != 'alpha').toList();
      app.update();
      await tester.pumpAndSettle();
      expect(_selectedIds(tester), ['bravo', 'coda', 'zulu']);
      app.userId = 'other-user';
      app.update();
      await tester.pumpAndSettle();
      expect(find.byType(SelectionControls), findsNothing);
      await _tap(tester, 'Select tracks');
      expect(_selectedIds(tester), isEmpty);
    },
  );

  _libraryTest(
    'switching accounts during delete confirmation cannot delete new account tracks',
    (tester, app) async {
      await _selectAll(tester);
      await _tap(tester, 'Delete selected');
      app.userId = 'other-user';
      app.update();
      await tester.pumpAndSettle();
      await _tap(tester, 'Delete');
      expect(app.deleted, isEmpty);
    },
  );

  _libraryTest(
    'empty selection and offline state disable unavailable actions',
    (tester, app) async {
      await _tap(tester, 'Select tracks');
      TextButton button(String label) =>
          tester.widget<TextButton>(find.widgetWithText(TextButton, label));
      expect(button('Play selected').onPressed, isNull);
      expect(button('Delete selected').onPressed, isNull);
      await _tap(tester, 'Alpha');
      app.offline = true;
      app.update();
      await tester.pumpAndSettle();
      expect(button('Add selected to playlist').onPressed, isNull);
      expect(button('Delete selected').onPressed, isNull);
      expect(button('Play selected').onPressed, isNotNull);
      expect(button('Keep selected offline').onPressed, isNotNull);
      await tester.enterText(find.byType(TextField), 'no matching songs');
      await tester.pumpAndSettle();
      final controls = tester.widget<SelectionControls>(
        find.byType(SelectionControls),
      );
      expect(controls.selectedCount, 0);
      expect(controls.onSelectAll, isNull);
      expect(controls.allSelected, isFalse);
    },
  );

  for (final scale in [1.0, 1.5]) {
    _libraryTest(
      'selection controls wrap on a narrow screen at text scale $scale',
      (tester, app) async {
        await _selectAll(tester);
        expect(tester.takeException(), isNull);
        await _tap(tester, 'Keep selected offline');
        expect(app.pinned.toSet(), _tracks.map((track) => track.id).toSet());
        await _tap(tester, 'Delete selected');
        await _tap(tester, 'Cancel');
        await _tap(tester, 'Albums');
        await _tap(tester, 'Collection');
        await _selectAll(tester);
        await _tap(tester, 'Play selected');
        expect(app.playback.queue.map((track) => track.id), [
          'zulu',
          'alpha',
          'coda',
        ]);
      },
      size: const Size(320, 1100),
      scale: scale,
    );
  }
}
