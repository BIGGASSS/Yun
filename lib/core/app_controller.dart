import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/models.dart';
import '../services/api_client.dart';
import '../services/artwork_cache.dart';
import '../services/cache_database.dart';
import '../services/playback_engine.dart';
import '../services/system_media_controls.dart';
import '../services/transfer_service.dart';
import 'playback_controller.dart';

export '../models/models.dart';
export '../services/transfer_service.dart'
    show DownloadProgress, DownloadStatus;
export 'playback_controller.dart'
    show PlaybackController, PlaybackSettings, RepeatMode;

/// UI-facing, account-scoped application state. All writes except listening
/// segments, upload jobs and offline pins are online-only. See README.md.
class AppController extends ChangeNotifier {
  AppController({
    ApiClient? api,
    Future<Directory> Function()? storageDirectory,
    CacheDatabase Function(File)? databaseFactory,
    PlaybackEngine? playbackEngine,
    SystemMediaControls? systemControls,
    bool enableSystemControls = true,
    PlaybackSettings playbackSettings = const PlaybackSettings(),
    Future<void> Function(PlaybackSettings)? savePlaybackSettings,
    int Function()? listeningMonotonicMs,
    this.automaticRefresh = true,
    this.artworkCacheMaxBytes = ArtworkCache.defaultMaxBytes,
  }) : assert(artworkCacheMaxBytes >= 0),
       _api = api ?? ApiClient(),
       _storageDirectory = storageDirectory ?? getApplicationSupportDirectory,
       _databaseFactory = databaseFactory ?? CacheDatabase.new {
    playback = PlaybackController(
      resolveSource: _resolveSource,
      engine: playbackEngine,
      controls: systemControls,
      enableSystemControls: enableSystemControls,
      initialSettings: playbackSettings,
      saveSettings: savePlaybackSettings,
      monotonicMs: listeningMonotonicMs,
    );
  }
  final ApiClient _api;
  final Future<Directory> Function() _storageDirectory;
  final CacheDatabase Function(File) _databaseFactory;
  final bool automaticRefresh;
  final int artworkCacheMaxBytes;
  late final PlaybackController playback;
  CacheDatabase? _database;
  TransferService? _transfers;
  ArtworkCache? _artwork;
  Directory? _root;
  String? _deviceId;
  Account? account;
  bool initialized = false, busy = false, isOffline = false;
  String? error;
  bool get isAuthenticated => account != null;
  List<Track> _tracks = const [];
  List<Playlist> _playlists = const [];
  List<UploadJob> _uploads = const [];
  List<PinSelection> _pins = const [];
  Map<String, Track> _tracksById = const {};
  Map<String, String> _files = {};
  Set<String> _downloadedTrackIds = const {};
  Set<String> _wantedDownloads = {};
  List<Track> get tracks => _tracks;
  List<Playlist> get playlists => _playlists;
  List<UploadJob> get uploads => _uploads;
  List<PinSelection> get pins => _pins;
  Set<String> get downloadedTrackIds => _downloadedTrackIds;
  int get downloadSectionsRevision =>
      !_locking ? _transfers?.downloadSectionsRevision ?? 0 : 0;
  final ChangeNotifier downloadChanges = ChangeNotifier();
  final ChangeNotifier artworkChanges = ChangeNotifier();
  int pendingEventCount = 0;
  ServerStats? stats;
  Timer? _retryTimer, _integrityTimer;
  Future<void>? _initializing, _refreshing, _outboxRunning, _shutdownFuture;
  bool _disposed = false, _locking = false, _notifierDisposed = false;
  final Set<Future<dynamic>> _onlineOperations = {};
  final Set<Future<void>> _uploadOperations = {};
  Future<void>? _reloadRunning;
  bool _reloadRequested = false,
      _uploadsRequested = false,
      _filesRequested = false;
  int _generation = 0;
  String newId() => const Uuid().v4();
  void _notify() {
    if (!_disposed && !_notifierDisposed) notifyListeners();
  }

  void _notifyDownloads() {
    if (!_disposed && !_notifierDisposed && !_locking) {
      downloadChanges.notifyListeners();
    }
  }

  void clearError() {
    error = null;
    _notify();
  }

