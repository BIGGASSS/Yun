import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/listening_tracker.dart';

void main() {
  late int mono, wall, id;
  late ListeningTracker tracker;
  setUp(() {
    mono = 0;
    wall = 100000;
    id = 0;
    tracker = ListeningTracker(
      deviceId: 'device',
      newId: () => '${id++}',
      monotonicMs: () => mono,
      wallNow: () => DateTime.fromMillisecondsSinceEpoch(wall),
    );
    tracker.start('track');
  });
  void advance(int ms) {
    mono += ms;
    wall += ms;
    tracker.tick();
  }

  test('counts monotonic playback, excludes buffering, pauses and seeks', () {
    tracker.setActive(true);
    for (var i = 0; i < 10; i++) {
      advance(1000);
    }
    tracker.setActive(false);
    advance(1000);
    advance(1000);
    tracker.setActive(true);
    advance(1000);
    final event = tracker.flush().single;
    expect(event.listenedMs, 11000);
    expect(event.endedAt - event.startedAt, 11000);
    expect(tracker.flush(), isEmpty);
  });
  test('excludes long gaps without position evidence', () {
    tracker.setActive(true);
    advance(1000);
    advance(120000);
    advance(1000);
    expect(tracker.flush().single.listenedMs, 2000);
  });
  group('position-backed scheduler gaps', () {
    void observe(int ms, {bool active = true}) =>
        tracker.setActive(active, position: Duration(milliseconds: ms));

    test('recovers long audible gaps and splits them into valid segments', () {
      observe(0);
      advance(130000);
      observe(130000);
      final events = tracker.flush();
      expect(events.map((e) => e.listenedMs), [60000, 60000, 10000]);
      expect(events.map((e) => e.sessionId).toSet().length, 1);
      expect(tracker.schedulerGapMs, 130000);
      expect(tracker.recoveredGapMs, 130000);
      expect(tracker.pendingGapMs, 0);
    });

    test('multiple gaps share one anchor without reusing flushed credit', () {
      observe(0);
      var positionMs = 0;
      for (var i = 0; i < 5; i++) {
        advance(30000);
        positionMs += 30000;
        observe(positionMs);
        expect(tracker.flush().single.listenedMs, 30000);
        advance(1000);
        positionMs += 1000;
        observe(positionMs);
        expect(tracker.flush().single.listenedMs, 1000);
      }
      expect(tracker.schedulerGapMs, 150000);
      expect(tracker.recoveredGapMs, 150000);
      expect(tracker.pendingGapMs, 0);
      expect(tracker.flush(), isEmpty);
    });

    test('stationary and partial progress do not credit silent minutes', () {
      observe(0);
      advance(120000);
      observe(0);
      expect(tracker.flush(), isEmpty);
      observe(30000);
      expect(tracker.flush().single.listenedMs, 30000);
      observe(30000);
      expect(tracker.flush(), isEmpty);
      observe(30000, active: false);
      expect(tracker.discardedGapMs, 90000);
      expect(tracker.pendingGapMs, 0);
    });

    test('caps recovery at monotonic elapsed even if position is ahead', () {
      observe(0);
      advance(30000);
      observe(31000);
      expect(tracker.flush().single.listenedMs, 30000);
    });

    test('checkpoint and repeated stale snapshots retain gap evidence', () {
      observe(0);
      advance(30000);
      expect(tracker.flush(), isEmpty);
      observe(0);
      observe(0);
      observe(15000);
      expect(tracker.flush().single.listenedMs, 15000);
      observe(30000);
      expect(tracker.flush().single.listenedMs, 15000);
      observe(30000);
      expect(tracker.flush(), isEmpty);
    });

    test('already-flushed wall credit consumes position evidence', () {
      observe(0);
      for (var i = 0; i < 10; i++) {
        advance(1000);
      }
      expect(tracker.flush().single.listenedMs, 10000);
      advance(30000);
      observe(35000);
      expect(tracker.flush().single.listenedMs, 25000);
      observe(40000);
      expect(tracker.flush().single.listenedMs, 5000);
      advance(1000);
      observe(41000);
      expect(tracker.flush().single.listenedMs, 1000);
      expect(tracker.recoveredGapMs, 30000);
    });

    test('ordinary ticks after a gap cannot reuse subsequent progress', () {
      observe(0);
      advance(30000);
      for (var i = 0; i < 10; i++) {
        advance(1000);
      }
      expect(tracker.flush().single.listenedMs, 10000);
      observe(30000);
      expect(tracker.flush().single.listenedMs, 20000);
      observe(40000);
      expect(tracker.flush().single.listenedMs, 10000);
      expect(tracker.recoveredGapMs, 30000);
    });

    test('inactive terminal observation recovers only the old interval', () {
      observe(0);
      advance(30000);
      observe(20000, active: false);
      expect(tracker.flush().single.listenedMs, 20000);
      advance(120000);
      observe(20000);
      advance(1000);
      observe(21000);
      expect(tracker.flush().single.listenedMs, 1000);
      expect(tracker.discardedGapMs, 10000);
    });

    test('late terminal positions cannot reopen an inactive interval', () {
      observe(0);
      advance(30000);
      observe(0, active: false);
      observe(30000, active: false);
      expect(tracker.flush(), isEmpty);
      expect(tracker.discardedGapMs, 30000);
    });

    for (final jump in [-1000, 10000]) {
      test('unannounced position jump $jump invalidates evidence', () {
        observe(0);
        advance(3000);
        observe(jump);
        expect(tracker.flush(), isEmpty);
        expect(tracker.discardedGapMs, 3000);
      });
    }

    test('backward position above the original anchor is discontinuous', () {
      observe(0);
      advance(30000);
      observe(20000);
      expect(tracker.flush().single.listenedMs, 20000);
      observe(15000);
      expect(tracker.discardedGapMs, 10000);
      advance(30000);
      observe(45000);
      expect(tracker.flush().single.listenedMs, 30000);
    });

    test('backwards monotonic time invalidates outstanding evidence', () {
      observe(0);
      advance(30000);
      advance(-1000);
      observe(30000);
      expect(tracker.flush(), isEmpty);
      expect(tracker.discardedGapMs, 30000);
    });

    test('seek-disabled evidence stays disabled through resume', () {
      observe(0);
      advance(30000);
      tracker.resetPositionEvidence(enabled: false);
      observe(0, active: false);
      observe(0);
      advance(30000);
      observe(30000);
      expect(tracker.flush(), isEmpty);
      advance(1000);
      expect(tracker.flush().single.listenedMs, 1000);
      expect(tracker.discardedGapMs, 60000);
    });

    test('new source and explicit reset permit recovery again', () {
      for (final restart in [false, true]) {
        tracker.resetPositionEvidence(enabled: false);
        observe(0, active: false);
        if (restart) {
          tracker.start('next');
        } else {
          tracker.resetPositionEvidence();
        }
        observe(0);
        advance(30000);
        observe(30000);
        expect(tracker.flush().single.listenedMs, 30000);
      }
    });

    test('new track cannot inherit an unresolved gap', () {
      observe(0);
      advance(30000);
      tracker.start('next');
      observe(0);
      advance(1000);
      observe(1000);
      final event = tracker.flush().single;
      expect(event.trackId, 'next');
      expect(event.listenedMs, 1000);
      expect(tracker.discardedGapMs, 30000);
    });

    test(
      'diagnostics contain bounded accounting counters, not identifiers',
      () {
        final diagnostics = <ListeningGapDiagnostic>[];
        tracker = ListeningTracker(
          deviceId: 'private-device',
          newId: () => '${id++}',
          monotonicMs: () => mono,
          wallNow: () => DateTime.fromMillisecondsSinceEpoch(wall),
          onGapDiagnostic: diagnostics.add,
        )..start('private-track');
        observe(0);
        advance(30000);
        observe(20000);
        observe(20000, active: false);
        expect(diagnostics.map((d) => d.reason), [
          'scheduler_gap',
          'position_recovery',
          'continuity_ended',
        ]);
        final last = diagnostics.last;
        expect(last.observedMs, 30000);
        expect(last.recoveredMs, 20000);
        expect(last.discardedMs, 10000);
        expect(last.pendingMs, 0);
        expect(last.toString(), isNot(contains('private')));
      },
    );
  });

  test('segments have <=60 second duration and same session identity', () {
    tracker.setActive(true);
    for (var i = 0; i < 130; i++) {
      advance(1000);
    }
    final events = tracker.flush();
    expect(events.map((e) => e.listenedMs), [60000, 60000, 10000]);
    expect(events.map((e) => e.sessionId).toSet().length, 1);
    expect(events.map((e) => e.id).toSet().length, 3);
  });
  test('clock moving backwards preserves monotonic listening without future segments', () {
    tracker.setActive(true);
    advance(1000);
    wall -= 10000;
    final corrected = tracker.flush().single;
    expect(corrected.listenedMs, 1000);
    expect(corrected.endedAt, wall);
    expect(corrected.startedAt, wall - 1000);
    advance(1000);
    final event = tracker.flush().single;
    expect(event.endedAt, wall);
    expect(event.listenedMs, 1000);
  });
  test('transition creates a new listening session', () {
    tracker.setActive(true);
    advance(1000);
    final first = tracker.flush().single;
    tracker.start('next');
    tracker.setActive(true);
    advance(1000);
    final next = tracker.flush().single;
    expect(next.trackId, 'next');
    expect(next.sessionId, isNot(first.sessionId));
  });
}
