import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/playback_controller.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/playback_engine.dart';

import 'fakes.dart';

const _tracks = [
  Track(id: 'a', title: 'A', durationMs: 120000),
  Track(id: 'b', title: 'B', durationMs: 120000),
];

class _ListeningHarness {
  _ListeningHarness() {
    player =
        PlaybackController(
          engine: engine,
          enableSystemControls: false,
          monotonicMs: () => nowMs,
          resolveSource: (track, _) async => resolve == null
              ? AudioSource('https://audio.test/${track.id}')
              : await resolve!(track),
        )..configureRecording('device', (event) async {
          await beforeSave?.call(event);
          saved.add(event);
        });
  }

  final engine = FakeEngine();
  final saved = <ListeningEvent>[];
  late final PlaybackController player;
  int nowMs = 0;
  Future<AudioSource> Function(Track)? resolve;
  Future<void> Function(ListeningEvent)? beforeSave;

  int get totalMs => saved.fold(0, (total, event) => total + event.listenedMs);

  void emit(
    int positionMs, {
    bool playing = true,
    bool buffering = false,
    bool waiting = false,
    bool completed = false,
    String? error,
  }) => engine.emit(
    EngineState(
      playing: playing,
      buffering: buffering,
      waitingForAudio: waiting,
      completed: completed,
      error: error,
      position: Duration(milliseconds: positionMs),
      duration: const Duration(seconds: 120),
    ),
  );

  // Drain automatic writes without explicitly checkpointing: otherwise a test
  // could accidentally hide the absence of immediate catch-up persistence.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await player.shutdown();
    player.dispose();
  }
}

