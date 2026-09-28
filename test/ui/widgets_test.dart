import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/ui/theme.dart';
import 'package:yun/ui/widgets.dart';

void main() {
  test('duration and byte formatting are deterministic', () {
    expect(formatDuration(const Duration(seconds: 65)), '1:05');
    expect(formatDuration(const Duration(hours: 2, seconds: 9)), '2:00:09');
    expect(formatBytes(2048), '2.0 KB');
    expect(formatDate(DateTime(2025, 3, 4)), '2025-03-04');
  });

  testWidgets('empty states fit large text and short viewports', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: YunTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: EmptyState(
              icon: Icons.music_note,
              title: 'Your music library',
              message: 'Connect to a server to get started.',
              action: FilledButton(
                onPressed: () {},
                child: const Text('Connect'),
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Your music library'), findsOneWidget);
  });

  testWidgets('reduced motion uses a static progress indicator', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(body: QuietProgress(label: 'Syncing')),
        ),
      ),
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('name dialog validates and trims names', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await askForName(context, title: 'New playlist');
              },
              child: const Text('Create'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a name'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '  Evening  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(result, 'Evening');
    expect(tester.takeException(), isNull);
  });
}
