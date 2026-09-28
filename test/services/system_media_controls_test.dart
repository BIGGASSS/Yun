import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/system_media_controls.dart';

void main() {
  test('queue changes independently of current ID, supports duplicates and revisions', () async {
    final handler = BaseAudioHandler();
    final controls = NativeSystemMediaControls(handler: handler);
    const a = Track(id: 'a', title: 'A');
    const b = Track(id: 'b', title: 'B');
    const c = Track(id: 'c', title: 'C');
    Future<void> update(List<Track> queue, {int index = 0, int position = 0}) =>
        controls.update(
          track: queue.isEmpty ? null : queue[index],
          queue: queue,
          index: queue.isEmpty ? -1 : index,
          playing: queue.isNotEmpty,
          buffering: false,
          position: Duration(milliseconds: position),
          shuffle: false,
          repeat: 0,
        );
    await update([a, b]);
    await update([a, c]);
    expect(handler.queue.value.map((item) => item.id), ['a', 'c']);
    await update([a, a, c], index: 1);
    expect(handler.queue.value.map((item) => item.id), ['a', 'a', 'c']);
    expect(handler.playbackState.value.queueIndex, 1);
    const revised = Track(
      id: 'a',
      title: 'Corrected title',
      durationMs: 1234,
      revision: 2,
    );
    await update([revised, a, c]);
    expect(handler.mediaItem.value!.title, 'Corrected title');
    expect(handler.mediaItem.value!.duration!.inMilliseconds, 1234);
    expect(handler.queue.value.first.title, 'Corrected title');
    final queueSnapshot = handler.queue.value;
    final itemSnapshot = handler.mediaItem.value;
    for (var i = 0; i < 10; i++) {
      await update([revised, a, c], position: i * 100);
    }
    // Position updates publish playback state, not repeated metadata/queues.
    expect(identical(handler.queue.value, queueSnapshot), isTrue);
    expect(identical(handler.mediaItem.value, itemSnapshot), isTrue);
    await update([]);
    expect(handler.queue.value, isEmpty);
    expect(handler.mediaItem.value, isNull);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.idle,
    );
    await controls.dispose();
  });
}
