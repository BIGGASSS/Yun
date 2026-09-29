import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yun/services/linux_status_notifier_tray.dart';
import 'package:yun/services/native_desktop_host.dart';

class _ControlledAvailability implements LinuxDesktopTray {
  void Function()? show;
  void Function()? quit;
  bool failInitialize = false;
  bool failDispose = false;

  bool available = true;
  int initializations = 0;
  int checks = 0;
  int disposals = 0;
  void Function(bool)? changed;
  Completer<bool>? pendingCheck;

  @override
  Future<void> initialize({
    required void Function() onShow,
    required void Function() onQuit,
    required void Function(bool) onChanged,
    required void Function(Object) onError,
  }) async {
    initializations++;
    if (failInitialize) throw PlatformException(code: 'tray');
    show = onShow;
    quit = onQuit;
    changed = onChanged;
    onChanged(available);
  }

  @override
  Future<bool> check() async {
    checks++;
    return pendingCheck?.future ?? available;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    if (failDispose) throw PlatformException(code: 'tray');
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');
  const trayChannel = MethodChannel('tray_manager');
  const codec = StandardMethodCodec();

  group('NativeDesktopHost (mock plugins only)', () {
    late _ControlledAvailability availability;
    late NativeDesktopHost host;
    late List<MethodCall> windows;
    late List<MethodCall> tray;
    late List<bool> changes;
    late List<Object> errors;
    late int closes;
    late int shows;
    late int quits;
    bool minimized = false;
    String? failWindow;
    String? failTray;
    Completer<void>? initializeGate;
    Future<void> Function(MethodCall)? windowHook;

    Future<void> initialize({
      void Function()? onShow,
      void Function(Object)? onError,
    }) => host.initialize(
      onClose: () => closes++,
      onShow: onShow ?? () => shows++,
      onQuit: () => quits++,
      onTrayAvailabilityChanged: changes.add,
      onError: onError ?? errors.add,
    );

    Future<void> windowEvent(String name) async {
      final response = Completer<void>();
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        windowChannel.name,
        codec.encodeMethodCall(MethodCall('onEvent', {'eventName': name})),
        (data) {
          if (data != null) codec.decodeEnvelope(data);
          response.complete();
        },
      );
      await response.future;
    }

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      // No real bus or native tray APIs in adapter tests.
      availability = _ControlledAvailability();
      host = NativeDesktopHost(linuxTray: availability);
      windows = [];
      tray = [];
      changes = [];
      errors = [];
      closes = shows = quits = 0;
      minimized = false;
      failWindow = failTray = null;
      initializeGate = null;
      windowHook = null;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(windowChannel, (
        call,
      ) async {
        windows.add(call);
        if (call.method == failWindow) throw PlatformException(code: 'window');
        if (call.method == 'ensureInitialized') await initializeGate?.future;
        await windowHook?.call(call);
        if (call.method == 'isMinimized') return minimized;
        if (call.method == 'restore') minimized = false;
        return null;
      });
      binding.defaultBinaryMessenger.setMockMethodCallHandler(trayChannel, (
        call,
      ) async {
        tray.add(call);
        if (call.method == failTray) throw PlatformException(code: 'tray');
        return null;
      });
    });

