import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
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
      ) {
    account = const Account(
      server: 'https://a.test',
      userId: 'a',
      username: 'a',
    );
  }
  final artwork = <Uint8List>[];
  @override
  Future<Track> setArtwork(
    Track track,
    Uint8List bytes, {
    String mimeType = 'image/jpeg',
  }) async {
    artwork.add(bytes);
    return track;
  }

  final updates = <Map<String, dynamic>>[];
  @override
  Future<Track> updateTrack(Track track, Map<String, dynamic> fields) async {
    updates.add(fields);
    return Track.fromJson({...track.toJson(), ...fields});
  }
}

class _Picker extends FilePicker {
  final result = Completer<FilePickerResult?>();
  bool? requestedData, requestedStream;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) {
    requestedData = withData;
    requestedStream = withReadStream;
    return result.future;
  }
}

void main() {
  FilePicker.platform = _Picker();
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

  testWidgets('an old metadata dialog cannot edit another account', (
    tester,
  ) async {
    final app = await open(
      tester,
      const Track(id: 'shared', title: 'Original'),
    );
    app.account = const Account(
      server: 'https://b.test',
      userId: 'b',
      username: 'b',
    );
    await tester.tap(find.text('Save metadata'));
    await tester.pumpAndSettle();
    expect(app.updates, isEmpty);
    expect(find.textContaining('Account changed'), findsOneWidget);
  });

  for (final oversized in [false, true]) {
    testWidgets('artwork uses bounded streaming (oversized=$oversized)', (
      tester,
    ) async {
      final picker = _Picker();
      final previous = FilePicker.platform;
      FilePicker.platform = picker;
      addTearDown(() => FilePicker.platform = previous);
      final app = await open(
        tester,
        const Track(id: 'track', title: 'Original'),
      );
      await tester.tap(find.text('Replace artwork'));
      await tester.pump();
      await tester.runAsync(() async {
        picker.result.complete(
          FilePickerResult([
            PlatformFile(
              name: 'cover.png',
              size: 3,
              readStream: Stream.fromIterable(
                oversized
                    ? [
                        Uint8List(10 * 1024 * 1024),
                        [1],
                      ]
                    : [
                        [1, 2],
                        [3],
                      ],
              ),
            ),
          ]),
        );
        // Allow the stream's cancellation future to settle on the real clock.
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pumpAndSettle();
      expect(picker.requestedData, isFalse);
      expect(picker.requestedStream, isTrue);
      expect(
        app.artwork,
        oversized
            ? isEmpty
            : [
                [1, 2, 3],
              ],
      );
      if (oversized) {
        expect(find.textContaining('no larger than 10 MB'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('account change during artwork selection does not upload', (
    tester,
  ) async {
    final picker = _Picker();
    final previous = FilePicker.platform;
    FilePicker.platform = picker;
    addTearDown(() => FilePicker.platform = previous);
    final app = await open(
      tester,
      const Track(id: 'shared', title: 'Original'),
    );
    await tester.tap(find.text('Replace artwork'));
    await tester.pump();
    app.account = const Account(
      server: 'https://b.test',
      userId: 'b',
      username: 'b',
    );
    picker.result.complete(
      FilePickerResult([
        PlatformFile(
          name: 'cover.png',
          size: 3,
          bytes: Uint8List.fromList([1, 2, 3]),
          readStream: Stream.value([1, 2, 3]),
        ),
      ]),
    );
    await tester.pumpAndSettle();
    expect(app.artwork, isEmpty);
    expect(find.textContaining('Account changed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
