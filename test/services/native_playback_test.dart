// Opt-in REAL libmpv/media_kit decode + timing smoke test, with NULL audio output.
// This is NOT a speaker, device routing, MPRIS, or mobile background-audio test.
// RUN_NATIVE_PLAYBACK=1 LD_LIBRARY_PATH=/path/to/extracted/usr/lib \
//   .fvm/flutter_sdk/bin/flutter test test/services/native_playback_test.dart
// Optional: LIBMPV_PATH=/absolute/path/to/libmpv.so
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as native;
import 'package:yun/core/playback_controller.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/playback_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'REAL native libmpv: volume, decode, pause, seek, queue completion, accounting (NULL audio)',
    () async {
      native.MediaKit.ensureInitialized(
        libmpv: Platform.environment['LIBMPV_PATH'],
      );
      final directory = await Directory.systemTemp.createTemp(
        'yun-native-smoke-',
      );
      final wav = File('${directory.path}/tone.wav');
      await wav.writeAsBytes(_tone());
      final errors = <String>[];
      final events = <ListeningEvent>[];
      late native.Player nativePlayer;
      final engine = MediaKitEngine(
        createPlayer: () async {
          final player = nativePlayer = native.Player();
          // Set before opening any media: no physical audio output is used.
          await (player.platform as native.NativePlayer).setProperty(
            'ao',
            'null',
          );
          return player;
        },
      );
      final subscription = engine.states.listen((state) {
        if (state.error != null) errors.add(state.error!);
      });
      final controller =
          PlaybackController(
            engine: engine,
            enableSystemControls: false,
            resolveSource: (_, _) async => AudioSource(wav.path, local: true),
          )..configureRecording('native-smoke', (event) async {
            events.add(event);
          });
      // UI loudness 37.5% is converted to mpv's native cubic volume scale.
      const expectedNativeVolume = 58.0978976016;
      // Native mixer options may round to single-precision floats.
      bool volumeRestored() =>
          (nativePlayer.state.volume - expectedNativeVolume).abs() < 1e-4;
      try {
        await controller.setVolume(37.5);
        await controller.playQueue(const [
          Track(id: 'tone-a', title: 'Generated PCM A', durationMs: 6000),
          Track(id: 'tone-b', title: 'Generated PCM B', durationMs: 6000),
        ]);
        await _until(() => controller.position.inMilliseconds >= 400);
        expect(controller.isPlaying, isTrue);
        expect(controller.duration.inMilliseconds, closeTo(6000, 100));
        await _until(volumeRestored);
        await controller.toggleMute();
        await _until(() => nativePlayer.state.volume == 0);
        expect(controller.isMuted, isTrue);
        await controller.toggleMute();
        await _until(volumeRestored);
        await controller.pause();
        await _until(() => !controller.isPlaying);
        final paused = controller.position;
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(
          (controller.position - paused).inMilliseconds.abs(),
          lessThan(150),
        );
        await controller.seek(const Duration(seconds: 3));
        await controller.play();
        await _until(() => controller.position.inMilliseconds >= 3400);
        await controller.seek(const Duration(milliseconds: 5700));
        await _until(() => controller.currentTrack?.id == 'tone-b');
        await _until(() => controller.position.inMilliseconds >= 300);
        expect(nativePlayer.state.volume, closeTo(expectedNativeVolume, 1e-4));
        expect(controller.volume, 37.5);
        await controller.seek(const Duration(milliseconds: 5800));
        await _until(() => controller.currentTrack == null);
        await controller.checkpoint();
        expect(errors, isEmpty);
        expect(events.map((e) => e.trackId).toSet(), {'tone-a', 'tone-b'});
        final listened = events.fold<int>(
          0,
          (total, e) => total + e.listenedMs,
        );
        expect(listened, greaterThan(500));
        // Seeking across twelve seconds of content must not count as listening.
        expect(listened, lessThan(5000));
        expect(controller.isPlaying, isFalse);
        expect(controller.volume, 37.5);
      } finally {
        await controller.shutdown();
        controller.dispose();
        await subscription.cancel();
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.environment['RUN_NATIVE_PLAYBACK'] != '1',
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Future<void> _until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 8)) {
      fail('Timed out waiting for real native playback state');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Uint8List _tone() {
  const rate = 44100, frames = rate * 6;
  final bytes = Uint8List(44 + frames * 2);
  final data = ByteData.sublistView(bytes);
  void text(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, value.codeUnits);
  text(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  text(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  text(36, 'data');
  data.setUint32(40, frames * 2, Endian.little);
  for (var i = 0; i < frames; i++) {
    data.setInt16(
      44 + i * 2,
      (sin(2 * pi * 440 * i / rate) * 4096).round(),
      Endian.little,
    );
  }
  return bytes;
}
