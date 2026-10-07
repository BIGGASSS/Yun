import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yun/services/download_buffer.dart';

void main() {
  test('4 KiB network fragments produce one write per 256 KiB block', () async {
    final chunk = Uint8List(4096)..fillRange(0, 4096, 7);
    final lengths = <int>[];
    final writer = BufferedDownloadWriter(
      write: (buffer, length) async {
        lengths.add(length);
        expect(buffer.length, BufferedDownloadWriter.bufferSize);
        expect(buffer.take(length).every((byte) => byte == 7), isTrue);
      },
    );
    for (var i = 0; i < 1024; i++) {
      await writer.add(chunk);
    }
    await writer.flush();
    expect(lengths, List.filled(16, BufferedDownloadWriter.bufferSize));
  });

  test(
    'large fragments are split into bounded writes with one final tail',
    () async {
      final bytes = Uint8List.fromList(
        List.generate(
          3 * BufferedDownloadWriter.bufferSize + 17,
          (i) => i % 251,
        ),
      );
      final output = BytesBuilder(copy: false);
      final lengths = <int>[];
      final writer = BufferedDownloadWriter(
        write: (buffer, length) async {
          lengths.add(length);
          output.add(Uint8List.fromList(buffer.sublist(0, length)));
        },
      );
      await writer.add(bytes);
      expect(lengths, List.filled(3, BufferedDownloadWriter.bufferSize));
      await writer.flush();
      await writer.flush();
      await writer.add(Uint8List(0));
      expect(lengths, [
        ...List.filled(3, BufferedDownloadWriter.bufferSize),
        17,
      ]);
      expect(output.takeBytes(), bytes);
    },
  );

  test(
    'buffer owns its tail rather than retaining mutable source fragments',
    () async {
      final written = <int>[];
      final writer = BufferedDownloadWriter(
        write: (buffer, length) async => written.addAll(buffer.take(length)),
      );
      final chunk = Uint8List.fromList([1, 2, 3]);
      await writer.add(chunk);
      chunk.fillRange(0, chunk.length, 9);
      expect(written, isEmpty);
      await writer.flush();
      expect(written, [1, 2, 3]);
    },
  );

  testWidgets('byte ticks coalesce to the latest value every 100 ms', (
    tester,
  ) async {
    var liveBytes = 1;
    final observed = <int>[];
    final throttle = DownloadProgressThrottle(() => observed.add(liveBytes));
    addTearDown(throttle.close);
    throttle.schedule();
    await tester.pump(const Duration(milliseconds: 49));
    liveBytes = 2;
    throttle.schedule();
    await tester.pump(const Duration(milliseconds: 50));
    expect(observed, isEmpty);
    liveBytes = 3;
    throttle.schedule();
    await tester.pump(const Duration(milliseconds: 1));
    expect(observed, [3]);

    liveBytes = 4;
    throttle.schedule();
    await tester.pump(const Duration(milliseconds: 99));
    expect(observed, [3]);
    await tester.pump(const Duration(milliseconds: 1));
    expect(observed, [3, 4]);
    // A stalled stream produces one trailing tick, not periodic idle ticks.
    await tester.pump(const Duration(seconds: 1));
    expect(observed, [3, 4]);
  });

  testWidgets(
    'closing cancels trailing notifications and prevents rescheduling',
    (tester) async {
      var notifications = 0;
      final throttle = DownloadProgressThrottle(() => notifications++);
      throttle.schedule();
      await tester.pump(const Duration(milliseconds: 99));
      throttle.close();
      throttle.schedule();
      await tester.pump(const Duration(seconds: 1));
      expect(notifications, 0);
    },
  );
}
