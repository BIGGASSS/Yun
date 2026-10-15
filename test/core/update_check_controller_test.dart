import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/update_check_controller.dart';
import 'package:yun/models/app_update.dart';
import 'package:yun/services/github_update_checker.dart';

class _FakeChecker implements GitHubUpdateChecker {
  _FakeChecker({this.payload, this.error});

  Map<String, dynamic>? payload;
  Object? error;
  int calls = 0;
  String? lastCurrentVersion;
  final inFlight = <Completer<void>>[];

  @override
  String repository = GitHubUpdateChecker.defaultRepository;

  @override
  Future<AppUpdate?> findUpdate({required String currentVersion}) async {
    calls++;
    lastCurrentVersion = currentVersion;
    if (inFlight.isNotEmpty) await inFlight.last.future;
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

UpdateCheckController _controllerWith(
  _FakeChecker checker, {
  String currentVersion = '0.1.9',
  Future<bool> Function(Uri)? openRelease,
}) => UpdateCheckController(
  checker: checker,
  currentVersion: currentVersion,
  openRelease: openRelease,
);

const _newerPayload = {
  'tag_name': 'v0.2.0',
  'html_url': 'https://github.com/BIGGASSS/Yun/releases/tag/v0.2.0',
  'body': 'Quieter tray and offline fixes.',
};

void main() {
  group('UpdateCheckController', () {
    test('starts idle before any check', () {
      final controller = _controllerWith(_FakeChecker(payload: _newerPayload));
      expect(controller.status, UpdateCheckStatus.idle);
      expect(controller.availableUpdate, isNull);
      expect(controller.error, isNull);
      expect(controller.completedChecks, 0);
      expect(controller.isChecking, isFalse);
    });

    test('a newer release exposes an update with release info', () async {
      final controller = _controllerWith(_FakeChecker(payload: _newerPayload));
      await controller.check();
      expect(controller.status, UpdateCheckStatus.updateAvailable);
      final update = controller.availableUpdate!;
      expect(update.version, '0.2.0');
      expect(
        update.releaseUrl,
        'https://github.com/BIGGASSS/Yun/releases/tag/v0.2.0',
      );
      expect(update.releaseNotes, 'Quieter tray and offline fixes.');
      expect(controller.error, isNull);
      expect(controller.completedChecks, 1);
    });

    test('the latest release reports up to date', () async {
      final controller = _controllerWith(
        _FakeChecker(payload: const {'tag_name': 'v0.1.9'}),
      );
      await controller.check();
      expect(controller.status, UpdateCheckStatus.upToDate);
      expect(controller.availableUpdate, isNull);
    });

    test('failures stay in state instead of throwing', () async {
      final controller = _controllerWith(
        _FakeChecker(error: StateError('no route')),
      );
      await controller.check();
      expect(controller.status, UpdateCheckStatus.failed);
      expect(controller.availableUpdate, isNull);
      expect(controller.error, 'Could not check for updates');
    });

    test('a retry after a failure succeeds', () async {
      final checker = _FakeChecker(error: StateError('offline'));
      final controller = _controllerWith(checker);
      await controller.check();
      expect(controller.status, UpdateCheckStatus.failed);
      checker.error = null;
      checker.payload = _newerPayload;
      await controller.check();
      expect(controller.status, UpdateCheckStatus.updateAvailable);
      expect(checker.calls, 2);
      expect(controller.completedChecks, 2);
    });

    test('checking state is published while the request runs', () async {
      final checker = _FakeChecker(payload: _newerPayload);
      checker.inFlight.add(Completer<void>());
      final controller = _controllerWith(checker);
      final statuses = <UpdateCheckStatus>[];
      controller.addListener(() => statuses.add(controller.status));
      final pending = controller.check();
      expect(controller.isChecking, isTrue);
      expect(controller.status, UpdateCheckStatus.checking);
      checker.inFlight.single.complete();
      await pending;
      expect(controller.isChecking, isFalse);
      expect(statuses.first, UpdateCheckStatus.checking);
      expect(statuses.last, UpdateCheckStatus.updateAvailable);
    });

    for (final fails in [false, true]) {
      test(
        'disposing during a ${fails ? 'failed' : 'successful'} check is safe',
        () async {
          final checker = _FakeChecker(
            payload: _newerPayload,
            error: fails ? StateError('offline') : null,
          );
          checker.inFlight.add(Completer<void>());
          final controller = _controllerWith(checker);
          var notifications = 0;
          controller.addListener(() => notifications++);
          final pending = controller.check();
          controller.dispose();
          checker.inFlight.single.complete();
          await pending;
          await controller.check();
          expect(await controller.openReleasePage(), isFalse);
          expect(checker.calls, 1);
          expect(notifications, 1);
          expect(controller.availableUpdate, isNull);
        },
      );
    }

    test('a listener retry shares the request being announced', () async {
      final checker = _FakeChecker(payload: _newerPayload);
      final controller = _controllerWith(checker);
      Future<void>? nested;
      controller.addListener(() {
        if (controller.isChecking) nested = controller.check();
      });
      final pending = controller.check();
      expect(identical(nested, pending), isTrue);
      await pending;
      expect(checker.calls, 1);
      expect(controller.completedChecks, 1);
      controller.dispose();
    });

    test('each manual check re-queries GitHub', () async {
      final checker = _FakeChecker(payload: _newerPayload);
      final controller = _controllerWith(checker);
      await controller.check();
      await controller.check();
      expect(checker.calls, 2);
      expect(checker.lastCurrentVersion, '0.1.9');
    });

    test('openReleasePage launches the release URL', () async {
      final launched = <Uri>[];
      final controller = _controllerWith(
        _FakeChecker(payload: _newerPayload),
        openRelease: (uri) async {
          launched.add(uri);
          return true;
        },
      );
      expect(await controller.openReleasePage(), isFalse);
      await controller.check();
      expect(await controller.openReleasePage(), isTrue);
      expect(launched, [
        Uri.parse('https://github.com/BIGGASSS/Yun/releases/tag/v0.2.0'),
      ]);
    });

    test('openReleasePage reports launch failures without throwing', () async {
      final controller = _controllerWith(
        _FakeChecker(payload: _newerPayload),
        openRelease: (uri) async => false,
      );
      await controller.check();
      expect(await controller.openReleasePage(), isFalse);
    });

    test(
      'openReleasePage reports throwing launchers without throwing',
      () async {
        final controller = _controllerWith(
          _FakeChecker(payload: _newerPayload),
          openRelease: (uri) async => throw StateError('no browser'),
        );
        await controller.check();
        expect(await controller.openReleasePage(), isFalse);
      },
    );

    test('the current version is required', () {
      expect(
        () => _controllerWith(_FakeChecker(), currentVersion: '  '),
        throwsArgumentError,
      );
    });
  });
}
