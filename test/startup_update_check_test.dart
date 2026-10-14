import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/core/update_check_controller.dart';
import 'package:yun/main.dart';
import 'package:yun/models/app_update.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/github_update_checker.dart';
import 'package:yun/ui/app.dart';

import 'core/fake_desktop_host.dart';
import 'core/fakes.dart';

class _FakeChecker implements GitHubUpdateChecker {
  _FakeChecker({this.payload, this.error});

  final Map<String, dynamic>? payload;
  Object? error;
  int calls = 0;

  @override
  String repository = GitHubUpdateChecker.defaultRepository;

  @override
  Future<AppUpdate?> findUpdate({required String currentVersion}) async {
    calls++;
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

class _StartupApp extends AppController {
  _StartupApp({
    required super.storageDirectory,
    required super.playbackSettings,
    required super.savePlaybackSettings,
  }) : super(
         // No account is signed in, so no request should ever be made.
         api: ApiClient(
           credentials: MemoryCredentials(),
           dio: Dio()
             ..httpClientAdapter = FakeAdapter(
               (options, _) => throw StateError(
                 'Unexpected startup request: ${options.uri}',
               ),
             ),
         ),
         playbackEngine: FakeEngine(),
         enableSystemControls: false,
         automaticRefresh: false,
       );
}

const _newerPayload = {
  'tag_name': 'v0.2.0',
  'html_url': 'https://github.com/BIGGASSS/Yun/releases/tag/v0.2.0',
  'body': 'Quieter tray and offline fixes.',
};

const _releaseUrl = 'https://github.com/BIGGASSS/Yun/releases/tag/v0.2.0';
const _banner = 'Yun 0.2.0 is available. You are running 0.1.9.';

/// Mounts a real [YunBootstrap] with isolated storage and an injected update
/// checker, waiting until the app shell is on screen.
Future<_StartupResult> _mountBootstrap(
  WidgetTester tester, {
  required _FakeChecker checker,
  List<Uri>? opened,
  bool skipCheck = false,
}) async {
  late _StartupApp app;
  final result = _StartupResult(checker: checker);
  await tester.runAsync(() async {
    SharedPreferences.setMockInitialValues({});
    result.storage = await Directory.systemTemp.createTemp('yun-update-test-');
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      YunBootstrap(
        desktopHostFactory: () => FakeDesktopHost(<String>[]),
        controllerFactory:
            ({required playbackSettings, required savePlaybackSettings}) =>
                _StartupApp(
                  storageDirectory: () async => result.storage,
                  playbackSettings: playbackSettings,
                  savePlaybackSettings: savePlaybackSettings,
                ),
        updateCheckerFactory: skipCheck
            ? () async => null
            : () async {
                final controller = UpdateCheckController(
                  checker: checker,
                  currentVersion: '0.1.9',
                  openRelease: (uri) async {
                    opened?.add(uri);
                    return true;
                  },
                );
                result.updateCheck = controller;
                return controller;
              },
      ),
    );
    // Native/settings and SQLite file work can finish after pumpAndSettle
    // observes no scheduled frame; bound the wait by elapsed real time.
    final opening = Stopwatch()..start();
    while (opening.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pumpAndSettle();
      if (find.byType(YunApp).evaluate().isNotEmpty) {
        app =
            tester.widget<YunApp>(find.byType(YunApp)).controller
                as _StartupApp;
        return;
      }
    }
    fail('Bootstrap did not finish opening');
  });
  result.app = app;
  return result;
}

class _StartupResult {
  _StartupResult({required this.checker});
  final _FakeChecker checker;
  late final Directory storage;
  late _StartupApp app;
  UpdateCheckController? updateCheck;
}

void main() {
  Future<void> unmount(WidgetTester tester, _StartupResult result) async {
    await tester.runAsync(result.app.shutdown);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => result.storage.delete(recursive: true));
    debugDefaultTargetPlatformOverride = null;
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }

  testWidgets('startup checks GitHub once and offers the release page', (
    tester,
  ) async {
    final opened = <Uri>[];
    final result = await _mountBootstrap(
      tester,
      checker: _FakeChecker(payload: _newerPayload),
      opened: opened,
    );
    await tester.pumpAndSettle();
    expect(
      result.checker.calls,
      1,
      reason: 'the check runs automatically at startup',
    );
    expect(result.updateCheck, isNotNull);

    final shell = tester.widget<YunApp>(find.byType(YunApp));
    expect(identical(shell.updateCheck, result.updateCheck), isTrue);

    expect(find.text(_banner), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'View release'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse(_releaseUrl)]);
    expect(find.text(_banner), findsNothing, reason: 'dismissed after opening');

    await unmount(tester, result);
  });

  testWidgets('a startup check that finds nothing stays quiet', (tester) async {
    final result = await _mountBootstrap(
      tester,
      checker: _FakeChecker(payload: const {'tag_name': 'v0.1.9'}),
    );
    await tester.pumpAndSettle();
    expect(result.checker.calls, 1);
    expect(find.byType(MaterialBanner), findsNothing);
    await unmount(tester, result);
  });

  testWidgets('a failing startup check never breaks startup', (tester) async {
    final result = await _mountBootstrap(
      tester,
      checker: _FakeChecker(error: StateError('offline')),
    );
    await tester.pumpAndSettle();
    // The library is ready instead of the failure screen.
    expect(result.app.initialized, isTrue);
    expect(find.byType(YunApp), findsOneWidget);
    expect(result.updateCheck!.status, UpdateCheckStatus.failed);
    expect(find.byType(MaterialBanner), findsNothing);
    expect(tester.takeException(), isNull);
    await unmount(tester, result);
  });

  testWidgets('an unavailable checker is skipped, not fatal', (tester) async {
    final result = await _mountBootstrap(
      tester,
      checker: _FakeChecker(payload: _newerPayload),
      skipCheck: true,
    );
    await tester.pumpAndSettle();
    expect(result.updateCheck, isNull);
    expect(result.checker.calls, 0);
    expect(tester.widget<YunApp>(find.byType(YunApp)).updateCheck, isNull);
    expect(find.byType(YunApp), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester, result);
  });
}
