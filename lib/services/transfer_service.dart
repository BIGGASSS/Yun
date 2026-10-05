import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../models/models.dart';
import 'api_client.dart';
import 'cache_database.dart';
import 'download_verification.dart';

export 'download_verification.dart';

/// Pin selections are durable references, not independent copies of audio.
Map<String, int> pinReferences(
  List<PinSelection> pins,
  List<Track> tracks,
  List<Playlist> playlists,
) {
  final refs = <String, int>{};
  final known = <String>{};
  final albums = <String, Set<String>>{};
  final playlistTracks = <String, Set<String>>{};
  // Build membership indexes once per snapshot, not once per selection.
  for (final track in tracks) {
    known.add(track.id);
    final album = albumPinId(
      track.album,
      track.albumArtist.isEmpty ? track.artist : track.albumArtist,
    );
    (albums[album] ??= {}).add(track.id);
  }
  for (final playlist in playlists) {
    (playlistTracks[playlist.id] ??= {}).addAll(
      playlist.entries.map((entry) => entry.trackId),
    );
  }
  for (final pin in pins) {
    final Iterable<String> ids = switch (pin.type) {
      'track' => [pin.id],
      'album' => albums[pin.id] ?? const <String>{},
      'playlist' => playlistTracks[pin.id] ?? const <String>{},
      _ => const <String>[],
    };
    for (final id in ids) {
      if (known.contains(id)) {
        refs.update(id, (n) => n + 1, ifAbsent: () => 1);
      }
    }
  }
  return refs;
}

enum DownloadStatus {
  availableOnline,
  queued,
  downloading,
  verifying,
  failed,
  downloaded,
}

class DownloadProgress {
  const DownloadProgress({
    required this.trackId,
    required this.totalBytes,
    this.receivedBytes = 0,
    this.status = DownloadStatus.queued,
    this.error,
    this.historyCleared = false,
    this.repairRequired = false,
    this.previouslyDownloaded = false,
  });
  final String trackId;
  final int receivedBytes, totalBytes;
  final DownloadStatus status;
  final String? error;

  /// Dismiss completed activity without removing its verified local audio.
  final bool historyCleared;

  /// An existing download is unavailable. Only explicit repair clears this.
  final bool repairRequired;

  /// Preserve offline playback intent while an explicit repair is in progress
  /// or fails. A queued first download alone must not prevent online playback.
  final bool previouslyDownloaded;
  bool get requiresOfflinePlayback =>
      previouslyDownloaded ||
      repairRequired ||
      status == DownloadStatus.downloaded;
  double get fraction =>
      totalBytes <= 0 ? 0 : (receivedBytes / totalBytes).clamp(0.0, 1.0);
  Map<String, dynamic> toJson() => {
    'id': trackId,
    'received_bytes': receivedBytes,
    'total_bytes': totalBytes,
    'status': status.name,
    'error': error,
    'history_cleared': historyCleared,
    'repair_required': repairRequired,
    'previously_downloaded': requiresOfflinePlayback,
  };
  factory DownloadProgress.fromJson(Map<String, dynamic> j) => DownloadProgress(
    trackId: j['id'] as String,
    totalBytes: (j['total_bytes'] as num).toInt(),
    receivedBytes: (j['received_bytes'] as num).toInt(),
    status: DownloadStatus.values.byName(j['status'] as String),
    error: j['error'] as String?,
    historyCleared: j['history_cleared'] as bool? ?? false,
    repairRequired: j['repair_required'] as bool? ?? false,
    previouslyDownloaded: j['previously_downloaded'] as bool? ?? false,
  );
}

/// Expected cancellation when an account closes or a selection is removed.
class TransferCancelled extends StateError {
  TransferCancelled() : super('Transfer cancelled');
}

/// Immutable selections plus their once-computed membership index.
class _DownloadSelection {
  _DownloadSelection(
    List<Track> tracks,
    List<Playlist> playlists,
    List<PinSelection> pins,
  ) : tracks = List.of(tracks),
      references = pinReferences(pins, tracks, playlists);

  final List<Track> tracks;
  final Map<String, int> references;
}

class TransferService {
  TransferService({
    required this.api,
    required this.database,
    required this.directory,
    required this.onChanged,
    required this.onTrack,
    required this.onError,
    this.onDownloadChanged,
    this.onFilesChanged,
    this.onUploadChanged,
    this.onUploadsRemoved,
    this.onFileChanged,
    this.onDownloaded,
    this.onVerificationChanged,
    DownloadFileVerifier Function()? verificationWorkerFactory,
    Directory? importsDirectory,
  }) : _verificationWorkerFactory =
           verificationWorkerFactory ?? IsolateDownloadFileVerifier.new,
       importsDirectory =
           importsDirectory ?? Directory(p.join(directory.path, 'imports'));
  final ApiClient api;
  final CacheDatabase database;
  final Directory directory;
  final Directory importsDirectory;
  static const defaultMaxUploadBytes = 1024 * 1024 * 1024;
  final Set<Future<UploadJob>> _importsRunning = {};

