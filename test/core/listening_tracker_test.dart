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
  test('excludes process suspension instead of counting silent minutes', () {
    tracker.setActive(true);
    advance(1000);
    advance(120000);
    advance(1000);
    expect(tracker.flush().single.listenedMs, 2000);
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
