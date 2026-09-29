import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/ui/uploads.dart';

import '../core/fakes.dart';

class _UploadsApp extends AppController {
  _UploadsApp(List<UploadJob> jobs)
    : _jobs = List.of(jobs),
      super(
        playbackEngine: FakeEngine(),
        enableSystemControls: false,
        automaticRefresh: false,
      );

  final List<UploadJob> _jobs;
  int clearCalls = 0;
  final retried = <String>[];
  final cancelled = <String>[];

  @override
  List<UploadJob> get uploads => List.unmodifiable(_jobs);

  void setStatus(String id, String status) {
    final index = _jobs.indexWhere((job) => job.id == id);
    _jobs[index] = _jobs[index].copyWith(status: status);
    notifyListeners();
  }

  void add(UploadJob job) {
    _jobs.add(job);
    notifyListeners();
  }

  @override
  Future<void> clearDoneUploads() async {
    clearCalls++;
    _jobs.removeWhere((job) => job.status == 'done');
    notifyListeners();
  }

  @override
  Future<void> retryUpload(String id) async {
    retried.add(id);
    setStatus(id, 'queued');
  }

  @override
  Future<void> cancelUpload(String id) async {
    cancelled.add(id);
    setStatus(id, 'cancelled');
  }
}

UploadJob _job(String id, String status) => UploadJob(
  id: id,
  localPath: '/imports/$id.source',
  filename: '$id.wav',
  sizeBytes: 100,
  offset: 50,
  status: status,
);