void main() {
  late _ListeningHarness h;

  setUp(() => h = _ListeningHarness());
  tearDown(() => h.close());

  test(
    'native progress across a long Dart gap is persisted immediately',
    () async {
      await h.player.playQueue(_tracks);
      h.nowMs = 95000;
      h.emit(95000);
      await h.settle();

      expect(h.totalMs, 95000);
      expect(h.saved.map((event) => event.listenedMs), [60000, 35000]);
      expect(h.saved.map((event) => event.sessionId).toSet(), hasLength(1));
      expect(h.saved.map((event) => event.id).toSet(), hasLength(2));
      expect(h.saved.every((event) => event.trackId == 'a'), isTrue);
      for (final event in h.saved) {
        expect(event.endedAt - event.startedAt, event.listenedMs);
      }
      h.emit(95000);
      await h.player.checkpoint();
      expect(
        h.totalMs,
        95000,
        reason: 'Repeated snapshots cannot reuse progress',
      );
    },
  );

  test(
    'catch-up survives blocked and failed persistence with stable IDs',
    () async {
      final accepted = Completer<void>();
      final blocked = Completer<void>();
      final attempts = <ListeningEvent>[];
      var fail = true;
      h.beforeSave = (event) async {
        attempts.add(event);
        if (fail) {
          accepted.complete();
          await blocked.future;
          throw StateError('storage unavailable');
        }
      };
      await h.player.playQueue(_tracks);
      h.nowMs = 30000;
      h.emit(30000);
      await accepted.future;
      h.nowMs = 60000;
      h.emit(60000);
      blocked.complete();
      await h.settle();
      expect(h.saved, isEmpty);
      expect(h.player.error, contains('storage unavailable'));
      fail = false;
      await h.player.checkpoint();
      expect(h.totalMs, 60000);
      expect(h.saved.map((e) => e.listenedMs), [30000, 30000]);
      expect(attempts[0].id, attempts[1].id);
      expect(h.saved.map((e) => e.id).toSet(), hasLength(2));
      h.emit(60000);
      await h.player.checkpoint();
      expect(h.totalMs, 60000);
      expect(attempts, hasLength(3));
    },
  );

  test('stationary native position cannot recover a long Dart gap', () async {
    await h.player.playQueue(_tracks);
    h.nowMs = 60000;
    h.emit(0);
    await h.settle();
    expect(h.saved, isEmpty);
    await h.player.checkpoint();
    expect(h.saved, isEmpty);

    h.nowMs += 1000;
    h.emit(1000);
    await h.player.pause();
    expect(h.totalMs, 1000);
  });

  test(
    'checkpoint before delayed position loses nothing and counts once',
    () async {
      await h.player.playQueue(_tracks);
      h.nowMs = 1000;
      h.emit(1000);
      await h.player.checkpoint();
      expect(h.totalMs, 1000);

      h.nowMs = 61000;
      await h.player
          .checkpoint(); // Timer/lifecycle arrives before native state.
      await h.player.checkpoint();
      expect(h.totalMs, 1000);
      h.emit(61000);
      await h.settle();
      expect(
        h.totalMs,
        61000,
        reason: 'Recovery saves even just after a checkpoint',
      );
      h.emit(61000);
      await h.player.checkpoint();
      expect(h.totalMs, 61000);

      h.nowMs += 1000;
      h.emit(62000);
      await h.player.pause();
      expect(h.totalMs, 62000);
      expect(h.saved.map((event) => event.sessionId).toSet(), hasLength(1));
    },
  );

  for (final boundary in ['pause', 'buffer', 'wait']) {
    test(
      '$boundary reconciles progress then excludes inactive downtime',
      () async {
        await h.player.playQueue(_tracks);
        h.nowMs = 30000;
        h.emit(
          30000,
          playing: boundary != 'pause',
          buffering: boundary == 'buffer',
          waiting: boundary == 'wait',
        );
        await h.settle();
        expect(h.totalMs, 30000);
        expect(h.player.isPlaying && !h.player.isBuffering, isFalse);

        h.nowMs += 60000;
        // Even a changed position while inactive is not evidence of listening.
        h.emit(60000, playing: false);
        await h.player.checkpoint();
        expect(h.totalMs, 30000);
        h.emit(60000);
        h.nowMs += 10000;
        h.emit(70000);
        await h.settle();
        expect(h.totalMs, 40000);
      },
    );
  }

  test('explicit pause discards unproven gap before resume', () async {
    await h.player.playQueue(_tracks);
    h.nowMs = 60000;
    await h.player.pause();
    expect(h.saved, isEmpty);
    h.nowMs += 60000;
    await h.player.play();
    h.nowMs += 10000;
    h.emit(10000);
    await h.settle();
    expect(h.totalMs, 10000);
    expect(h.engine.opens, 1);
  });

  test(
    'EOF reconciles final progress and does not count idle queue end',
    () async {
      await h.player.playQueue([_tracks.first]);
      h.nowMs = 120000;
      h.emit(120000, playing: false, completed: true);
      await h.player.flushSettings();
      expect(h.totalMs, 120000);
      expect(h.player.currentTrack, isNull);
      h.nowMs += 60000;
      h.emit(120000, playing: false, completed: true);
      await h.player.checkpoint();
      expect(h.totalMs, 120000);
    },
  );

  for (final transition in ['next', 'EOF next', 'repeat one', 'repeat all']) {
    test(
      '$transition isolates accounting and starts a fresh session',
      () async {
        final repeating = transition.startsWith('repeat');
        await h.player.playQueue(repeating ? [_tracks.first] : _tracks);
        if (repeating) {
          h.player.setRepeat(
            transition == 'repeat one' ? RepeatMode.one : RepeatMode.all,
          );
        }
        h.nowMs = 120000;
        if (transition == 'next') {
          h.emit(120000);
          await h.settle();
          await h.player.next();
        } else {
          h.emit(120000, playing: false, completed: true);
          // Duplicate completion must not reopen twice or recover twice.
          h.emit(120000, playing: false, completed: true);
          await h.player.flushSettings();
        }
        expect(h.totalMs, 120000);
        expect(h.engine.opens, 2);
        expect(h.player.currentTrack!.id, repeating ? 'a' : 'b');
        final previousSession = h.saved.first.sessionId;
        h.nowMs += 20000;
        h.emit(20000);
        await h.settle();
        expect(h.totalMs, 140000);
        expect(h.saved.last.listenedMs, 20000);
        expect(h.saved.last.sessionId, isNot(previousSession));
        expect(h.saved.last.trackId, repeating ? 'a' : 'b');
      },
    );
  }

  test(
    'stream recovery never bridges pending evidence or lookup downtime',
    () async {
      await h.player.playQueue(_tracks);
      h.nowMs = 1000;
      h.emit(1000);
      await h.player.checkpoint();
      h.nowMs = 61000;
      await h.player.checkpoint(); // Unproven gap must die with this source.
      final entered = Completer<void>();
      final source = Completer<AudioSource>();
      h.resolve = (_) {
        entered.complete();
        return source.future;
      };
      h.emit(40000, playing: false, error: 'stream disconnected');
      await entered.future;
      h.nowMs += 60000;
      h.emit(100000); // Retired decoder while the replacement is resolving.
      await h.player.checkpoint();
      expect(h.totalMs, 1000);
      source.complete(const AudioSource('https://audio.test/recovered'));
      await h.player.flushSettings();
      expect(h.engine.opens, 2);
      expect(h.player.position, const Duration(seconds: 40));
      expect(h.player.error, isNull);
      h.nowMs += 10000;
      h.emit(50000);
      await h.settle();
      expect(h.totalMs, 11000);
      expect(h.saved.map((event) => event.sessionId).toSet(), hasLength(1));
    },
  );

  for (final targetMs in [45000, 5000]) {
    for (final pauseResume in [false, true]) {
      test(
        'seek to $targetMs rejects delayed stale snapshots '
        '(pause/resume=$pauseResume), but short intervals still count',
        () async {
          await h.player.playQueue(_tracks);
          h.nowMs = 30000;
          h.emit(30000);
          await h.settle();
          expect(h.totalMs, 30000);
          await h.player.seek(Duration(milliseconds: targetMs));
          expect(h.player.position.inMilliseconds, targetMs);
          if (pauseResume) {
            await h.player.pause();
            h.nowMs += 60000;
            await h.player.play();
          }
          // Seek's Future completed, but native delivery can still be stale.
          h.emit(30000);
          h.nowMs += 60000;
          // Relative to the stale 30s snapshot, both directions now look like
          // plausible forward progress within the elapsed gap. Neither proves
          // continuity across a seek, even after the seek Future has completed.
          h.emit(targetMs + 30000);
          await h.settle();
          expect(
            h.totalMs,
            30000,
            reason: 'Neither seek jump nor gap is proof',
          );

          h.nowMs += 1000;
          h.emit(targetMs + 31000);
          h.nowMs += 2500;
          h.emit(targetMs + 33500);
          await h.player.checkpoint();
          expect(h.totalMs, 33500);
          // A normal tick must not silently re-enable position recovery.
          h.nowMs += 10000;
          h.emit(targetMs + 43500);
          await h.settle();
          expect(h.totalMs, 33500);

          await h.player.next();
          h.nowMs += 10000;
          h.emit(10000);
          await h.settle();
          expect(h.totalMs, 43500, reason: 'New source restores recovery');
          expect(h.saved.last.trackId, 'b');
        },
      );
    }
  }

  test(
    'stream reopen re-enables recovery after seeking without a new session',
    () async {
      await h.player.playQueue(_tracks);
      h.nowMs = 1000;
      h.emit(1000);
      await h.player.seek(const Duration(seconds: 40));
      expect(h.totalMs, 1000);
      final session = h.saved.single.sessionId;
      h.nowMs += 10000;
      h.emit(50000);
      await h.settle();
      expect(h.totalMs, 1000);
      h.emit(50000, playing: false, error: 'stream disconnected');
      await h.player.flushSettings();
      expect(h.engine.opens, 2);
      h.nowMs += 20000;
      h.emit(70000);
      await h.settle();
      expect(h.totalMs, 21000);
      expect(h.saved.last.sessionId, session);
    },
  );

  testWidgets('periodic checkpoint uses elapsed deadline, not callback count', (
    tester,
  ) async {
    // Construct in the widget test's fake-async zone, not the outer setUp zone.
    final h = _ListeningHarness();
    addTearDown(() => tester.runAsync(h.close));
    await h.player.playQueue(_tracks);
    h.nowMs = 1000;
    h.emit(1000);
    // One timer callback after a long scheduling gap must save the already
    // proven second. A callback-count implementation would wait nine more ticks.
    h.nowMs = 61000;
    await tester.pump(const Duration(seconds: 1));
    expect(h.totalMs, 1000);
    h.emit(61000);
    await tester.pump();
    expect(h.totalMs, 61000);

    h.nowMs += 1000;
    h.emit(62000);
    await tester.pump(const Duration(seconds: 9));
    expect(
      h.totalMs,
      61000,
      reason: 'Timer callbacks alone are not a deadline',
    );
    h.nowMs += 9000;
    await tester.pump(const Duration(seconds: 1));
    expect(h.totalMs, 62000);
    h.emit(71000);
    await tester.pump();
    expect(h.totalMs, 71000, reason: 'Delayed position persists right away');
    // Cancel the periodic timer before the widget test checks pending timers.
    await tester.runAsync(h.close);
  });
}
