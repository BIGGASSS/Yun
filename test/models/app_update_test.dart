import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/app_update.dart';

void main() {
  group('compareVersions', () {
    test('equal versions', () {
      expect(compareVersions('0.1.9', '0.1.9'), 0);
      expect(compareVersions('v1.2.3', '1.2.3'), 0);
      expect(compareVersions('1.2.3', ' 1.2.3 '), 0);
    });

    test('numeric segments compare numerically, not lexicographically', () {
      expect(compareVersions('0.2.0', '0.10.0'), lessThan(0));
      expect(compareVersions('1.10.0', '1.9.0'), greaterThan(0));
      expect(compareVersions('2.0.0', '1.99.99'), greaterThan(0));
    });

    test('missing segments count as zero', () {
      expect(compareVersions('1.2.3', '1.2'), greaterThan(0));
      expect(compareVersions('1.2', '1.2.0'), lessThan(0));
      expect(compareVersions('1', '1.0.0'), lessThan(0));
    });

    test('a release outranks its pre-releases', () {
      expect(compareVersions('1.0.0', '1.0.0-rc.1'), greaterThan(0));
      expect(compareVersions('1.0.0-rc.1', '1.0.0'), lessThan(0));
    });

    test('pre-release identifiers follow semver precedence', () {
      expect(compareVersions('1.0.0-rc.2', '1.0.0-rc.1'), greaterThan(0));
      expect(compareVersions('1.0.0-alpha', '1.0.0-beta'), lessThan(0));
      expect(compareVersions('1.0.0-1', '1.0.0-alpha'), lessThan(0));
      expect(compareVersions('1.0.0-alpha', '1.0.0-alpha.1'), lessThan(0));
      expect(compareVersions('1.0.0-alpha.1', '1.0.0-alpha.beta'), lessThan(0));
    });

    test('build metadata is ignored', () {
      expect(compareVersions('1.2.3+10', '1.2.3'), 0);
      expect(compareVersions('0.1.9+10', '0.1.9'), 0);
      expect(compareVersions('1.2.3+9', '1.2.4+10'), lessThan(0));
    });

    test('app build numbers parse from the version', () {
      expect(compareVersions('0.1.9', '0.1.9+10'), 0);
    });

    test('unrecognized versions throw', () {
      expect(() => compareVersions('banana', '1.0.0'), throwsFormatException);
      expect(() => compareVersions('1.0.0', ''), throwsFormatException);
      expect(() => compareVersions('1.0.0', '1..0'), throwsFormatException);
      expect(() => compareVersions('v', '1.0.0'), throwsFormatException);
      expect(() => compareVersions('1.0.0', '1.0.0-'), throwsFormatException);
    });
  });
}
