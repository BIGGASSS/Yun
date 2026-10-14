/// A newer Yun release published on GitHub.
class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.releaseUrl,
    this.releaseNotes,
  });

  /// Release tag as published, with any leading `v` removed (for example
  /// `0.2.0`).
  final String version;

  /// Browser page for the release, used to guide the user to the download.
  final String releaseUrl;

  /// Optional release body in Markdown; may be null for untagged releases.
  final String? releaseNotes;
}

final _versionPattern = RegExp(
  r'^v?(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$',
);

/// Parses a dotted version such as `v1.2.3-rc.1+7` into
/// `([1, 2, 3], ['rc', '1'])`. Build metadata after `+` is ignored.
(List<int>, List<String>)? _parseVersion(String value) {
  final text = value.trim();
  final match = _versionPattern.firstMatch(text);
  if (match == null) return null;
  final numbers = match
      .group(1)!
      .split('.')
      .map(int.parse)
      .toList(growable: false);
  final preRelease = match.group(2);
  return (numbers, preRelease == null ? const [] : preRelease.split('.'));
}

/// Orders two semver-style versions. A release outranks its pre-releases,
/// more numeric segments outrank fewer when the shared segments are equal,
/// and pre-release identifiers follow semver precedence: numeric identifiers
/// compare numerically and rank below alphanumeric ones, and a longer
/// identifier list outranks a shorter prefix when everything else matches.
/// Throws [FormatException] when either version is unrecognized.
int compareVersions(String a, String b) {
  final parsedA = _parseVersion(a);
  final parsedB = _parseVersion(b);
  if (parsedA == null) {
    throw FormatException('Unrecognized version "$a"');
  }
  if (parsedB == null) {
    throw FormatException('Unrecognized version "$b"');
  }
  final (numbersA, preA) = parsedA;
  final (numbersB, preB) = parsedB;
  final shared = numbersA.length > numbersB.length
      ? numbersB.length
      : numbersA.length;
  for (var i = 0; i < shared; i++) {
    final comparison = numbersA[i].compareTo(numbersB[i]);
    if (comparison != 0) return comparison;
  }
  final lengthComparison = numbersA.length.compareTo(numbersB.length);
  if (lengthComparison != 0) return lengthComparison;
  if (preA.isEmpty != preB.isEmpty) {
    // 1.0.0 outranks 1.0.0-rc.1.
    return preA.isEmpty ? 1 : -1;
  }
  for (
    var i = 0;
    i < (preA.length > preB.length ? preB.length : preA.length);
    i++
  ) {
    final comparison = _compareIdentifier(preA[i], preB[i]);
    if (comparison != 0) return comparison;
  }
  return preA.length.compareTo(preB.length);
}

int _compareIdentifier(String a, String b) {
  final numberA = int.tryParse(a);
  final numberB = int.tryParse(b);
  if (numberA != null && numberB != null) return numberA.compareTo(numberB);
  if (numberA != null) return -1;
  if (numberB != null) return 1;
  return a.compareTo(b);
}
