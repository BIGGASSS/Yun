import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/update_check_controller.dart';
import 'package:yun/models/app_update.dart';
import 'package:yun/services/github_update_checker.dart';
import 'package:yun/ui/settings_screen.dart';

import '../core/fakes.dart';
import 'player_test_app.dart';

class _SettingsApp extends PlayerTestApp {
  _SettingsApp(super.engine);

  @override
  int get pendingEventCount => 0;
}

class _FakeChecker implements GitHubUpdateChecker {
  _FakeChecker({this.payload, this.error});

  final Map<String, dynamic>? payload;
  Object? error;
  int calls = 0;
  Completer<void>? gate;

  @override
  String repository = GitHubUpdateChecker.defaultRepository;

  @override
  Future<AppUpdate?> findUpdate({required String currentVersion}) async {
    calls++;
    await gate?.future;
    final failure = error;
    if (failure != null) throw failure;
    final data = payload;
    if (data == null) return null;
    final tag = data['tag_name'] as String;
    final version = tag.replaceFirst(RegExp(r'^v'), '');
    if (compareVersions(version, currentVersion) <= 0) return null;
    return AppUpdate(
      version: version,
      releaseUrl: data['html_url'] as String,
      releaseNotes: data['body'] as String?,
    );
  }
}

const _newerPayload = {
  'tag_name': 'v0.2.0',
  'html_url': 'https://github.com/BIGGASSS/Yun/releases/tag/v0.2.0',
  'body': 'Quieter tray and offline fixes.',
};
const _latestPayload = {'tag_name': 'v0.1.9'};

const _releaseUrl = 'https://github.com/BIGGASSS/Yun/releases/tag/v0.2.0';

Future<UpdateCheckController> pumpSettings(
  WidgetTester tester,
  UpdateCheckController updates,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SettingsScreen(
          app: _SettingsApp(FakeEngine()),
          desktop: null,
          updateCheck: updates,
          themeMode: ThemeMode.light,
          onThemeChanged: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return updates;
}

UpdateCheckController _controllerWith(
  _FakeChecker checker, {
  List<Uri>? opened,
}) => UpdateCheckController(
  checker: checker,
  currentVersion: '0.1.9',
  openRelease: (uri) async {
    opened?.add(uri);
    return true;
  },
);

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('idle before any check offers the manual check', (tester) async {
    final updates = await pumpSettings(
      tester,
      _controllerWith(_FakeChecker(payload: _newerPayload)),
    );
    expect(find.text('Updates'), findsOneWidget);
    expect(
      find.text('Yun checks GitHub for new releases when it starts.'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(OutlinedButton, 'Check for updates'),
      findsOneWidget,
    );
    expect(find.text('Open version 0.2.0'), findsNothing);
    expect(updates.status, UpdateCheckStatus.idle);
  });

  testWidgets('a newer release guides the user to the release page', (
    tester,
  ) async {
    final opened = <Uri>[];
    final updates = await pumpSettings(
      tester,
      _controllerWith(_FakeChecker(payload: _newerPayload), opened: opened),
    );
    await updates.check();
    await tester.pumpAndSettle();
    expect(
      find.text('Version 0.2.0 is available. You are running 0.1.9.'),
      findsOneWidget,
    );
    final button = find.widgetWithText(FilledButton, 'Open version 0.2.0');
    expect(button, findsOneWidget);
    await tapVisible(tester, button);
    expect(opened, [Uri.parse(_releaseUrl)]);
  });

  testWidgets('the latest release says so', (tester) async {
    final updates = await pumpSettings(
      tester,
      _controllerWith(_FakeChecker(payload: _latestPayload)),
    );
    await updates.check();
    await tester.pumpAndSettle();
    expect(
      find.text('You are running 0.1.9, the latest published release.'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(FilledButton, 'Open version 0.2.0'),
      findsNothing,
    );
  });

  testWidgets('a failed check explains the failure without breaking the app', (
    tester,
  ) async {
    final updates = await pumpSettings(
      tester,
      _controllerWith(_FakeChecker(error: StateError('offline'))),
    );
    await updates.check();
    await tester.pumpAndSettle();
    expect(
      find.text('Could not reach GitHub. Check your connection and try again.'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the manual button checks GitHub and shows progress', (
    tester,
  ) async {
    final checker = _FakeChecker(payload: _newerPayload);
    checker.gate = Completer<void>();
    final updates = await pumpSettings(tester, _controllerWith(checker));
    await tapVisible(
      tester,
      find.widgetWithText(OutlinedButton, 'Check for updates'),
    );
    expect(checker.calls, 1);
    expect(find.text('Checking for updates…'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Checking…'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Checking…'),
          )
          .onPressed,
      isNull,
      reason: 'no concurrent check while one runs',
    );
    checker.gate!.complete();
    await tester.pumpAndSettle();
    expect(
      find.text('Version 0.2.0 is available. You are running 0.1.9.'),
      findsOneWidget,
    );
    expect(updates.status, UpdateCheckStatus.updateAvailable);
  });

  testWidgets('a launch failure is reported in a snackbar', (tester) async {
    final updates = UpdateCheckController(
      checker: _FakeChecker(payload: _newerPayload),
      currentVersion: '0.1.9',
      openRelease: (uri) async => false,
    );
    await pumpSettings(tester, updates);
    await updates.check();
    await tester.pumpAndSettle();
    await tapVisible(
      tester,
      find.widgetWithText(FilledButton, 'Open version 0.2.0'),
    );
    expect(
      find.text('Could not open the release page. Visit $_releaseUrl'),
      findsOneWidget,
    );
  });
}
