import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/desktop_controller.dart';
import 'package:yun/services/desktop_host.dart';
import 'package:yun/services/desktop_settings_store.dart';
import 'package:yun/ui/app.dart';
import 'package:yun/ui/settings_screen.dart';

import '../core/fakes.dart';
import 'player_test_app.dart';

class _SettingsApp extends PlayerTestApp {
  _SettingsApp(super.engine);

  @override
  int get pendingEventCount => 0;
}

class _Store implements DesktopSettingsStore {
  DesktopCloseBehavior saved = DesktopCloseBehavior.quit;
  final writes = <DesktopCloseBehavior>[];
  Completer<void>? pending;
  bool fail = false;

  @override
  Future<DesktopCloseBehavior> readCloseBehavior() async => saved;

  @override
  Future<void> writeCloseBehavior(DesktopCloseBehavior behavior) async {
    writes.add(behavior);
    await pending?.future;
    if (fail) throw StateError('Disk is full');
    saved = behavior;
  }
}

class _Host implements DesktopHost {
  bool available = true;
  int hides = 0, shows = 0, exits = 0;
  late void Function(bool) availabilityChanged;
  late void Function(Object) reportError;

  @override
  Future<void> initialize({
    required void Function() onClose,
    required void Function() onShow,
    required void Function() onQuit,
    required void Function(bool) onTrayAvailabilityChanged,
    required void Function(Object) onError,
  }) async {
    availabilityChanged = onTrayAvailabilityChanged;
    reportError = onError;
  }

  @override
  Future<bool> checkTrayAvailability() async => available;
  @override
  Future<void> hide() async => hides++;
  @override
  Future<void> show() async => shows++;
  @override
  Future<void> exitApplication() async => exits++;
  @override
  Future<void> dispose() async {}
}

class DesktopSettingsFixture {
  final host = _Host();
  final store = _Store();
  final app = _SettingsApp(FakeEngine());
  int shutdowns = 0, checkpoints = 0;
  Completer<void>? shutdownPending;
  late final desktop = DesktopController(
    host: host,
    settings: store,
    shutdown: () async {
      shutdowns++;
      await shutdownPending?.future;
    },
    checkpoint: () async => checkpoints++,
  );
}

final _minimizeChoice = find.byWidgetPredicate(
  (widget) =>
      widget is RadioListTile<DesktopCloseBehavior> &&
      widget.value == DesktopCloseBehavior.minimizeToTray,
);
final _quitChoice = find.byWidgetPredicate(
  (widget) =>
      widget is RadioListTile<DesktopCloseBehavior> &&
      widget.value == DesktopCloseBehavior.quit,
);
final _minimizeButton = find.widgetWithText(OutlinedButton, 'Minimize to tray');
final _quitButton = find.widgetWithText(OutlinedButton, 'Quit Yun');

void desktopTest(
  String description,
  Future<void> Function(WidgetTester, DesktopSettingsFixture) body, {
  TargetPlatform platform = TargetPlatform.linux,
  Size size = const Size(1000, 900),
  double textScale = 1,
  bool inject = true,
  void Function(DesktopSettingsFixture)? configure,
}) {
  testWidgets(description, (tester) async {
    final fixture = DesktopSettingsFixture();
    configure?.call(fixture);
    debugDefaultTargetPlatformOverride = platform;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    try {
      await fixture.desktop.initialize();
      await tester.pumpWidget(
        YunApp(
          controller: fixture.app,
          desktop: inject ? fixture.desktop : null,
        ),
      );
      await tester.pumpAndSettle();
      await body(tester, fixture);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.desktop.dispose();
      await tester.runAsync(fixture.app.shutdown);
      fixture.app.dispose();
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    }
  });
}

Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.settings_outlined));
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

DesktopCloseBehavior? selected(WidgetTester tester) => tester
    .widget<RadioGroup<DesktopCloseBehavior>>(
      find.byType(RadioGroup<DesktopCloseBehavior>),
    )
    .groupValue;

