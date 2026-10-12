import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:yun/services/desktop_window_startup.dart';

class _StartupBinding extends AutomatedTestWidgetsFlutterBinding {
  final events = <String>[];
  Completer<void> rasterized = Completer<void>();

  @override
  void deferFirstFrame() {
    events.add('defer');
    super.deferFirstFrame();
  }

  @override
  void allowFirstFrame() {
    events.add('allow');
    super.allowFirstFrame();
  }

  @override
  Future<void> get waitUntilFirstFrameRasterized => rasterized.future;
}

void main() {
  final binding = _StartupBinding();
  const windows = MethodChannel('window_manager');
  const screens = MethodChannel('dev.leanflutter.plugins/screen_retriever');
  const startup = MethodChannel('yun/desktop_startup');
  Completer<void>? displayGate;
  bool failDisplay = false;

  setUp(() {
    binding.events.clear();
    binding.rasterized = Completer<void>();
    displayGate = null;
    failDisplay = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(windows, (
      call,
    ) async {
      binding.events.add(call.method);
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(screens, (
      call,
    ) async {
      binding.events.add(call.method);
      await displayGate?.future;
      if (failDisplay) throw PlatformException(code: 'display');
      return const Display(
        id: 'primary',
        size: Size(1920, 1080),
        visibleSize: Size(1920, 1040),
        visiblePosition: Offset.zero,
      ).toJson();
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(startup, (
      call,
    ) async {
      binding.events.add(call.method);
      return null;
    });
  });

  tearDown(() {
    for (final channel in [windows, screens, startup]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    testWidgets('${platform.name}: configure before launch and first reveal', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        binding.rasterized = Completer<void>();
        displayGate = Completer<void>();
        final launching = launchWithDesktopWindow(
          () => binding.events.add('runApp'),
        );
        await tester.pump();
        expect(binding.events, [
          'defer',
          'ensureInitialized',
          'getPrimaryDisplay',
        ]);
        displayGate!.complete();
        await launching;
        expect(binding.events, [
          'defer',
          'ensureInitialized',
          'getPrimaryDisplay',
          'setBounds',
          'runApp',
          'allow',
        ]);
        // macOS must not reveal merely because sizing or runApp completed.
        binding.rasterized.complete();
        await tester.pump();
        expect(
          binding.events.where((event) => event == 'ready'),
          platform == TargetPlatform.macOS ? ['ready'] : isEmpty,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  for (final timeout in [false, true]) {
    testWidgets(
      'configuration ${timeout ? 'timeout' : 'error'} still launches',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        try {
          binding.rasterized = Completer<void>();
          failDisplay = !timeout;
          if (timeout) displayGate = Completer<void>();
          final launching = launchWithDesktopWindow(
            () => binding.events.add('runApp'),
          );
          await tester.pump();
          if (timeout) await tester.pump(const Duration(seconds: 3));
          await launching;
          expect(binding.events, [
            'defer',
            'ensureInitialized',
            'getPrimaryDisplay',
            'runApp',
            'allow',
          ]);
          binding.rasterized.complete();
          await tester.pump();
          expect(binding.events.last, 'ready');
          if (timeout) {
            displayGate!.complete();
            await tester.pump();
            expect(binding.events, isNot(contains('setBounds')));
          }
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('${platform.name}: launch without desktop calls or deferral', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await launchWithDesktopWindow(() => binding.events.add('runApp'));
        expect(binding.events, ['runApp']);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('a throwing launch callback still releases frame deferral', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await expectLater(
        launchWithDesktopWindow(() => throw StateError('launch failed')),
        throwsStateError,
      );
      expect(binding.events.last, 'allow');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