void main() {
  Future<_UploadsApp> open(WidgetTester tester, List<UploadJob> jobs) async {
    final app = _UploadsApp(jobs);
    addTearDown(app.dispose);
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showUploads(context, app),
              child: const Text('Open uploads'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open uploads'));
    // Completing uploads have an indeterminate progress indicator.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    return app;
  }

  Finder getScroll() => find
      .descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Scrollable),
      )
      .first;

  Future<void> reveal(WidgetTester tester, Finder target) async {
    final scroll = getScroll();
    tester.state<ScrollableState>(scroll).position.jumpTo(0);
    await tester.pump();
    await tester.scrollUntilVisible(target, 80, scrollable: scroll);
    await tester.pump();
  }

  Future<double> position(WidgetTester tester, String text) async {
    await reveal(tester, find.text(text));
    return tester.getTopLeft(find.text(text)).dy +
        tester.state<ScrollableState>(getScroll()).position.pixels;
  }

  Future<void> expectGroups(
    WidgetTester tester, {
    required List<String> pending,
    required List<String> done,
    required List<String> failed,
  }) async {
    var previous = double.negativeInfinity;
    for (final section in {
      'Pending': pending,
      'Done': done,
      'Failed': failed,
    }.entries) {
      final headingY = await position(tester, section.key);
      expect(headingY, greaterThan(previous));
      previous = headingY;
      // The count is separate from the exact heading text. Find the smallest
      // header ancestor containing more than just the heading's Text widget.
      var checkedCount = false;
      tester.element(find.text(section.key)).visitAncestorElements((element) {
        final texts = find
            .descendant(
              of: find.byWidget(element.widget),
              matching: find.byType(Text),
            )
            .evaluate()
            .map((element) => (element.widget as Text).data)
            .toList();
        if (texts.length < 2) return true;
        expect(texts, contains('${section.value.length}'));
        checkedCount = true;
        return false;
      });
      expect(checkedCount, isTrue);
      for (final id in section.value) {
        final jobY = await position(tester, '$id.wav');
        expect(jobY, greaterThan(previous));
        previous = jobY;
      }
    }
    expect(tester.takeException(), isNull);
  }

  Finder clearButton() => find.widgetWithText(TextButton, 'Clear done');

  testWidgets('groups every status with separate counts and keeps cancelled', (
    tester,
  ) async {
    final app = await open(tester, [
      _job('cancelled', 'cancelled'),
      _job('done', 'done'),
      _job('queued', 'queued'),
      _job('failed', 'failed'),
      _job('uploading', 'uploading'),
      _job('completing', 'completing'),
    ]);
    await expectGroups(
      tester,
      pending: ['queued', 'uploading', 'completing'],
      done: ['done'],
      failed: ['cancelled', 'failed'],
    );
    await reveal(tester, find.text('cancelled.wav'));
    expect(
      find.textContaining('Cancelled · choose the file again to upload'),
      findsOneWidget,
    );
    expect(find.byTooltip('Retry cancelled.wav'), findsNothing);
    expect(find.byTooltip('Cancel cancelled.wav'), findsNothing);
    expect(app.uploads.first.status, 'cancelled');
    expect(tester.widget<TextButton>(clearButton()).onPressed, isNotNull);
  });

  testWidgets('regroups and updates counts while the dialog remains open', (
    tester,
  ) async {
    final app = await open(tester, [
      _job('first', 'queued'),
      _job('second', 'done'),
      _job('third', 'failed'),
    ]);
    await expectGroups(
      tester,
      pending: ['first'],
      done: ['second'],
      failed: ['third'],
    );
    app.setStatus('first', 'done');
    await tester.pump();
    await expectGroups(
      tester,
      pending: [],
      done: ['first', 'second'],
      failed: ['third'],
    );
    await reveal(tester, find.byTooltip('Retry third.wav'));
    await tester.tap(find.byTooltip('Retry third.wav'));
    await tester.pump();
    expect(app.retried, ['third']);
    await expectGroups(
      tester,
      pending: ['third'],
      done: ['first', 'second'],
      failed: [],
    );
    await reveal(tester, find.byTooltip('Cancel third.wav'));
    await tester.tap(find.byTooltip('Cancel third.wav'));
    await tester.pump();
    expect(app.cancelled, ['third']);
    expect(app.uploads.last.status, 'cancelled');
    await expectGroups(
      tester,
      pending: [],
      done: ['first', 'second'],
      failed: ['third'],
    );
  });

  testWidgets('clear done preserves all other jobs and becomes disabled', (
    tester,
  ) async {
    final app = await open(tester, [
      _job('done', 'done'),
      _job('queued', 'queued'),
      _job('uploading', 'uploading'),
      _job('completing', 'completing'),
      _job('failed', 'failed'),
      _job('cancelled', 'cancelled'),
      _job('also-done', 'done'),
    ]);
    final retained = app.uploads
        .where((job) => job.status != 'done')
        .map((job) => job.toJson())
        .toList();
    expect(tester.widget<TextButton>(clearButton()).onPressed, isNotNull);
    await tester.tap(clearButton());
    await tester.pump();
    expect(app.clearCalls, 1);
    expect(app.uploads.map((job) => job.toJson()).toList(), retained);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('done.wav'), findsNothing);
    expect(find.text('also-done.wav'), findsNothing);
    await expectGroups(
      tester,
      pending: ['queued', 'uploading', 'completing'],
      done: [],
      failed: ['failed', 'cancelled'],
    );
    expect(tester.widget<TextButton>(clearButton()).onPressed, isNull);
    await tester.tap(clearButton());
    await tester.pump();
    expect(app.clearCalls, 1);
    expect(app.retried, isEmpty);
    expect(app.cancelled, isEmpty);
  });

  testWidgets(
    'clear done is disabled for an empty queue and reacts to new jobs',
    (tester) async {
      final app = await open(tester, []);
      expect(tester.widget<TextButton>(clearButton()).onPressed, isNull);
      await tester.tap(clearButton());
      await tester.pump();
      expect(app.clearCalls, 0);
      app.add(_job('finished', 'done'));
      await tester.pump();
      expect(tester.widget<TextButton>(clearButton()).onPressed, isNotNull);
      await tester.tap(clearButton());
      await tester.pump();
      expect(app.clearCalls, 1);
      expect(app.uploads, isEmpty);
      expect(tester.widget<TextButton>(clearButton()).onPressed, isNull);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