void main() {
  setUp(mockDesktopDrop);

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    for (final width in [320.0, 840.0, 1400.0]) {
      desktopTest(
        '$platform exposes desktop settings at ${width.toInt()}px',
        (tester, fixture) async {
          await openSettings(tester);
          expect(find.text('Window behavior'), findsOneWidget);
          expect(selected(tester), DesktopCloseBehavior.quit);
          await tapVisible(tester, _minimizeChoice);
          expect(selected(tester), DesktopCloseBehavior.minimizeToTray);
          expect(fixture.store.saved, DesktopCloseBehavior.minimizeToTray);
          await tapVisible(tester, _quitChoice);
          expect(fixture.store.saved, DesktopCloseBehavior.quit);
        },
        platform: platform,
        size: Size(width, 900),
      );
    }
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    desktopTest(
      '$platform hides desktop controls and errors even at desktop width',
      (tester, fixture) async {
        fixture.host.reportError('Desktop-only error');
        await openSettings(tester);
        expect(find.text('Window behavior'), findsNothing);
        expect(_minimizeButton, findsNothing);
        expect(_quitButton, findsNothing);
        expect(find.byType(MaterialBanner), findsNothing);
      },
      platform: platform,
      size: const Size(1400, 900),
    );
  }

  desktopTest('desktop without a controller preserves settings', (
    tester,
    fixture,
  ) async {
    await openSettings(tester);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Window behavior'), findsNothing);
  }, inject: false);

  desktopTest('saving disables controls and keeps the committed choice', (
    tester,
    fixture,
  ) async {
    await openSettings(tester);
    fixture.store.pending = Completer<void>();
    await tapVisible(tester, _minimizeChoice);
    expect(find.text('Saving…'), findsOneWidget);
    expect(selected(tester), DesktopCloseBehavior.quit);
    expect(
      tester
          .widget<RadioListTile<DesktopCloseBehavior>>(_minimizeChoice)
          .enabled,
      isFalse,
    );
    expect(tester.widget<OutlinedButton>(_quitButton).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(_minimizeButton).onPressed, isNull);
    fixture.store.pending!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Saving…'), findsNothing);
    expect(selected(tester), DesktopCloseBehavior.minimizeToTray);
    expect(fixture.store.writes, [DesktopCloseBehavior.minimizeToTray]);
    // Navigation does not recreate the policy or reset the committed value.
    await tester.tap(find.byIcon(Icons.library_music_outlined));
    await tester.pumpAndSettle();
    await openSettings(tester);
    expect(selected(tester), DesktopCloseBehavior.minimizeToTray);
  });

  desktopTest('failed saves retain the choice and show one dismissible error', (
    tester,
    fixture,
  ) async {
    await openSettings(tester);
    fixture.store.fail = true;
    await tapVisible(tester, _minimizeChoice);
    expect(selected(tester), DesktopCloseBehavior.quit);
    expect(fixture.store.saved, DesktopCloseBehavior.quit);
    expect(
      find.textContaining('Could not save close behavior'),
      findsOneWidget,
    );
    expect(find.byType(MaterialBanner), findsOneWidget);
    expect(find.text('Saving…'), findsNothing);
    await tapVisible(tester, find.text('Dismiss'));
    expect(fixture.desktop.error, isNull);
    expect(find.byType(MaterialBanner), findsNothing);
    fixture.store.fail = false;
    await tapVisible(tester, _minimizeChoice);
    expect(selected(tester), DesktopCloseBehavior.minimizeToTray);
  });

  desktopTest(
    'unavailable tray preserves a saved minimize choice and allows future policy',
    (tester, fixture) async {
      await openSettings(tester);
      expect(selected(tester), DesktopCloseBehavior.minimizeToTray);
      expect(fixture.store.writes, isEmpty);
      expect(find.textContaining('No usable system tray'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(_minimizeButton).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(_quitButton).onPressed, isNotNull);
      await tapVisible(tester, _quitChoice);
      await tapVisible(tester, _minimizeChoice);
      expect(fixture.store.saved, DesktopCloseBehavior.minimizeToTray);
      fixture.host.available = true;
      fixture.host.availabilityChanged(true);
      await tester.pumpAndSettle();
      expect(find.textContaining('No usable system tray'), findsNothing);
      expect(
        tester.widget<OutlinedButton>(_minimizeButton).onPressed,
        isNotNull,
      );
    },
    configure: (fixture) {
      fixture.host.available = false;
      fixture.store.saved = DesktopCloseBehavior.minimizeToTray;
    },
  );

  desktopTest(
    'close failure appears outside Settings without losing navigation state',
    (tester, fixture) async {
      expect(find.byType(SettingsScreen), findsNothing);
      await fixture.desktop.requestWindowClose();
      await tester.pumpAndSettle();
      expect(find.textContaining('Yun was not hidden'), findsOneWidget);
      expect(fixture.host.hides, 0);
      expect(find.byType(SettingsScreen), findsNothing);
      await tapVisible(tester, find.text('Dismiss'));
      expect(find.byType(MaterialBanner), findsNothing);
    },
    configure: (fixture) {
      fixture.host.available = false;
      fixture.store.saved = DesktopCloseBehavior.minimizeToTray;
    },
  );

  desktopTest(
    'manual minimize checkpoints; explicit Quit ignores close policy',
    (tester, fixture) async {
      await openSettings(tester);
      await tapVisible(tester, _minimizeChoice);
      await tapVisible(tester, _minimizeButton);
      expect(fixture.host.hides, 1);
      expect(fixture.checkpoints, 1);
      expect(fixture.shutdowns, 0);
      fixture.shutdownPending = Completer<void>();
      await tapVisible(tester, _quitButton);
      expect(find.text('Quitting Yun…'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(_quitButton).onPressed, isNull);
      expect(tester.widget<OutlinedButton>(_minimizeButton).onPressed, isNull);
      expect(
        tester.widget<RadioListTile<DesktopCloseBehavior>>(_quitChoice).enabled,
        isFalse,
      );
      expect(fixture.host.exits, 0);
      fixture.shutdownPending!.complete();
      await tester.pumpAndSettle();
      expect(fixture.shutdowns, 1);
      expect(fixture.host.exits, 1);
    },
  );

  desktopTest(
    '320px large text wraps choices, actions, and a bounded scrolling error',
    (tester, fixture) async {
      await openSettings(tester);
      await tapVisible(tester, _minimizeChoice);
      expect(selected(tester), DesktopCloseBehavior.minimizeToTray);
      await tester.ensureVisible(_minimizeButton);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      fixture.host.reportError(
        List.filled(30, 'A long desktop error.').join(' '),
      );
      await tester.pumpAndSettle();
      final bannerScroll = find.ancestor(
        of: find.byType(MaterialBanner),
        matching: find.byType(SingleChildScrollView),
      );
      expect(tester.getSize(bannerScroll).height, lessThanOrEqualTo(142));
      await tapVisible(tester, find.text('Dismiss'));
      expect(find.byType(MaterialBanner), findsNothing);
    },
    size: const Size(320, 568),
    textScale: 2,
  );
}