    tearDown(() async {
      await host.dispose();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        windowChannel,
        null,
      );
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        trayChannel,
        null,
      );
      debugDefaultTargetPlatformOverride = null;
      expect(windowManager.listeners, isNot(contains(host)));
      expect(trayManager.hasListeners, isFalse);
    });

    test(
      'Linux uses only Dart SNI callbacks, never AppIndicator APIs',
      () async {
        await initialize();
        expect(windows.map((c) => c.method), [
          'ensureInitialized',
          'setPreventClose',
        ]);
        expect(windows.last.arguments, {'isPreventClose': true});
        expect(tray, isEmpty);
        expect(trayManager.hasListeners, isFalse);
        expect(changes, [false, true]);
        host.onTrayIconMouseDown();
        host.onTrayIconRightMouseDown();
        expect(shows, 0);
        expect(tray, isEmpty);
        host.onTrayMenuItemClick(MenuItem(key: 'quit', label: 'Quit Yun'));
        expect(quits, 0);
        availability.show!();
        availability.quit!();
        await windowEvent('close');
        expect([shows, quits, closes], [1, 1, 1]);
        expect(errors, isEmpty);
      },
    );

    test(
      'unregistered Linux item keeps startup visible and can recover',
      () async {
        availability.available = false;
        await initialize();
        expect(changes, [false]);
        await expectLater(host.hide(), throwsStateError);
        expect(windows.map((c) => c.method), isNot(contains('hide')));
        availability.available = true;
        availability.changed!(true);
        await host.hide();
        expect(changes, [false, true]);
        expect(windows.last.method, 'hide');
        expect(tray, isEmpty);
      },
    );

    test(
      'Linux SNI activation and watcher loss use the restoration bridge',
      () async {
        var hidden = false;
        Future<void>? restoration;
        await host.initialize(
          onClose: () => closes++,
          onShow: () {
            restoration = host.show();
          },
          onQuit: () => quits++,
          onTrayAvailabilityChanged: (available) {
            changes.add(available);
            if (!available && hidden) restoration = host.show();
          },
          onError: errors.add,
        );
        await host.hide();
        minimized = true;
        windows.clear();
        availability.show!();
        await restoration;
        expect(
          windows.map((c) => c.method),
          containsAllInOrder(['restore', 'show', 'focus']),
        );
        expect(quits, 0);
        await host.hide();
        hidden = true;
        windows.clear();
        availability.available = false;
        availability.changed!(false);
        await restoration;
        expect(changes, [false, true, false]);
        expect(
          windows.map((c) => c.method),
          containsAllInOrder(['show', 'focus']),
        );
        expect(tray, isEmpty);
      },
    );

    test(
      'hide rechecks availability rather than trusting earlier success',
      () async {
        await initialize();
        expect(await host.checkTrayAvailability(), isTrue);
        availability.available = false;
        await expectLater(host.hide(), throwsStateError);
        expect(availability.checks, 2);
        expect(windows.map((c) => c.method), isNot(contains('hide')));
        expect(changes, [false, true, false]);
        availability.available = true;
        await host.hide();
        expect(availability.checks, 3);
        expect(windows.last.method, 'hide');
      },
    );

    test(
      'a late successful probe cannot enable hiding after disposal',
      () async {
        await initialize();
        availability.pendingCheck = Completer<bool>();
        final hiding = host.hide();
        final failedHide = expectLater(hiding, throwsStateError);
        await host.dispose();
        availability.pendingCheck!.complete(true);
        await failedHide;
        expect(await host.checkTrayAvailability(), isFalse);
        expect(windows.map((c) => c.method), isNot(contains('hide')));
      },
    );

    test('show restores minimized windows, then shows and focuses', () async {
      await host.show();
      expect(windows, isEmpty);
      await initialize();
      windows.clear();
      minimized = true;
      await host.show();
      expect(windows.map((c) => c.method), [
        'isMinimized',
        'restore',
        'isMinimized', // window_manager.show also checks the minimized state.
        'show',
        'focus',
      ]);
      windows.clear();
      minimized = false;
      await host.show();
      expect(windows.map((c) => c.method), [
        'isMinimized',
        'isMinimized',
        'show',
        'focus',
      ]);
    });

    test('failed quit can restore a hidden window after successful cleanup', () async {
      await initialize();
      await host.hide();
      await host.dispose();
      windows.clear();
      tray.clear();
      minimized = true;
      // DesktopController calls show if exitApplication throws after disposal.
      await host.show();
      expect(windows.map((c) => c.method), [
        'isMinimized',
        'restore',
        'isMinimized',
        'show',
        'focus',
      ]);
      expect(tray, isEmpty);
      expect(await host.checkTrayAvailability(), isFalse);
      expect(availability.disposals, 1);
      expect(windowManager.listeners, isNot(contains(host)));
    });

    test(
      'external focus reconciles hidden state once; own show has no feedback',
      () async {
        await initialize();
        await windowEvent('focus');
        expect(shows, 0);
        await host.hide();
        await windowEvent('focus');
        await windowEvent('focus');
        expect(shows, 1);
        await host.hide();
        windowHook = (call) async {
          if ([
            'isMinimized',
            'restore',
            'show',
            'focus',
          ].contains(call.method)) {
            await windowEvent('focus');
          }
        };
        minimized = true;
        await host.show();
        expect(shows, 1);
      },
    );

    test('hidden tracking precedes hide, and failed hide clears it', () async {
      await initialize();
      windowHook = (call) async {
        if (call.method == 'hide') await windowEvent('focus');
      };
      await host.hide();
      expect(shows, 1);
      failWindow = 'hide';
      await expectLater(host.hide(), throwsA(isA<PlatformException>()));
      await windowEvent('focus');
      expect(shows, 1);
    });

    test(
      'initialization and teardown are idempotent, including startup in flight',
      () async {
        initializeGate = Completer<void>();
        final first = initialize();
        final second = initialize();
        expect(identical(first, second), isTrue);
        final disposal = host.dispose();
        expect(identical(disposal, host.dispose()), isTrue);
        initializeGate!.complete();
        await first;
        await disposal;
        await initialize();
        expect(windows.map((c) => c.method), [
          'ensureInitialized',
          'setPreventClose',
          'setPreventClose',
        ]);
        expect(windows.last.arguments, {'isPreventClose': false});
        expect(tray, isEmpty);
        expect(availability.initializations, 0);
        expect(availability.disposals, 1);
        final snapshot = List<bool>.of(changes);
        host.onWindowClose();
        host.onTrayMenuItemClick(MenuItem(key: 'show', label: 'Show'));
        expect(closes + shows, 0);
        expect(changes, snapshot);
      },
    );

    test('successful initialization/teardown happen only once', () async {
      await initialize();
      await initialize();
      expect(availability.initializations, 1);
      expect(
        windowManager.listeners.where((item) => identical(item, host)),
        hasLength(1),
      );
      await host.dispose();
      await host.dispose();
      expect(tray, isEmpty);
      expect(
        windows
            .where((c) => c.method == 'setPreventClose')
            .map((c) => c.arguments),
        [
          {'isPreventClose': true},
          {'isPreventClose': false},
        ],
      );
      final snapshot = List<bool>.of(changes);
      availability.changed!(true);
      expect(changes, snapshot);
      expect(availability.disposals, 1);
    });

    test(
      'SNI setup failure keeps close interception but cannot hide',
      () async {
        availability.failInitialize = true;
        await initialize();
        expect(errors.single, isA<PlatformException>());
        expect(changes, [false]);
        expect(await host.checkTrayAvailability(), isFalse);
        await expectLater(host.hide(), throwsStateError);
        expect(tray, isEmpty);
        expect(trayManager.hasListeners, isFalse);
        expect(windowManager.listeners, contains(host));
        await windowEvent('close');
        expect(closes, 1);
        await host.dispose();
        expect(availability.disposals, 1);
      },
    );

    test(
      'tray teardown failure is reported but interception still releases',
      () async {
        await initialize();
        availability.failDispose = true;
        await host.dispose();
        await host.dispose();
        expect(errors.single, isA<PlatformException>());
        expect(availability.disposals, 1);
        expect(tray, isEmpty);
        expect(windows.last.arguments, {'isPreventClose': false});
        expect(windowManager.listeners, isNot(contains(host)));
      },
    );

    test('interception failure rolls back and never creates a tray', () async {
      failWindow = 'setPreventClose';
      await initialize();
      expect(errors, hasLength(2)); // setup and best-effort rollback
      expect(errors, everyElement(isA<PlatformException>()));
      expect(await host.checkTrayAvailability(), isFalse);
      expect(tray, isEmpty);
      expect(windowManager.listeners, isNot(contains(host)));
    });

    test(
      'sync and async callback failures are reported, not unhandled',
      () async {
        final syncError = StateError('sync callback');
        await initialize(onShow: () => throw syncError);
        availability.show!();
        await Future<void>.delayed(Duration.zero);
        expect(errors, [syncError]);
        final asyncError = StateError('async callback');
        await initialize(
          onShow: () async {
            await Future<void>.delayed(Duration.zero);
            throw asyncError;
          },
        );
        availability.show!();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(errors, [syncError, asyncError]);

        await initialize(
          onShow: () => throw syncError,
          onError: (_) async {
            await Future<void>.delayed(Duration.zero);
            throw StateError('reporter also failed');
          },
        );
        availability.show!();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        // flutter_test fails this test if either asynchronous error escapes.
      },
    );
  }, skip: !Platform.isLinux);

  group('NativeDesktopHost Windows (mock channels only)', () {
    const closeChannel = MethodChannel('yun/desktop_close');
    late NativeDesktopHost host;
    late List<MethodCall> bridge;
    late List<MethodCall> windows;
    late List<MethodCall> tray;
    late List<bool> changes;
    late List<Object> errors;
    late int closes;
    late int quits;
    bool hasIcon = true;
    bool disposedInTest = false;
    String? failBridge;
    Completer<bool>? probeGate;

    Future<void> initialize({void Function(bool)? onAvailability}) =>
        host.initialize(
          onClose: () => closes++,
          onShow: () {},
          onQuit: () => quits++,
          onTrayAvailabilityChanged: (available) {
            changes.add(available);
            onAvailability?.call(available);
          },
          onError: errors.add,
        );

    Future<ByteData?> bridgeClose() async {
      final response = Completer<ByteData?>();
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        closeChannel.name,
        codec.encodeMethodCall(const MethodCall('onClose')),
        response.complete,
      );
      return response.future;
    }

    setUp(() {
      // Exercise the Windows adapter without invoking any real desktop API.
      host = NativeDesktopHost(platform: TargetPlatform.windows);
      bridge = [];
      windows = [];
      tray = [];
      changes = [];
      errors = [];
      closes = quits = 0;
      hasIcon = true;
      disposedInTest = false;
      failBridge = null;
      probeGate = null;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(closeChannel, (
        call,
      ) async {
        bridge.add(call);
        if (call.method == failBridge) throw PlatformException(code: 'bridge');
        if (call.method == 'hasTrayIcon') return probeGate?.future ?? hasIcon;
        return null;
      });
      binding.defaultBinaryMessenger.setMockMethodCallHandler(windowChannel, (
        call,
      ) async {
        windows.add(call);
        if (call.method == 'isMinimized') return false;
        return null;
      });
      binding.defaultBinaryMessenger.setMockMethodCallHandler(trayChannel, (
        call,
      ) async {
        tray.add(call);
        return null;
      });
    });

    tearDown(() async {
      // Do not await a future created in a testWidgets fake-async zone here.
      if (!disposedInTest) await host.dispose();
      for (final channel in [closeChannel, windowChannel, trayChannel]) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
      expect(windowManager.listeners, isNot(contains(host)));
      expect(trayManager.hasListeners, isFalse);
    });

    test(
      'runner bridge owns close interception and probes the actual icon',
      () async {
        await initialize();
        expect(bridge.map((call) => call.method), [
          'setEnabled',
          'hasTrayIcon',
        ]);
        expect(bridge.first.arguments, isTrue);
        expect(windows.map((call) => call.method), [
          'ensureInitialized',
          'setPreventClose',
        ]);
        expect(
          tray.first.arguments['iconPath'],
          endsWith('assets/tray_icons/yun.ico'),
        );
        expect(changes, [false, true]);
        await bridgeClose();
        expect(closes, 1);
        host.onWindowClose(); // Ignore duplicate window_manager close events.
        expect(closes, 1);
        await host.dispose();
        expect(bridge.last.method, 'setEnabled');
        expect(bridge.last.arguments, isFalse);
        expect(await bridgeClose(), isNull); // Native callback handler removed.
        expect(closes, 1);
      },
    );

    test(
      'setIcon success does not imply availability; each hide rechecks',
      () async {
        hasIcon = false;
        await initialize();
        expect(changes, [false]);
        await expectLater(host.hide(), throwsStateError);
        expect(windows.map((call) => call.method), isNot(contains('hide')));
        hasIcon = true;
        expect(await host.checkTrayAvailability(), isTrue);
        hasIcon = false;
        await expectLater(host.hide(), throwsStateError);
        expect(windows.map((call) => call.method), isNot(contains('hide')));
        hasIcon = true;
        await host.hide();
        expect(windows.last.method, 'hide');
        expect(
          bridge.where((call) => call.method == 'hasTrayIcon'),
          hasLength(5),
        );
      },
    );

    test('probe exceptions fail closed without hiding', () async {
      await initialize();
      failBridge = 'hasTrayIcon';
      await expectLater(host.hide(), throwsStateError);
      expect(changes, [false, true, false]);
      expect(errors.single, isA<PlatformException>());
      expect(windows.map((call) => call.method), isNot(contains('hide')));
    });

    testWidgets('probe timeout fails closed without hiding', (tester) async {
      await initialize();
      probeGate = Completer<bool>();
      final failedHide = expectLater(host.hide(), throwsStateError);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await failedHide;
      expect(changes, [false, true, false]);
      expect(errors.single, isA<TimeoutException>());
      expect(windows.map((call) => call.method), isNot(contains('hide')));
      probeGate!.complete(true);
      await tester.pump();
      expect(changes.last, isFalse);
      await host.dispose();
      disposedInTest = true;
    });

    testWidgets(
      'lifetime polling notifies loss to restore; disposal cancels polling',
      (tester) async {
        bool hidden = false;
        Future<void>? restoration;
        await initialize(
          onAvailability: (available) {
            // This is the controller's restoration callback, not native close.
            if (!available && hidden) {
              hidden = false;
              restoration = host.show();
            }
          },
        );
        await host.hide();
        hidden = true;
        hasIcon = false;
        await tester.pump(const Duration(seconds: 5));
        await restoration;
        expect(changes, [false, true, false]);
        expect(hidden, isFalse);
        expect(
          windows.map((call) => call.method),
          containsAllInOrder(['hide', 'show', 'focus']),
        );
        hasIcon = true;
        await tester.pump(const Duration(seconds: 5));
        expect(changes.last, isTrue); // Monitor also runs while visible.
        await host.dispose();
        disposedInTest = true;
        final calls = bridge.length;
        await tester.pump(const Duration(seconds: 15));
        expect(bridge, hasLength(calls));
        expect(bridge.last.arguments, isFalse);
        expect(tray.last.method, 'destroy');
      },
    );

    testWidgets('late probe cannot hide after disposal', (tester) async {
      await initialize();
      probeGate = Completer<bool>();
      final failedHide = expectLater(host.hide(), throwsStateError);
      await host.dispose();
      disposedInTest = true;
      probeGate!.complete(true);
      await failedHide;
      expect(windows.map((call) => call.method), isNot(contains('hide')));
      expect(await host.checkTrayAvailability(), isFalse);
    });

    test(
      'failed bridge handshake rolls back and never creates a tray',
      () async {
        failBridge = 'setEnabled';
        await initialize();
        expect(errors, hasLength(2));
        expect(tray, isEmpty);
        expect(await host.checkTrayAvailability(), isFalse);
        expect(await bridgeClose(), isNull);
      },
    );

    test(
      'Quit uses required process exit, never window close / WM_CLOSE',
      () async {
        await initialize();
        host.onTrayMenuItemClick(MenuItem(key: 'quit', label: 'Quit Yun'));
        expect(quits, 1);
        await host.dispose();
        // TestWidgetsFlutterBinding rejects required exits with this error;
        // cancelable exits return cancel instead. No real process exit occurs.
        await expectLater(
          host.exitApplication(),
          throwsA(
            isA<FlutterError>().having(
              (error) => error.message,
              'message',
              'Unexpected application exit request while running test',
            ),
          ),
        );
        expect(windows.map((call) => call.method), isNot(contains('close')));
        expect(closes, 0);
      },
    );
  });
}
