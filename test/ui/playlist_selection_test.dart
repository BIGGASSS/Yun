import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/core/playback_controller.dart' show AudioSource;
import 'package:yun/ui/playlist_screen.dart';

import '../core/fakes.dart';

const _tracks = [
  Track(
    id: 'z',
    title: 'Zulu',
    artist: 'Able',
    album: 'Two',
    durationMs: 3000,
    createdAt: 1,
  ),
  Track(
    id: 'a',
    title: 'Alpha',
    artist: 'Zulu',
    album: 'One',
    durationMs: 1000,
    createdAt: 3,
  ),
  Track(
    id: 'b',
    title: 'Beta',
    artist: 'Middle',
    album: 'One',
    durationMs: 2000,
    createdAt: 2,
  ),
];

Playlist _playlist({
  String id = 'p',
  String name = 'Mix',
  int revision = 1,
  int updatedAt = 1,
  List<PlaylistEntry>? entries,
}) => Playlist(
  id: id,
  name: name,
  revision: revision,
  updatedAt: updatedAt,
  entries:
      entries ??
      const [
        PlaylistEntry(id: 'ez', trackId: 'z'),
        PlaylistEntry(id: 'missing', trackId: 'gone'),
        PlaylistEntry(id: 'ea', trackId: 'a'),
        PlaylistEntry(id: 'eb', trackId: 'b'),
      ],
);

// Make the shuffled start observably different from an explicit first row.
class _LastRandom implements Random {
  @override
  int nextInt(int max) => max - 1;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected random operation');
}

class _PlaylistApp extends ChangeNotifier implements AppController {
  _PlaylistApp() {
    playback = PlaybackController(
      resolveSource: (_, _) async =>
          const AudioSource('fake.audio', local: true),
      engine: engine,
      random: _LastRandom(),
      enableSystemControls: false,
    );
  }

  final engine = FakeEngine();
  @override
  late final PlaybackController playback;
  @override
  Account? account = const Account(
    server: 'https://one.example',
    userId: 'one',
    username: 'One',
  );
  @override
  bool get isAuthenticated => account != null;
  @override
  bool isPinned(String type, String id) => pinned.contains(id);
  @override
  Future<void> shutdown() => playback.shutdown();
  @override
  void dispose() {
    playback.dispose();
    super.dispose();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected app operation: ${invocation.memberName}',
  );
  List<Track> library = [..._tracks];
  List<Playlist> collections = [_playlist()];
  final saves = <Playlist>[];
  final created = <String>[];
  final deleted = <String>[];
  final pinned = <String>[];
  Completer<void>? saveGate, pinGate;
  int _nextId = 0;

  @override
  List<Track> get tracks => library;
  @override
  List<Playlist> get playlists => collections;
  @override
  Track? trackById(String id) =>
      library.where((track) => track.id == id).firstOrNull;
  @override
  String newId() => 'new-${_nextId++}';
  @override
  Future<Playlist> createPlaylist(String name) async {
    created.add(name);
    final result = _playlist(id: newId(), name: name, entries: []);
    collections.add(result);
    notifyListeners();
    return result;
  }

  @override
  Future<Playlist> savePlaylist(
    Playlist playlist, {
    String? name,
    List<PlaylistEntry>? entries,
  }) async {
    saves.add(playlist);
    await saveGate?.future;
    final result = Playlist(
      id: playlist.id,
      name: name ?? playlist.name,
      revision: playlist.revision + 1,
      entries: entries ?? playlist.entries,
    );
    collections = [
      for (final item in collections)
        if (item.id == playlist.id) result else item,
    ];
    notifyListeners();
    return result;
  }

  @override
  Future<void> deletePlaylist(Playlist playlist) async {
    deleted.add(playlist.id);
    collections.removeWhere((item) => item.id == playlist.id);
    notifyListeners();
  }

  @override
  Future<void> pinPlaylist(String id, {bool pinned = true}) async {
    this.pinned.add(id);
    await pinGate?.future;
    notifyListeners();
  }

  void switchAccount({bool server = false, bool notify = true}) {
    account = Account(
      server: server ? 'https://two.example' : account!.server,
      userId: server ? account!.userId : 'two',
      username: 'Two',
    );
    // Deliberately retain identical playlist, entry and track IDs/revisions.
    if (notify) notifyListeners();
  }

