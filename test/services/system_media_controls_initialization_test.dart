import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smtc_windows/smtc_windows.dart' as win;
import 'package:yun/models/models.dart';
import 'package:yun/services/system_media_controls.dart';

MediaCommands _commands({Future<void> Function()? play}) => MediaCommands(
  play: play ?? () async {},
  pause: () async {},
  stop: () async {},
  next: () async {},
  previous: () async {},
  seek: (_) async {},
  shuffle: (_) {},
  repeat: (_) {},
);

Future<void> _update(NativeSystemMediaControls controls, String title) =>
    controls.update(
      track: Track(id: title, title: title),
      queue: [Track(id: title, title: title)],
      index: 0,
      playing: true,
      buffering: false,
      position: Duration.zero,
      shuffle: false,
      repeat: 0,
    );

class _Windows implements win.SMTCWindows {
  final buttons = StreamController<win.PressedButton>.broadcast(sync: true);
  final shuffle = StreamController<bool>.broadcast(sync: true);
  final repeat = StreamController<win.RepeatMode>.broadcast(sync: true);
  bool failRepeat = false;
  int disposals = 0;

  @override
  Stream<win.PressedButton> get buttonPressStream => buttons.stream;
  @override
  Stream<bool> get shuffleChangeStream => shuffle.stream;
  @override
  Stream<win.RepeatMode> get repeatModeChangeStream {
    if (failRepeat) throw StateError('partial subscription failure');
    return repeat.stream;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  Future<void> close() async {
    await buttons.close();
    await shuffle.close();
    await repeat.close();
  }
}

void main() {
  test(
    'native initialization coalesces, retries failure and stays idempotent',
    () async {
      var calls = 0;
      var gate = Completer<BaseAudioHandler>();
      final controls = NativeSystemMediaControls(
        initializeHandler: () {
          calls++;
          return gate.future;
        },
      );
      final first = controls.initialize(_commands());
      final concurrent = controls.initialize(_commands());
      expect(identical(first, concurrent), isTrue);
      final failure = expectLater(first, throwsStateError);
      gate.completeError(StateError('configure failed'));
      await failure;
      expect(calls, 1);
      final handler = BaseAudioHandler();
      gate = Completer<BaseAudioHandler>();
      final retry = controls.initialize(_commands());
      gate.complete(handler);
      await retry;
      await controls.initialize(_commands());
      expect(calls, 2);
      await _update(controls, 'Recovered');
      expect(handler.mediaItem.value!.title, 'Recovered');
      await controls.dispose();
    },
  );

  test(
    'dispose drains successful late initialization into idle once',
    () async {
      final gate = Completer<BaseAudioHandler>();
      final controls = NativeSystemMediaControls(
        initializeHandler: () => gate.future,
      );
      final initialization = controls.initialize(_commands());
      final disposal = controls.dispose();
      expect(identical(controls.dispose(), disposal), isTrue);
      final handler = BaseAudioHandler();
      handler.playbackState.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      gate.complete(handler);
      await Future.wait([initialization, disposal]);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.idle,
      );
      expect(handler.playbackState.value.playing, isFalse);
      await controls.initialize(_commands());
      await _update(controls, 'Ignored');
      expect(handler.mediaItem.value, isNull);
    },
  );

  test(
    'dispose tolerates failed in-flight initialization without retry',
    () async {
      final gate = Completer<BaseAudioHandler>();
      var calls = 0;
      final controls = NativeSystemMediaControls(
        initializeHandler: () {
          calls++;
          return gate.future;
        },
      );
      final initialization = expectLater(
        controls.initialize(_commands()),
        throwsStateError,
      );
      final disposal = controls.dispose();
      gate.completeError(StateError('late failure'));
      await Future.wait([initialization, disposal]);
      await controls.initialize(_commands());
      expect(calls, 1);
    },
  );

  test(
    'old disposal and pending snapshots cannot clear a newer handler owner',
    () async {
      final handler = BaseAudioHandler();
      final old = NativeSystemMediaControls(handler: handler);
      await _update(old, 'Old');
      final stale = _update(old, 'Stale pending update');
      final newer = NativeSystemMediaControls(handler: handler);
      final disposal = old.dispose();
      await _update(newer, 'New');
      await Future.wait([stale, disposal]);
      expect(handler.mediaItem.value!.title, 'New');
      expect(handler.queue.value.single.title, 'New');
      expect(handler.playbackState.value.playing, isTrue);
      await newer.dispose();
      expect(handler.mediaItem.value, isNull);
    },
  );

  test(
    'partial Windows subscriptions are cancelled before explicit retry',
    () async {
      final first = _Windows()..failRepeat = true;
      final second = _Windows();
      var calls = 0, plays = 0;
      final controls = NativeSystemMediaControls(
        initializeWindows: () async => ++calls == 1 ? first : second,
      );
      final commands = _commands(
        play: () async {
          plays++;
        },
      );
      await expectLater(controls.initialize(commands), throwsStateError);
      expect(first.disposals, 1);
      expect(first.buttons.hasListener, isFalse);
      expect(first.shuffle.hasListener, isFalse);
      await controls.initialize(commands);
      await controls.initialize(commands);
      expect(calls, 2);
      second.buttons.add(win.PressedButton.play);
      expect(plays, 1);
      await controls.dispose();
      second.buttons.add(win.PressedButton.play);
      expect(plays, 1);
      expect(second.disposals, 1);
      await first.close();
      await second.close();
    },
  );

  test(
    'late Windows allocation is disposed without installing callbacks',
    () async {
      final windows = _Windows();
      final gate = Completer<win.SMTCWindows>();
      final controls = NativeSystemMediaControls(
        initializeWindows: () => gate.future,
      );
      final initializing = controls.initialize(_commands());
      final disposal = controls.dispose();
      gate.complete(windows);
      await Future.wait([initializing, disposal]);
      expect(windows.disposals, 1);
      expect(windows.buttons.hasListener, isFalse);
      expect(windows.shuffle.hasListener, isFalse);
      expect(windows.repeat.hasListener, isFalse);
      await windows.close();
    },
  );
}
