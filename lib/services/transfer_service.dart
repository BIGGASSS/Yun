import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../models/models.dart';
import 'api_client.dart';
import 'cache_database.dart';

/// Pin selections are durable references, not independent copies of audio.
Map<String, int> pinReferences(
  List<PinSelection> pins,
  List<Track> tracks,
  List<Playlist> playlists,
) {
  final refs = <String, int>{};
  final known = tracks.map((t) => t.id).toSet();
  for (final pin in pins) {
    final ids = <String>{};
    if (pin.type == 'track') ids.add(pin.id);
    if (pin.type == 'album') {
      ids.addAll(
        tracks
            .where(
              (t) =>
                  albumPinId(
                    t.album,
                    t.albumArtist.isEmpty ? t.artist : t.albumArtist,
                  ) ==
                  pin.id,
            )
            .map((t) => t.id),
      );
    }
    if (pin.type == 'playlist') {
      for (final playlist in playlists.where((p) => p.id == pin.id)) {
        ids.addAll(playlist.entries.map((e) => e.trackId));
      }
    }
    for (final id in ids.intersection(known)) {
      refs.update(id, (n) => n + 1, ifAbsent: () => 1);
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
  });
  final String trackId;
  final int receivedBytes, totalBytes;
  final DownloadStatus status;
  final String? error;

  /// Dismiss completed activity without removing its verified local audio.
  final bool historyCleared;
  double get fraction =>
      totalBytes <= 0 ? 0 : (receivedBytes / totalBytes).clamp(0.0, 1.0);
  Map<String, dynamic> toJson() => {
    'id': trackId,
    'received_bytes': receivedBytes,
    'total_bytes': totalBytes,
    'status': status.name,
    'error': error,
    'history_cleared': historyCleared,
  };
  factory DownloadProgress.fromJson(Map<String, dynamic> j) => DownloadProgress(
    trackId: j['id'] as String,
    totalBytes: (j['total_bytes'] as num).toInt(),
    receivedBytes: (j['received_bytes'] as num).toInt(),
    status: DownloadStatus.values.byName(j['status'] as String),
    error: j['error'] as String?,
    historyCleared: j['history_cleared'] as bool? ?? false,
  );
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
    this.onDownloaded,
    Directory? importsDirectory,
  }) : importsDirectory =
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
    if (_closed) return Future.error(StateError('Account locked'));
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
          if (_closed) throw StateError('Account locked');
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
      if (_closed) throw StateError('Account locked');
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
      if (_closed) throw StateError('Account locked');
      await database.put('upload', id, job.toJson());
      committed = true;
      onChanged();
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
  final Future<void> Function(Track)? onDownloaded;
  final Map<String, DownloadProgress> _downloads = {};
  Map<String, DownloadProgress> get downloads => Map.unmodifiable(_downloads);
  DownloadProgress? progressFor(String trackId) => _downloads[trackId];
  int _downloadSectionsRevision = 0;

  /// Changes only when activity moves between sections, not on byte ticks.
  int get downloadSectionsRevision => _downloadSectionsRevision;

  /// Startup only, before accepting reconciliations or history clears.
  Future<void> restoreDownloads() async {
    for (final record in await database.list('download')) {
      final saved = DownloadProgress.fromJson(record);
      final interrupted =
          saved.status == DownloadStatus.downloading ||
          saved.status == DownloadStatus.verifying;
      if (interrupted) {
        // A crash can leave progress behind the committed, verified file. Only
        // recover completion if that file still matches the current library;
        // an older revision must not dismiss an interrupted replacement.
        final trackRecord = await database.get('track', saved.trackId);
        final fileRecord = await database.get('file', saved.trackId);
        if (trackRecord != null && fileRecord != null) {
          final track = Track.fromJson(trackRecord);
          final stat = await File(fileRecord['path'] as String).stat();
          if (fileRecord['sha256'] == track.sha256 &&
              stat.type == FileSystemEntityType.file &&
              stat.size == track.sizeBytes) {
            _downloads[saved.trackId] = DownloadProgress(
              trackId: saved.trackId,
              totalBytes: track.sizeBytes,
              receivedBytes: track.sizeBytes,
              status: DownloadStatus.downloaded,
            );
            await _saveDownload(saved.trackId);
            continue;
          }
        }
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
        receivedBytes: await partial.exists()
            ? await partial.length()
            : saved.status == DownloadStatus.downloaded
            ? saved.totalBytes
            : 0,
        status: interrupted ? DownloadStatus.queued : saved.status,
        error: saved.error,
        historyCleared: saved.historyCleared && !interrupted,
      );
    }
  }

  bool _progress(
    Track track,
    DownloadStatus status,
    int bytes, {
    String? error,
  }) {
    final previous = _downloads[track.id];
    if (previous != null &&
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
    );
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
        if (record == null ||
            record['sha256'] != track.sha256 ||
            !await File(record['path'] as String).exists()) {
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
  final CancelToken _downloadToken = CancelToken();
  final Set<String> _cancelled = {};
  bool _closed = false;
  (List<Track>, List<Playlist>, List<PinSelection>)? _nextReconciliation;
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
    onChanged();
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
      onChanged();
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
    await database.transaction(() async {
      for (final record in await database.list('upload')) {
        if (record['status'] == 'done') {
          await database.remove('upload', record['id'] as String);
        }
      }
    });
    onChanged();
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
    _nextReconciliation = (List.of(tracks), List.of(playlists), List.of(pins));
    return _downloadsRunning ??= _drainReconciliations();
  }

  Future<void> _drainReconciliations() async {
    try {
      while (!_closed && _nextReconciliation != null) {
        final (tracks, playlists, pins) = _nextReconciliation!;
        _nextReconciliation = null;
        await _reconcile(tracks, playlists, pins);
      }
    } finally {
      _downloadsRunning = null;
    }
  }

  Future<void> _reconcile(
    List<Track> tracks,
    List<Playlist> playlists,
    List<PinSelection> pins,
  ) async {
    await directory.create(recursive: true);
    final refs = pinReferences(pins, tracks, playlists);
    for (final record in await database.list('download')) {
      final id = record['id'] as String;
      if (!refs.containsKey(id)) await database.remove('download', id);
    }
    final removedProgress = _downloads.keys.any((id) => !refs.containsKey(id));
    _downloads.removeWhere((id, _) => !refs.containsKey(id));
    if (removedProgress) {
      _downloadSectionsRevision++;
      (onDownloadChanged ?? onChanged)();
    }
    for (final track in tracks.where((t) => refs.containsKey(t.id))) {
      if (!_downloads.containsKey(track.id)) {
        _progress(track, DownloadStatus.queued, 0);
      }
    }
    final selectedPartials = refs.keys
        .map((id) => '${Uri.encodeComponent(id)}.audio.part')
        .toSet();
    await for (final file in directory.list()) {
      if (file is File &&
          file.path.endsWith('.audio.part') &&
          !selectedPartials.contains(p.basename(file.path))) {
        await file.delete();
      }
    }
    final files = {
      for (final record in await database.list('file'))
        record['id'] as String: record,
    };
    var removedFiles = false;
    for (final record in files.values) {
      final id = record['id'] as String;
      if (!refs.containsKey(id)) {
        final file = File(record['path'] as String);
        if (await file.exists()) await file.delete();
        await database.remove('file', id);
        removedFiles = true;
      } else if (record['references'] != refs[id]) {
        await database.put('file', id, {...record, 'references': refs[id]});
      }
    }
    if (removedFiles) (onFilesChanged ?? onChanged)();
    for (final track in tracks.where((t) => refs.containsKey(t.id))) {
      if (_closed) break;
      try {
        final record = files[track.id];
        if (record != null &&
            record['sha256'] == track.sha256 &&
            await File(record['path'] as String).exists()) {
          if (_progress(track, DownloadStatus.downloaded, track.sizeBytes)) {
            await _saveDownload(track.id);
            await onDownloaded?.call(track);
          }
          continue;
        }
        // A stale verified record must not expose old audio after a failure.
        if (record != null) {
          await database.remove('file', track.id);
          (onFilesChanged ?? onChanged)();
        }
        final file = await _download(track);
        await database.put('file', track.id, {
          'id': track.id,
          'path': file.path,
          'sha256': track.sha256,
          'references': refs[track.id],
        });
        _progress(track, DownloadStatus.downloaded, track.sizeBytes);
        await _saveDownload(track.id);
        (onFilesChanged ?? onChanged)();
        await onDownloaded?.call(track);
      } catch (e) {
        final partial = File(
          p.join(directory.path, '${Uri.encodeComponent(track.id)}.audio.part'),
        );
        _progress(
          track,
          _closed ? DownloadStatus.queued : DownloadStatus.failed,
          await partial.exists() ? await partial.length() : 0,
          error: _closed ? null : e.toString(),
        );
        await _saveDownload(track.id);
        if (!_closed) onError(e);
      }
    }
  }

  Future<File> _download(Track track) async {
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
    if (offset < track.sizeBytes) {
      final response = await api.request(
        '/tracks/${track.id}/audio',
        responseType: ResponseType.stream,
        headers: offset > 0
            ? {'Range': 'bytes=$offset-', 'If-Range': '"${track.sha256}"'}
            : null,
        cancelToken: _downloadToken,
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
      final sink = partial.openWrite(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      try {
        await sink.addStream(
          (response.data as ResponseBody).stream.map((chunk) {
            offset += chunk.length;
            _progress(track, DownloadStatus.downloading, offset);
            return chunk;
          }),
        );
        await sink.flush();
      } catch (_) {
        // addStream may already close the sink on a transport error. Preserve
        // the original failure instead of replacing it with "File closed".
        try {
          await sink.close();
        } catch (_) {}
        rethrow;
      }
      await sink.close();
    }
    if (await partial.length() != track.sizeBytes) {
      throw StateError('Incomplete download; retry will resume');
    }
    _progress(track, DownloadStatus.verifying, track.sizeBytes);
    final digest = await sha256.bind(partial.openRead()).first;
    if (digest.toString() != track.sha256) {
      await partial.delete();
      throw StateError('Downloaded audio checksum mismatch');
    }
    if (await destination.exists()) await destination.delete();
    return partial.rename(destination.path);
  }

  Future<void> close() async {
    _closed = true;
    _downloadToken.cancel('Account locked');
    for (final token in _uploadTokens.values) {
      token.cancel('Account locked');
    }
    await Future.wait([
      ?_uploadsRunning,
      ?_downloadsRunning,
      ..._importsRunning.map(
        (f) => f.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      ),
    ]);
  }
}
