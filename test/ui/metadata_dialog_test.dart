import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/ui/track_widgets.dart';

import '../core/fakes.dart';

class _MetadataApp extends AppController {
  _MetadataApp()
    : super(
        playbackEngine: FakeEngine(),
        enableSystemControls: false,
        automaticRefresh: false,
      );
  final updates = <Map<String, dynamic>>[];
  @override
  Future<Track> updateTrack(Track track, Map<String, dynamic> fields) async {
    updates.add(fields);
    return Track.fromJson({...track.toJson(), ...fields});
  }
}

void main() {
  Future<_MetadataApp> open(WidgetTester tester, Track track) async {
    final app = _MetadataApp();
    addTearDown(app.dispose);
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => MetadataDialog(app: app, track: track),
              ),
              child: const Text('Edit'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    return app;
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  testWidgets(
    'untouched nullable metadata fields display blank and submit null',
    (tester) async {
      final app = await open(
        tester,
        const Track(id: 'track', title: 'Original'),
      );
      expect(
        tester.widget<TextFormField>(field('Track number')).controller!.text,
        '',
      );
      expect(
        tester.widget<TextFormField>(field('Disc number')).controller!.text,
        '',
      );
      await tester.enterText(field('Title'), ' Title only ');
      await tester.tap(find.text('Save metadata'));
      await tester.pumpAndSettle();
      expect(app.updates, hasLength(1));
      expect(app.updates.single['title'], 'Title only');
      expect(app.updates.single['track_number'], isNull);
      expect(app.updates.single['disc_number'], isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('blank input clears previously numbered tracks', (tester) async {
    final app = await open(
      tester,
      const Track(
        id: 'track',
        title: 'Original',
        trackNumber: 12,
        discNumber: 2,
      ),
    );
    expect(
      tester.widget<TextFormField>(field('Track number')).controller!.text,
      '12',
    );
    expect(
      tester.widget<TextFormField>(field('Disc number')).controller!.text,
      '2',
    );
    await tester.enterText(field('Track number'), '');
    await tester.enterText(field('Disc number'), '  ');
    await tester.tap(find.text('Save metadata'));
    await tester.pumpAndSettle();
    expect(app.updates, hasLength(1));
    expect(app.updates.single['track_number'], isNull);
    expect(app.updates.single['disc_number'], isNull);
  });

  testWidgets('numeric metadata enforces server range on both fields', (
    tester,
  ) async {
    final app = await open(tester, const Track(id: 'track', title: 'Original'));
    for (final invalid in ['0', '-1', '1000001', '1.5', 'oops']) {
      await tester.enterText(field('Track number'), invalid);
      await tester.enterText(field('Disc number'), invalid);
      await tester.tap(find.text('Save metadata'));
      await tester.pumpAndSettle();
      expect(app.updates, isEmpty, reason: invalid);
      expect(find.text('Enter 1–1,000,000 or leave blank'), findsNWidgets(2));
    }
    await tester.enterText(field('Track number'), ' 1 ');
    await tester.enterText(field('Disc number'), '1000000');
    await tester.tap(find.text('Save metadata'));
    await tester.pumpAndSettle();
    expect(app.updates, hasLength(1));
    expect(app.updates.single['track_number'], 1);
    expect(app.updates.single['disc_number'], 1000000);
    expect(tester.takeException(), isNull);
  });
}
