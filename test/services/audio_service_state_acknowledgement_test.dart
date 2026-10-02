import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/system_media_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Exercise the real vendored singleton and its observer, rather than mocking
  // NativeSystemMediaControls.update or bypassing the platform acknowledgement.
  final platform = _Platform();
  AudioServicePlatform.instance = platform;

  test(
    'real state acknowledgement, failure latch and explicit bounded retry',
    () async {
      final handler = await AudioService.init(
        builder: BaseAudioHandler.new,
        cacheManager: _Cache(),
        config: const AudioServiceConfig(androidStopForegroundOnPause: false),
      );
      await _tick();
      final controls = NativeSystemMediaControls(handler: handler);
      final statuses = <SystemMediaControlsStatus>[];
      final errors = <Object>[];
      final statusSubscription = controls.statusChanges.listen(statuses.add);
      final errorSubscription = AudioService.asyncError.listen(errors.add);
      const track = Track(id: 'a', title: 'A');
      Future<void> update({
        bool playing = true,
        bool stop = false,
        int position = 0,
      }) => controls.update(
        track: stop ? null : track,
        queue: stop ? const [] : const [track],
        index: stop ? -1 : 0,
        playing: playing,
        buffering: false,
        position: Duration(milliseconds: position),
        shuffle: false,
        repeat: 0,
      );

      final denied = PlatformException(code: 'old upstream raw /private/path');
      final firstGate = platform.nextGate = Completer<void>();
      var finished = false;
      final first = update();
      final firstFailure = expectLater(first, throwsA(same(denied)));
      first.then((_) => finished = true, onError: (_) => finished = true);
      await _tick();
      expect(
        platform.states,
        hasLength(2),
      ); // Initial idle, then requested play.
      expect(
        finished,
        isFalse,
        reason: 'stream publication is not native success',
      );
      expect(statuses, isEmpty);
      for (var i = 1; i <= 1000; i++) {
        expect(identical(update(position: i), first), isTrue);
      }
      firstGate.completeError(denied);
      await firstFailure;
      await _tick();
      expect(finished, isTrue);
      expect(errors, [same(denied)]);
      expect(statuses.last.available, isFalse);
      expect(statuses.last.errorCode, 'native_state_failed');
      expect(statuses.last.error, isNot(contains('/private/path')));
      expect(
        platform.states,
        hasLength(2),
        reason: 'pending polls cannot retry a failed promotion',
      );

      for (var i = 0; i < 25; i++) {
        await update(position: i);
      }
      expect(platform.states, hasLength(2));
      await update(playing: false);
      await update(playing: false, stop: true);
      expect(
        platform.states,
        hasLength(4),
        reason: 'pause and stop cleanup still reach native',
      );
      expect(platform.stops, 1);
      expect(
        statuses,
        hasLength(1),
        reason: 'successful cleanup cannot clear a failed promotion',
      );

      final retryGate = platform.nextGate = Completer<void>();
      final retry = controls.retryPlaybackState();
      var recovered = false;
      retry.then((_) => recovered = true);
      for (var i = 0; i < 20; i++) {
        expect(identical(controls.retryPlaybackState(), retry), isTrue);
      }
      await _tick();
      expect(platform.states, hasLength(5));
      expect(platform.states.last.state.playing, isTrue);
      expect(recovered, isFalse);
      expect(statuses.last.available, isFalse);
      final passiveDuringRetry = update(position: 88);
      await _tick();
      expect(
        platform.states,
        hasLength(5),
        reason: 'poll during retry cannot cause another start',
      );
      retryGate.complete();
      await Future.wait([retry, passiveDuringRetry]);
      expect(recovered, isTrue);
      expect(statuses.last.available, isTrue);
      expect(statuses.last.error, isNull);
      await update(position: 89);
      expect(platform.states, hasLength(7));

      // An explicitly retried rejection remains visible, without a retry loop.
      final failure = PlatformException(
        code: 'foreground_service_start_denied',
      );
      final nextFailureGate = platform.nextGate = Completer<void>();
      final nextFailure = expectLater(update(), throwsA(same(failure)));
      await _tick();
      nextFailureGate.completeError(failure);
      await nextFailure;
      expect(statuses.last.errorCode, 'foreground_service_start_denied');
      final rejectedRetryGate = platform.nextGate = Completer<void>();
      final rejectedRetry = controls.retryPlaybackState();
      final rejected = expectLater(rejectedRetry, throwsA(same(failure)));
      await _tick();
      final countBeforeRejection = platform.states.length;
      rejectedRetryGate.completeError(failure);
      await rejected;
      for (var i = 0; i < 10; i++) {
        await update(position: i);
      }
      expect(platform.states, hasLength(countBeforeRejection));
      expect(statuses.last.available, isFalse);
      await controls.retryPlaybackState();
      expect(platform.states, hasLength(countBeforeRejection + 1));
      expect(statuses.last.available, isTrue);
      await controls.retryPlaybackState();
      expect(
        platform.states,
        hasLength(countBeforeRejection + 1),
        reason: 'healthy service needs no recovery',
      );

      // Even callers reusing one immutable state get distinct acknowledgements.
      final repeated = PlaybackState(
        processingState: AudioProcessingState.ready,
      );
      final firstPublishGate = platform.nextGate = Completer<void>();
      final publishedFirst = AudioService.publishPlaybackState(
        handler,
        repeated,
      );
      await _tick();
      final secondPublishGate = platform.nextGate = Completer<void>();
      final publishedSecond = AudioService.publishPlaybackState(
        handler,
        repeated,
      );
      var secondFinished = false;
      publishedSecond.then((_) => secondFinished = true);
      firstPublishGate.complete();
      await publishedFirst;
      await _tick();
      expect(secondFinished, isFalse);
      secondPublishGate.complete();
      await publishedSecond;
      expect(secondFinished, isTrue);

      final disposalGate = platform.nextGate = Completer<void>();
      var disposed = false;
      final disposal = controls.dispose();
      disposal.then((_) => disposed = true);
      await _tick();
      expect(
        platform.states.last.state.processingState,
        AudioProcessingStateMessage.idle,
      );
      expect(
        disposed,
        isFalse,
        reason: 'disposal waits for real native cleanup',
      );
      final statusCount = statuses.length;
      await controls.retryPlaybackState();
      final successor = NativeSystemMediaControls(handler: handler);
      const nextTrack = Track(id: 'b', title: 'B');
      final successorUpdate = successor.update(
        track: nextTrack,
        queue: const [nextTrack],
        index: 0,
        playing: true,
        buffering: false,
        position: Duration.zero,
        shuffle: false,
        repeat: 0,
      );
      await _tick();
      disposalGate.complete();
      await Future.wait([disposal, successorUpdate]);
      expect(handler.mediaItem.value?.id, 'b');
      expect(handler.queue.value.single.id, 'b');
      await successor.dispose();
      expect(
        statuses,
        hasLength(statusCount),
        reason: 'retired owner never emits late status',
      );
      await statusSubscription.cancel();
      await errorSubscription.cancel();
      await handler.mediaItem.close();
      await handler.queue.close();
      await handler.playbackState.close();
      await handler.androidPlaybackInfo.close();
    },
  );
}

Future<void> _tick() => Future<void>.delayed(Duration.zero);

class _Platform extends AudioServicePlatform {
  final states = <SetStateRequest>[];
  Completer<void>? nextGate;
  int stops = 0;

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) {}
  @override
  Future<void> configure(ConfigureRequest request) async {}
  @override
  Future<void> setState(SetStateRequest request) async {
    states.add(request);
    final gate = nextGate;
    nextGate = null;
    await gate?.future;
  }

  @override
  Future<void> setQueue(SetQueueRequest request) async {}
  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async {}
  @override
  Future<void> setAndroidPlaybackInfo(
    SetAndroidPlaybackInfoRequest request,
  ) async {}
  @override
  Future<void> stopService(StopServiceRequest request) async => stops++;
}

class _Cache implements BaseCacheManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
