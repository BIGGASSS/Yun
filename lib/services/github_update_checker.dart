import 'package:dio/dio.dart';

import '../models/app_update.dart';

/// Fetches the decoded `/releases/latest` payload from GitHub. Injectable so
/// tests can supply payloads without a network.
typedef ReleasePayloadFetcher = Future<Map<String, dynamic>> Function(
  Uri endpoint,
);

/// Reads Yun's latest published release from the GitHub Releases API.
class GitHubUpdateChecker {
  GitHubUpdateChecker({
    this.repository = defaultRepository,
    ReleasePayloadFetcher? fetch,
  }) : _fetch = fetch ?? _dioFetcher {
    if (repository.isEmpty || !repository.contains('/')) {
      throw ArgumentError('Use an "owner/name" repository, got "$repository"');
    }
  }

  /// Yun's GitHub repository, the source of its releases.
  static const defaultRepository = 'BIGGASSS/Yun';

  final String repository;
  final ReleasePayloadFetcher _fetch;

  Uri get _endpoint =>
      Uri.parse('https://api.github.com/repos/$repository/releases/latest');

  /// Returns the published release when it is newer than [currentVersion],
  /// otherwise null. Throws when the payload cannot be understood.
  Future<AppUpdate?> findUpdate({required String currentVersion}) async {
    final payload = await _fetch(_endpoint);
    final tag = payload['tag_name'];
    if (tag is! String || tag.trim().isEmpty) {
      throw const FormatException('GitHub release has no tag');
    }
    final version = tag.trim().replaceFirst(RegExp(r'^v'), '');
    if (compareVersions(version, currentVersion) <= 0) return null;
    final notes = payload['body'];
    return AppUpdate(
      version: version,
      releaseUrl:
          payload['html_url'] as String? ??
          'https://github.com/$repository/releases/tag/$tag',
      releaseNotes: notes is String && notes.trim().isNotEmpty
          ? notes.trim()
          : null,
    );
  }
}

/// Default transport: plain GitHub REST request over HTTPS. No account, token,
/// or personal data leaves the device; only the public release endpoint is
/// contacted. GitHub's API is authoritative for the newest release, which may
/// be a pre-release only when the repository marks it as latest.
Future<Map<String, dynamic>> _dioFetcher(Uri endpoint) async {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      sendTimeout: const Duration(seconds: 10),
      responseType: ResponseType.json,
      validateStatus: (status) =>
          status != null && status >= 200 && status < 300,
      headers: const {
        'Accept': 'application/vnd.github+json',
        // GitHub requires a User-Agent on API requests.
        'User-Agent': 'Yun-App',
      },
    ),
  );
  try {
    final response = await dio.getUri<Object?>(endpoint);
    final data = response.data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw const FormatException('Unexpected GitHub release payload');
  } finally {
    dio.close(force: true);
  }
}
