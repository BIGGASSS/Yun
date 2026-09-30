import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/ui/track_widgets.dart';

import '../core/fakes.dart';
import 'player_test_app.dart';

class _QueueApp extends PlayerTestApp {
  _QueueApp(super.engine);

  @override
  Future<void> queueNext(Track track) => playback.queueNext(track);
}

void main() {
  testWidgets(
    'track menu queues repeated selections without interrupting playback',
    (tester) async {
      final app = _QueueApp(FakeEngine());
      const original = Track(id: 'original', title: 'Original');
      const extra = Track(id: 'extra', title: 'Extra');
      try {
        await app.playback.playQueue([original]);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TrackMenu(app: app, track: extra),
            ),
          ),
        );
        for (var i = 0; i < 2; i++) {
          await tester.tap(find.byTooltip('Options for Extra'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Play next'));
          await tester.pumpAndSettle();
        }
        expect(app.playback.currentTrack, original);
        expect(app.playback.effectiveQueue.map((e) => e.track), [
          original,
          extra,
          extra,
        ]);
        await app.playback.next();
        expect(app.playback.currentTrack, extra);
        expect(app.playback.effectiveIndex, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(app.shutdown);
        app.dispose();
      }
    },
  );
}
