import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

enum VerificationStatus { preparing, running, completed, cancelled, failed }

/// Bytes are verification work, including known-size files rejected by stat.
/// Throughput uses only bytes actually hashed; missing/unknown files do not
/// create fictitious hashing speed. Unknown sizes contribute only to counts.
class DownloadVerificationProgress {
  const DownloadVerificationProgress({
    required this.status,
    this.totalFiles = 0,
    this.checkedFiles = 0,
    this.validFiles = 0,
    this.invalidFiles = 0,
    this.skippedFiles = 0,
    this.processedBytes = 0,
    this.totalBytes = 0,
    this.hashedBytes = 0,
    this.elapsed = Duration.zero,
    this.invalidTrackIds = const [],
    this.error,
  });

  final VerificationStatus status;
  final int totalFiles, checkedFiles, validFiles, invalidFiles, skippedFiles;
  final int processedBytes, totalBytes, hashedBytes;
  final Duration elapsed;
  final List<String> invalidTrackIds;
  final String? error;
  bool get isRunning =>
      status == VerificationStatus.preparing ||
      status == VerificationStatus.running;
  double? get fraction => status == VerificationStatus.preparing
      ? null
      : status == VerificationStatus.completed
      ? 1
      : totalBytes > 0
      ? (processedBytes / totalBytes).clamp(0.0, 1.0)
      : isRunning
      ? null
      : 0;
  Duration? get eta {
    if (status != VerificationStatus.running ||
        elapsed.inMilliseconds < 1000 ||
        hashedBytes <= 0 ||
        totalBytes <= processedBytes) {
      return null;
    }
    return Duration(
      milliseconds:
          ((totalBytes - processedBytes) * elapsed.inMilliseconds / hashedBytes)
              .ceil(),
    );
  }
}

class VerificationFile {
  const VerificationFile({
    required this.path,
    required this.sizeBytes,
    required this.sha256,
    required this.recordedSha256,
  });
  final String path, sha256;
  final Object? recordedSha256;
  final int sizeBytes;
}

enum FileVerificationOutcome { valid, invalid, skipped }

class FileVerificationResult {
  const FileVerificationResult(this.outcome, {this.error});
  final FileVerificationOutcome outcome;
  final String? error;
}

class VerificationCancelled implements Exception {}

/// Injectable for deterministic cancellation/concurrency tests. The production
/// implementation keeps hashing CPU and file reads off Flutter's UI isolate.
abstract class DownloadFileVerifier {
  Future<FileVerificationResult> verify(
    VerificationFile file,
    void Function(int bytesRead) onBytes,
  );
  void cancel();
  Future<void> close();
}

class IsolateDownloadFileVerifier implements DownloadFileVerifier {
  Isolate? _isolate;
  ReceivePort? _events;
  SendPort? _commands;
  Future<void>? _starting;
  StreamSubscription<dynamic>? _subscription;
  final Completer<SendPort> _ready = Completer<SendPort>();
  Completer<FileVerificationResult>? _result;
  void Function(int)? _onBytes;
  bool _cancelled = false;

  Future<void> _start() async {
    final events = _events = ReceivePort();
    _subscription = events.listen((dynamic message) {
      if (message is SendPort) {
        if (!_ready.isCompleted) _ready.complete(message);
      } else if (message is int) {
        _onBytes?.call(message);
      } else if (message is FileVerificationResult) {
        final pending = _result;
        if (pending != null && !pending.isCompleted) pending.complete(message);
      } else {
        final failure = _cancelled
            ? VerificationCancelled()
            : StateError('Verification worker stopped unexpectedly');
        if (!_ready.isCompleted) _ready.completeError(failure);
        final pending = _result;
        if (pending != null && !pending.isCompleted) {
          pending.completeError(failure);
        }
      }
    });
    _isolate = await Isolate.spawn(
      _verificationWorker,
      events.sendPort,
      onError: events.sendPort,
      onExit: events.sendPort,
    );
    if (_cancelled) {
      _isolate!.kill(priority: Isolate.immediate);
      if (!_ready.isCompleted) _ready.completeError(VerificationCancelled());
    }
    _commands = await _ready.future;
  }

  @override
  Future<FileVerificationResult> verify(
    VerificationFile file,
    void Function(int bytesRead) onBytes,
  ) async {
    if (_cancelled) throw VerificationCancelled();
    await (_starting ??= _start());
    if (_cancelled) throw VerificationCancelled();
    final pending = _result = Completer<FileVerificationResult>();
    _onBytes = onBytes;
    _commands!.send(file);
    try {
      return await pending.future;
    } finally {
      _result = null;
      _onBytes = null;
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    _isolate?.kill(priority: Isolate.immediate);
    final pending = _result;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(VerificationCancelled());
    }
  }

  @override
  Future<void> close() async {
    cancel();
    try {
      await _starting;
    } catch (_) {
      // The caller observes startup/cancellation through verify().
    }
    await _subscription?.cancel();
    _events?.close();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

Future<void> _verificationWorker(SendPort events) async {
  final commands = ReceivePort();
  events.send(commands.sendPort);
  await for (final dynamic command in commands) {
    final input = command as VerificationFile;
    try {
      final file = File(input.path);
      final before = await file.stat();
      if (input.recordedSha256 != input.sha256 ||
          before.type != FileSystemEntityType.file ||
          before.size != input.sizeBytes) {
        events.send(
          const FileVerificationResult(FileVerificationOutcome.invalid),
        );
        continue;
      }
      final digest = _DigestSink();
      final sink = sha256.startChunkedConversion(digest);
      final clock = Stopwatch()..start();
      var read = 0, lastUpdate = -100;
      try {
        await for (final chunk in file.openRead()) {
          sink.add(chunk);
          read += chunk.length;
          if (clock.elapsedMilliseconds - lastUpdate >= 100) {
            events.send(read);
            lastUpdate = clock.elapsedMilliseconds;
          }
        }
      } finally {
        sink.close();
      }
      events.send(read);
      final after = await file.stat();
      if (before.size != after.size ||
          before.modified != after.modified ||
          before.changed != after.changed ||
          read != before.size) {
        events.send(
          const FileVerificationResult(
            FileVerificationOutcome.skipped,
            error: 'File changed during verification; run verification again.',
          ),
        );
        continue;
      }
      events.send(
        FileVerificationResult(
          digest.value.toString() == input.sha256
              ? FileVerificationOutcome.valid
              : FileVerificationOutcome.invalid,
        ),
      );
    } on FileSystemException {
      events.send(
        const FileVerificationResult(
          FileVerificationOutcome.skipped,
          error:
              'A file could not be read. Check storage access and try again.',
        ),
      );
    } catch (_) {
      events.send(
        const FileVerificationResult(
          FileVerificationOutcome.skipped,
          error: 'A file could not be verified. Try again.',
        ),
      );
    }
  }
}
