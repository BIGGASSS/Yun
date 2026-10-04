import 'dart:math';

import '../models/models.dart';

/// A cumulative, identifier-free snapshot for diagnosing background accounting.
class ListeningGapDiagnostic {
  const ListeningGapDiagnostic({
    required this.reason,
    required this.observedMs,
    required this.recoveredMs,
    required this.discardedMs,
    required this.pendingMs,
  });

  final String reason;
  final int observedMs, recoveredMs, discardedMs, pendingMs;

  @override
  String toString() =>
      '$reason observedMs=$observedMs recoveredMs=$recoveredMs '
      'discardedMs=$discardedMs pendingMs=$pendingMs';
}

/// Pure accounting: wall time labels events; monotonic time measures listening.
/// Short active intervals are counted directly. Long scheduler gaps require
/// position evidence: native audio can continue while Dart callbacks are delayed.
class ListeningTracker {
  ListeningTracker({
    required this.deviceId,
    required this.newId,
    required this.monotonicMs,
    required this.wallNow,
    this.onGapDiagnostic,
  });
  final String deviceId;
  final String Function() newId;
  final int Function() monotonicMs;
  final DateTime Function() wallNow;

  /// Sanitized counters only; no track, account, or media identifiers.
  final void Function(ListeningGapDiagnostic diagnostic)? onGapDiagnostic;
  int _schedulerGapMs = 0, _recoveredGapMs = 0, _discardedGapMs = 0;
  int get schedulerGapMs => _schedulerGapMs;
  int get recoveredGapMs => _recoveredGapMs;
  int get discardedGapMs => _discardedGapMs;
  int get pendingGapMs => _gapBudget;

  String? _trackId, _sessionId;
  bool _active = false, _positionRecoveryEnabled = true;
  int? _lastMono, _positionAnchor, _positionMono, _lastPosition;
  int _listened = 0, _creditedSinceAnchor = 0, _gapBudget = 0;

  void start(String trackId) {
    clear();
    _trackId = trackId;
    _sessionId = newId();
    _lastMono = monotonicMs();
  }

  /// Supply a fresh engine observation, never the controller's cached position
  /// from a timer. Reconcile the old active interval before pause/buffer/EOF.
  void setActive(bool active, {Duration? position}) {
    tick();
    final positionMs = position?.inMilliseconds;
    if (_active && positionMs != null) _reconcilePosition(positionMs);
    if (!active) {
      _resetEvidence();
    } else if (_positionRecoveryEnabled &&
        _positionAnchor == null &&
        positionMs != null &&
        positionMs >= 0) {
      _positionAnchor = _lastPosition = positionMs;
      _positionMono = _lastMono;
    }
    _active = active;
  }

  /// Invalidate discontinuous/ambiguous position evidence. Seek completion does
  /// not guarantee that subsequent native snapshots are post-seek, so callers
  /// disable recovery until the next source open. Wall accounting is unaffected.
  void resetPositionEvidence({bool enabled = true}) {
    _resetEvidence();
    _positionRecoveryEnabled = enabled;
  }

  void tick() {
    final now = monotonicMs();
    if (_lastMono != null && _active && _trackId != null) {
      final delta = now - _lastMono!;
      if (delta > 0 && delta <= 2500) {
        _credit(delta);
      } else if (delta > 2500) {
        _schedulerGapMs += delta;
        if (_positionRecoveryEnabled && _positionAnchor != null) {
          _gapBudget += delta;
        } else {
          _discardedGapMs += delta;
        }
        _diagnose('scheduler_gap');
      } else if (delta < 0) {
        _resetEvidence();
      }
    }
    _lastMono = now;
  }

  void _credit(int ms) {
    _listened += ms;
    if (_positionAnchor != null) _creditedSinceAnchor += ms;
  }

  void _reconcilePosition(int positionMs) {
    final anchor = _positionAnchor;
    if (!_positionRecoveryEnabled || anchor == null) return;
    final progress = positionMs - anchor;
    final elapsed = _lastMono! - _positionMono!;
    // An unannounced backwards/implausible jump cannot prove audible playback.
    // Explicit seeks are disabled separately, even if their jump fits elapsed.
    if (positionMs < _lastPosition! || progress > elapsed + 2500) {
      _resetEvidence();
      return;
    }
    _lastPosition = positionMs;
    final recovered = min(
      _gapBudget,
      max(0, min(progress, elapsed) - _creditedSinceAnchor),
    );
    if (recovered == 0) return;
    _credit(recovered);
    _gapBudget -= recovered;
    _recoveredGapMs += recovered;
    _diagnose('position_recovery');
  }

  void _resetEvidence() {
    final discarded = _gapBudget;
    _discardedGapMs += discarded;
    _gapBudget = 0;
    _positionAnchor = _positionMono = _lastPosition = null;
    _creditedSinceAnchor = 0;
    if (discarded > 0) _diagnose('continuity_ended');
  }

  void _diagnose(String reason) => onGapDiagnostic?.call(
    ListeningGapDiagnostic(
      reason: reason,
      observedMs: schedulerGapMs,
      recoveredMs: recoveredGapMs,
      discardedMs: discardedGapMs,
      pendingMs: pendingGapMs,
    ),
  );

  List<ListeningEvent> flush() {
    tick();
    final now = wallNow();
    final end = now.millisecondsSinceEpoch;
    // Wall-clock corrections must not discard real, monotonically measured
    // listening. Label the interval backwards from now (never in the future).
    final listened = min(_listened, max(0, end));
    _listened = 0;
    // Do not clear position evidence/credit: delayed observations may recover a
    // gap after a checkpoint, but must never reuse already-persisted listening.
    if (listened <= 0 || _trackId == null) return [];
    final events = <ListeningEvent>[];
    var remaining = listened;
    var cursor = end - listened;
    while (remaining > 0) {
      final length = min(remaining, 60000);
      events.add(
        ListeningEvent(
          id: newId(),
          deviceId: deviceId,
          sessionId: _sessionId!,
          trackId: _trackId!,
          startedAt: cursor,
          endedAt: cursor + length,
          listenedMs: length,
          timezoneOffsetMinutes: now.timeZoneOffset.inMinutes,
        ),
      );
      remaining -= length;
      cursor += length;
    }
    return events;
  }

  void clear() {
    _resetEvidence();
    _positionRecoveryEnabled = true;
    _active = false;
    _trackId = null;
    _sessionId = null;
    _listened = 0;
    _lastMono = null;
  }
}
