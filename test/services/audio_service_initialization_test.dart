import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_service_platform_interface/audio_service_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AudioService caches AudioServicePlatform.instance in a lazy top-level
  // variable. Install one fake before its first use and drive the whole
  // singleton lifecycle in one test; swapping fakes between tests is unsafe.
  final platform = _ControlledAudioServicePlatform();
  AudioServicePlatform.instance = platform;

  test(
    'real init retries early failures, coalesces calls, and observes once',
    () async {
      var assertionsEnabled = false;
      assert(assertionsEnabled = true);
      expect(
        assertionsEnabled,
        isTrue,
        reason: 'Exercises the upstream assert',
      );

      final failedCache = _FakeCacheManager();
      final ignoredCache = _FakeCacheManager();
      final successfulCache = _FakeCacheManager();
      final handler = _CountingAudioHandler();
      var builderCalls = 0;
      var ignoredBuilderCalls = 0;

      _CountingAudioHandler buildHandler() {
        builderCalls++;
        return handler;
      }

      _CountingAudioHandler ignoredBuilder() {
        ignoredBuilderCalls++;
        throw StateError('A coalesced call must not run another builder');
      }

      // A synchronous callback-installation error must not poison the cache
      // guard or the shared initialization future either.
      final callbackError = StateError('callback setup failed');
      platform.callbackError = callbackError;
      await expectLater(
        AudioService.init(builder: buildHandler, cacheManager: failedCache),
        throwsA(same(callbackError)),
      );
      expect(platform.configurations, isEmpty);
      expect(builderCalls, 0);
      expect(() => AudioService.cacheManager, throwsA(isA<TypeError>()));
      expect(failedCache.disposeCalls, 0);
      platform.callbackError = null;

      // Repeated failures also recover. Each pair shares one pending platform
      // configuration and receives the original error, without a builder run.
      for (var attempt = 0; attempt < 2; attempt++) {
        final first = AudioService.init(
          builder: buildHandler,
          cacheManager: failedCache,
        );
        final concurrent = AudioService.init(
          builder: ignoredBuilder,
          cacheManager: ignoredCache,
        );
        expect(platform.configurations, hasLength(attempt + 1));
        expect(AudioService.cacheManager, same(failedCache));
        expect(builderCalls, 0);
        expect(ignoredBuilderCalls, 0);
        expect(platform.states, isEmpty);
        expect(platform.queues, isEmpty);

        final error = PlatformException(code: 'configure_failed_$attempt');
        final firstError = expectLater(first, throwsA(same(error)));
        final concurrentError = expectLater(concurrent, throwsA(same(error)));
        platform.configurations.last.completeError(error);
        await Future.wait([firstError, concurrentError]);
        expect(() => AudioService.cacheManager, throwsA(isA<TypeError>()));
        expect(failedCache.disposeCalls, 0);
        expect(ignoredCache.disposeCalls, 0);
      }

      final oldCallbacks = platform.callbacks;
      const config = AudioServiceConfig(
        androidNotificationChannelId: 'retry.success',
      );
      final retry = AudioService.init(
        builder: buildHandler,
        config: config,
        cacheManager: successfulCache,
      );
      final concurrentRetry = AudioService.init<AudioHandler>(
        builder: ignoredBuilder,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'ignored.concurrent',
        ),
        cacheManager: ignoredCache,
      );
      expect(platform.configurations, hasLength(3));
      expect(platform.callbacks, isNot(same(oldCallbacks)));
      expect(AudioService.cacheManager, same(successfulCache));
      expect(builderCalls, 0);
      platform.configurations.last.complete();
      expect(await retry, same(handler));
      expect(await concurrentRetry, same(handler));
      expect(AudioService.config, same(config));
      expect(builderCalls, 1);
      expect(ignoredBuilderCalls, 0);

      // Successful initialization stays shared, including a broader generic
      // return type. No second configure, builder, or global observer appears.
      expect(
        await AudioService.init<AudioHandler>(
          builder: ignoredBuilder,
          cacheManager: ignoredCache,
        ),
        same(handler),
      );
      expect(platform.configurations, hasLength(3));
      expect(platform.callbackInstallations, 4);
      expect(builderCalls, 1);
      expect(ignoredBuilderCalls, 0);
      expect(AudioService.cacheManager, same(successfulCache));

      // Drain each subject's initial event before measuring live updates.
      await Future<void>.delayed(Duration.zero);
      expect(platform.states, hasLength(1));
      expect(platform.queues, hasLength(1));
      expect(platform.mediaItems, isEmpty);
      expect(platform.playbackInfos, isEmpty);
      const mediaItem = MediaItem(id: 'track', title: 'Recovered track');
      handler.mediaItem.add(mediaItem);
      handler.queue.add([mediaItem]);
      handler.playbackState.add(
        PlaybackState(processingState: AudioProcessingState.ready),
      );
      handler.androidPlaybackInfo.add(LocalAndroidPlaybackInfo());
      await Future<void>.delayed(Duration.zero);
      expect(platform.states, hasLength(2));
      expect(platform.queues, hasLength(2));
      expect(platform.mediaItems, hasLength(1));
      expect(platform.playbackInfos, hasLength(1));
      await platform.callbacks!.play(const PlayRequest());
      expect(handler.playCalls, 1);
      expect(successfulCache.disposeCalls, 0);

      await handler.mediaItem.close();
      await handler.queue.close();
      await handler.playbackState.close();
      await handler.androidPlaybackInfo.close();
    },
  );
}

class _ControlledAudioServicePlatform extends AudioServicePlatform {
  final configurations = <Completer<void>>[];
  final states = <SetStateRequest>[];
  final queues = <SetQueueRequest>[];
  final mediaItems = <SetMediaItemRequest>[];
  final playbackInfos = <SetAndroidPlaybackInfoRequest>[];
  AudioHandlerCallbacks? callbacks;
  Object? callbackError;
  var callbackInstallations = 0;

  @override
  void setHandlerCallbacks(AudioHandlerCallbacks callbacks) {
    callbackInstallations++;
    final error = callbackError;
    if (error != null) throw error;
    this.callbacks = callbacks;
  }

  @override
  Future<void> configure(ConfigureRequest request) {
    final completer = Completer<void>();
    configurations.add(completer);
    return completer.future;
  }

  @override
  Future<void> setState(SetStateRequest request) async => states.add(request);

  @override
  Future<void> setQueue(SetQueueRequest request) async => queues.add(request);

  @override
  Future<void> setMediaItem(SetMediaItemRequest request) async =>
      mediaItems.add(request);

  @override
  Future<void> setAndroidPlaybackInfo(
    SetAndroidPlaybackInfoRequest request,
  ) async => playbackInfos.add(request);
}

class _CountingAudioHandler extends BaseAudioHandler {
  var playCalls = 0;

  @override
  Future<void> play() async => playCalls++;
}

class _FakeCacheManager implements BaseCacheManager {
  var disposeCalls = 0;

  @override
  Future<void> dispose() async => disposeCalls++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
