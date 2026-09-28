import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yun/main.dart';
import 'package:yun/core/app_controller.dart';

void main() {
  testWidgets('startup storage failure is recoverable, not a blank screen', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      YunBootstrap(
        controllerFactory: () => AppController(
          storageDirectory: () =>
              Future.error(StateError('Storage unavailable')),
          enableSystemControls: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, '韵');
    expect(find.text('韵'), findsOneWidget);
    expect(find.text('Your library could not be opened.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