  File _importFile(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(id)) {
      throw ArgumentError('Invalid upload ID');
    }
    return File(p.join(importsDirectory.absolute.path, '$id.source'));
  }

  Future<void> _prepareImports() async {
    final type = await FileSystemEntity.type(
      importsDirectory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw StateError('Upload spool must be a private directory');
    }
    await importsDirectory.create(recursive: true);
  }

  /// Call while the picker still grants access. No external path is queued:
  /// bytes are streamed to a flushed .part, atomically renamed, then persisted.
  Future<UploadJob> enqueueUpload(
    String id,
    String path, {
    int maxBytes = defaultMaxUploadBytes,
  }) {
    if (_closed) return Future.error(TransferCancelled());
    final operation = _importUpload(id, path, maxBytes);
    _importsRunning.add(operation);
    return operation.whenComplete(() => _importsRunning.remove(operation));
  }

  Future<UploadJob> _importUpload(String id, String path, int maxBytes) async {
    final source = File(path);
    final before = await source.stat();
    if (before.type != FileSystemEntityType.file || before.size <= 0) {
      throw ArgumentError('Upload source must be a non-empty regular file');
    }
    if (maxBytes <= 0 || before.size > maxBytes) {
      throw ArgumentError('Upload exceeds the $maxBytes byte limit');
    }
    await _prepareImports();
    final destination = _importFile(id);
    final partial = File('${destination.path}.part');
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
            FileSystemEntityType.notFound ||
        await FileSystemEntity.type(partial.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw StateError('Upload source already exists');
    }
    var committed = false;
    try {
      final output = await partial.open(mode: FileMode.write);
      try {
        var copied = 0;
        await for (final chunk in source.openRead()) {
          if (_closed) throw TransferCancelled();
          copied += chunk.length;
          if (copied > maxBytes || copied > before.size) {
            throw StateError('Upload source has changed during import');
          }
          await output.writeFrom(chunk);
        }
        final after = await source.stat();
        if (after.type != FileSystemEntityType.file ||
            copied != before.size ||
            after.size != before.size ||
            after.modified != before.modified ||
            after.changed != before.changed) {
          throw StateError('Upload source has changed during import');
        }
        await output.flush();
      } finally {
        await output.close();
      }
      if (_closed) throw TransferCancelled();
      await partial.rename(destination.path);
      final stat = await destination.stat();
      final job = UploadJob(
        id: id,
        localPath: destination.path,
        filename: p.basename(path),
        sizeBytes: stat.size,
        modifiedAtMs: stat.modified.millisecondsSinceEpoch,
        ownedSource: true,
      );
      if (_closed) throw TransferCancelled();
      await database.put('upload', id, job.toJson());
      committed = true;
      _publishUpload(id, job);
      return job;
    } finally {
      if (!committed) {
        if (await partial.exists()) await partial.delete();
        if (await destination.exists()) await destination.delete();
      }
    }
  }

  Future<void> _deleteOwnedSource(UploadJob job) async {
    if (!job.ownedSource || !RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(job.id)) {
      return;
    }
    final expected = _importFile(job.id);
    if (p.normalize(File(job.localPath).absolute.path) !=
        p.normalize(expected.path)) {
      return;
    }
    // Never follow a spool/file symlink, or trust an arbitrary JSON path.
    if (await FileSystemEntity.type(
              importsDirectory.path,
              followLinks: false,
            ) !=
            FileSystemEntityType.directory ||
        await FileSystemEntity.type(expected.path, followLinks: false) !=
            FileSystemEntityType.file) {
      return;
    }
    await expected.delete();
  }

  /// Startup only, before accepting imports. Keep all resumable job sources;
  /// collect interrupted copies and copies orphaned between rename and DB put.
  Future<void> restoreUploads() async {
    await _prepareImports();
    final retained = <String>{};
    for (final record in await database.list('upload')) {
      final job = UploadJob.fromJson(record);
      if (job.ownedSource &&
          (job.status == 'done' || job.status == 'cancelled')) {
        await _deleteOwnedSource(job);
      } else {
        retained.add(p.normalize(File(job.localPath).absolute.path));
      }
    }
    await for (final entity in importsDirectory.list(followLinks: false)) {
      if (entity is! File ||
          !RegExp(r'^[a-zA-Z0-9_-]+\.source(\.part)?$')
              .hasMatch(p.basename(entity.path)) ||
          retained.contains(p.normalize(entity.absolute.path))) {
        continue;
      }
      await entity.delete();
    }
  }

  final void Function() onChanged;
  final Future<void> Function(Track) onTrack;
  final void Function(Object) onError;
  final void Function()? onDownloadChanged;
  final void Function()? onFilesChanged;

  /// Committed record deltas; null means removal. Published synchronously so
  /// awaiting an operation also observes its updated inventory.
  final void Function(String id, UploadJob? job)? onUploadChanged;
  final void Function(Set<String> ids)? onUploadsRemoved;
  final void Function(String id, Map<String, dynamic>? record)? onFileChanged;

  void _publishUpload(String id, UploadJob? job) {
    if (onUploadChanged != null) {
      onUploadChanged!(id, job);
    } else {
      onChanged();
    }
  }

  void _publishFile(String id, Map<String, dynamic>? record) {
    if (onFileChanged != null) {
      onFileChanged!(id, record);
    } else {
      (onFilesChanged ?? onChanged)();
    }
  }

  final Future<void> Function(Track)? onDownloaded;
  final void Function()? onVerificationChanged;
  final DownloadFileVerifier Function() _verificationWorkerFactory;
  final Map<String, DownloadProgress> _downloads = {};
  final Set<String> _runningDownloadIds = {};
  final Set<String> _downloadBatchIds = {};
  final Set<String> _completedDownloadBatchIds = {};

  /// Live workers only; queued and restored interrupted jobs are not running.
  bool get hasRunningDownloads => _runningDownloadIds.isNotEmpty;

  /// Current reconciliation batch, excluding downloads completed before it.
  ({int completed, int total}) get downloadBatchProgress => (
    completed: _completedDownloadBatchIds.length,
    total: _downloadBatchIds.length,
  );
  Map<String, DownloadProgress> get downloads => Map.unmodifiable(_downloads);
  DownloadProgress? progressFor(String trackId) => _downloads[trackId];
  int _downloadSectionsRevision = 0;

  /// Changes only when activity moves between sections, not on byte ticks.
  int get downloadSectionsRevision => _downloadSectionsRevision;

  /// Startup only, before accepting reconciliations or history clears.
  Future<void> restoreDownloads() async {
    // Restore cached identities with cheap metadata checks only. Full hashing
    // of existing audio belongs exclusively to the explicit Downloads action.
    // Keep the legacy-file path, but do not read its audio bytes at startup.
    for (final record in await database.list('download')) {
      final saved = DownloadProgress.fromJson(record);
      _downloads[saved.trackId] = saved;
    }
    final available = <String, Track>{};
    for (final record in await database.list('file')) {
      final id = record['id'] as String;
      final trackRecord = await database.get('track', id);
      if (trackRecord != null) {
        final track = Track.fromJson(trackRecord);
        if (await _hasExpectedFileMetadata(track, record)) {
          available[id] = track;
          continue;
        }
      }
      if (trackRecord != null) {
        await holdUnavailableDownload(Track.fromJson(trackRecord));
      } else {
        await _invalidateFile(id, record);
      }
    }
    for (final record in await database.list('download')) {
      final saved = DownloadProgress.fromJson(record);
      final interrupted =
          saved.status == DownloadStatus.downloading ||
          saved.status == DownloadStatus.verifying;
      final needsVerification =
          available.containsKey(saved.trackId) ||
          interrupted ||
          saved.status == DownloadStatus.downloaded;
      if (needsVerification) {
        final track = available[saved.trackId];
        if (track != null) {
          _downloads[saved.trackId] = DownloadProgress(
            trackId: saved.trackId,
            totalBytes: track.sizeBytes,
            receivedBytes: track.sizeBytes,
            status: DownloadStatus.downloaded,
            historyCleared: saved.historyCleared && !interrupted,
          );
          await _saveDownload(saved.trackId);
          continue;
        }
      }
      if ((saved.repairRequired || saved.status == DownloadStatus.downloaded) &&
          !available.containsKey(saved.trackId)) {
        _downloads[saved.trackId] = DownloadProgress(
          trackId: saved.trackId,
          totalBytes: saved.totalBytes,
          status: DownloadStatus.failed,
          error: saved.repairRequired
              ? saved.error
              : _unavailableDownloadMessage,
          repairRequired: true,
          previouslyDownloaded: true,
        );
        await _saveDownload(saved.trackId);
        continue;
      }
      final partial = File(
        p.join(
          directory.path,
          '${Uri.encodeComponent(saved.trackId)}.audio.part',
        ),
      );
      _downloads[saved.trackId] = DownloadProgress(
        trackId: saved.trackId,
        totalBytes: saved.totalBytes,
        receivedBytes: await partial.exists() ? await partial.length() : 0,
        status: needsVerification ? DownloadStatus.queued : saved.status,
        error: needsVerification ? null : saved.error,
        historyCleared: saved.historyCleared && !needsVerification,
        repairRequired: saved.repairRequired,
        previouslyDownloaded: saved.requiresOfflinePlayback,
      );
      if (needsVerification) await _saveDownload(saved.trackId);
    }
    // Upgrade legacy file-only records in one commit, rather than fsync each
    // cached track on the first startup. Publish memory only after acceptance.
    final legacyCompletions = {
      for (final track in available.values)
        if (!_downloads.containsKey(track.id))
          track.id: DownloadProgress(
            trackId: track.id,
            totalBytes: track.sizeBytes,
            receivedBytes: track.sizeBytes,
            status: DownloadStatus.downloaded,
          ),
    };
    if (legacyCompletions.isNotEmpty) {
      await database.transaction(() async {
        for (final entry in legacyCompletions.entries) {
          await database.put('download', entry.key, entry.value.toJson());
        }
      });
      _downloads.addAll(legacyCompletions);
      _downloadSectionsRevision++;
      (onDownloadChanged ?? onChanged)();
    }
    final knownIds = {
      for (final track in await database.list('track')) track['id'],
    };
    final damaged = [
      for (final progress in _downloads.values)
        if (progress.repairRequired && knownIds.contains(progress.trackId))
          progress.trackId,
    ];
    if (damaged.isNotEmpty) {
      _verificationProgress = DownloadVerificationProgress(
        status: VerificationStatus.completed,
        totalFiles: damaged.length,
        checkedFiles: damaged.length,
        invalidFiles: damaged.length,
        invalidTrackIds: List.unmodifiable(damaged),
        error: 'Downloaded files are unavailable and need repair.',
      );
      onVerificationChanged?.call();
    }
  }

  static const _unavailableDownloadMessage =
      'Downloaded audio is missing or unavailable. Redownload to repair.';

  /// Keep a failed existing copy offline until the user explicitly repairs it.
  /// This never deletes bytes or contacts the server. Recheck under a transaction
  /// so a concurrent replacement cannot be quarantined using stale evidence.
  Future<bool> holdUnavailableDownload(Track track) async {
    if (_closed) throw TransferCancelled();
    DownloadProgress? failed;
    await database.transaction(() async {
      if (_closed) throw TransferCancelled();
      final record = await database.get('file', track.id);
      final currentTrack = await database.get('track', track.id);
      if (currentTrack != null &&
          (currentTrack['sha256'] != track.sha256 ||
              currentTrack['size_bytes'] != track.sizeBytes)) {
        return;
      }
      final previous = _downloads[track.id];
      if (record == null && previous?.status != DownloadStatus.downloaded) {
        return;
      }
      if (record != null && await _hasExpectedFileMetadata(track, record)) {
        return;
      }
      failed = DownloadProgress(
        trackId: track.id,
        totalBytes: track.sizeBytes,
        status: DownloadStatus.failed,
        error: previous?.repairRequired == true
            ? previous!.error
            : _unavailableDownloadMessage,
        repairRequired: true,
        previouslyDownloaded: true,
      );
      await database.remove('file', track.id);
      await database.put('download', track.id, failed!.toJson());
    });
    if (failed == null) return false;
    _downloads[track.id] = failed!;
    _runningDownloadIds.remove(track.id);
    _completedDownloadBatchIds.remove(track.id);
    _downloadSectionsRevision++;
    _publishFile(track.id, null);
    (onDownloadChanged ?? onChanged)();
    return true;
  }

  Future<bool> _hasExpectedFileMetadata(
    Track track,
    Map<String, dynamic> record,
  ) async {
    if (record['sha256'] != track.sha256) return false;
    final file = File(record['path'] as String);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size != track.sizeBytes) {
      return false;
    }
    return true;
  }

  Future<void> _invalidateFile(String id, Map<String, dynamic> record) async {
    // Remove the playable reference before attempting cleanup or replacement.
    await database.remove('file', id);
    _publishFile(id, null);
    final file = File(record['path'] as String);
    if (await file.exists()) await file.delete();
  }

  DownloadVerificationProgress? _verificationProgress;
  DownloadVerificationProgress? get verificationProgress =>
      _verificationProgress;
  Future<void>? _verificationRunning;
  DownloadFileVerifier? _verificationWorker;
  bool _verificationCancelled = false;
  Completer<void>? _verificationStop;

  /// One scan per account. Navigation does not own or cancel this operation.
  Future<void> verifyDownloads() {
    if (_closed) return Future.error(TransferCancelled());
    if (_verificationRunning != null) return _verificationRunning!;
    final completed = Completer<void>();
    _verificationRunning = completed.future;
    _verificationCancelled = false;
    _verificationStop = Completer<void>();
    _verificationProgress = const DownloadVerificationProgress(
      status: VerificationStatus.preparing,
    );
    onVerificationChanged?.call();
    unawaited(() async {
      try {
        await _verifyDownloads();
      } finally {
        _verificationRunning = null;
        completed.complete();
        // Existing sync/download requests retain their latest selections. Files
        // quarantined by this scan are held until explicit repair, even on restart.
        unawaited(
          _resumeReconciliations().catchError((Object e) => onError(e)),
        );
      }
    }());
    return completed.future;
  }

  void cancelVerification() {
    _verificationCancelled = true;
    if (_verificationStop?.isCompleted == false) _verificationStop!.complete();
    _verificationWorker?.cancel();
  }

  Future<void> _resumeReconciliations() {
    if (_closed ||
        _verificationRunning != null ||
        _nextReconciliation == null) {
      return Future.value();
    }
    return _downloadsRunning ??= _drainReconciliations();
  }

  Future<void> _verifyDownloads() async {
    final clock = Stopwatch();
    var total = 0, checked = 0, valid = 0, invalid = 0, skipped = 0;
    var totalBytes = 0, processed = 0, hashed = 0, currentReading = 0;
    final damaged = <String>{
      for (final progress in _downloads.values)
        if (progress.repairRequired) progress.trackId,
    };
    String? lastError;
    var terminalStatus = VerificationStatus.completed;
    void publish(VerificationStatus status, {int reading = 0}) {
      _verificationProgress = DownloadVerificationProgress(
        status: status,
        totalFiles: total,
        checkedFiles: checked,
        validFiles: valid,
        invalidFiles: invalid,
        skippedFiles: skipped,
        processedBytes: (processed + reading).clamp(0, totalBytes),
        totalBytes: totalBytes,
        hashedBytes: hashed + reading,
        elapsed: clock.elapsed,
        invalidTrackIds: List.unmodifiable(damaged),
        error: lastError,
      );
      if (!_closed) onVerificationChanged?.call();
    }

    bool getCancelled() => _closed || _verificationCancelled;
    try {
      // Let the current track finish; the reconciliation loop yields before
      // opening another. A scan never hashes a partial or replacement in flight.
      if (_downloadsRunning != null) {
        await Future.any([_downloadsRunning!, _verificationStop!.future]);
      }
      if (getCancelled()) throw VerificationCancelled();
      final records = await database.list('file');
      final tracks = {
        for (final record in await database.list('track'))
          record['id'] as String: Track.fromJson(record),
      };
      damaged.retainAll(tracks.keys);
      total = records.length;
      for (final record in records) {
        final size = tracks[record['id']]?.sizeBytes ?? 0;
        if (size > 0) totalBytes += size;
      }
      if (getCancelled()) throw VerificationCancelled();
      clock.start();
      publish(VerificationStatus.running);
      final worker = _verificationWorker = _verificationWorkerFactory();
      for (final record in records) {
        if (getCancelled()) throw VerificationCancelled();
        final id = record['id'] as String;
        final track = tracks[id];
        if (track == null) {
          checked++;
          skipped++;
          lastError = 'A cached file has no library metadata and was skipped.';
          publish(VerificationStatus.running);
          continue;
        }
        var reading = 0;
        final result = await worker.verify(
          VerificationFile(
            path: record['path'] as String,
            sizeBytes: track.sizeBytes,
            sha256: track.sha256,
            recordedSha256: record['sha256'],
          ),
          (bytes) {
            reading = bytes.clamp(0, track.sizeBytes);
            currentReading = reading;
            if (!getCancelled()) {
              publish(VerificationStatus.running, reading: reading);
            }
          },
        );
        if (getCancelled()) throw VerificationCancelled();
        var outcome = result.outcome;
        DownloadProgress? invalidProgress;
        lastError = result.error ?? lastError;
        // Library sync may update metadata while the worker runs. Compare under
        // a transaction and never invalidate a newer identity or replacement.
        await database.transaction(() async {
          if (getCancelled()) throw VerificationCancelled();
          final current = await database.get('file', id);
          final currentTrack = await database.get('track', id);
          if (current?['path'] != record['path'] ||
              current?['sha256'] != record['sha256'] ||
              currentTrack?['sha256'] != track.sha256 ||
              currentTrack?['size_bytes'] != track.sizeBytes) {
            outcome = FileVerificationOutcome.skipped;
            lastError = 'Library changed during verification; run it again.';
            return;
          }
          if (outcome == FileVerificationOutcome.invalid) {
            final failed = DownloadProgress(
              trackId: id,
              totalBytes: track.sizeBytes,
              status: DownloadStatus.failed,
              error: 'Cached audio failed verification. Redownload to repair.',
              repairRequired: true,
            );
            await database.remove('file', id);
            await database.put('download', id, failed.toJson());
            invalidProgress = failed;
          }
        });
        if (outcome == FileVerificationOutcome.invalid) {
          _downloads[id] = invalidProgress!;
          _runningDownloadIds.remove(id);
          _completedDownloadBatchIds.remove(id);
          damaged.add(id);
          invalid++;
          _downloadSectionsRevision++;
          _publishFile(id, null);
          (onDownloadChanged ?? onChanged)();
          // The invalid reference is already quarantined. Failure to delete
          // leftover bytes does not allow playback or prevent other checks.
          try {
            final file = File(record['path'] as String);
            if (await FileSystemEntity.type(file.path, followLinks: false) ==
                FileSystemEntityType.file) {
              await file.delete();
            }
          } on FileSystemException {
            lastError =
                'A corrupt file was quarantined but could not be removed.';
          }
        } else if (outcome == FileVerificationOutcome.valid) {
          valid++;
        } else {
          skipped++;
        }
        checked++;
        processed += track.sizeBytes > 0 ? track.sizeBytes : 0;
        hashed += reading;
        currentReading = 0;
        publish(VerificationStatus.running);
      }
      terminalStatus = getCancelled()
          ? VerificationStatus.cancelled
          : VerificationStatus.completed;
    } on VerificationCancelled {
      terminalStatus = VerificationStatus.cancelled;
    } catch (_) {
      lastError =
          'Verification could not finish. Check storage access and try again.';
      terminalStatus = getCancelled()
          ? VerificationStatus.cancelled
          : VerificationStatus.failed;
    } finally {
      clock.stop();
      try {
        await _verificationWorker?.close();
      } catch (_) {
        if (!getCancelled()) {
          lastError = 'Verification worker could not close cleanly. Try again.';
          terminalStatus = VerificationStatus.failed;
        }
      }
      _verificationWorker = null;
      publish(terminalStatus, reading: currentReading);
    }
  }

  /// Repairs only explicit manual-check failures through the existing verified
  /// download path. The controller adds a pin only if no selection covers it.
  Future<void> redownloadCorruptedFiles(
    List<Track> tracks,
    List<Playlist> playlists,
    List<PinSelection> pins,
  ) async {
    if (_closed) throw TransferCancelled();
    if (_verificationRunning != null) return;
    final known = {for (final track in tracks) track.id: track};
    for (final id in _verificationProgress?.invalidTrackIds ?? <String>[]) {
      final track = known[id];
      if (track == null ||
          _downloads[id]?.status == DownloadStatus.downloaded) {
        continue;
      }
      _progress(track, DownloadStatus.queued, 0);
      await _saveDownload(id);
    }
    await reconcile(tracks, playlists, pins);
    final previous = _verificationProgress;
    if (previous != null && !_closed) {
      _verificationProgress = DownloadVerificationProgress(
        status: previous.status,
        totalFiles: previous.totalFiles,
        checkedFiles: previous.checkedFiles,
        validFiles: previous.validFiles,
        invalidFiles: previous.invalidFiles,
        skippedFiles: previous.skippedFiles,
        processedBytes: previous.processedBytes,
        totalBytes: previous.totalBytes,
        hashedBytes: previous.hashedBytes,
        elapsed: previous.elapsed,
        error: previous.error,
        invalidTrackIds: List.unmodifiable(
          previous.invalidTrackIds.where(
            (id) =>
                known.containsKey(id) &&
                _downloads[id]?.status != DownloadStatus.downloaded,
          ),
        ),
      );
      onVerificationChanged?.call();
    }
  }

  final Set<String> _requestedRedownloads = {};

  /// The explicit per-track repair action, serialized with downloads and scans.
  /// Bytes are replaced only after this user action; successful replacement must
  /// pass the same checksum validation as every other download.
  Future<void> redownloadTrack(
    Track track,
    List<Track> tracks,
    List<Playlist> playlists,
    List<PinSelection> pins,
  ) {
    if (_closed) return Future.error(TransferCancelled());
    _requestedRedownloads.add(track.id);
    return reconcile(tracks, playlists, pins);
  }

  bool _progress(
    Track track,
    DownloadStatus status,
    int bytes, {
    String? error,
  }) {
    final previous = _downloads[track.id];
    if (previous != null &&
        !previous.repairRequired &&
        previous.status == status &&
        previous.totalBytes == track.sizeBytes &&
        previous.receivedBytes == bytes &&
        previous.error == error) {
      return false;
    }
    _downloads[track.id] = DownloadProgress(
      trackId: track.id,
      totalBytes: track.sizeBytes,
      receivedBytes: bytes,
      status: status,
      error: error,
      previouslyDownloaded: previous?.requiresOfflinePlayback ?? false,
    );
    if (status == DownloadStatus.downloading ||
        status == DownloadStatus.verifying) {
      _runningDownloadIds.add(track.id);
    } else {
      _runningDownloadIds.remove(track.id);
    }
    if (_downloadBatchIds.contains(track.id)) {
      if (status == DownloadStatus.downloaded) {
        _completedDownloadBatchIds.add(track.id);
      } else {
        _completedDownloadBatchIds.remove(track.id);
      }
    }
    if (_downloadSection(previous?.status) != _downloadSection(status) ||
        previous?.historyCleared == true) {
      _downloadSectionsRevision++;
    }
    (onDownloadChanged ?? onChanged)();
    return true;
  }

  Future<void> _saveDownload(String id) =>
      database.put('download', id, _downloads[id]!.toJson());

  static int _downloadSection(DownloadStatus? status) => switch (status) {
    DownloadStatus.downloaded => 1,
    DownloadStatus.failed => 2,
    _ => 0,
  };

  /// Retain completion records so a later sync does not recreate cleared Done
  /// entries. A real download changes status and starts fresh activity.
  Future<void> clearDoneDownloads(Iterable<Track> downloadedTracks) async {
    final cleared = <String, DownloadProgress>{};
    final previous = <String, DownloadProgress?>{};
    await database.transaction(() async {
      for (final track in downloadedTracks) {
        final progress = _downloads[track.id];
        if (progress?.historyCleared == true ||
            (progress != null &&
                progress.status != DownloadStatus.downloaded)) {
          continue;
        }
        final record = await database.get('file', track.id);
        if (record == null || !await _hasExpectedFileMetadata(track, record)) {
          continue;
        }
        final dismissed = DownloadProgress(
          trackId: track.id,
          totalBytes: track.sizeBytes,
          receivedBytes: track.sizeBytes,
          status: DownloadStatus.downloaded,
          historyCleared: true,
        );
        await database.put('download', track.id, dismissed.toJson());
        previous[track.id] = progress;
        cleared[track.id] = dismissed;
      }
    });
    // A download that starts while the transaction is committing is new
    // activity. Do not overwrite its fresh progress with an old dismissal.
    cleared.removeWhere((id, _) => _downloads[id] != previous[id]);
    if (cleared.isEmpty) return;
    _downloads.addAll(cleared);
    _downloadSectionsRevision++;
    (onDownloadChanged ?? onChanged)();
  }

  final Map<String, CancelToken> _uploadTokens = {};
  final Map<String, Completer<void>> _uploadDone = {};
  CancelToken? _downloadToken;
  String? _activeDownloadId;
  bool _activeDownloadCancelled = false;
  DownloadFileVerifier? _automaticVerificationWorker;
  final Set<String> _cancelled = {};
  bool _closed = false;
  _DownloadSelection? _nextReconciliation, _latestSelection;
  Future<void>? _uploadsRunning, _downloadsRunning;
  bool _uploadsRequested = false;
  Future<void> runUploads() {
    if (_closed) return Future.value();
    // Enqueues may finish while the current database snapshot is uploading.
    _uploadsRequested = true;
    return _uploadsRunning ??= _drainUploads();
  }

  Future<void> _drainUploads() async {
    try {
      while (!_closed && _uploadsRequested) {
        _uploadsRequested = false;
        await _runUploads();
      }
    } finally {
      // Clear synchronously with the last queue check, so another enqueue cannot
      // request a pass between finishing the loop and a whenComplete callback.
      _uploadsRunning = null;
    }
  }

  Future<void> _save(UploadJob job) async {
    await database.put('upload', job.id, job.toJson());
    _publishUpload(job.id, job);
  }

  Future<void> _runUploads() async {
    await _retryCancellations();
    for (final j in await database.list('upload')) {
      if (_closed) break;
      var job = UploadJob.fromJson(j);
      if (['done', 'cancelled'].contains(job.status) ||
          _cancelled.contains(job.id)) {
        continue;
      }
      final token = CancelToken();
      _uploadTokens[job.id] = token;
      _uploadDone[job.id] = Completer<void>();
      try {
        final file = File(job.localPath);
        Future<void> validateSource() async {
          final stat = await file.stat();
          if (stat.type != FileSystemEntityType.file ||
              stat.size != job.sizeBytes ||
              (job.modifiedAtMs != null &&
                  stat.modified.millisecondsSinceEpoch != job.modifiedAtMs)) {
            throw StateError('Upload source is missing or has changed');
          }
        }

        // The server may already have all bytes (including a completion receipt)
        // even if the local ACK/offset was lost. Consult it before opening source.
        int? offset;
        if (job.remoteId != null) {
          try {
            final remote = await api.request(
              '/uploads/${job.remoteId}',
              cancelToken: token,
            );
            offset = ((remote.data as Map)['offset'] as num).toInt();
          } on DioException catch (e) {
            if (e.response?.statusCode != 404) rethrow;
            // Reservation/receipt expired while offline. Persist the reset even
            // if source validation or reservation creation subsequently fails.
            job = job.copyWith(
              clearRemoteId: true,
              offset: 0,
              status: 'queued',
            );
            await _save(job);
          }
        }
        if (job.remoteId == null) {
          await validateSource();
          if (_closed || _cancelled.contains(job.id)) {
            throw StateError('Upload cancelled');
          }
          final response = await api.request(
            '/uploads',
            method: 'POST',
            data: {'filename': job.filename, 'size_bytes': job.sizeBytes},
            cancelToken: token,
          );
          offset = ((response.data as Map)['offset'] as num).toInt();
          job = job.copyWith(
            remoteId: (response.data as Map)['id'] as String,
            offset: 0,
            status: 'uploading',
          );
          await _save(job);
        }
        if (offset == null || offset < 0 || offset > job.sizeBytes) {
          throw StateError('Server returned invalid upload offset');
        }
        job = job.copyWith(offset: offset, status: 'uploading');
        await _save(job);
        if (job.offset < job.sizeBytes) {
          await validateSource();
          final handle = await file.open();
          try {
            while (job.offset < job.sizeBytes) {
              if (_closed || _cancelled.contains(job.id)) {
                throw StateError('Upload cancelled');
              }
              await handle.setPosition(job.offset);
              final remaining = job.sizeBytes - job.offset;
              final bytes = await handle.read(
                remaining > 4 * 1024 * 1024 ? 4 * 1024 * 1024 : remaining,
              );
              if (bytes.isEmpty) throw StateError('Upload source truncated');
              final response = await api.request(
                '/uploads/${job.remoteId}',
                method: 'PATCH',
                data: bytes,
                headers: {
                  'Content-Type': 'application/octet-stream',
                  'Upload-Offset': job.offset,
                },
                cancelToken: token,
              );
              final next = ((response.data as Map)['offset'] as num).toInt();
              if (next != job.offset + bytes.length) {
                throw StateError(
                  'Server did not acknowledge the complete chunk',
                );
              }
              job = job.copyWith(offset: next);
              await _save(
                job,
              ); // Only the server's durable acknowledgement advances progress.
            }
          } finally {
            await handle.close();
          }
        }
        if (_closed || _cancelled.contains(job.id)) {
          throw StateError('Upload cancelled');
        }
        job = job.copyWith(status: 'completing');
        await _save(job);
        final response = await api.request(
          '/uploads/${job.remoteId}/complete',
          method: 'POST',
          cancelToken: token,
        );
        await onTrack(
          Track.fromJson(Map<String, dynamic>.from(response.data as Map)),
        );
        await _save(job.copyWith(status: 'done'));
        // Cleanup failure must not turn an acknowledged completion into a retry.
        try {
          await _deleteOwnedSource(job);
        } catch (e) {
          onError(e);
        }
      } catch (e) {
        final cancelled = _cancelled.contains(job.id);
        await _save(
          job.copyWith(
            status: cancelled
                ? 'cancelled'
                : _closed
                ? 'queued'
                : 'failed',
            error: cancelled || _closed ? null : e.toString(),
          ),
        );
        if (!cancelled && !_closed) onError(e);
      } finally {
        _uploadTokens.remove(job.id);
        _uploadDone.remove(job.id)?.complete();
      }
    }
  }

  Future<void> cancelUpload(String id) async {
    _cancelled.add(id);
    final existing = await database.get('upload', id);
    if (existing != null) {
      final job = UploadJob.fromJson(existing);
      await database.transaction(() async {
        await database.put(
          'upload',
          id,
          job.copyWith(status: 'cancelled').toJson(),
        );
        if (job.remoteId != null) {
          await database.put('upload_cancel', id, {
            'id': id,
            'remote_id': job.remoteId,
          });
        }
      });
      _publishUpload(id, job.copyWith(status: 'cancelled'));
    }
    _uploadTokens[id]?.cancel('Cancelled');
    // Wait only for this job, not unrelated uploads later in the queue.
    await _uploadDone[id]?.future;
    final j = await database.get('upload', id);
    if (j == null) return;
    final job = UploadJob.fromJson(j);
    await _save(job.copyWith(status: 'cancelled'));
    // Local cleanup is independent of (possibly offline) server cancellation.
    await _deleteOwnedSource(job);
    if (job.remoteId != null) {
      await database.put('upload_cancel', id, {
        'id': id,
        'remote_id': job.remoteId,
      });
      await _retryCancellations();
    }
  }

  Future<void> _retryCancellations() async {
    for (final record in await database.list('upload_cancel')) {
      if (_closed) return;
      try {
        await api.request('/uploads/${record['remote_id']}', method: 'DELETE');
        await database.remove('upload_cancel', record['id'] as String);
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) {
          await database.remove('upload_cancel', record['id'] as String);
        } else {
          onError(e);
        }
      } catch (e) {
        onError(e);
      }
    }
  }

  /// Clear completed history without touching pending, failed or cancelled jobs.
  Future<void> clearDoneUploads() async {
    final removed = <String>{};
    await database.transaction(() async {
      for (final record in await database.list('upload')) {
        if (record['status'] == 'done') {
          final id = record['id'] as String;
          await database.remove('upload', id);
          removed.add(id);
        }
      }
    });
    if (removed.isEmpty) return;
    if (onUploadsRemoved != null) {
      onUploadsRemoved!(removed);
    } else {
      for (final id in removed) {
        _publishUpload(id, null);
      }
    }
  }

  Future<void> retryUpload(String id) async {
    _cancelled.remove(id);
    final j = await database.get('upload', id);
    if (j == null) return;
    final job = UploadJob.fromJson(j);
    if (job.status == 'cancelled') {
      throw StateError('Enqueue cancelled files again to start a new upload');
    }
    if (job.status == 'done') return;
    await _save(job.copyWith(status: 'queued'));
    await runUploads();
  }

  Future<void> reconcile(
    List<Track> tracks,
    List<Playlist> playlists,
    List<PinSelection> pins,
  ) {
    if (_closed) return Future.value();
    final selection = _DownloadSelection(tracks, playlists, pins);
    _latestSelection = _nextReconciliation = selection;
    _requestedRedownloads.retainAll(selection.references.keys);
    if (_activeDownloadId != null &&
        !selection.references.containsKey(_activeDownloadId)) {
      _activeDownloadCancelled = true;
      _downloadToken?.cancel('Download no longer selected');
      _automaticVerificationWorker?.cancel();
    }
    if (_verificationRunning != null) {
      return _verificationRunning!.then((_) => _resumeReconciliations());
    }
    return _downloadsRunning ??= _drainReconciliations();
  }

  Future<void> _drainReconciliations() async {
    var pausedForVerification = false;
    try {
      while (!_closed &&
          _verificationRunning == null &&
          _nextReconciliation != null) {
        final selection = _nextReconciliation!;
        _nextReconciliation = null;
        await _reconcile(selection);
      }
      pausedForVerification =
          !_closed &&
          _verificationRunning != null &&
          _nextReconciliation != null;
    } finally {
      _downloadsRunning = null;
      if (!pausedForVerification && _downloadBatchIds.isNotEmpty) {
        _downloadBatchIds.clear();
        _completedDownloadBatchIds.clear();
        (onDownloadChanged ?? onChanged)();
      }
    }
  }

  void _startDownloadTask(String id) {
    final previous = downloadBatchProgress;
    _downloadBatchIds.add(id);
    _completedDownloadBatchIds.remove(id);
    if (downloadBatchProgress != previous) {
      (onDownloadChanged ?? onChanged)();
    }
  }

  Future<void> _reconcile(_DownloadSelection selection) async {
    final tracks = selection.tracks;
    final refs = selection.references;
    bool obsolete() => _closed || !identical(selection, _latestSelection);
    await directory.create(recursive: true);
    if (obsolete()) return;
    for (final record in await database.list('download')) {
      if (obsolete()) return;
      final id = record['id'] as String;
      if (!refs.containsKey(id) && record['repair_required'] != true) {
        await database.remove('download', id);
      }
    }
    if (obsolete()) return;
    final removedProgress = _downloads.entries.any(
      (entry) => !refs.containsKey(entry.key) && !entry.value.repairRequired,
    );
    _downloads.removeWhere(
      (id, progress) => !refs.containsKey(id) && !progress.repairRequired,
    );
    _runningDownloadIds.retainAll(_downloads.keys);
    if (removedProgress) {
      _downloadSectionsRevision++;
      (onDownloadChanged ?? onChanged)();
    }
    for (final track in tracks.where((t) => refs.containsKey(t.id))) {
      if (!_downloads.containsKey(track.id)) {
        _progress(track, DownloadStatus.queued, 0);
      }
    }
    final files = {
      for (final record in await database.list('file'))
        record['id'] as String: record,
    };
    // Repairs remove the playable database reference but retain the old audio
    // until replacement succeeds. Reclaim those bytes on deselection too,
    // including when the repair was interrupted by an account close or restart.
    final selectedFiles = {
      for (final id in refs.keys) ...[
        p.join(directory.path, '${Uri.encodeComponent(id)}.audio'),
        p.join(directory.path, '${Uri.encodeComponent(id)}.audio.part'),
      ],
      for (final record in files.values)
        if (refs.containsKey(record['id'])) record['path'] as String,
    }.map((path) => p.normalize(p.absolute(path))).toSet();
    await for (final file in directory.list()) {
      if (obsolete()) return;
      if (file is File &&
          (file.path.endsWith('.audio') || file.path.endsWith('.audio.part')) &&
          !selectedFiles.contains(p.normalize(file.absolute.path))) {
        await file.delete();
      }
    }
    for (final record in files.values) {
      if (obsolete()) return;
      final id = record['id'] as String;
      if (!refs.containsKey(id)) {
        final file = File(record['path'] as String);
        final exists = await file.exists();
        if (obsolete()) return;
        if (exists) await file.delete();
        await database.remove('file', id);
        _publishFile(id, null);
      } else if (record['references'] != refs[id]) {
        await database.put('file', id, {...record, 'references': refs[id]});
      }
    }
    if (obsolete()) return;
    // Plan all actual download work before starting the first track. Cached
    // files and repair-held downloads are not tasks unless explicitly retried.
    final previousBatch = downloadBatchProgress;
    _downloadBatchIds.retainAll(refs.keys);
    _completedDownloadBatchIds.retainAll(_downloadBatchIds);
    for (final track in tracks.where((t) => refs.containsKey(t.id))) {
      final progress = _downloads[track.id];
      if (_requestedRedownloads.contains(track.id) ||
          (files[track.id] == null &&
              progress?.status != DownloadStatus.downloaded &&
              progress?.repairRequired != true)) {
        _downloadBatchIds.add(track.id);
      }
    }
    if (downloadBatchProgress != previousBatch) {
      (onDownloadChanged ?? onChanged)();
    }
    for (final track in tracks.where((t) => refs.containsKey(t.id))) {
      if (obsolete()) break;
      if (_verificationRunning != null) {
        _nextReconciliation ??= selection;
        break;
      }
      final redownload = _requestedRedownloads.remove(track.id);
      if (!redownload && _downloads[track.id]?.repairRequired == true) continue;
      try {
        if (redownload) {
          // A repair request can arrive after this pass planned its batch.
          _startDownloadTask(track.id);
          // A decoder error does not prove corruption. Keep the old bytes until
          // the verified replacement is ready, but stop exposing its reference.
          await database.transaction(() async {
            final currentTrack = await database.get('track', track.id);
            if (currentTrack != null &&
                (currentTrack['sha256'] != track.sha256 ||
                    currentTrack['size_bytes'] != track.sizeBytes)) {
              throw StateError(
                'Track changed; choose it again from your library',
              );
            }
            await database.remove('file', track.id);
          });
          files.remove(track.id);
          _publishFile(track.id, null);
          final partial = File(
            p.join(
              directory.path,
              '${Uri.encodeComponent(track.id)}.audio.part',
            ),
          );
          if (await partial.exists()) await partial.delete();
          _progress(track, DownloadStatus.queued, 0);
          await _saveDownload(track.id);
        }
        if (obsolete()) return;
        final record = files[track.id];
        final cached =
            record != null && await _hasExpectedFileMetadata(track, record);
        if (obsolete()) return;
        if (cached) {
          if (_progress(track, DownloadStatus.downloaded, track.sizeBytes)) {
            await _saveDownload(track.id);
            await onDownloaded?.call(track);
          }
          continue;
        }
        // Previously completed downloads stay offline even after a local copy
        // disappears. Only the explicit repair path can authorize replacement.
        if (record != null ||
            _downloads[track.id]?.status == DownloadStatus.downloaded) {
          await holdUnavailableDownload(track);
          continue;
        }
        _startDownloadTask(track.id);
        final file = await _download(track);
        if (_closed || !_latestSelection!.references.containsKey(track.id)) {
          // A selection can change while the final rename is in flight.
          if (await file.exists()) await file.delete();
          throw TransferCancelled();
        }
        final completedFile = <String, dynamic>{
          'id': track.id,
          'path': file.path,
          'sha256': track.sha256,
          'references': _latestSelection!.references[track.id],
        };
        await database.put('file', track.id, completedFile);
        _publishFile(track.id, completedFile);
        if (_closed || !_latestSelection!.references.containsKey(track.id)) {
          throw TransferCancelled();
        }
        _progress(track, DownloadStatus.downloaded, track.sizeBytes);
        await _saveDownload(track.id);
        if (!_closed && _latestSelection!.references.containsKey(track.id)) {
          await onDownloaded?.call(track);
        }
      } catch (e) {
        // Per-track worker boundary: persist failure for retry and report it,
        // without preventing independent pinned tracks from downloading.
        final partial = File(
          p.join(directory.path, '${Uri.encodeComponent(track.id)}.audio.part'),
        );
        final cancelled =
            _closed ||
            e is TransferCancelled ||
            !_latestSelection!.references.containsKey(track.id);
        _progress(
          track,
          cancelled ? DownloadStatus.queued : DownloadStatus.failed,
          await partial.exists() ? await partial.length() : 0,
          error: cancelled ? null : e.toString(),
        );
        await _saveDownload(track.id);
        if (!cancelled) onError(e);
      }
    }
  }

  void _checkDownloadWanted() {
    if (_closed ||
        _activeDownloadCancelled ||
        !_latestSelection!.references.containsKey(_activeDownloadId)) {
      throw TransferCancelled();
    }
  }

  Future<File> _download(Track track) async {
    _activeDownloadId = track.id;
    _activeDownloadCancelled = false;
    try {
      return await _downloadSelected(track);
    } catch (_) {
      _checkDownloadWanted();
      rethrow;
    } finally {
      try {
        await _automaticVerificationWorker?.close();
      } finally {
        _automaticVerificationWorker = null;
        _activeDownloadId = null;
      }
    }
  }

  Future<File> _downloadSelected(Track track) async {
    _checkDownloadWanted();
    final destination = File(
      p.join(directory.path, '${Uri.encodeComponent(track.id)}.audio'),
    );
    final partial = File('${destination.path}.part');
    var offset = await partial.exists() ? await partial.length() : 0;
    if (offset > track.sizeBytes) {
      await partial.delete();
      offset = 0;
    }
    _progress(track, DownloadStatus.downloading, offset);
    await _saveDownload(track.id);
    _checkDownloadWanted();
    if (offset < track.sizeBytes) {
      final token = CancelToken();
      _downloadToken = token;
      try {
        final response = await api.request(
          '/tracks/${track.id}/audio',
          responseType: ResponseType.stream,
          headers: offset > 0
              ? {'Range': 'bytes=$offset-', 'If-Range': '"${track.sha256}"'}
              : null,
          cancelToken: token,
        );
        final etag = response.headers.value('etag');
        if (etag != null && etag != '"${track.sha256}"') {
          throw StateError('Audio checksum identity changed; refresh library');
        }
        if (response.statusCode == 206) {
          final range = response.headers.value('content-range');
          if (range == null || !range.startsWith('bytes $offset-')) {
            throw StateError('Invalid resume response');
          }
        } else if (response.statusCode == 200) {
          offset = 0;
        } else {
          throw StateError('Unexpected download status ${response.statusCode}');
        }
        _progress(track, DownloadStatus.downloading, offset);
        final output = await partial.open(
          mode: offset > 0 ? FileMode.append : FileMode.write,
        );
        try {
          await for (final chunk in (response.data as ResponseBody).stream) {
            _checkDownloadWanted();
            if (chunk.length > track.sizeBytes - offset) {
              // Cancel before awaiting stream/file cleanup, and never write an
              // offending chunk. Do not poison subsequent requests or retries.
              token.cancel('Audio exceeds expected size');
              throw StateError('Downloaded audio exceeds expected size');
            }
            await output.writeFrom(chunk);
            offset += chunk.length;
            _progress(track, DownloadStatus.downloading, offset);
          }
          await output.flush();
        } finally {
          await output.close();
        }
      } finally {
        // Also release an unread body when headers or local I/O are rejected.
        token.cancel('Download response closed');
        _downloadToken = null;
      }
    }
    _checkDownloadWanted();
    if (await partial.length() != track.sizeBytes) {
      throw StateError('Incomplete download; retry will resume');
    }
    _checkDownloadWanted();
    _progress(track, DownloadStatus.verifying, track.sizeBytes);
    _checkDownloadWanted();
    final worker = _automaticVerificationWorker = _verificationWorkerFactory();
    final result = await worker.verify(
      VerificationFile(
        path: partial.path,
        sizeBytes: track.sizeBytes,
        sha256: track.sha256,
        recordedSha256: track.sha256,
      ),
      (_) {},
    );
    _checkDownloadWanted();
    if (result.outcome == FileVerificationOutcome.invalid) {
      await partial.delete();
      throw StateError('Downloaded audio checksum mismatch');
    }
    if (result.outcome != FileVerificationOutcome.valid) {
      throw StateError(
        result.error ?? 'Downloaded audio could not be verified',
      );
    }
    final destinationExists = await destination.exists();
    _checkDownloadWanted();
    if (destinationExists) await destination.delete();
    _checkDownloadWanted();
    return partial.rename(destination.path);
  }

  Future<void> close() async {
    _closed = true;
    cancelVerification();
    _automaticVerificationWorker?.cancel();
    _downloadToken?.cancel('Account locked');
    for (final token in _uploadTokens.values) {
      token.cancel('Account locked');
    }
    await Future.wait([
      ?_uploadsRunning,
      ?_downloadsRunning,
      ?_verificationRunning,
      ..._importsRunning.map(
        (f) => f.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    ]);
  }
}