  void replace(Playlist playlist, {bool notify = true}) {
    collections = [
      for (final item in collections)
        if (item.id == playlist.id) playlist else item,
    ];
    if (notify) notifyListeners();
  }
}

typedef _Body = Future<void> Function(WidgetTester tester, _PlaylistApp app);

void _test(String description, _Body body, {Size size = const Size(900, 900)}) {
  testWidgets(description, (tester) async {
    final app = _PlaylistApp();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PlaylistsScreen(app: app)),
        ),
      );
      await tester.pumpAndSettle();
      await body(tester, app);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(app.shutdown);
      app.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    }
  });
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester) => _tap(tester, find.text('Mix'));
Future<void> _sort(WidgetTester tester, String label) async {
  await _tap(tester, find.byTooltip('Sort by').last);
  await _tap(tester, find.text(label).last);
}

Finder _entry(String id) => find.byKey(ValueKey(id));
Finder _check(String id) =>
    find.descendant(of: _entry(id), matching: find.byType(Checkbox));
Finder _picker(String id) => find.byKey(ValueKey('picker-$id'));
List<String> _entryTitles(WidgetTester tester) => tester
    .widgetList<ListTile>(find.byType(ListTile))
    .map((tile) => (tile.title! as Text).data!)
    .toList();
Finder _dialogText(String text) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

