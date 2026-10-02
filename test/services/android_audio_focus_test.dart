import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/services/android_audio_focus.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('yun/android_audio_focus');
  const codec = StandardMethodCodec();
  late AndroidAudioFocus focus;
  late List<MethodCall> calls;
  late List<AndroidFocusChange> changes;
  late StreamSubscription<AndroidFocusChange> subscription;
  late Future<Object?> Function(MethodCall) reply;

  Future<void> event(
    Object? arguments, {
    String method = 'focusChanged',
  }) async {
    final completed = Completer<void>();
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (data) {
        if (data != null) codec.decodeEnvelope(data);
        completed.complete();
      },
    );
    await completed.future;
  }

  int requestId([int index = 0]) =>
      (calls
                  .where((call) => call.method == 'request')
                  .elementAt(index)
                  .arguments
              as Map)['requestId']
          as int;

  Future<void> change(String name, [int? id]) =>
      event({'requestId': id ?? requestId(), 'change': name});

  setUp(() {
    calls = [];
    changes = [];
    reply = (call) async => call.method == 'request' ? 'granted' : true;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return reply(call);
    });
    focus = AndroidAudioFocus(channel: channel);
    subscription = focus.changes.listen(changes.add);
  });

  tearDown(() async {
    // Ensure a test's deliberately pending/error handler cannot block disposal.
    reply = (_) async => true;
    await subscription.cancel();
    await focus.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  for (final expected in AudioFocusRequestResult.values) {
    test('preserves native ${expected.name} acquisition result', () async {
      reply = (_) async => expected.name;
      expect(await focus.request(), expected);
      expect(calls.single.method, 'request');
      expect(requestId(), isPositive);
      expect(changes, isEmpty);
    });
  }

  test('delayed request listens for gain without another request', () async {
    reply = (_) async => 'delayed';
    expect(await focus.request(), AudioFocusRequestResult.delayed);
    await change('gain');
    expect(changes, [AndroidFocusChange.gain]);
    expect(calls, hasLength(1));
  });

  test(
    'request after gain reuses the grant without another native request',
    () async {
      reply = (_) async => 'delayed';
      await focus.request();
      await change('gain');
      expect(await focus.request(), AudioFocusRequestResult.granted);
      expect(await focus.request(), AudioFocusRequestResult.granted);
      expect(calls, hasLength(1));
    },
  );

  test(
    'request during delayed or transient loss waits without stealing focus',
    () async {
      reply = (_) async => 'delayed';
      await focus.request();
      expect(await focus.request(), AudioFocusRequestResult.delayed);
      await change('gain');
      await change('transientLoss');
      expect(await focus.request(), AudioFocusRequestResult.delayed);
      expect(calls, hasLength(1));
    },
  );

  test('concurrent acquisition shares its original native request', () async {
    final pending = Completer<Object?>();
    reply = (_) => pending.future;
    final first = focus.request();
    final second = focus.request();
    await Future<void>.delayed(Duration.zero);
    expect(calls, hasLength(1));
    pending.complete('granted');
    expect(await first, AudioFocusRequestResult.granted);
    expect(await second, AudioFocusRequestResult.granted);
  });

  test('gain before delayed method reply preserves the newer grant', () async {
    final pending = Completer<Object?>();
    reply = (_) => pending.future;
    final requested = focus.request();
    await Future<void>.delayed(Duration.zero);
    await change('gain');
    pending.complete('delayed');
    expect(await requested, AudioFocusRequestResult.granted);
    expect(await focus.request(), AudioFocusRequestResult.granted);
    expect(calls, hasLength(1));
  });

  test(
    'transient loss before granted method reply preserves waiting',
    () async {
      final pending = Completer<Object?>();
      reply = (_) => pending.future;
      final requested = focus.request();
      await Future<void>.delayed(Duration.zero);
      await change('transientLoss');
      pending.complete('granted');
      expect(await requested, AudioFocusRequestResult.delayed);
      expect(await focus.request(), AudioFocusRequestResult.delayed);
      expect(calls, hasLength(1));
    },
  );

  for (final initial in ['granted', 'delayed']) {
    test('unplug clears $initial focus and rejects late gain', () async {
      reply = (call) async => call.method == 'request' ? initial : true;
      await focus.request();
      await change('noisy');
      await change('gain');
      await change('noisy');
      expect(changes, [AndroidFocusChange.noisy]);
      await focus.request();
      expect(calls.where((call) => call.method == 'request'), hasLength(2));
    });
  }

  test(
    'unplug before the acquisition reply cannot leave a grant cached',
    () async {
      final pending = Completer<Object?>();
      reply = (_) => pending.future;
      final requested = focus.request();
      await Future<void>.delayed(Duration.zero);
      await change('noisy');
      pending.complete('granted');
      expect(await requested, AudioFocusRequestResult.failed);
      await change('gain');
      expect(changes, [AndroidFocusChange.noisy]);
    },
  );

  test('queued unplug from cancelled or old requests is ignored', () async {
    await focus.request();
    await focus.abandon();
    await change('noisy');
    await focus.request();
    await change('noisy');
    await change('gain', requestId(1));
    expect(changes, [AndroidFocusChange.gain]);
  });

  test(
    'unplug while transiently interrupted requires explicit new Play',
    () async {
      await focus.request();
      await change('transientLoss');
      await change('noisy');
      await change('gain');
      expect(changes, [
        AndroidFocusChange.transientLoss,
        AndroidFocusChange.noisy,
      ]);
      expect(await focus.request(), AudioFocusRequestResult.granted);
      expect(calls.where((call) => call.method == 'request'), hasLength(2));
    },
  );

  test('unknown native result fails closed', () async {
    reply = (_) async => 'unknown';
    expect(await focus.request(), AudioFocusRequestResult.failed);
    await change('gain');
    expect(changes, isEmpty);
  });

  test('denied request cannot be resumed by an unsolicited gain', () async {
    reply = (_) async => 'failed';
    await focus.request();
    await change('gain');
    expect(changes, isEmpty);
  });

  test('transient loss and gain keep the same active registration', () async {
    await focus.request();
    await change('transientLoss');
    await change('gain');
    expect(changes, [
      AndroidFocusChange.transientLoss,
      AndroidFocusChange.gain,
    ]);
    expect(calls, hasLength(1));
  });

  test('permanent loss drops later gain until explicit new request', () async {
    await focus.request();
    await change('loss');
    await change('gain');
    expect(changes, [AndroidFocusChange.loss]);
    await focus.request();
    await change('gain', requestId(1));
    expect(changes, [AndroidFocusChange.loss, AndroidFocusChange.gain]);
  });

  test('abandon invalidates synchronously before native completion', () async {
    await focus.request();
    final pending = Completer<Object?>();
    reply = (_) => pending.future;
    final abandoned = focus.abandon();
    await change('gain');
    expect(changes, isEmpty);
    pending.complete(true);
    expect(await abandoned, isTrue);
  });

  test(
    'cancelled acquisition response cannot rearm a waiting request',
    () async {
      final pending = Completer<Object?>();
      reply = (call) => call.method == 'request'
          ? pending.future
          : Future<Object?>.value(true);
      final requested = focus.request();
      await Future<void>.delayed(Duration.zero);
      await focus.abandon();
      pending.complete('delayed');
      expect(await requested, AudioFocusRequestResult.failed);
      await change('gain');
      expect(changes, isEmpty);
    },
  );

  test(
    'replacement rejects old gain, loss and late acquisition reply',
    () async {
      final pending = Completer<Object?>();
      reply = (_) => pending.future;
      final oldRequest = focus.request();
      await Future<void>.delayed(Duration.zero);
      reply = (call) async => call.method == 'request' ? 'delayed' : true;
      await focus.abandon();
      expect(await focus.request(), AudioFocusRequestResult.delayed);
      expect(requestId(1), isNot(requestId()));
      pending.complete('granted');
      expect(await oldRequest, AudioFocusRequestResult.failed);
      await change('gain');
      await change('loss');
      await change('gain', requestId(1));
      expect(changes, [AndroidFocusChange.gain]);
    },
  );

  test('old abandonment reply does not invalidate a new request', () async {
    await focus.request();
    final pending = Completer<Object?>();
    reply = (call) => call.method == 'abandon'
        ? pending.future
        : Future<Object?>.value('granted');
    final abandoned = focus.abandon();
    await focus.request();
    pending.complete(true);
    await abandoned;
    await change('gain', requestId(1));
    expect(changes, [AndroidFocusChange.gain]);
  });

  test('malformed, unknown and idle events are ignored', () async {
    await event({'requestId': null, 'change': 'gain'});
    await focus.request();
    await event(null);
    await event('gain');
    await event({'change': 'gain'});
    await event({'requestId': requestId(), 'change': 'unexpected'});
    await event({
      'requestId': requestId(),
      'change': 'gain',
    }, method: 'notAFocusEvent');
    expect(changes, isEmpty);
  });

  test(
    'platform acquisition error invalidates its events and is reported',
    () async {
      reply = (_) async => throw PlatformException(code: 'unavailable');
      await expectLater(focus.request(), throwsA(isA<PlatformException>()));
      await change('gain');
      expect(changes, isEmpty);
      reply = (_) async => 'granted';
      expect(await focus.request(), AudioFocusRequestResult.granted);
      await change('gain', requestId(1));
      expect(changes, [AndroidFocusChange.gain]);
    },
  );

  test('abandonment failure remains cancelled and reports false', () async {
    await focus.request();
    reply = (_) async => false;
    expect(await focus.abandon(), isFalse);
    await change('gain');
    expect(changes, isEmpty);
  });

  test('abandonment exception still invalidates queued callbacks', () async {
    await focus.request();
    reply = (_) async => throw PlatformException(code: 'abandon');
    await expectLater(focus.abandon(), throwsA(isA<PlatformException>()));
    await change('gain');
    expect(changes, isEmpty);
  });

  test(
    'dispose releases once, closes stream and rejects future requests',
    () async {
      await focus.request();
      var closed = false;
      subscription.onDone(() => closed = true);
      await focus.dispose();
      await focus.dispose();
      expect(closed, isTrue);
      expect(await focus.request(), AudioFocusRequestResult.failed);
      expect(await focus.abandon(), isTrue);
      expect(calls.where((call) => call.method == 'abandon'), hasLength(1));
    },
  );

  test('dispose invalidates acquisition already waiting for a reply', () async {
    final pending = Completer<Object?>();
    reply = (call) =>
        call.method == 'request' ? pending.future : Future<Object?>.value(true);
    final requested = focus.request();
    await Future<void>.delayed(Duration.zero);
    await focus.dispose();
    pending.complete('granted');
    expect(await requested, AudioFocusRequestResult.failed);
  });
}
