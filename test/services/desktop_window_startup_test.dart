import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:yun/services/desktop_window_startup.dart';

Display _display({
  Size size = const Size(1920, 1080),
  Size? visibleSize = const Size(1920, 1040),
  Offset? origin = Offset.zero,
  double scale = 1,
}) => Display(
  id: 'primary',
  size: size,
  visibleSize: visibleSize,
  visiblePosition: origin,
  scaleFactor: scale,
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  group('initial desktop geometry', () {
    test('preferred outer size is centered in the work area', () {
      expect(
        initialDesktopWindowBounds(_display()),
        const Rect.fromLTWH(320, 160, 1280, 720),
      );
    });

    test('taskbar offsets and negative screen coordinates are respected', () {
      final bounds = initialDesktopWindowBounds(
        _display(
          visibleSize: const Size(1200, 700),
          origin: const Offset(-1280, -740),
        ),
      );
      expect(bounds, const Rect.fromLTWH(-1220, -705, 1080, 630));
    });

    test('logical dimensions are not scaled a second time', () {
      for (final scale in [1.0, 1.5, 2.0]) {
        final bounds = initialDesktopWindowBounds(
          _display(
            size: Size(1366 / scale, 768 / scale),
            visibleSize: Size(1366 / scale, 728 / scale),
            scale: scale,
          ),
        );
        expect(bounds.width, lessThanOrEqualTo(1366 / scale * .9));
        expect(bounds.height, lessThanOrEqualTo(728 / scale * .9));
        expect(bounds.width, lessThanOrEqualTo(1280));
        expect(bounds.height, lessThanOrEqualTo(720));
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.top, greaterThanOrEqualTo(0));
      }
    });

    test('GTK titlebar is included in the outer-window budget', () {
      final bounds = initialDesktopWindowBounds(
        _display(visibleSize: const Size(1000, 600)),
        gtk: true,
      );
      expect(bounds, const Rect.fromLTWH(50, 30, 900, 492));
      expect(bounds.height + 48, 600 * .9);
    });

    test('tiny screens do not acquire a larger minimum size', () {
      final bounds = initialDesktopWindowBounds(
        _display(visibleSize: const Size(40, 40)),
        gtk: true,
      );
      expect(bounds.width, 36);
      expect(bounds.height, 1);
      expect(bounds.top, 2);
    });

    test('missing work-area details use the display size and origin zero', () {
      expect(
        initialDesktopWindowBounds(
          _display(size: const Size(800, 600), visibleSize: null, origin: null),
        ),
        const Rect.fromLTWH(40, 30, 720, 540),
      );
    });

    test('invalid work areas are rejected without invalid native bounds', () {
      for (final size in [
        Size.zero,
        const Size(-1, 600),
        const Size(double.nan, 600),
        const Size(800, double.infinity),
      ]) {
        expect(
          () => initialDesktopWindowBounds(_display(visibleSize: size)),
          throwsStateError,
        );
      }
      expect(
        () => initialDesktopWindowBounds(
          _display(origin: const Offset(double.infinity, 0)),
        ),
        throwsStateError,
      );
    });
  });

  group('desktop startup channels', () {
    const windowChannel = MethodChannel('window_manager');
    const screenChannel = MethodChannel(
      'dev.leanflutter.plugins/screen_retriever',
    );
    const startupChannel = MethodChannel('yun/desktop_startup');
    late List<MethodCall> windows;
    late List<MethodCall> screens;
    late List<MethodCall> startup;
    late Display display;
    String? failWindow;
    bool failDisplay = false;
    Completer<void>? windowGate;
    Completer<void>? boundsGate;
    Completer<Display>? displayGate;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      windows = [];
      screens = [];
      startup = [];
      display = _display();
      failWindow = null;
      failDisplay = false;
      windowGate = null;
      boundsGate = null;
      displayGate = null;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(windowChannel, (
        call,
      ) async {
        windows.add(call);
        if (call.method == failWindow) throw PlatformException(code: 'window');
        if (call.method == 'ensureInitialized') await windowGate?.future;
        if (call.method == 'setBounds') await boundsGate?.future;
        return null;
      });
      binding.defaultBinaryMessenger.setMockMethodCallHandler(screenChannel, (
        call,
      ) async {
        screens.add(call);
        if (failDisplay) throw PlatformException(code: 'display');
        return (await displayGate?.future ?? display).toJson();
      });
      binding.defaultBinaryMessenger.setMockMethodCallHandler(startupChannel, (
        call,
      ) async {
        startup.add(call);
        return null;
      });
    });

    tearDown(() {
      for (final channel in [windowChannel, screenChannel, startupChannel]) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
      debugDefaultTargetPlatformOverride = null;
    });

    for (final platform in [
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.linux,
    ]) {
      test(
        '${platform.name}: size and position use the same primary area',
        () async {
          debugDefaultTargetPlatformOverride = platform;
          await configureDesktopWindow(environment: {});
          expect(windows.map((call) => call.method), [
            'ensureInitialized',
            'setBounds',
          ]);
          expect(screens.map((call) => call.method), ['getPrimaryDisplay']);
          final arguments = windows.last.arguments as Map;
          final bounds = initialDesktopWindowBounds(
            display,
            gtk: platform == TargetPlatform.linux,
          );
          expect(arguments['x'], bounds.left);
          expect(arguments['y'], bounds.top);
          expect(arguments['width'], bounds.width);
          expect(arguments['height'], bounds.height);
          expect(arguments['animate'], isFalse);
          expect(startup, isEmpty);
        },
      );
    }

    test(
      'Windows payload uses the native view DPI for physical conversion',
      () async {
        // window_manager 0.5.2 reads dart:ui's native window, not tester.view's
        // mocked metrics. Exercise that actual conversion boundary explicitly.
        final scale = PlatformDispatcher.instance.views.single.devicePixelRatio;
        display = _display(
          size: Size(1366 / scale, 768 / scale),
          visibleSize: Size(1366 / scale, 728 / scale),
          origin: Offset(0, 40 / scale),
          scale: scale,
        );
        await configureDesktopWindow(environment: {});
        final args = windows.last.arguments as Map;
        expect(args['devicePixelRatio'], scale);
        final x = (args['x'] as double) * scale;
        final y = (args['y'] as double) * scale;
        final width = (args['width'] as double) * scale;
        final height = (args['height'] as double) * scale;
        expect(width, lessThanOrEqualTo(1366 * .9));
        expect(height, lessThanOrEqualTo(728 * .9));
        expect(x, greaterThanOrEqualTo(0));
        expect(y, greaterThanOrEqualTo(40));
        expect(x + width, lessThanOrEqualTo(1366));
        expect(y + height, lessThanOrEqualTo(768));
      },
    );

    for (final env in [
      {'XDG_SESSION_TYPE': 'wayland'},
      {'WAYLAND_DISPLAY': 'wayland-1'},
    ]) {
      test('Wayland requests size only: $env', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.linux;
        await configureDesktopWindow(environment: env);
        final arguments = windows.last.arguments as Map;
        expect(arguments['width'], 1280);
        expect(arguments['height'], 720);
        expect(arguments.containsKey('x'), isFalse);
        expect(arguments.containsKey('y'), isFalse);
      });
    }

    test('mobile never calls native desktop APIs', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await configureDesktopWindow();
      await revealDesktopWindow();
      expect(windows, isEmpty);
      expect(screens, isEmpty);
      expect(startup, isEmpty);
    });

    for (final method in ['ensureInitialized', 'setBounds']) {
      test('window failure at $method is nonfatal', () async {
        failWindow = method;
        await configureDesktopWindow(environment: {});
        expect(windows.last.method, method);
        expect(startup, isEmpty);
      });
    }

    test('display failure retains the fitted native fallback', () async {
      failDisplay = true;
      await configureDesktopWindow(environment: {});
      expect(windows.map((call) => call.method), ['ensureInitialized']);
    });

    test('invalid display data never reaches setBounds', () async {
      display = _display(visibleSize: Size.zero);
      await configureDesktopWindow(environment: {});
      expect(windows.map((call) => call.method), ['ensureInitialized']);
    });

    testWidgets('late display result cannot resize after startup timeout', (
      tester,
    ) async {
      displayGate = Completer<Display>();
      var complete = false;
      final sizing = configureDesktopWindow(
        environment: {},
        timeout: const Duration(seconds: 1),
      ).then((_) => complete = true);
      await tester.pump();
      expect(complete, isFalse);
      await tester.pump(const Duration(seconds: 1));
      await sizing;
      expect(complete, isTrue);
      displayGate!.complete(display);
      await tester.pump();
      expect(windows.map((call) => call.method), ['ensureInitialized']);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('late plugin initialization cannot configure a shown window', (
      tester,
    ) async {
      windowGate = Completer<void>();
      final sizing = configureDesktopWindow(
        environment: {},
        timeout: const Duration(seconds: 1),
      );
      await tester.pump(const Duration(seconds: 1));
      await sizing;
      windowGate!.complete();
      await tester.pump();
      expect(screens, isEmpty);
      expect(windows.map((call) => call.method), ['ensureInitialized']);
      debugDefaultTargetPlatformOverride = null;
    });

    for (final lateError in [false, true]) {
      testWidgets('delayed geometry response is nonfatal (error: $lateError)', (
        tester,
      ) async {
        boundsGate = Completer<void>();
        final sizing = configureDesktopWindow(
          environment: {},
          timeout: const Duration(seconds: 1),
        );
        await tester.pump();
        expect(windows.last.method, 'setBounds');
        await tester.pump(const Duration(seconds: 1));
        await sizing;
        // Future.timeout cannot cancel native geometry already issued. Current
        // plugins apply it synchronously; late acknowledgments/errors are safe.
        if (lateError) {
          boundsGate!.completeError(PlatformException(code: 'late-bounds'));
        } else {
          boundsGate!.complete();
        }
        await tester.pump();
        expect(
          windows.where((call) => call.method == 'setBounds'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      });
    }

    test(
      'macOS has a separate first-frame reveal, not a tray operation',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        await revealDesktopWindow();
        expect(startup.map((call) => call.method), ['ready']);
        expect(windows, isEmpty);
        expect(screens, isEmpty);
      },
    );

    test('missing macOS reveal channel is nonfatal', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        startupChannel,
        null,
      );
      await revealDesktopWindow();
    });
  });
}
