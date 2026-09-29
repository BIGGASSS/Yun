import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:yun/services/native_desktop_host.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const windowChannel = MethodChannel('window_manager');
  const trayChannel = MethodChannel('tray_manager');
  const closeChannel = MethodChannel('yun/desktop_close');
  const iconAsset = 'assets/tray_icons/yun_macos.png';
  late NativeDesktopHost host;
  late List<MethodCall> trayCalls;
  late List<MethodCall> closeCalls;

  setUp(() {
    // Both adapter selection and tray_manager's asset/base64 branch must use
    // macOS. All native APIs are mocked; no Linux bus is created or contacted.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    host = NativeDesktopHost(platform: TargetPlatform.macOS);
    trayCalls = [];
    closeCalls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      windowChannel,
      (call) async => call.method == 'isMinimized' ? false : null,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(trayChannel, (
      call,
    ) async {
      trayCalls.add(call);
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(closeChannel, (
      call,
    ) async {
      closeCalls.add(call);
      return call.method == 'hasTrayIcon' ? true : null;
    });
  });

  tearDown(() async {
    await host.dispose();
    for (final channel in [windowChannel, trayChannel, closeChannel]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
    debugDefaultTargetPlatformOverride = null;
    expect(windowManager.listeners, isNot(contains(host)));
    expect(trayManager.hasListeners, isFalse);
  });

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    test(
      '${platform.name}: left click shows; only right click opens menu',
      () async {
        await host.dispose();
        debugDefaultTargetPlatformOverride = platform;
        host = NativeDesktopHost(platform: platform);
        var shows = 0;
        var quits = 0;
        final errors = <Object>[];
        await host.initialize(
          onClose: () {},
          onShow: () => shows++,
          onQuit: () => quits++,
          onTrayAvailabilityChanged: (_) {},
          onError: errors.add,
        );
        trayCalls.clear();

        Future<void> click(String event) async {
          const codec = StandardMethodCodec();
          final response = Completer<void>();
          await binding.defaultBinaryMessenger.handlePlatformMessage(
            trayChannel.name,
            codec.encodeMethodCall(MethodCall(event)),
            (data) {
              if (data != null) codec.decodeEnvelope(data);
              response.complete();
            },
          );
          await response.future;
        }

        await click('onTrayIconMouseDown');
        await click('onTrayIconMouseUp');
        expect(shows, 1);
        expect(trayCalls, isEmpty);
        await click('onTrayIconRightMouseDown');
        await click('onTrayIconRightMouseUp');
        expect(trayCalls.map((call) => call.method), ['popUpContextMenu']);
        expect(shows, 1);
        expect(quits, 0);
        expect(errors, isEmpty);
      },
    );
  }

  test(
    'macOS sends the bundled full-color logo at 18 points, not a template',
    () async {
      final errors = <Object>[];
      final availability = <bool>[];
      await host.initialize(
        onClose: () {},
        onShow: () {},
        onQuit: () {},
        onTrayAvailabilityChanged: availability.add,
        onError: errors.add,
      );

      expect(errors, isEmpty);
      expect(availability, [false, true]);
      expect(closeCalls, isEmpty);
      expect(trayCalls.map((call) => call.method), [
        'setIcon',
        'setContextMenu',
        'setToolTip',
      ]);
      final arguments =
          trayCalls.singleWhere((call) => call.method == 'setIcon').arguments
              as Map;
      expect(arguments['iconPath'], endsWith(iconAsset));
      expect(arguments['isTemplate'], isFalse);
      expect(arguments['iconSize'], 18);

      // Exercise the real asset bundle and plugin encoder, not a fake logo.
      final bundled = await rootBundle.load(iconAsset);
      expect(
        base64Decode(arguments['base64Icon'] as String),
        orderedEquals(
          bundled.buffer.asUint8List(
            bundled.offsetInBytes,
            bundled.lengthInBytes,
          ),
        ),
      );
    },
  );
}
