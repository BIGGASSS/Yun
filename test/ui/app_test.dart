import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/ui/app.dart';
import 'package:yun/ui/playlist_screen.dart';
import 'package:yun/ui/theme.dart';

class _TestApp extends AppController {
  _TestApp({bool signedIn = false})
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

  final library = <Track>[
    const Track(
      id: 'one',
      title: 'First song',
      artist: 'Artist A',
      album: 'Album A',
    ),
    const Track(
      id: 'two',
      title: 'Second song',
      artist: 'Artist B',
      album: 'Album B',
    ),
  ];
  final collections = <Playlist>[
    const Playlist(
      id: 'playlist',
      name: 'Evening',
      entries: [
        PlaylistEntry(id: 'entry-1', trackId: 'one'),
        PlaylistEntry(id: 'entry-2', trackId: 'one'),
      ],
    ),
  ];
  @override
  List<Track> get tracks => isAuthenticated ? library : [];
  @override
  List<Playlist> get playlists => isAuthenticated ? collections : [];
  @override
  Track? trackById(String id) =>
      library.where((track) => track.id == id).firstOrNull;
  @override
  Future<Playlist> savePlaylist(
    Playlist playlist, {
    String? name,
    List<PlaylistEntry>? entries,
  }) async {
    final updated = Playlist(
      id: playlist.id,
      name: name ?? playlist.name,
      revision: playlist.revision + 1,
      entries: entries ?? playlist.entries,
    );
    collections[collections.indexWhere((item) => item.id == playlist.id)] =
        updated;
    notifyListeners();
    return updated;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('desktop_drop'),
          (_) async => null,
        );
  });

  Future<void> size(WidgetTester tester, Size value) async {
    tester.view.physicalSize = value;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  for (final width in [390.0, 1000.0, 1400.0]) {
    testWidgets('app branding at ${width.toInt()}px', (tester) async {
      final app = _TestApp();
      addTearDown(app.dispose);
      await size(tester, Size(width, 900));
      await tester.pumpWidget(YunApp(controller: app));
      await tester.pumpAndSettle();

      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, '韵');
      final logo = find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName == 'assets/icon.png',
      );
      expect(logo, findsOneWidget);
      expect(tester.widget<Image>(logo).semanticLabel, '韵');
      expect(tester.getSize(logo), Size.square(width >= 840 ? 48 : 32));
      if (width >= 840) {
        expect(
          find.descendant(of: find.byType(NavigationRail), matching: logo),
          findsOneWidget,
        );
      }
      expect(find.text('yun'), findsNothing);
      expect(find.text('Yun'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('mobile offers five destinations and a real connection form', (
    tester,
  ) async {
    final app = _TestApp();
    addTearDown(app.dispose);
    await size(tester, const Size(390, 844));
    await tester.pumpWidget(YunApp(controller: app));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    await tester.tap(find.text('Connect to server'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'Server URL'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Password'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop uses a rail, filters real tracks, and search has a shortcut',
    (tester) async {
      final app = _TestApp(signedIn: true);
      addTearDown(app.dispose);
      await size(tester, const Size(1400, 900));
      await tester.pumpWidget(YunApp(controller: app));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('First song'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      await tester.enterText(find.byType(TextField), 'Artist B');
      await tester.pumpAndSettle();
      expect(find.text('First song'), findsNothing);
      expect(find.text('Second song'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('large text fits a narrow library and settings', (tester) async {
    final app = _TestApp(signedIn: true);
    addTearDown(app.dispose);
    await size(tester, const Size(320, 568));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(YunApp(controller: app));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeated playlist entries are distinct and ordered', (
    tester,
  ) async {
    final app = _TestApp(signedIn: true);
    addTearDown(app.dispose);
    await size(tester, const Size(900, 800));
    await tester.pumpWidget(
      MaterialApp(
        theme: YunTheme.light(),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: app,
            builder: (_, _) => PlaylistsScreen(app: app),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Evening'));
    await tester.pumpAndSettle();
    expect(find.text('1. First song'), findsOneWidget);
    expect(find.text('2. First song'), findsOneWidget);
    await tester.tap(find.byTooltip('Entry 1 options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Repeat this track'));
    await tester.pumpAndSettle();
    expect(app.playlists.single.entries.length, 3);
    expect(
      app.playlists.single.entries.map((entry) => entry.id).toSet().length,
      3,
    );
    expect(tester.takeException(), isNull);
  });
}
