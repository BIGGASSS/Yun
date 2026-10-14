import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_update.dart';
import '../services/github_update_checker.dart';

/// Outcome of the most recent update check.
enum UpdateCheckStatus {
  /// No check has completed yet.
  idle,

  /// A request is in flight.
  checking,

  /// A newer release than the running version was found.
  updateAvailable,

  /// The running version is the newest published release.
  upToDate,

  /// The check could not complete (offline, GitHub unreachable).
  failed,
}

/// Owns the startup update check and its observable result. Failures are kept
/// in state instead of thrown: a check must never interrupt the app.
class UpdateCheckController extends ChangeNotifier {
  UpdateCheckController({
    required this._checker,
    required this.currentVersion,
    this.openRelease,
  }) {
    if (currentVersion.trim().isEmpty) {
      throw ArgumentError('A current version is required', 'currentVersion');
    }
  }

  final GitHubUpdateChecker _checker;

  /// Version of the running build, for comparison against the latest release.
  final String currentVersion;

  /// Injected so tests can observe browser launches; defaults to the system
  /// browser through url_launcher.
  final Future<bool> Function(Uri)? openRelease;

  UpdateCheckStatus _status = UpdateCheckStatus.idle;
  UpdateCheckStatus get status => _status;
  bool get isChecking => _status == UpdateCheckStatus.checking;

  AppUpdate? _availableUpdate;
  AppUpdate? get availableUpdate => _availableUpdate;

  String? _error;
  String? get error => _error;

  /// Number of finished checks, useful for asserting a manual retry.
  int completedChecks = 0;

  Future<void>? _inFlight;

  /// Checks GitHub for a newer release. Concurrent callers share the in-flight
  /// request, and the latest result is retained between calls.
  Future<void> check() {
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;
    final request = _check().whenComplete(() => _inFlight = null);
    _inFlight = request;
    return request;
  }

  Future<void> _check() async {
    if (_status != UpdateCheckStatus.checking) {
      _status = UpdateCheckStatus.checking;
      _error = null;
      notifyListeners();
    }
    try {
      final update = await _checker.findUpdate(currentVersion: currentVersion);
      _availableUpdate = update;
      _status = update == null
          ? UpdateCheckStatus.upToDate
          : UpdateCheckStatus.updateAvailable;
      _error = null;
    } catch (_) {
      _availableUpdate = null;
      _status = UpdateCheckStatus.failed;
      _error = 'Could not check for updates';
    } finally {
      completedChecks++;
      notifyListeners();
    }
  }

  /// Opens the release page for the available update in the system browser.
  /// Returns false when no update is available or launching fails.
  Future<bool> openReleasePage() async {
    final update = _availableUpdate;
    if (update == null) return false;
    final open =
        openRelease ??
        (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
    try {
      return await open(Uri.parse(update.releaseUrl));
    } catch (_) {
      return false;
    }
  }
}