void main() {
  for (final selected in [false, true]) {
    _test(
      '${selected ? 'Play selected' : 'Play'} honors shuffle and settings; entry taps stay explicit',
      (tester, app) async {
        app.playback.setShuffle(true);
        app.playback.setRepeat(RepeatMode.all);
        await app.playback.setVolume(37);
        await _open(tester);
        await _sort(tester, 'Title');
        await _tap(tester, find.byTooltip('Sort descending'));
        if (selected) {
          await _tap(tester, find.text('Select all'));
          await _tap(tester, _check('eb'));
        }
        await _tap(tester, find.text(selected ? 'Play selected' : 'Play'));
        expect(app.playback.queue.map((track) => track.id), [
          'z',
          if (!selected) 'b',
          'a',
        ]);
        expect(app.playback.currentTrack?.id, 'a');
        expect(app.playback.isPlaying, isTrue);
        expect(app.playback.shuffle, isTrue);
        expect(app.playback.repeatMode, RepeatMode.all);
        expect(app.playback.volume, 37);
        expect(app.engine.volume, 37);

        // Unavailable entries never enter the queue; explicit indices still
        // select their track, including index zero, while shuffle stays on.
        for (final (entry, track) in [('eb', 'b'), ('ez', 'z')]) {
          await _tap(tester, _entry(entry));
          expect(app.playback.currentTrack?.id, track);
          expect(app.playback.queue.map((track) => track.id), ['z', 'b', 'a']);
          expect(app.playback.shuffle, isTrue);
          expect(app.playback.repeatMode, RepeatMode.all);
          expect(app.playback.volume, 37);
          expect(app.engine.volume, 37);
        }
        expect(app.saves, isEmpty);
      },
    );
  }

  for (final server in [false, true]) {
    _test(
      'selection resets on ${server ? 'server' : 'user'} change without parent rebuild',
      (tester, app) async {
        await _tap(tester, find.text('Select all'));
        final staleSelect = tester
            .widget<Checkbox>(_check('playlist-p'))
            .onChanged!;
        app.switchAccount(server: server);
        await tester.pumpAndSettle();
        expect(find.text('0 selected'), findsOneWidget);
        expect(find.text('Delete selected'), findsNothing);
        staleSelect(true);
        await tester.pumpAndSettle();
        expect(tester.widget<Checkbox>(_check('playlist-p')).value, isFalse);
      },
    );
  }

  _test(
    'detail scope invalidation survives switching away and back before a frame',
    (tester, app) async {
      await _open(tester);
      await _tap(tester, _check('ez'));
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      final stalePlay = tester.widget<ListTile>(_entry('ez')).onTap!;
      final original = app.account;
      app.switchAccount();
      app.account = original;
      app.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(ReorderableListView), findsNothing);
      await _open(tester);
      expect(find.text('0 selected'), findsOneWidget);
      list.onReorderItem!(0, 3);
      stalePlay();
      await tester.pumpAndSettle();
      expect(app.saves, isEmpty);
      expect(app.playback.queue, isEmpty);
    },
  );

  for (final operation in [
    'create',
    'rename',
    'delete',
    'remove',
    'bulk delete',
  ]) {
    _test(
      '$operation dialog cannot write to a changed account before rebuild',
      (tester, app) async {
        switch (operation) {
          case 'create':
            await _tap(tester, find.text('New playlist'));
            await tester.enterText(find.byType(TextField), 'New name');
          case 'bulk delete':
            await _tap(tester, find.text('Select all'));
            await _tap(tester, find.text('Delete selected'));
          case 'remove':
            await _open(tester);
            await _tap(tester, _check('ez'));
            await _tap(tester, find.text('Remove selected'));
          default:
            await _open(tester);
            await _tap(tester, find.byTooltip('Playlist options'));
            await _tap(
              tester,
              find.text(operation == 'rename' ? 'Rename' : 'Delete playlist'),
            );
            if (operation == 'rename') {
              await tester.enterText(find.byType(TextField), 'New name');
            }
        }
        app.switchAccount(notify: false);
        final label = switch (operation) {
          'create' || 'rename' => 'Save',
          'remove' => 'Remove',
          _ => 'Delete',
        };
        await _tap(tester, _dialogText(label));
        expect(app.saves, isEmpty);
        expect(app.deleted, isEmpty);
        expect(app.created, isEmpty);
        expect(app.playlists.single.name, 'Mix');
        app.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.text('0 selected'), findsOneWidget);
      },
    );
  }

  for (final menu in ['Move down', 'Keep playlist offline', 'Remove entry']) {
    _test('open $menu menu retains its original account scope', (
      tester,
      app,
    ) async {
      await _open(tester);
      await _tap(
        tester,
        find.byTooltip(
          menu == 'Keep playlist offline'
              ? 'Playlist options'
              : 'Entry 1 options',
        ),
      );
      app.switchAccount();
      await tester.pumpAndSettle();
      await _tap(tester, find.text(menu));
      expect(app.saves, isEmpty);
      expect(app.pinned, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
    });
  }

  _test(
    'picker selection is invalidated by account change even when IDs coincide',
    (tester, app) async {
      app.replace(_playlist(entries: []));
      await tester.pumpAndSettle();
      await _open(tester);
      await _tap(tester, find.text('Add tracks'));
      await _tap(tester, _dialogText('Select all'));
      final original = app.account;
      app.switchAccount();
      await tester.pumpAndSettle();
      expect(
        find.text('Account changed; reopen this playlist'),
        findsOneWidget,
      );
      expect(find.byType(CheckboxListTile), findsNothing);
      app.account = original;
      app.notifyListeners();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Add 0'))
            .onPressed,
        isNull,
      );
      await _tap(tester, _dialogText('Cancel'));
      expect(app.saves, isEmpty);
    },
  );

  _test('picker submission rechecks account before its next notification', (
    tester,
    app,
  ) async {
    app.replace(_playlist(entries: []));
    await tester.pumpAndSettle();
    await _open(tester);
    await _tap(tester, find.text('Add tracks'));
    await _tap(tester, _dialogText('Select all'));
    app.switchAccount(server: true, notify: false);
    await _tap(tester, find.text('Add 3'));
    expect(app.saves, isEmpty);
  });

  _test('bulk pin stops between awaited operations when account changes', (
    tester,
    app,
  ) async {
    app.collections.add(_playlist(id: 'q', name: 'Other'));
    app.notifyListeners();
    await tester.pumpAndSettle();
    await _tap(tester, find.text('Select all'));
    app.pinGate = Completer<void>();
    await tester.tap(find.text('Keep offline'));
    await tester.pump();
    expect(app.pinned, hasLength(1));
    app.switchAccount();
    app.pinGate!.complete();
    await tester.pumpAndSettle();
    expect(app.pinned, hasLength(1));
    expect(find.text('0 selected'), findsOneWidget);
  });

  _test(
    'replacing controller with identical account and IDs cancels old dialog intent',
    (tester, app) async {
      await _open(tester);
      await _tap(tester, _check('ez'));
      await _tap(tester, find.text('Remove selected'));
      final replacement = _PlaylistApp();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: PlaylistsScreen(app: replacement)),
          ),
        );
        await tester.pumpAndSettle();
        await _tap(tester, _dialogText('Remove'));
        expect(app.saves, isEmpty);
        expect(replacement.saves, isEmpty);
        expect(find.text('0 selected'), findsOneWidget);
        await _open(tester);
        expect(find.text('Remove selected'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(replacement.shutdown);
        replacement.dispose();
      }
    },
  );

  _test(
    'descending playlist order reverses display and playback, never persisted order',
    (tester, app) async {
      await _open(tester);
      final staleReorder = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      await _tap(tester, _check('ez'));
      await _tap(tester, find.byTooltip('Sort descending'));
      expect(_entryTitles(tester), [
        '1. Beta',
        '2. Alpha',
        '3. Unavailable track',
        '4. Zulu',
      ]);
      expect(find.byType(ReorderableListView), findsNothing);
      expect(find.byType(ReorderableDragStartListener), findsNothing);
      expect(tester.widget<Checkbox>(_check('ez')).value, isTrue);
      staleReorder.onReorderItem!(0, 3);
      await tester.pumpAndSettle();
      await _tap(tester, find.byTooltip('Entry 2 options'));
      for (final label in ['Move up', 'Move down']) {
        expect(
          tester
              .widget<PopupMenuItem<String>>(
                find.widgetWithText(PopupMenuItem<String>, label),
              )
              .enabled,
          isFalse,
        );
      }
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await _tap(tester, find.text('2. Alpha'));
      expect(app.playback.queue.map((track) => track.id), ['b', 'a', 'z']);
      expect(app.playback.currentTrack?.id, 'a');
      expect(app.playlists.single.entries.map((entry) => entry.id), [
        'ez',
        'missing',
        'ea',
        'eb',
      ]);
      expect(app.saves, isEmpty);
      await _tap(tester, find.byTooltip('Sort ascending'));
      expect(find.byType(ReorderableListView), findsOneWidget);
      expect(_entryTitles(tester).first, '1. Zulu');
    },
  );

  _test(
    'overview sorting, stable selection, select all, offline and confirmed delete',
    (tester, app) async {
      app.collections = [
        _playlist(id: 'z', name: 'Zebra', updatedAt: 2, entries: []),
        _playlist(id: 'a', name: 'Alpha', updatedAt: 3),
        _playlist(
          id: 'b',
          name: 'Beta',
          updatedAt: 1,
          entries: const [PlaylistEntry(id: 'b', trackId: 'b')],
        ),
      ];
      app.notifyListeners();
      await tester.pumpAndSettle();
      expect(_entryTitles(tester), ['Alpha', 'Beta', 'Zebra']);
      await _tap(tester, _check('playlist-a'));
      await _sort(tester, 'Date updated');
      expect(_entryTitles(tester), ['Beta', 'Zebra', 'Alpha']);
      expect(tester.widget<Checkbox>(_check('playlist-a')).value, isTrue);
      await _tap(tester, find.byTooltip('Sort descending'));
      expect(_entryTitles(tester), ['Alpha', 'Zebra', 'Beta']);
      await _sort(tester, 'Track count');
      expect(_entryTitles(tester), ['Alpha', 'Beta', 'Zebra']);
      await _tap(tester, find.text('Select all'));
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((box) => box.value!),
        isTrue,
      );
      await _tap(tester, find.text('Deselect all'));
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((box) => !box.value!),
        isTrue,
      );
      await _tap(tester, find.text('Select all'));
      await _tap(tester, find.text('Keep offline'));
      expect(app.pinned.toSet(), {'a', 'b', 'z'});
      await _tap(tester, find.text('Select all'));
      await _tap(tester, find.text('Delete selected'));
      await _tap(tester, _dialogText('Cancel'));
      expect(app.deleted, isEmpty);
      await _tap(tester, find.text('Delete selected'));
      await _tap(tester, _dialogText('Delete'));
      expect(app.deleted.toSet(), {'a', 'b', 'z'});
    },
  );

  _test(
    'detail sorted view preserves persisted order and plays displayed queue',
    (tester, app) async {
      await _open(tester);
      expect(find.byType(ReorderableListView), findsOneWidget);
      await _tap(tester, _check('ez'));
      await _sort(tester, 'Title');
      expect(_entryTitles(tester), [
        '1. Alpha',
        '2. Beta',
        '3. Zulu',
        '4. Unavailable track',
      ]);
      expect(app.saves, isEmpty);
      expect(tester.widget<Checkbox>(_check('ez')).value, isTrue);
      expect(find.byType(ReorderableListView), findsNothing);
      expect(find.byType(ReorderableDragStartListener), findsNothing);
      await _tap(tester, find.byTooltip('Entry 2 options'));
      final moveUp = tester.widget<PopupMenuItem<String>>(
        find.widgetWithText(PopupMenuItem<String>, 'Move up'),
      );
      expect(moveUp.enabled, isFalse);
      expect(find.text('Repeat this track'), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await _tap(tester, find.text('2. Beta'));
      expect(app.playback.queue.map((track) => track.id), ['a', 'b', 'z']);
      expect(app.playback.currentTrack?.id, 'b');
      await _tap(tester, find.text('Play selected'));
      expect(app.playback.queue.map((track) => track.id), ['z']);
      await _tap(tester, find.byTooltip('Sort descending'));
      await _tap(tester, find.text('Play'));
      expect(app.playback.queue.map((track) => track.id), ['z', 'b', 'a']);
      expect(app.playlists.single.entries.map((entry) => entry.id), [
        'ez',
        'missing',
        'ea',
        'eb',
      ]);
      await _sort(tester, 'Playlist order');
      expect(find.byType(ReorderableListView), findsOneWidget);
      expect(_entryTitles(tester), [
        '1. Zulu',
        '2. Unavailable track',
        '3. Alpha',
        '4. Beta',
      ]);
    },
  );

  _test('detail supports every common sort and direction without saving', (
    tester,
    app,
  ) async {
    await _open(tester);
    for (final (label, first) in [
      ('Artist', 'Zulu'),
      ('Album', 'Alpha'),
      ('Duration', 'Alpha'),
      ('Date added', 'Zulu'),
    ]) {
      await _sort(tester, label);
      expect(_entryTitles(tester).first, '1. $first');
      expect(_entryTitles(tester).last, '4. Unavailable track');
    }
    expect(app.saves, isEmpty);
  });

  _test(
    'detail selection uses entry IDs, removes unavailable and legacy duplicates safely',
    (tester, app) async {
      app.replace(
        _playlist(
          entries: const [
            PlaylistEntry(id: 'first', trackId: 'a'),
            PlaylistEntry(id: 'second', trackId: 'a'),
            PlaylistEntry(id: 'missing', trackId: 'gone'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await _open(tester);
      await _tap(tester, _check('second'));
      expect(tester.widget<Checkbox>(_check('first')).value, isFalse);
      await _tap(tester, find.text('Remove selected'));
      await _tap(tester, _dialogText('Cancel'));
      expect(app.saves, isEmpty);
      await _tap(tester, find.text('Remove selected'));
      app.replace(
        _playlist(
          revision: 8,
          entries: const [
            PlaylistEntry(id: 'first', trackId: 'a'),
            PlaylistEntry(id: 'second', trackId: 'a'),
            PlaylistEntry(id: 'new', trackId: 'b'),
            PlaylistEntry(id: 'missing', trackId: 'gone'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await _tap(tester, _dialogText('Remove'));
      expect(app.saves.single.revision, 8);
      expect(app.playlists.single.entries.map((entry) => entry.id), [
        'first',
        'new',
        'missing',
      ]);
      await _tap(tester, _check('missing'));
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Play selected'),
            )
            .onPressed,
        isNull,
      );
      await _tap(tester, find.text('Select all'));
      await _tap(tester, find.text('Remove selected'));
      await _tap(tester, _dialogText('Remove'));
      expect(app.playlists.single.entries, isEmpty);
    },
  );

  _test(
    'original queue skips unavailable entries without shifting clicked track',
    (tester, app) async {
      await _open(tester);
      expect(tester.widget<ListTile>(_entry('missing')).onTap, isNull);
      await _tap(tester, find.text('3. Alpha'));
      expect(app.playback.queue.map((track) => track.id), ['z', 'a', 'b']);
      expect(app.playback.currentTrack?.id, 'a');
    },
  );

  _test('reorder callback and menus persist only playlist order', (
    tester,
    app,
  ) async {
    await _open(tester);
    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    list.onReorderItem!(0, 3);
    await tester.pumpAndSettle();
    expect(app.playlists.single.entries.map((entry) => entry.id), [
      'missing',
      'ea',
      'eb',
      'ez',
    ]);
    await _tap(tester, find.byTooltip('Entry 4 options'));
    await _tap(tester, find.text('Move up'));
    expect(app.playlists.single.entries.map((entry) => entry.id), [
      'missing',
      'ea',
      'ez',
      'eb',
    ]);
    expect(app.saves, hasLength(2));
  });

  _test('reorder ignores stale positions after a concurrent update', (
    tester,
    app,
  ) async {
    await _open(tester);
    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    app.replace(
      _playlist(
        revision: 12,
        entries: const [PlaylistEntry(id: 'new', trackId: 'a')],
      ),
      notify: false,
    );
    list.onReorderItem!(0, 3);
    await tester.pumpAndSettle();
    expect(app.saves, isEmpty);
    expect(app.playlists.single.revision, 12);
  });

  _test(
    'picker excludes existing tracks, toggles Set selection and selects filtered view',
    (tester, app) async {
      app.replace(
        _playlist(
          entries: const [PlaylistEntry(id: 'ea', trackId: 'a')],
        ),
      );
      await tester.pumpAndSettle();
      await _open(tester);
      await _tap(tester, find.text('Add tracks'));
      expect(_picker('a'), findsNothing);
      expect(_picker('b'), findsOneWidget);
      expect(_picker('z'), findsOneWidget);
      expect(find.textContaining('occurrence'), findsNothing);
      await _tap(tester, _picker('z'));
      expect(find.text('Add 1'), findsOneWidget);
      await _tap(tester, _picker('z'));
      expect(find.text('Add 0'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Zulu');
      await tester.pumpAndSettle();
      await _tap(tester, _dialogText('Select all'));
      expect(find.text('Add 1'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Beta');
      await tester.pumpAndSettle();
      await _tap(tester, _dialogText('Select all'));
      expect(find.text('Add 2'), findsOneWidget);
      await _tap(tester, _dialogText('Deselect all'));
      expect(find.text('Add 1'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(_picker('z')).value, isTrue);
      expect(tester.widget<CheckboxListTile>(_picker('b')).value, isFalse);
      await _sort(tester, 'Artist');
      final rows = tester.widgetList<CheckboxListTile>(
        find.byType(CheckboxListTile),
      );
      expect((rows.first.title! as Text).data, 'Zulu');
      await _tap(tester, find.byTooltip('Sort descending').last);
      expect(
        (tester
                    .widgetList<CheckboxListTile>(find.byType(CheckboxListTile))
                    .first
                    .title!
                as Text)
            .data,
        'Beta',
      );
      await _tap(tester, find.text('Add 1'));
      expect(app.playlists.single.entries.map((entry) => entry.trackId), [
        'a',
        'z',
      ]);
    },
  );

  _test(
    'picker listens to latest playlist and prunes externally added selection',
    (tester, app) async {
      app.replace(_playlist(entries: []));
      await tester.pumpAndSettle();
      await _open(tester);
      await _tap(tester, find.text('Add tracks'));
      await _tap(tester, _dialogText('Select all'));
      expect(find.text('Add 3'), findsOneWidget);
      app.replace(
        _playlist(
          revision: 5,
          entries: const [PlaylistEntry(id: 'external', trackId: 'a')],
        ),
      );
      await tester.pumpAndSettle();
      expect(_picker('a'), findsNothing);
      expect(find.text('Add 2'), findsOneWidget);
      app.library.removeWhere((track) => track.id == 'b');
      app.notifyListeners();
      await tester.pumpAndSettle();
      expect(_picker('b'), findsNothing);
      expect(find.text('Add 1'), findsOneWidget);
      await _tap(tester, find.text('Add 1'));
      expect(app.saves.single.revision, 5);
      expect(app.playlists.single.entries.map((entry) => entry.trackId), [
        'a',
        'z',
      ]);
    },
  );

  _test('submit rechecks membership and revision even before modal rebuild', (
    tester,
    app,
  ) async {
    app.replace(_playlist(entries: []));
    await tester.pumpAndSettle();
    await _open(tester);
    await _tap(tester, find.text('Add tracks'));
    await _tap(tester, _dialogText('Select all'));
    // No notification: exercise the post-dialog check, not only modal pruning.
    app.replace(
      _playlist(
        revision: 17,
        entries: const [PlaylistEntry(id: 'external', trackId: 'a')],
      ),
      notify: false,
    );
    await _tap(tester, find.text('Add 3'));
    expect(app.saves.single.revision, 17);
    final entries = app.playlists.single.entries;
    expect(entries.map((entry) => entry.trackId).toSet(), {'a', 'b', 'z'});
    expect(entries, hasLength(3));
    expect(entries.first.id, 'external');
    expect(entries.map((entry) => entry.id).toSet(), hasLength(3));
  });

  _test('picker disables submission when playlist disappears', (
    tester,
    app,
  ) async {
    app.replace(_playlist(entries: []));
    await tester.pumpAndSettle();
    await _open(tester);
    await _tap(tester, find.text('Add tracks'));
    await _tap(tester, _dialogText('Select all'));
    app.collections.clear();
    app.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Playlist no longer exists'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Add 0'))
          .onPressed,
      isNull,
    );
    await _tap(tester, _dialogText('Cancel'));
    expect(app.saves, isEmpty);
  });

  _test(
    'saving disables selection, picker, menus and duplicate reorder writes',
    (tester, app) async {
      await _open(tester);
      app.saveGate = Completer<void>();
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      list.onReorderItem!(0, 3);
      await tester.pump();
      expect(app.saves, hasLength(1));
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Add tracks'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((box) => box.onChanged == null),
        isTrue,
      );
      expect(
        tester
            .widgetList<ReorderableDragStartListener>(
              find.byType(ReorderableDragStartListener),
            )
            .every((handle) => !handle.enabled),
        isTrue,
      );
      list.onReorderItem!(1, 0);
      await tester.pump();
      expect(app.saves, hasLength(1));
      app.saveGate!.complete();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Add tracks'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  _test('failed save releases guards and leaves playlist unchanged', (
    tester,
    app,
  ) async {
    await _open(tester);
    app.saveGate = Completer<void>();
    final list = tester.widget<ReorderableListView>(
      find.byType(ReorderableListView),
    );
    list.onReorderItem!(0, 3);
    await tester.pump();
    app.saveGate!.completeError(StateError('Save failed'));
    await tester.pumpAndSettle();
    expect(app.playlists.single.entries.first.id, 'ez');
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Add tracks'),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widgetList<Checkbox>(find.byType(Checkbox))
          .every((box) => box.onChanged != null),
      isTrue,
    );
    expect(find.textContaining('Save failed'), findsOneWidget);
  });

  _test('select all only includes current entries after external deletion', (
    tester,
    app,
  ) async {
    await _open(tester);
    await _tap(tester, find.text('Select all'));
    app.replace(
      _playlist(
        revision: 9,
        entries: const [PlaylistEntry(id: 'replacement', trackId: 'b')],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Remove selected'), findsNothing);
    expect(tester.widget<Checkbox>(_check('replacement')).value, isFalse);
    await _tap(tester, find.text('Select all'));
    await _tap(tester, find.text('Play selected'));
    expect(app.playback.queue.map((track) => track.id), ['b']);
  });

  _test('overview, selected detail and filtered picker fit narrow windows', (
    tester,
    app,
  ) async {
    await _tap(tester, find.text('Select all'));
    expect(tester.takeException(), isNull);
    await _open(tester);
    await _tap(tester, find.text('Select all'));
    await _sort(tester, 'Title');
    expect(tester.takeException(), isNull);
    await _tap(tester, find.text('Add tracks'));
    expect(find.text('No matching tracks to add'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _tap(tester, _dialogText('Cancel'));
    app.replace(_playlist(entries: []));
    await tester.pumpAndSettle();
    await _tap(tester, find.text('Add tracks'));
    await tester.enterText(find.byType(TextField), 'One');
    await tester.pumpAndSettle();
    await _tap(tester, _dialogText('Select all'));
    expect(find.text('Add 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _tap(tester, _dialogText('Cancel'));
  }, size: const Size(320, 600));
}
