import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/ui/player.dart';
import 'package:yun/ui/theme.dart';
import 'package:yun/ui/track_widgets.dart';

import '../core/fakes.dart';
import 'player_test_app.dart';

const _longArtist =
    'An exceptionally long artist name with many collaborators and guest musicians';

class _TrackApp extends PlayerTestApp {
  _TrackApp() : super(FakeEngine());

  DownloadStatus status = DownloadStatus.availableOnline;

  @override
  DownloadProgress downloadProgress(Track track) => DownloadProgress(
    trackId: track.id,
    totalBytes: 2048,
    receivedBytes: 1024,
    status: status,
  );
}

Future<void> _show(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: YunTheme.light(),
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _close(WidgetTester tester, PlayerTestApp app) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(app.shutdown);
  app.dispose();
}

void main() {
  for (final reported in [320, null]) {
    testWidgets('TrackInfo labels and explains bitrate (reported=$reported)', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      try {
        final exact = reported == 320;
        final bitrate = exact ? 320 : 128;
        final label = '· ${exact ? '' : '~'}$bitrate kbps';
        final semanticLabel =
            '${exact ? 'Bitrate' : 'Estimated bitrate'}: $bitrate kilobits per second';
        final tooltip = exact
            ? 'Audio bitrate'
            : 'Estimated average bitrate from file size and duration';
        await _show(
          tester,
          TrackInfo(
            track: Track(
              id: 'track',
              title: 'Song',
              artist: 'Artist',
              bitrateKbps: reported,
              sizeBytes: 4800000,
              durationMs: 300000,
            ),
          ),
        );
        expect(find.text('Artist'), findsOneWidget);
        expect(find.text(label), findsOneWidget);
        expect(find.bySemanticsLabel(semanticLabel), findsOneWidget);
        expect(find.bySemanticsLabel(label), findsNothing);
        expect(
          tester.widget<Tooltip>(find.byTooltip(tooltip)).excludeFromSemantics,
          isTrue,
        );
        await tester.longPress(find.text(label));
        await tester.pumpAndSettle();
        expect(find.text(tooltip), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
      }
    });
  }

  testWidgets('unknown bitrate stays hidden without hiding artist or status', (
    tester,
  ) async {
    for (final track in const [
      Track(id: 'missing', title: 'Missing'),
      Track(id: 'zero', title: 'Zero', bitrateKbps: 0),
      Track(
        id: 'invalid',
        title: 'Invalid',
        bitrateKbps: -1,
        sizeBytes: 4800000,
        durationMs: -1,
      ),
    ]) {
      await _show(
        tester,
        TrackInfo(track: track, status: const Text('· Verifying download')),
      );
      expect(find.text('Unknown artist'), findsOneWidget);
      expect(find.text('· Verifying download'), findsOneWidget);
      expect(find.textContaining('kbps'), findsNothing);
      expect(find.byType(Tooltip), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'TrackTile fits long artist and bitrate at 2x in every download state',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final app = _TrackApp();
      try {
        await _show(
          tester,
          TrackTile(
            app: app,
            track: const Track(
              id: 'track',
              title: 'Song',
              artist: _longArtist,
              bitrateKbps: 320,
            ),
          ),
        );
        final artist = tester.widget<Text>(find.text(_longArtist));
        expect(artist.maxLines, 2);
        expect(artist.overflow, TextOverflow.ellipsis);
        for (final (status, label, icon) in [
          (
            DownloadStatus.availableOnline,
            'Available online',
            Icons.cloud_outlined,
          ),
          (DownloadStatus.downloaded, 'Downloaded', Icons.offline_pin_outlined),
          (DownloadStatus.queued, 'Queued · 1.0 KB / 2.0 KB', null),
          (DownloadStatus.downloading, 'Downloading · 1.0 KB / 2.0 KB', null),
          (DownloadStatus.verifying, 'Verifying download', null),
          (DownloadStatus.failed, 'Download failed · 1.0 KB / 2.0 KB', null),
        ]) {
          app.status = status;
          app.downloadChanges.notifyListeners();
          await tester.pumpAndSettle();
          expect(find.text('· 320 kbps'), findsOneWidget);
          expect(find.text(_longArtist), findsOneWidget);
          for (final availabilityIcon in [
            Icons.cloud_outlined,
            Icons.offline_pin_outlined,
          ]) {
            expect(
              find.byIcon(availabilityIcon),
              availabilityIcon == icon ? findsOneWidget : findsNothing,
            );
          }
          if (icon == null) {
            expect(find.text('· $label'), findsOneWidget);
          } else {
            expect(find.byTooltip(label), findsOneWidget);
            expect(tester.widget<Icon>(find.byIcon(icon)).semanticLabel, label);
          }
          final bitrateRect = tester.getRect(find.text('· 320 kbps'));
          expect(bitrateRect.right, lessThanOrEqualTo(320));
          expect(bitrateRect.bottom, lessThanOrEqualTo(800));
          expect(tester.takeException(), isNull, reason: status.name);
        }
      } finally {
        await _close(tester, app);
      }
    },
  );

  testWidgets(
    'queue keeps each track bitrate and current/queued status distinct',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      const tracks = [
        Track(
          id: 'exact',
          title: 'Exact',
          artist: _longArtist,
          bitrateKbps: 320,
        ),
        Track(
          id: 'other',
          title: 'Other',
          artist: _longArtist,
          bitrateKbps: 192,
        ),
        Track(id: 'unknown', title: 'Unknown', artist: _longArtist),
      ];
      const legacy = Track(
        id: 'legacy',
        title: 'Legacy',
        artist: _longArtist,
        sizeBytes: 4800000,
        durationMs: 300000,
      );
      Finder info(String id) => find.byWidgetPredicate(
        (widget) => widget is TrackInfo && widget.track.id == id,
      );
      Finder status(String id, String text) =>
          find.descendant(of: info(id), matching: find.text(text));
      final app = PlayerTestApp(FakeEngine());
      try {
        await app.playback.playQueue(tracks);
        await app.playback.queueNext(legacy);
        await _show(tester, QueuePanel(app: app));
        expect(status('exact', 'Now playing'), findsOneWidget);
        expect(status('legacy', 'Queued next'), findsOneWidget);
        for (final advance in [false, true]) {
          if (advance) {
            await app.playback.next();
            await tester.pumpAndSettle();
            expect(status('legacy', 'Now playing'), findsOneWidget);
            expect(status('exact', 'Now playing'), findsNothing);
          }
          for (final (id, label) in [
            ('exact', '· 320 kbps'),
            ('other', '· 192 kbps'),
            ('legacy', '· ~128 kbps'),
          ]) {
            expect(status(id, label), findsOneWidget);
          }
          // No Flutter overflow exception is raised when a ListTile's child
          // spills outside a fixed itemExtent. Assert actual row containment.
          for (final tile in find.byType(ListTile).evaluate()) {
            final row = find.byElementPredicate((element) => element == tile);
            final rowRect = tester.getRect(row);
            final texts = find.descendant(of: row, matching: find.byType(Text));
            for (final text in texts.evaluate()) {
              final textRect = tester.getRect(
                find.byElementPredicate((element) => element == text),
              );
              expect(textRect.top, greaterThanOrEqualTo(rowRect.top));
              expect(textRect.bottom, lessThanOrEqualTo(rowRect.bottom));
            }
          }
          expect(info('unknown'), findsOneWidget);
          expect(
            find.descendant(
              of: info('unknown'),
              matching: find.textContaining('kbps'),
            ),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        }
      } finally {
        await _close(tester, app);
      }
    },
  );
}
