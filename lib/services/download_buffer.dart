import 'dart:async';
import 'dart:typed_data';

/// Coalesces network fragments into bounded writes. Calls to [add] and [flush]
/// must be awaited serially; the write callback borrows the buffer until it
/// completes. Neither this class nor its caller retries a failed file write.
class BufferedDownloadWriter {
  BufferedDownloadWriter({required this.write});

  static const bufferSize = 256 * 1024;
  final Future<void> Function(Uint8List bytes, int length) write;
  final Uint8List _buffer = Uint8List(bufferSize);
  int _used = 0;

  Future<void> add(Uint8List chunk) async {
    var start = 0;
    while (start < chunk.length) {
      final available = bufferSize - _used;
      final remaining = chunk.length - start;
      final count = remaining < available ? remaining : available;
      _buffer.setRange(_used, _used + count, chunk, start);
      _used += count;
      start += count;
      if (_used == bufferSize) await flush();
    }
  }

  Future<void> flush() async {
    if (_used == 0) return;
    final length = _used;
    // A failed write may already have written a prefix. Do not append the
    // same buffer again when the download's error handler drains its tail.
    _used = 0;
    await write(_buffer, length);
  }
}

/// Trailing byte notifications use the latest live progress, not a captured
/// snapshot. Status changes bypass this throttle in TransferService.
class DownloadProgressThrottle {
  DownloadProgressThrottle(this._notify);

  static const interval = Duration(milliseconds: 100);
  final void Function() _notify;
  Timer? _timer;
  bool _closed = false;

  void schedule() {
    if (_closed) return;
    _timer ??= Timer(interval, () {
      _timer = null;
      _notify();
    });
  }

  void close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }
}
