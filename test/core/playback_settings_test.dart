import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yun/core/playback_controller.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/playback_settings_store.dart';
import 'package:yun/services/system_media_controls.dart';

import 'fakes.dart';

const _tracks = [Track(id: 'a', title: 'A'), Track(id: 'b', title: 'B')];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  PlaybackController player({
    required FakeEngine engine,
    PlaybackSettings settings = const PlaybackSettings(),
    Future<void> Function(PlaybackSettings)? save,
    SystemMediaControls? controls,
  }) {
    final result = PlaybackController(
      engine: engine,
      initialSettings: settings,
      saveSettings: save,
      controls: controls,
      enableSystemControls: controls != null,
      resolveSource: (track, _) async => AudioSource('/fake/${track.id}'),
    );
    addTearDown(() async {
      await result.shutdown();
      result.dispose();
    });
    return result;
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final muted in [false, true]) {
    test('preferences restore across controllers (muted: $muted)', () async {
      final preferences = await SharedPreferences.getInstance();
      final firstStore = SharedPreferencesPlaybackSettingsStore(preferences);
      final firstEngine = FakeEngine();
      final first = player(engine: firstEngine, save: firstStore.write);
      await first.playQueue(_tracks);
      await first.setVolume(37.25);
      first.setShuffle(true);
      first.setRepeat(RepeatMode.all);
      if (muted) await first.toggleMute();
      await first.flushSettings();
      await first.shutdown();

      // Use the real store codec, not a directly passed in-memory snapshot.
      final secondStore = SharedPreferencesPlaybackSettingsStore(
        await SharedPreferences.getInstance(),
      );
      final saved = await secondStore.read();
      expect(saved.volume, muted ? 0 : 37.25);
      expect(saved.lastPositiveVolume, 37.25);
      final secondEngine = FakeEngine();
      final second = player(
        engine: secondEngine,
        settings: saved,
        save: secondStore.write,
      );
      expect(second.volume, muted ? 0 : 37.25);
      expect(second.isMuted, muted);
      expect(second.shuffle, isTrue);
      expect(second.repeatMode, RepeatMode.all);
      expect(second.queue, isEmpty);
      expect(second.currentTrack, isNull);
      expect(second.isPlaying, isFalse);
      expect(secondEngine.initializations, 0);
      expect(secondEngine.calls, isEmpty);
      await second.playQueue(_tracks);
      expect(secondEngine.calls.take(4), [
        'initialize',
        'volume',
        'stop',
        'open',
      ]);
      expect(secondEngine.volumeCalls, [muted ? 0 : 37.25]);
      if (muted) {
        await second.toggleMute();
        expect(second.volume, 37.25);
        expect(secondEngine.volume, 37.25);
        await second.flushSettings();
        expect((await secondStore.read()).volume, 37.25);
      }
    });
  }

  for (final modesOnly in [false, true]) {
    test(
      'null volume never overrides native defaults (modes: $modesOnly)',
      () async {
        final store = SharedPreferencesPlaybackSettingsStore(
          await SharedPreferences.getInstance(),
        );
        if (modesOnly) {
          final first = player(engine: FakeEngine(), save: store.write);
          first.setShuffle(true);
          first.setRepeat(RepeatMode.all);
          await first.flushSettings();
          await first.shutdown();
        }
        final saved = await store.read();
        expect(saved.volume, isNull);
        final engine = FakeEngine()..volume = 63;
        final restored = player(
          engine: engine,
          settings: saved,
          save: store.write,
        );
        expect(engine.initializations, 0);
        expect(restored.shuffle, modesOnly);
        expect(
          restored.repeatMode,
          modesOnly ? RepeatMode.all : RepeatMode.off,
        );
        await restored.playQueue(_tracks);
        await restored.next();
        await restored.stop();
        await restored.playQueue(_tracks);
        expect(engine.volumeCalls, isEmpty);
        expect(engine.volume, 63);
      },
    );
  }

  test(
    'constructor normalizes malformed settings without audio or writes',
    () async {
      final writes = <PlaybackSettings>[];
      final engine = FakeEngine();
      final restored = player(
        engine: engine,
        settings: const PlaybackSettings(
          volume: double.nan,
          lastPositiveVolume: -12,
          shuffle: true,
          repeatMode: RepeatMode.one,
        ),
        save: (settings) async => writes.add(settings),
      );
      await restored.flushSettings();
      expect(restored.volume, 100);
      expect(restored.shuffle, isTrue);
      expect(restored.repeatMode, RepeatMode.one);
      expect(engine.calls, isEmpty);
      expect(writes, isEmpty);
      await restored.toggleMute();
      await restored.toggleMute();
      expect(restored.volume, 100);
      await restored.flushSettings();
      expect(writes.last.lastPositiveVolume, 100);
    },
  );

  test(
    'slow writes serialize eager snapshots without blocking audio',
    () async {
      final release = Completer<void>();
      final started = Completer<void>();
      final writes = <PlaybackSettings>[];
      final committed = <PlaybackSettings>[];
      final engine = FakeEngine();
      final playback = player(
        engine: engine,
        save: (settings) async {
          writes.add(settings);
          if (writes.length == 1) {
            started.complete();
            await release.future;
          }
          committed.add(settings);
        },
      );
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      await playback.playQueue(_tracks);
      playback.setShuffle(true);
      // Persistence starts eagerly, before flushSettings or shutdown.
      await started.future;
      playback.setRepeat(RepeatMode.all);
      await playback.setVolume(24.5);
      await playback.toggleMute();
      await playback.pause();
      expect(playback.isPlaying, isFalse);
      await playback.play();
      await playback.next();
      expect(engine.opens, 2);
      expect(engine.volumeCalls, [24.5, 0]);
      expect(writes, hasLength(1));
      expect(committed, isEmpty);
      var flushed = false;
      final flushing = playback.flushSettings().then((_) => flushed = true);
      await Future<void>.delayed(Duration.zero);
      expect(flushed, isFalse);
      release.complete();
      await flushing;
      expect(writes.map((s) => s.toJson()), [
        const PlaybackSettings(shuffle: true).toJson(),
        const PlaybackSettings(
          shuffle: true,
          repeatMode: RepeatMode.all,
        ).toJson(),
        const PlaybackSettings(
          volume: 24.5,
          lastPositiveVolume: 24.5,
          shuffle: true,
          repeatMode: RepeatMode.all,
        ).toJson(),
        const PlaybackSettings(
          volume: 0,
          lastPositiveVolume: 24.5,
          shuffle: true,
          repeatMode: RepeatMode.all,
        ).toJson(),
      ]);
      expect(committed, orderedEquals(writes));
    },
  );

  test(
    'flush waits for an accepted native command and its settings write',
    () async {
      final nativeStarted = Completer<void>();
      final releaseNative = Completer<void>();
      final saveStarted = Completer<void>();
      final releaseSave = Completer<void>();
      final writes = <PlaybackSettings>[];
      final engine = FakeEngine();
      final playback = player(
        engine: engine,
        save: (settings) async {
          saveStarted.complete();
          await releaseSave.future;
          writes.add(settings);
        },
      );
      addTearDown(() {
        if (!releaseNative.isCompleted) releaseNative.complete();
        if (!releaseSave.isCompleted) releaseSave.complete();
      });
      await playback.playQueue(_tracks);
      engine.onSetVolume = (_) {
        nativeStarted.complete();
        return releaseNative.future;
      };
      final change = playback.setVolume(18.75);
      await nativeStarted.future;
      var flushed = false;
      final flushing = playback.flushSettings().then((_) => flushed = true);
      await Future<void>.delayed(Duration.zero);
      expect(flushed, isFalse);
      expect(writes, isEmpty);
      releaseNative.complete();
      await saveStarted.future;
      expect(flushed, isFalse);
      releaseSave.complete();
      await Future.wait([change, flushing]);
      expect(writes.single.volume, 18.75);
    },
  );

  test(
    'failed native volume or mute never persists unsuccessful settings',
    () async {
      final writes = <PlaybackSettings>[];
      final engine = FakeEngine();
      final playback = player(engine: engine, save: (s) async => writes.add(s));
      await playback.playQueue(_tracks);
      await playback.setVolume(31.5);
      await playback.flushSettings();
      engine.onSetVolume = (_) async => throw StateError('native rejected');
      await expectLater(playback.setVolume(80), throwsStateError);
      await expectLater(playback.toggleMute(), throwsStateError);
      await playback.flushSettings();
      expect(writes, hasLength(1));
      expect(writes.single.volume, 31.5);
      expect(playback.volume, 31.5);
      expect(playback.error, contains('native rejected'));
      engine.onSetVolume = null;
      await playback.toggleMute();
      await playback.flushSettings();
      expect(writes.last.volume, 0);
      expect(writes.last.lastPositiveVolume, 31.5);
    },
  );

  for (final setting in ['volume', 'shuffle', 'repeat']) {
    test(
      'failed storage reports error and identical $setting setter retries',
      () async {
        var fail = true;
        var attempts = 0;
        final writes = <PlaybackSettings>[];
        final engine = FakeEngine();
        final playback = player(
          engine: engine,
          save: (settings) async {
            attempts++;
            if (fail) throw StateError('disk full');
            writes.add(settings);
          },
        );
        await playback.playQueue(_tracks);
        Future<void> change() async {
          switch (setting) {
            case 'volume':
              await playback.setVolume(42.75);
            case 'shuffle':
              playback.setShuffle(true);
            case 'repeat':
              playback.setRepeat(RepeatMode.one);
          }
        }

        await change();
        await playback.flushSettings();
        expect(attempts, 1);
        expect(playback.error, contains('disk full'));
        expect(playback.isPlaying, isTrue);
        if (setting == 'volume') {
          expect(playback.volume, 42.75);
          expect(engine.volume, 42.75);
        } else if (setting == 'shuffle') {
          expect(playback.shuffle, isTrue);
        } else {
          expect(playback.repeatMode, RepeatMode.one);
        }
        fail = false;
        await change();
        await playback.flushSettings();
        expect(attempts, 2);
        expect(writes, hasLength(1));
        expect(playback.error, isNull);
        expect(writes.single.volume, setting == 'volume' ? 42.75 : null);
        expect(writes.single.shuffle, setting == 'shuffle');
        expect(
          writes.single.repeatMode,
          setting == 'repeat' ? RepeatMode.one : RepeatMode.off,
        );
      },
    );
  }

  test(
    'shutdown drains pending writes and ignores all later setters',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final writes = <PlaybackSettings>[];
      final engine = FakeEngine();
      final playback = player(
        engine: engine,
        save: (settings) async {
          writes.add(settings);
          if (writes.length == 1) {
            started.complete();
            await release.future;
          }
        },
      );
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      playback.setShuffle(true);
      await started.future;
      playback.setRepeat(RepeatMode.one);
      var closed = false;
      final closing = playback.shutdown().then((_) => closed = true);
      playback.setShuffle(false);
      playback.setRepeat(RepeatMode.off);
      await playback.setVolume(50);
      await playback.toggleMute();
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(engine.controller.isClosed, isFalse);
      expect(writes, hasLength(1));
      release.complete();
      await closing;
      expect(writes, hasLength(2));
      expect(writes.last.shuffle, isTrue);
      expect(writes.last.repeatMode, RepeatMode.one);
      expect(engine.controller.isClosed, isTrue);
      playback.setShuffle(false);
      playback.setRepeat(RepeatMode.off);
      await playback.setVolume(70);
      await playback.toggleMute();
      await playback.flushSettings();
      expect(writes, hasLength(2));
      expect(playback.volume, 100);
      expect(playback.shuffle, isTrue);
      expect(playback.repeatMode, RepeatMode.one);
    },
  );

  test(
    'system shuffle and repeat commands persist through the same store',
    () async {
      final store = SharedPreferencesPlaybackSettingsStore(
        await SharedPreferences.getInstance(),
      );
      final controls = _MockSystemControls();
      final playback = player(
        engine: FakeEngine(),
        controls: controls,
        save: store.write,
      );
      await playback.playQueue(_tracks);
      controls.commands.shuffle(true);
      controls.commands.repeat(RepeatMode.all.index);
      expect(playback.shuffle, isTrue);
      expect(playback.repeatMode, RepeatMode.all);
      await playback.flushSettings();
      final saved = await store.read();
      expect(saved.shuffle, isTrue);
      expect(saved.repeatMode, RepeatMode.all);
      expect(saved.volume, isNull);
    },
  );

  test(
    'stop and account recording changes preserve device preferences',
    () async {
      final store = SharedPreferencesPlaybackSettingsStore(
        await SharedPreferences.getInstance(),
      );
      final playback = player(engine: FakeEngine(), save: store.write);
      playback.configureRecording('account-one-device', (_) async {});
      await playback.playQueue(_tracks);
      await playback.setVolume(47.25);
      await playback.toggleMute();
      playback.setShuffle(true);
      playback.setRepeat(RepeatMode.all);
      await playback.flushSettings();
      final before = (await store.read()).toJson();
      await playback.stop();
      playback.configureRecording('account-two-device', (_) async {});
      await playback.playQueue(_tracks);
      await playback.flushSettings();
      expect((await store.read()).toJson(), before);
      expect(playback.isMuted, isTrue);
      expect(playback.shuffle, isTrue);
      expect(playback.repeatMode, RepeatMode.all);
      await playback.toggleMute();
      expect(playback.volume, 47.25);
      await playback.flushSettings();
      expect((await store.read()).lastPositiveVolume, 47.25);
    },
  );
}

class _MockSystemControls implements SystemMediaControls {
  late MediaCommands commands;

  @override
  Future<void> initialize(MediaCommands commands) async {
    this.commands = commands;
  }

  @override
  Future<void> update({
    required Track? track,
    required List<Track> queue,
    required int index,
    required bool playing,
    required bool buffering,
    bool waitingForAudio = false,
    required Duration position,
    required bool shuffle,
    required int repeat,
  }) async {}

  @override
  Future<void> dispose() async {}
}
