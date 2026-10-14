import 'package:flutter_test/flutter_test.dart';
import 'package:yun/services/github_update_checker.dart';

class _Fixture {
  _Fixture({
    required Map<String, dynamic> payload,
    String repository = 'BIGGASSS/Yun',
    Object? error,
  }) {
    final requested = <Uri>[];
    checker = GitHubUpdateChecker(
      repository: repository,
      fetch: (endpoint) async {
        requested.add(endpoint);
        if (error != null) throw error;
        return payload;
      },
    );
    endpoints = requested;
  }

  late final GitHubUpdateChecker checker;
  late final List<Uri> endpoints;
}

Map<String, dynamic> releasePayload({
  required String tag,
  String? url,
  String? body,
}) => {
  'tag_name': tag,
  'html_url': ?url,
  'body': ?body,
  'prerelease': false,
  'draft': false,
};

const _releaseUrl = 'https://github.com/BIGGASSS/Yun/releases/tag/v0.2.0';

void main() {
  group('GitHubUpdateChecker', () {
    test('asks GitHub for the latest Yun release', () async {
      final fixture = _Fixture(payload: releasePayload(tag: 'v0.2.0'));
      await fixture.checker.findUpdate(currentVersion: '0.1.9');
      expect(fixture.endpoints, [
        Uri.parse('https://api.github.com/repos/BIGGASSS/Yun/releases/latest'),
      ]);
    });

    test('uses the configured repository', () async {
      final fixture = _Fixture(
        payload: releasePayload(tag: 'v0.2.0'),
        repository: 'other/yun',
      );
      await fixture.checker.findUpdate(currentVersion: '0.1.9');
      expect(fixture.endpoints, [
        Uri.parse('https://api.github.com/repos/other/yun/releases/latest'),
      ]);
    });

    test('reports a newer release from GitHub', () async {
      final fixture = _Fixture(
        payload: releasePayload(
          tag: 'v0.2.0',
          url: _releaseUrl,
          body: 'Offline fixes and a quieter tray.',
        ),
      );
      final update = await fixture.checker.findUpdate(currentVersion: '0.1.9');
      expect(update, isNotNull);
      expect(update!.version, '0.2.0');
      expect(update.releaseUrl, _releaseUrl);
      expect(update.releaseNotes, 'Offline fixes and a quieter tray.');
    });

    test('returns null when the running version is the latest', () async {
      final fixture = _Fixture(payload: releasePayload(tag: 'v0.2.0'));
      expect(await fixture.checker.findUpdate(currentVersion: '0.2.0'), isNull);
      expect(await fixture.checker.findUpdate(currentVersion: '0.2.1'), isNull);
      expect(
        await fixture.checker.findUpdate(currentVersion: 'v0.3.0'),
        isNull,
      );
      expect(
        await fixture.checker.findUpdate(currentVersion: '0.2.0+10'),
        isNull,
      );
    });

    test('falls back to the tag page without a payload URL', () async {
      final fixture = _Fixture(payload: releasePayload(tag: 'v0.2.0'));
      final update = await fixture.checker.findUpdate(currentVersion: '0.1.9');
      expect(update!.releaseUrl, _releaseUrl);
      expect(update.releaseNotes, isNull);
    });

    test('trims release notes and keeps tags without a v prefix', () async {
      final fixture = _Fixture(
        payload: releasePayload(
          tag: ' 0.2.0 ',
          url: 'https://github.com/BIGGASSS/Yun/releases/tag/0.2.0',
          body: '  Tray polish.  ',
        ),
      );
      final update = await fixture.checker.findUpdate(currentVersion: '0.1.9');
      expect(update!.version, '0.2.0');
      expect(update.releaseNotes, 'Tray polish.');
    });

    test('treats blank release notes as absent', () async {
      final fixture = _Fixture(
        payload: releasePayload(tag: 'v0.2.0', body: '   '),
      );
      final update = await fixture.checker.findUpdate(currentVersion: '0.1.9');
      expect(update!.releaseNotes, isNull);
    });

    test('rejects payloads without a tag', () async {
      final fixture = _Fixture(payload: {'html_url': 'https://example.test'});
      expect(
        () => fixture.checker.findUpdate(currentVersion: '0.1.9'),
        throwsA(isA<FormatException>()),
      );
    });

    test('propagates transport failures', () async {
      final fixture = _Fixture(payload: const {}, error: StateError('offline'));
      expect(
        () => fixture.checker.findUpdate(currentVersion: '0.1.9'),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects malformed repositories', () {
      expect(() => GitHubUpdateChecker(repository: 'yun'), throwsArgumentError);
      expect(() => GitHubUpdateChecker(repository: ''), throwsArgumentError);
    });
  });
}
