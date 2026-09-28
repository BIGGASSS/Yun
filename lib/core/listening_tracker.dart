import 'dart:math';

import '../models/models.dart';

/// Pure accounting: wall time labels events; monotonic time measures listening.
/// The owner calls tick at least once a second and flushes at transitions.
/// Long scheduler gaps are excluded (sleep/suspension is not audible playback).
class ListeningTracker {
  ListeningTracker({
    required this.deviceId,
    required this.newId,
    required this.monotonicMs,
    required this.wallNow,
  });
  final String deviceId;
  final String Function() newId;
  final int Function() monotonicMs;
  final DateTime Function() wallNow;
  String? _trackId, _sessionId;
  bool _active = false;
  int? _lastMono;
  int _listened = 0;
  void start(String trackId) {
    _trackId = trackId;
    _sessionId = newId();
    _lastMono = monotonicMs();
    _listened = 0;
    _active = false;
  }

  void setActive(bool active) {
    tick();
    _active = active;
  }

  void tick() {
    final now = monotonicMs();
    if (_lastMono != null && _active && _trackId != null) {
      final delta = now - _lastMono!;
      if (delta > 0 && delta <= 2500) _listened += delta;
    }
    _lastMono = now;
  }

  List<ListeningEvent> flush() {
    tick();
    final now = wallNow();
    final end = now.millisecondsSinceEpoch;
    // Wall-clock corrections must not discard real, monotonically measured
    // listening. Label the interval backwards from now (never in the future).
    final listened = min(_listened, max(0, end));
    _listened = 0;
    if (listened <= 0 || _trackId == null) return [];
    // Keep each segment's wall duration <= 60s even after long offline pauses.
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
    _active = false;
    _trackId = null;
    _sessionId = null;
    _listened = 0;
    _lastMono = null;
  }
}
