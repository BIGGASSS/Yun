import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/services/data_directory_picker.dart';

class _FilePicker extends FilePicker {
  final calls = <({String? title, String? initialDirectory})>[];
  String? result;
  Object? error;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    calls.add((title: dialogTitle, initialDirectory: initialDirectory));
    if (error case final error?) throw error;
    return result;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('yun/data_directory');
  const injectedChannel = MethodChannel('test/data_directory');
  late _FilePicker filePicker;
  late List<MethodCall> nativeCalls;
  Object? nativeResult;
  PlatformException? nativeError;
  Completer<Object?>? nativeGate;

  setUp(() {
    filePicker = _FilePicker();
    FilePicker.platform = filePicker;
    nativeCalls = [];
    nativeResult = null;
    nativeError = null;
    nativeGate = null;
    for (final channel in [channel, injectedChannel]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        nativeCalls.add(call);
        if (nativeError case final error?) throw error;
        return nativeGate?.future ?? nativeResult;
      });
    }
  });

  tearDown(() {
    for (final channel in [channel, injectedChannel]) {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    }
    debugDefaultTargetPlatformOverride = null;
  });

  test('default constructor uses the macOS data-directory channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    nativeResult = '/Volumes/Library/Yun';
    expect(
      await DataDirectoryPicker().pickDirectory(initialDirectory: '/old root'),
      '/Volumes/Library/Yun',
    );
    expect(nativeCalls.single.method, 'pickDirectory');
    expect(nativeCalls.single.arguments, {'initialDirectory': '/old root'});
    expect(filePicker.calls, isEmpty);
  });

  test(
    'macOS cancellation returns null, including without an initial root',
    () async {
      final picker = DataDirectoryPicker(platform: TargetPlatform.macOS);
      expect(await picker.pickDirectory(), isNull);
      expect(nativeCalls.single.method, 'pickDirectory');
      expect(nativeCalls.single.arguments, {'initialDirectory': null});
      expect(filePicker.calls, isEmpty);
    },
  );

  test('injected channel is used and picker errors are forwarded', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    nativeError = PlatformException(
      code: 'bookmark_save_failed',
      message: 'Could not save access',
      details: '/selected',
    );
    final picker = DataDirectoryPicker(
      platform: TargetPlatform.macOS,
      channel: injectedChannel,
    );
    await expectLater(
      picker.pickDirectory(),
      throwsA(
        isA<PlatformException>()
            .having((error) => error.code, 'code', 'bookmark_save_failed')
            .having(
              (error) => error.message,
              'message',
              'Could not save access',
            )
            .having((error) => error.details, 'details', '/selected'),
      ),
    );
    expect(filePicker.calls, isEmpty);
  });

  test(
    'macOS restoration awaits all native work and accepts warnings',
    () async {
      final picker = DataDirectoryPicker(platform: TargetPlatform.macOS);
      nativeGate = Completer<Object?>();
      var completed = false;
      final restore = picker.restoreAccess().then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(nativeCalls.single.method, 'restoreAccess');
      expect(nativeCalls.single.arguments, isNull);
      expect(completed, isFalse);
      nativeGate!.complete(['An obsolete bookmark is unavailable']);
      await restore;
      expect(completed, isTrue);
      expect(filePicker.calls, isEmpty);
    },
  );

  test('macOS restoration accepts an empty native response', () async {
    await DataDirectoryPicker(platform: TargetPlatform.macOS).restoreAccess();
    expect(nativeCalls.single.method, 'restoreAccess');
  });

  test('channel-level restoration errors are forwarded', () async {
    nativeError = PlatformException(code: 'channel_failure');
    await expectLater(
      DataDirectoryPicker(platform: TargetPlatform.macOS).restoreAccess(),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'channel_failure',
        ),
      ),
    );
  });

  for (final platform in TargetPlatform.values.where(
    (platform) => platform != TargetPlatform.macOS,
  )) {
    test(
      '${platform.name} uses FilePicker and never calls native access',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final picker = DataDirectoryPicker();
        nativeError = PlatformException(code: 'must_not_call_native');
        filePicker.result = '/selected';
        await picker.restoreAccess();
        expect(filePicker.calls, isEmpty);
        expect(
          await picker.pickDirectory(initialDirectory: '/initial'),
          '/selected',
        );
        expect(filePicker.calls, [
          (title: 'Choose data directory', initialDirectory: '/initial'),
        ]);
        expect(nativeCalls, isEmpty);
      },
    );
  }

  test('non-macOS forwards FilePicker cancellation and errors', () async {
    final picker = DataDirectoryPicker(platform: TargetPlatform.linux);
    expect(await picker.pickDirectory(), isNull);
    expect(filePicker.calls.single.initialDirectory, isNull);
    final error = PlatformException(code: 'file_picker_failure');
    filePicker.error = error;
    await expectLater(picker.pickDirectory(), throwsA(same(error)));
    expect(nativeCalls, isEmpty);
  });
}
