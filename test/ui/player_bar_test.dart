import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart' show Track;
import 'package:yun/core/playback_controller.dart' show RepeatMode;
import 'package:yun/ui/player.dart';
import 'package:yun/ui/player_icons.dart';

import 'player_test_app.dart';

void main() {
  setUp(mockDesktopDrop);

  Finder glyph(PlayerGlyph value) => find.byWidgetPredicate(
    (widget) => widget is PlayerIcon && widget.glyph == value,
  );

  playerTest(
    'desktop bar centers a bounded transport and seek at 1848',
    platform: TargetPlatform.linux,
    size: const Size(1848, 900),
    (tester, app, engine) async {
      final bar = find.byType(DesktopPlayerBar);
      expect(bar, findsOneWidget);
      // The bar stays a slim strip instead of a sprawling block.
      expect(tester.getSize(bar).height, lessThan(90));

      final seek = find.byType(PlaybackSeek);
      expect(seek, findsOneWidget);
      final seekRect = tester.getRect(seek);
      expect(seekRect.width, DesktopPlayerBar.maxSeekColumnWidth);
      // Equal flexible side zones keep the seek column optically centered.
      expect((seekRect.center.dx - 1848 / 2).abs(), lessThan(.5));
      // The symmetric transport row shares the same center.
      final playCenter = tester.getCenter(find.byTooltip('Pause'));
      expect((playCenter.dx - 1848 / 2).abs(), lessThan(.5));

      // Metadata hugs the left edge; volume and queue hug the right.
      expect(tester.getTopLeft(find.text('Test track')).dx, lessThan(200));
      expect(
        tester.getCenter(find.byTooltip('Show queue')).dx,
        greaterThan(1848 - 200),
      );
      expect(
        find.byKey(const ValueKey('playback-volume-slider')),
        findsOneWidget,
      );
    },
  );

  playerTest(
    'desktop bar keeps zones balanced at the 840 breakpoint',
    platform: TargetPlatform.macOS,
    size: const Size(840, 800),
    (tester, app, engine) async {
      final seek = find.byType(PlaybackSeek);
      expect(seek, findsOneWidget);
      final seekRect = tester.getRect(seek);
      expect(seekRect.width, lessThan(DesktopPlayerBar.maxSeekColumnWidth));
      expect((seekRect.center.dx - 420).abs(), lessThan(.5));
      expect(find.byTooltip('Show queue'), findsOneWidget);
    },
  );

  playerTest(
    'transport buttons drive playback and show selection state',
    platform: TargetPlatform.windows,
    size: const Size(1400, 900),
    tracks: const [
      Track(id: 'one', title: 'First song', artist: 'Artist A'),
      Track(id: 'two', title: 'Second song', artist: 'Artist B'),
    ],
    (tester, app, engine) async {
      IconButton buttonAt(Finder tooltip) => tester.widget<IconButton>(
        find.ancestor(of: tooltip, matching: find.byType(IconButton)),
      );

      // Play/pause toggle.
      expect(find.byTooltip('Pause'), findsOneWidget);
      await tester.tap(find.byTooltip('Pause'));
      await tester.pumpAndSettle();
      expect(engine.state.playing, isFalse);
      expect(find.byTooltip('Play'), findsOneWidget);
      await tester.tap(find.byTooltip('Play'));
      await tester.pumpAndSettle();
      expect(engine.state.playing, isTrue);

      // Track skipping.
      await tester.tap(find.byTooltip('Next track'));
      await tester.pumpAndSettle();
      expect(app.playback.currentTrack?.title, 'Second song');
      await tester.tap(find.byTooltip('Previous track'));
      await tester.pumpAndSettle();
      expect(app.playback.currentTrack?.title, 'First song');

      // Shuffle selects persistently.
      expect(buttonAt(find.byTooltip('Turn shuffle on')).isSelected, isFalse);
      await tester.tap(find.byTooltip('Turn shuffle on'));
      await tester.pumpAndSettle();
      expect(app.playback.shuffle, isTrue);
      expect(buttonAt(find.byTooltip('Turn shuffle off')).isSelected, isTrue);

      // Repeat cycles off -> all -> one -> off and swaps glyphs.
      await tester.tap(find.byTooltip('Repeat: off. Change repeat mode'));
      await tester.pumpAndSettle();
      expect(app.playback.repeatMode, RepeatMode.all);
      expect(
        buttonAt(find.byTooltip('Repeat: all. Change repeat mode')).isSelected,
        isTrue,
      );
      expect(glyph(PlayerGlyph.repeat), findsOneWidget);
      await tester.tap(find.byTooltip('Repeat: all. Change repeat mode'));
      await tester.pumpAndSettle();
      expect(app.playback.repeatMode, RepeatMode.one);
      expect(glyph(PlayerGlyph.repeatOne), findsOneWidget);
      await tester.tap(find.byTooltip('Repeat: one. Change repeat mode'));
      await tester.pumpAndSettle();
      expect(app.playback.repeatMode, RepeatMode.off);
    },
  );

  playerTest(
    'desktop seek slider seeks through the engine',
    platform: TargetPlatform.linux,
    (tester, app, engine) async {
      final slider = find.descendant(
        of: find.byType(PlaybackSeek),
        matching: find.byType(Slider),
      );
      expect(slider, findsOneWidget);
      tester.widget<Slider>(slider).onChanged!(60000);
      await tester.pump();
      tester.widget<Slider>(slider).onChangeEnd!(60000);
      await tester.pumpAndSettle();
      expect(engine.state.position, const Duration(seconds: 60));
      expect(app.playback.position, const Duration(seconds: 60));
      expect(find.text('1:00'), findsOneWidget);
      expect(find.text('2:00'), findsOneWidget);
    },
  );

  playerTest(
    'idle desktop bar disables transport and seek gracefully',
    platform: TargetPlatform.linux,
    tracks: const [],
    (tester, app, engine) async {
      expect(find.text('Nothing playing'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.ancestor(
                of: find.byTooltip('Play'),
                matching: find.byType(IconButton),
              ),
            )
            .onPressed,
        isNull,
      );
      final slider = find.descendant(
        of: find.byType(PlaybackSeek),
        matching: find.byType(Slider),
      );
      expect(tester.widget<Slider>(slider).onChanged, isNull);
    },
  );

  playerTest(
    'desktop bar uses local vector glyphs, not the icon font',
    platform: TargetPlatform.linux,
    (tester, app, engine) async {
      final bar = find.byType(DesktopPlayerBar);
      for (final icon in [
        Icons.shuffle_rounded,
        Icons.skip_previous_rounded,
        Icons.skip_next_rounded,
        Icons.repeat_rounded,
        Icons.volume_up_rounded,
        Icons.volume_down_rounded,
        Icons.volume_off_rounded,
        Icons.queue_music_rounded,
      ]) {
        expect(
          find.descendant(of: bar, matching: find.byIcon(icon)),
          findsNothing,
          reason: '$icon should be a painted glyph in the desktop bar',
        );
      }
      // shuffle, previous, pause, next, repeat, volume, queue.
      expect(
        find.descendant(of: bar, matching: find.byType(PlayerIcon)),
        findsNWidgets(7),
      );
    },
  );

  playerTest(
    'desktop queue button opens the side queue',
    platform: TargetPlatform.linux,
    size: const Size(1400, 900),
    (tester, app, engine) async {
      expect(find.text('Play queue'), findsNothing);
      await tester.tap(find.byTooltip('Show queue'));
      await tester.pumpAndSettle();
      expect(find.text('Play queue'), findsOneWidget);
      expect(find.text('Test track'), findsNWidgets(2));
      await tester.tap(find.byTooltip('Hide queue'));
      await tester.pumpAndSettle();
      expect(find.text('Play queue'), findsNothing);
    },
  );

  playerTest(
    'compact desktop window keeps its compact controls',
    platform: TargetPlatform.linux,
    size: const Size(500, 800),
    (tester, app, engine) async {
      expect(find.byType(DesktopPlayerBar), findsNothing);
      expect(find.byType(PlaybackSeek), findsNothing);
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(find.byTooltip('Next track'), findsOneWidget);
      expect(find.byTooltip('Volume'), findsOneWidget);
    },
  );

  // Regression: compact:false used to route every platform into the desktop
  // redesign. Wide touch windows must keep the legacy bar; only desktop
  // platforms get DesktopPlayerBar.
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    playerTest(
      '${platform.name} wide keeps the legacy touch bar',
      platform: platform,
      size: const Size(1200, 800),
      (tester, app, engine) async {
        final bar = find.byType(PlayerBar);
        Finder inBar(Finder matching) =>
            find.descendant(of: bar, matching: matching);

        expect(find.byType(DesktopPlayerBar), findsNothing);
        expect(inBar(find.byType(PlayerIcon)), findsNothing);
        // Original transport, seek, and queue affordances with Material icons.
        expect(inBar(find.byType(PlaybackButtons)), findsOneWidget);
        expect(inBar(find.byType(PlaybackSeek)), findsOneWidget);
        expect(inBar(find.byTooltip('Show queue')), findsOneWidget);
        expect(inBar(find.byIcon(Icons.shuffle_rounded)), findsOneWidget);
        expect(inBar(find.byIcon(Icons.skip_previous_rounded)), findsOneWidget);
        expect(inBar(find.byIcon(Icons.pause_rounded)), findsOneWidget);
        expect(inBar(find.byIcon(Icons.skip_next_rounded)), findsOneWidget);
        expect(inBar(find.byIcon(Icons.repeat_rounded)), findsOneWidget);
        expect(inBar(find.byIcon(Icons.queue_music_rounded)), findsOneWidget);
        // No desktop-only volume controls leak onto touch platforms.
        expect(
          find.byKey(const ValueKey('playback-volume-slider')),
          findsNothing,
        );
        // Legacy flex 3/5/2 over the 1200 - 40 padding row: the seek column
        // keeps its half-width share instead of the desktop centered column.
        final seekRect = tester.getRect(inBar(find.byType(PlaybackSeek)));
        expect(seekRect.width, moreOrLessEquals(580, epsilon: .5));
        expect(seekRect.left, moreOrLessEquals(368, epsilon: .5));
        // Queue button right-aligns inside its flex 2 zone.
        expect(
          tester.getCenter(inBar(find.byTooltip('Show queue'))).dx,
          greaterThan(948),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  playerTest(
    'Android compact bar is unchanged',
    platform: TargetPlatform.android,
    size: const Size(390, 844),
    (tester, app, engine) async {
      final bar = find.byType(PlayerBar);
      Finder inBar(Finder matching) =>
          find.descendant(of: bar, matching: matching);
      expect(find.byType(DesktopPlayerBar), findsNothing);
      expect(inBar(find.byType(PlaybackButtons)), findsNothing);
      expect(inBar(find.byType(PlaybackSeek)), findsNothing);
      expect(inBar(find.byTooltip('Pause')), findsOneWidget);
      expect(inBar(find.byTooltip('Next track')), findsOneWidget);
      expect(inBar(find.byTooltip('Volume')), findsNothing);
      expect(inBar(find.byTooltip('Show queue')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  playerTest(
    'desktop metadata ellipsizes long titles at 840 with large text',
    platform: TargetPlatform.linux,
    size: const Size(840, 800),
    textScale: 1.5,
    tracks: const [
      Track(
        id: 'one',
        title:
            'An extraordinarily long track title that keeps on going well '
            'past the edge of the metadata column',
        artist:
            'A very long artist name featuring several collaborators and a '
            'remix credit',
      ),
    ],
    (tester, app, engine) async {
      expect(find.byType(DesktopPlayerBar), findsOneWidget);
      final title = find.textContaining('An extraordinarily long');
      expect(title, findsOneWidget);
      final titleRect = tester.getRect(title);
      final seekRect = tester.getRect(find.byType(PlaybackSeek));
      // Truncated metadata stays inside the left zone, clear of the seek
      // column, even at 1.5x text scale.
      expect(titleRect.right, lessThan(seekRect.left));
      expect(
        tester.getSize(find.byType(DesktopPlayerBar)).height,
        lessThan(120),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