  void _backgroundError(Object e) {
    if (_disposed || _locking) return;
    // Mobile lifecycle transitions routinely interrupt background requests.
    // Use the offline indicator instead of a persistent error banner; explicit
    // actions still throw so their callers can report the failure locally.
    final transientConnectionFailure =
        e is DioException &&
        e.response == null &&
        (e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            e.type == DioExceptionType.receiveTimeout);
    if (!transientConnectionFailure) error = e.toString();
    if (e is DioException &&
        (e.response == null || e.response!.statusCode == 401)) {
      isOffline = true;
    }
    _notify();
  }

  Future<void> _background(Future<void> future) async {
    try {
      await future;
    } catch (e) {
      _backgroundError(e);
    }
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    busy = true;
    _notify();
    try {
      _root = await _storageDirectory();
      await _root!.create(recursive: true);
      _deviceId = await _api.credentials.read('yun.device_id');
      if (_deviceId == null) {
        _deviceId = newId();
        await _api.credentials.write('yun.device_id', _deviceId!);
      }
      final restored = await _api.restore();
      if (restored != null) await _openAccount(restored.account);
      initialized = true;
      if (automaticRefresh) {
        _retryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
          if (isAuthenticated && !_locking) unawaited(_background(refresh()));
        });
        _integrityTimer = Timer.periodic(const Duration(minutes: 5), (_) {
          if (isAuthenticated && !_locking) {
            unawaited(_background(retryDownloads()));
          }
        });
        if (isAuthenticated) unawaited(_background(refresh()));
      }
    } catch (e) {
      error = e.toString();
      rethrow;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> _openAccount(Account value) async {
    final key = sha256
        .convert(
          utf8.encode(
            jsonEncode([normalizeServer(value.server), value.userId]),
          ),
        )
        .toString();
    final directory = Directory(p.join(_root!.path, 'accounts', key));
    await directory.create(recursive: true);
    final db = _databaseFactory(File(p.join(directory.path, 'cache.sqlite')));
    _database = db;
    account = value;
    _generation++;
    final generation = _generation;
    playback.configureRecording(_deviceId!, (event) async {
      await db.enqueueEvent(event);
      final pending = await db.eventCount();
      if (generation == _generation) {
        pendingEventCount = pending;
        _notify();
      }
    }, accountKey: key);
    _artwork = ArtworkCache(
      api: _api,
      account: value,
      directory: Directory(p.join(_root!.path, 'artwork')),
      maxBytes: artworkCacheMaxBytes,
      onChanged: () {
        if (generation == _generation && !_locking && !_notifierDisposed) {
          artworkChanges.notifyListeners();
        }
      },
    );
    _transfers = TransferService(
      api: _api,
      database: db,
      directory: Directory(p.join(directory.path, 'audio')),
      importsDirectory: Directory(p.join(directory.path, 'imports')),
      onChanged: () {
        if (generation == _generation && !_locking) {
          unawaited(_background(_reloadUploads()));
        }
      },
      onTrack: (track) async {
        await db.put('track', track.id, track.toJson());
        if (generation == _generation) await _reloadCache();
      },
      onError: _backgroundError,
      onDownloadChanged: () {
        if (generation == _generation) _notifyDownloads();
      },
      onFilesChanged: () {
        if (generation == _generation && !_locking) {
          unawaited(_background(_reloadFiles()));
        }
      },
      onDownloaded: (track) async {
        // The cache bounds/deduplicates work; images cannot stall audio.
        if (generation == _generation && !_locking) {
          unawaited(
            _background(
              _artwork!
                  .get(track, online: !isOffline, background: true)
                  .then<void>((_) {}),
            ),
          );
        }
      },
    );
    await _transfers!.restoreUploads();
    await _transfers!.restoreDownloads();
    // Only this account's quarantined, non-durable segments can reenter its
    // durable outbox. A disk failure must not turn successful auth into logout.
    try {
      await playback.checkpoint();
    } catch (e) {
      error = e.toString();
    }
    await _reloadCache();
  }

  Future<void> _reloadCache() {
    _reloadRequested = true;
    return _scheduleReload();
  }

  Future<void> _reloadUploads() {
    _uploadsRequested = true;
    return _scheduleReload();
  }

  Future<void> _reloadFiles() {
    _filesRequested = true;
    return _scheduleReload();
  }

  Future<void> _scheduleReload() => _reloadRunning ??= _drainReloads();

  Future<void> _drainReloads() async {
    try {
      while (_reloadRequested || _uploadsRequested || _filesRequested) {
        final full = _reloadRequested;
        final uploads = _uploadsRequested;
        final files = _filesRequested;
        _reloadRequested = _uploadsRequested = _filesRequested = false;
        if (full) {
          await _loadCache();
        } else {
          final db = _database;
          final generation = _generation;
          if (db == null) continue;
          final jobs = uploads ? await db.list('upload') : null;
          final records = files ? await db.list('file') : null;
          if (generation != _generation || _disposed) continue;
          if (jobs != null) {
            _uploads = List.unmodifiable(jobs.map(UploadJob.fromJson));
          }
          if (records != null) {
            _setFiles({
              for (final record in records)
                if (_tracksById[record['id']]?.sha256 == record['sha256'])
                  record['id'] as String: record['path'] as String,
            });
          }
          _notifyDownloads();
        }
      }
    } finally {
      _reloadRunning = null;
    }
  }

  void _setFiles(Map<String, String> files) {
    if (mapEquals(_files, files)) return;
    _files = files;
    _downloadedTrackIds = Set.unmodifiable(files.keys);
  }

  Future<void> _loadCache() async {
    final db = _database;
    final generation = _generation;
    if (db == null) return;
    final tracks = (await db.list('track')).map(Track.fromJson).toList()
      ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    final playlists =
        (await db.list('playlist')).map(Playlist.fromJson).toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    final uploads = (await db.list('upload')).map(UploadJob.fromJson).toList();
    final pins = (await db.list('pin')).map(PinSelection.fromJson).toList();
    final files = <String, String>{};
    final hashes = {for (final track in tracks) track.id: track.sha256};
    for (final record in await db.list('file')) {
      final path = record['path'] as String;
      if (hashes[record['id']] == record['sha256'] &&
          await File(path).exists()) {
        files[record['id'] as String] = path;
      }
    }
    final pending = await db.eventCount();
    if (generation != _generation || _disposed) return;
    _tracks = List.unmodifiable(tracks);
    _tracksById = {for (final track in tracks) track.id: track};
    _artwork?.updateTracks(tracks);
    _playlists = List.unmodifiable(playlists);
    _uploads = List.unmodifiable(uploads);
    _pins = List.unmodifiable(pins);
    _wantedDownloads = pinReferences(pins, tracks, playlists).keys.toSet();
    _setFiles(files);
    pendingEventCount = pending;
    _notify();
  }

  Future<void> login(String server, String username, String password) async {
    await initialize();
    if (_locking) throw StateError('An account change is already in progress');
    _locking = true;
    busy = true;
    error = null;
    _notify();
    try {
      if (account != null) {
        try {
          await _closeAccount();
        } finally {
          await _api.logout();
        }
      }
      final value = await _api.login(server, username, password, _deviceId!);
      await _openAccount(value);
      isOffline = false;
    } catch (e) {
      error = e.toString();
      rethrow;
    } finally {
      _locking = false;
      busy = false;
      _notify();
    }
    // Authentication is successful even if a subsequent library request fails.
    await _background(refresh());
  }

  Future<void> _closeAccount() async {
    Object? failure;
    StackTrace? failureStack;
    Future<void> cleanup(Future<void> Function() action) async {
      try {
        await action();
      } catch (e, stack) {
        failure ??= e;
        failureStack ??= stack;
      }
    }

    // Lock local access immediately. A failed listening checkpoint must not
    // prevent cancellation, database closure or native-resource disposal.
    final artwork = _artwork;
    final closingArtwork = cleanup(() async {
      await artwork?.close();
    });
    _artwork = null;
    await cleanup(playback.stop);
    // Stop timer retries even after a failed checkpoint, and drain the captured
    // callback before closing its DB. Unsaved segments stay account-scoped.
    await cleanup(playback.detachRecording);
    await closingArtwork;
    await cleanup(() async {
      await _transfers?.close();
    });
    try {
      await _refreshing;
    } catch (_) {}
    try {
      await _outboxRunning;
    } catch (_) {}
    await Future.wait(
      [
        ..._onlineOperations,
        ..._uploadOperations,
      ].map((f) => f.then<void>((_) {}, onError: (Object _, StackTrace _) {})),
    );
    try {
      await _reloadRunning;
    } catch (_) {}
    _generation++;
    await cleanup(() async {
      await _database?.close();
    });
    _database = null;
    _transfers = null;
    account = null;
    _tracks = const [];
    _tracksById = const {};
    _playlists = const [];
    _uploads = const [];
    _pins = const [];
    _wantedDownloads = {};
    _setFiles({});
    stats = null;
    pendingEventCount = 0;
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  }

  Future<void> logout() async {
    if (_locking) throw StateError('An account change is already in progress');
    _locking = true;
    busy = true;
    _notify();
    try {
      try {
        await _closeAccount();
      } finally {
        // Cleanup may report a failed checkpoint after clearing the account.
        // Never leave restorable credentials behind a signed-out UI.
        await _api.logout();
      }
      isOffline = false;
      error = null;
    } finally {
      _locking = false;
      busy = false;
      _notify();
    }
  }

  CacheDatabase _requireDatabase() {
    if (_database == null || account == null || _locking) {
      throw StateError('Sign in required');
    }
    return _database!;
  }

  Future<void> refresh() {
    if (_locking || !isAuthenticated) return Future.value();
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    final db = _requireDatabase();
    final generation = _generation;
    try {
      final cursor = await db.cursor;
      final result = await _libraryPages(cursor);
      if (generation != _generation || _locking) return;
      final changed =
          result['reset'] == true ||
          [
            'tracks',
            'playlists',
            'deleted_track_ids',
            'deleted_playlist_ids',
          ].any((key) => (result[key] as List).isNotEmpty);
      if (changed || result['cursor'] != cursor) await db.applyLibrary(result);
      if (changed) await _reloadCache();
      isOffline = false;
      await flushOutbox();
      if (!_locking) {
        unawaited(_background(_transfers!.runUploads()));
        // No-op polling retries missing/failed work, but does not repeatedly
        // scan verified files. Integrity checks have their own slower cadence.
        if (changed || _wantedDownloads.any((id) => !_files.containsKey(id))) {
          unawaited(
            _background(_transfers!.reconcile(tracks, playlists, pins)),
          );
        }
      }
    } catch (e) {
      _backgroundError(e);
      rethrow;
    } finally {
      _notify();
    }
  }

  /// Stage an entire revision before committing it and its durable cursor.
  /// A revision conflict invalidates every page, including playlist fragments.
  Future<Map<String, dynamic>> _libraryPages(int? cursor) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final tracks = <Map<String, dynamic>>[];
        final playlists = <String, Map<String, dynamic>>{};
        final entryIds = <String, Set<String>>{};
        final trackIds = <String>{};
        final deletedTracks = <String>{}, deletedPlaylists = <String>{};
        final tokens = <String>{};
        String? token;
        int? revision;
        bool? reset;
        var entriesRead = 0;
        int recordCount() =>
            tracks.length +
            playlists.length +
            deletedTracks.length +
            deletedPlaylists.length +
            entriesRead;
        while (true) {
          final beforeRecords = recordCount();
          final result = await _api.json(
            '/library',
            query: {'paged': true, 'cursor': ?cursor, 'page_token': ?token},
          );
          if (_locking || _disposed) throw StateError('Account locked');
          if (result['cursor'] is! int || result['reset'] is! bool) {
            throw const FormatException('Invalid library snapshot');
          }
          revision ??= result['cursor'] as int;
          reset ??= result['reset'] as bool;
          if (revision != result['cursor'] || reset != result['reset']) {
            throw const FormatException(
              'Library snapshot changed between pages',
            );
          }
          for (final value in result['tracks'] as List? ?? const []) {
            final track = Map<String, dynamic>.from(value as Map);
            if (!trackIds.add(track['id'] as String)) {
              throw const FormatException('Duplicate library track');
            }
            tracks.add(track);
          }
          for (final value in result['playlists'] as List? ?? const []) {
            final fragment = Map<String, dynamic>.from(value as Map);
            final id = fragment['id'] as String;
            final entries = List<dynamic>.of(
              fragment.remove('entries') as List? ?? [],
            );
            final existing = playlists[id];
            if (existing == null) {
              playlists[id] = {...fragment, 'entries': <dynamic>[]};
              entryIds[id] = {};
            } else if (!mapEquals(
              Map<String, dynamic>.of(existing)..remove('entries'),
              fragment,
            )) {
              throw const FormatException('Conflicting playlist fragments');
            }
            for (final entry in entries) {
              if (!entryIds[id]!.add((entry as Map)['id'] as String)) {
                throw const FormatException('Duplicate playlist entry');
              }
            }
            (playlists[id]!['entries'] as List).addAll(entries);
            entriesRead += entries.length;
          }
          deletedTracks.addAll(
            (result['deleted_track_ids'] as List? ?? []).cast<String>(),
          );
          deletedPlaylists.addAll(
            (result['deleted_playlist_ids'] as List? ?? []).cast<String>(),
          );
          final next = result['next_page_token'];
          if (next == null) {
            return {
              'cursor': revision,
              'reset': reset,
              'tracks': tracks,
              'playlists': playlists.values.toList(),
              'deleted_track_ids': deletedTracks.toList(),
              'deleted_playlist_ids': deletedPlaylists.toList(),
            };
          }
          if (recordCount() == beforeRecords) {
            throw const FormatException('Library page made no progress');
          }
          if (next is! String || next.isEmpty || !tokens.add(next)) {
            throw const FormatException(
              'Invalid or repeated library page token',
            );
          }
          token = next;
        }
      } on DioException catch (e) {
        if (e.response?.statusCode != 409 || attempt == 2) rethrow;
      }
    }
    throw StateError('Library pagination retries exhausted');
  }

  /// Acknowledged IDs alone are removed; failed/partial batches stay durable.
  Future<void> flushOutbox() {
    if (_locking || !isAuthenticated) return Future.value();
    return _outboxRunning ??= _flushOutbox().whenComplete(
      () => _outboxRunning = null,
    );
  }

  Future<void> _flushOutbox() async {
    final db = _requireDatabase();
    while (!_locking) {
      final batch = await db.eventBatch();
      if (batch.isEmpty) break;
      final response = await _api.json(
        '/listening-events',
        method: 'POST',
        data: {'events': batch},
      );
      final submitted = batch.map((e) => e['id'] as String).toSet();
      final ack = (response['acknowledged_ids'] as List? ?? [])
          .cast<String>()
          .where(submitted.contains)
          .toSet();
      await db.acknowledgeEvents(ack);
      pendingEventCount = await db.eventCount();
      _notify();
      if (ack.length < batch.length) break;
    }
  }

  Track? trackById(String id) => _tracksById[id];

  String? localPath(String trackId) {
    if (!isAuthenticated || _locking) return null;
    return _files[trackId];
  }

  String? artworkPath(Track track) {
    if (!isAuthenticated || _locking) return null;
    return _artwork?.path(track);
  }

  /// Keep artwork resident for a mounted foreground consumer. Release on
  /// account/track/revision change or disposal; callbacks capture their cache.
  VoidCallback? retainArtwork(Track track) {
    if (!isAuthenticated || _locking) return null;
    return _artwork?.retain(track);
  }

  Future<String?> getArtwork(Track track) => _getArtwork(track);

  /// Deliberate user retry, independent of polling and cache notifications.
  Future<String?> retryArtwork(Track track) => _getArtwork(track, retry: true);

  Future<String?> _getArtwork(Track track, {bool retry = false}) async {
    if (!isAuthenticated || _locking) return null;
    final generation = _generation;
    final path = await _artwork?.get(track, online: !isOffline, retry: retry);
    return generation == _generation && !_locking ? path : null;
  }

  DownloadProgress downloadProgress(Track track) {
    if (localPath(track.id) != null) {
      return DownloadProgress(
        trackId: track.id,
        totalBytes: track.sizeBytes,
        receivedBytes: track.sizeBytes,
        status: DownloadStatus.downloaded,
        historyCleared:
            !_locking &&
            (_transfers?.progressFor(track.id)?.historyCleared ?? false),
      );
    }
    final selected = _wantedDownloads.contains(track.id);
    final progress = !_locking ? _transfers?.progressFor(track.id) : null;
    if (selected &&
        progress != null &&
        progress.status != DownloadStatus.downloaded) {
      return progress;
    }
    return DownloadProgress(
      trackId: track.id,
      totalBytes: track.sizeBytes,
      status: selected ? DownloadStatus.queued : DownloadStatus.availableOnline,
    );
  }

  Future<void> retryDownloads() async {
    _requireDatabase();
    await _transfers!.reconcile(tracks, playlists, pins);
  }

  Future<void> clearDoneDownloads() async {
    _requireDatabase();
    await _transfers!.clearDoneDownloads(
      tracks.where((track) => _downloadedTrackIds.contains(track.id)).toList(),
    );
  }

  Future<String> audioUrl(String trackId) async {
    _requireDatabase();
    return '${account!.server}/api/v1/tracks/${Uri.encodeComponent(trackId)}/audio';
  }

  Future<Map<String, String>> authorizationHeaders() {
    _requireDatabase();
    return _api.headers();
  }

  Future<AudioSource> _resolveSource(Track track, bool localFirst) async {
    final db = _requireDatabase();
    if (localFirst) {
      final local = localPath(track.id);
      if (local != null) {
        if (await File(local).exists()) return AudioSource(local, local: true);
        _setFiles(Map.of(_files)..remove(track.id));
        _notifyDownloads();
        // Do not let an unrelated file-only refresh resurrect a record that
        // failed validation. Recheck under the DB transaction in case a
        // concurrent download has already replaced the missing file.
        await db.transaction(() async {
          final record = await db.get('file', track.id);
          if (record?['path'] == local && !await File(local).exists()) {
            await db.remove('file', track.id);
          }
        });
      }
    }
    return AudioSource(
      await audioUrl(track.id),
      headers: await authorizationHeaders(),
    );
  }

  Future<void> play(Track track, {List<Track>? queue}) async {
    _requireDatabase();
    final list = queue ?? tracks;
    final index = list.indexWhere((t) => t.id == track.id);
    await playback.playQueue(
      index < 0 ? [track] : list,
      index: index < 0 ? 0 : index,
    );
  }

  Future<T> _online<T>(Future<T> Function(CacheDatabase) action) {
    final db = _requireDatabase();
    final operation = () async {
      try {
        final result = await action(db);
        isOffline = false;
        error = null;
        _notify();
        return result;
      } catch (e) {
        _backgroundError(e);
        rethrow;
      }
    }();
    _onlineOperations.add(operation);
    return operation.whenComplete(() => _onlineOperations.remove(operation));
  }

  Future<Track> updateTrack(Track track, Map<String, dynamic> changes) =>
      _online((db) async {
        const fields = {
          'title',
          'artist',
          'album',
          'album_artist',
          'track_number',
          'disc_number',
        };
        if (changes.keys.any((k) => !fields.contains(k))) {
          throw ArgumentError('Unsupported metadata field');
        }
        final result = Track.fromJson(
          await _api.json(
            '/tracks/${track.id}',
            method: 'PATCH',
            data: {...changes, 'revision': track.revision},
          ),
        );
        await db.put('track', result.id, result.toJson());
        await _reloadCache();
        if (localPath(result.id) != null) {
          await _artwork?.get(result, background: true);
        }
        return result;
      });
  Future<void> deleteTrack(String id) => _online((db) async {
    await _api.request('/tracks/$id', method: 'DELETE');
    if (playback.currentTrack?.id == id) await playback.stop();
    await db.remove('track', id);
    await refresh();
  });
  Future<Track> setArtwork(
    Track track,
    Uint8List bytes, {
    String mimeType = 'image/jpeg',
  }) => _online((db) async {
    if (bytes.length > 10 * 1024 * 1024 ||
        !['image/jpeg', 'image/png'].contains(mimeType)) {
      throw ArgumentError('Artwork must be JPEG or PNG, at most 10 MiB');
    }
    final result = Track.fromJson(
      await _api.json(
        '/tracks/${track.id}/artwork',
        method: 'PUT',
        data: bytes,
        headers: {'Content-Type': mimeType, 'If-Match': '"${track.revision}"'},
      ),
    );
    await db.put('track', result.id, result.toJson());
    await _reloadCache();
    await _artwork?.put(result, bytes);
    return result;
  });
  Future<Playlist> createPlaylist(String name) => _online((db) async {
    final result = Playlist.fromJson(
      await _api.json('/playlists', method: 'POST', data: {'name': name}),
    );
    await db.put('playlist', result.id, result.toJson());
    await _reloadCache();
    return result;
  });
  Future<Playlist> savePlaylist(
    Playlist playlist, {
    String? name,
    List<PlaylistEntry>? entries,
  }) => _online((db) async {
    final result = Playlist.fromJson(
      await _api.json(
        '/playlists/${playlist.id}',
        method: 'PUT',
        data: {
          'revision': playlist.revision,
          'name': name ?? playlist.name,
          'entries': (entries ?? playlist.entries)
              .map((e) => e.toJson())
              .toList(),
        },
      ),
    );
    await db.put('playlist', result.id, result.toJson());
    await _reloadCache();
    unawaited(_background(_transfers!.reconcile(tracks, playlists, pins)));
    return result;
  });
  Future<void> deletePlaylist(Playlist playlist) => _online((db) async {
    await _api.request(
      '/playlists/${playlist.id}',
      method: 'DELETE',
      query: {'revision': playlist.revision},
    );
    await db.remove('playlist', playlist.id);
    await _reloadCache();
    unawaited(_background(_transfers!.reconcile(tracks, playlists, pins)));
  });
  bool isPinned(String type, String id) =>
      _pins.any((pin) => pin.type == type && pin.id == id);
  Future<void> _pin(String type, String id, bool pinned) async {
    final db = _requireDatabase();
    final key = jsonEncode([type, id]);
    if (pinned) {
      await db.put('pin', key, PinSelection(type, id).toJson());
    } else {
      await db.remove('pin', key);
    }
    await _reloadCache();
    unawaited(_background(_transfers!.reconcile(tracks, playlists, pins)));
  }

  Future<void> pinTrack(String id, {bool pinned = true}) =>
      _pin('track', id, pinned);
  Future<void> pinAlbum(String album, String artist, {bool pinned = true}) =>
      _pin('album', albumPinId(album, artist), pinned);
  Future<void> pinPlaylist(String id, {bool pinned = true}) =>
      _pin('playlist', id, pinned);
  // Local upload work is tracked separately from online mutations: copying or
  // cancelling offline must not clear isOffline, nor lock out other enqueues.
  Future<void> _uploadOperation(Future<void> Function(TransferService) action) {
    _requireDatabase();
    final transfers = _transfers!;
    final generation = _generation;
    final operation = () async {
      await action(transfers);
      if (!_locking && generation == _generation) await _reloadUploads();
    }();
    _uploadOperations.add(operation);
    return operation.whenComplete(() => _uploadOperations.remove(operation));
  }

  Future<void> enqueueUpload(String path) =>
      _uploadOperation((transfers) async {
        await transfers.enqueueUpload(newId(), path);
        if (!_locking && !isOffline) {
          unawaited(_background(transfers.runUploads()));
        }
      });

  Future<void> cancelUpload(String id) =>
      _uploadOperation((transfers) => transfers.cancelUpload(id));

  Future<void> retryUpload(String id) =>
      _uploadOperation((transfers) => transfers.retryUpload(id));

  Future<void> clearDoneUploads() =>
      _uploadOperation((transfers) => transfers.clearDoneUploads());

  Future<ServerStats> loadStats({DateTime? from, DateTime? to}) =>
      _online((db) async {
        final result = ServerStats.fromJson(
          await _api.json(
            '/stats',
            query: {
              if (from != null) 'from': from.millisecondsSinceEpoch,
              if (to != null) 'to': to.millisecondsSinceEpoch,
            },
          ),
        );
        stats = result;
        _notify();
        return result;
      });

  /// Call and await at orderly shutdown; credentials remain for offline restore.
  Future<void> shutdown() => _shutdownFuture ??= _shutdown();
  Future<void> _shutdown() async {
    if (_disposed) return;
    _locking = true;
    try {
      await _initializing;
    } catch (_) {}
    _retryTimer?.cancel();
    _integrityTimer?.cancel();
    Object? failure;
    StackTrace? failureStack;
    try {
      await _closeAccount();
    } catch (e, stack) {
      failure = e;
      failureStack = stack;
    }
    try {
      await playback.shutdown();
    } catch (e, stack) {
      failure ??= e;
      failureStack ??= stack;
    } finally {
      _disposed = true;
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
  }

  @override
  void dispose() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    downloadChanges.dispose();
    artworkChanges.dispose();
    unawaited(
      shutdown().catchError((Object e) {
        error = e.toString();
      }),
    );
    super.dispose();
  }
}
