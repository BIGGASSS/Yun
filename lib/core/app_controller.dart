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
    this.automaticRefresh = true,
  }) : _api = api ?? ApiClient(),
       _storageDirectory = storageDirectory ?? getApplicationSupportDirectory,
       _databaseFactory = databaseFactory ?? CacheDatabase.new {
    playback = PlaybackController(
      resolveSource: _resolveSource,
      engine: playbackEngine,
      controls: systemControls,
      enableSystemControls: enableSystemControls,
      initialSettings: playbackSettings,
      saveSettings: savePlaybackSettings,
    );
    playback.addListener(_playbackChanged);
  }
  final ApiClient _api;
  final Future<Directory> Function() _storageDirectory;
  final CacheDatabase Function(File) _databaseFactory;
  final bool automaticRefresh;
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
  List<Track> _tracks = [];
  List<Playlist> _playlists = [];
  List<UploadJob> _uploads = [];
  List<PinSelection> _pins = [];
  Map<String, String> _files = {};
  Set<String> _wantedDownloads = {};
  List<Track> get tracks => List.unmodifiable(_tracks);
  List<Playlist> get playlists => List.unmodifiable(_playlists);
  List<UploadJob> get uploads => List.unmodifiable(_uploads);
  List<PinSelection> get pins => List.unmodifiable(_pins);
  Set<String> get downloadedTrackIds => Set.unmodifiable(_files.keys);
  int pendingEventCount = 0;
  ServerStats? stats;
  Timer? _retryTimer;
  Future<void>? _initializing, _refreshing, _outboxRunning, _shutdownFuture;
  bool _disposed = false, _locking = false, _notifierDisposed = false;
  final Set<Future<dynamic>> _onlineOperations = {};
  final Set<Future<void>> _uploadOperations = {};
  Future<void> _reloadTail = Future.value();
  int _generation = 0;
  String newId() => const Uuid().v4();
  void _notify() {
    if (!_disposed && !_notifierDisposed) notifyListeners();
  }

  void _playbackChanged() {
    _notify();
  }

  void clearError() {
    error = null;
    _notify();
  }

  void _backgroundError(Object e) {
    if (_disposed || _locking) return;
    error = e.toString();
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
        .convert(utf8.encode(jsonEncode([value.server, value.userId])))
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
      pendingEventCount = (await db.list('event')).length;
      _notify();
    });
    _artwork = ArtworkCache(
      api: _api,
      account: value,
      directory: Directory(p.join(_root!.path, 'artwork')),
      onChanged: () {
        if (generation == _generation && !_locking) _notify();
      },
    );
    _transfers = TransferService(
      api: _api,
      database: db,
      directory: Directory(p.join(directory.path, 'audio')),
      importsDirectory: Directory(p.join(directory.path, 'imports')),
      onChanged: () {
        if (generation == _generation && !_locking) {
          unawaited(_background(_reloadCache()));
        }
      },
      onTrack: (track) async {
        await db.put('track', track.id, track.toJson());
        if (generation == _generation) await _reloadCache();
      },
      onError: _backgroundError,
      onDownloadChanged: () {
        if (generation == _generation && !_locking) _notify();
      },
      onDownloaded: (track) async {
        if (generation == _generation && !_locking) await getArtwork(track);
      },
    );
    await _transfers!.restoreUploads();
    await _transfers!.restoreDownloads();
    await _reloadCache();
  }

  Future<void> _reloadCache() {
    final next = _reloadTail.then((_) => _loadCache());
    _reloadTail = next.catchError((Object e) {
      _backgroundError(e);
    });
    return next;
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
    final pending = (await db.list('event')).length;
    if (generation != _generation || _disposed) return;
    _tracks = tracks;
    _artwork?.updateTracks(tracks);
    _playlists = playlists;
    _uploads = uploads;
    _pins = pins;
    _wantedDownloads = pinReferences(pins, tracks, playlists).keys.toSet();
    _files = files;
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
        await _closeAccount();
        await _api.logout();
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
    // Lock local image access and cancel requests before any account can change.
    final closingArtwork = _artwork?.close();
    _artwork = null;
    await playback.stop();
    await closingArtwork;
    await _transfers?.close();
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
    await _reloadTail;
    _generation++;
    await _database?.close();
    _database = null;
    _transfers = null;
    account = null;
    _tracks = [];
    _playlists = [];
    _uploads = [];
    _pins = [];
    _wantedDownloads = {};
    _files = {};
    stats = null;
    pendingEventCount = 0;
  }

  Future<void> logout() async {
    if (_locking) throw StateError('An account change is already in progress');
    _locking = true;
    busy = true;
    _notify();
    try {
      await _closeAccount();
      await _api.logout();
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
      final result = await _api.json(
        '/library',
        query: cursor == null ? null : {'cursor': cursor},
      );
      if (generation != _generation) return;
      await db.applyLibrary(result);
      await _reloadCache();
      isOffline = false;
      await flushOutbox();
      if (!_locking) {
        unawaited(_background(_transfers!.runUploads()));
        unawaited(_background(_transfers!.reconcile(tracks, playlists, pins)));
      }
    } catch (e) {
      _backgroundError(e);
      rethrow;
    } finally {
      _notify();
    }
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
      final batch = (await db.list('event')).take(500).toList();
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
      pendingEventCount = (await db.list('event')).length;
      _notify();
      if (ack.length < batch.length) break;
    }
  }

  Track? trackById(String id) {
    for (final track in _tracks) {
      if (track.id == id) return track;
    }
    return null;
  }

  String? localPath(String trackId) {
    if (!isAuthenticated || _locking) return null;
    final value = _files[trackId];
    return value != null && File(value).existsSync() ? value : null;
  }

  String? artworkPath(Track track) {
    if (!isAuthenticated || _locking) return null;
    return _artwork?.path(track);
  }

  Future<String?> getArtwork(Track track) async {
    if (!isAuthenticated || _locking) return null;
    final generation = _generation;
    final path = await _artwork?.get(track, online: !isOffline);
    return generation == _generation && !_locking ? path : null;
  }

  DownloadProgress downloadProgress(Track track) {
    if (localPath(track.id) != null) {
      return DownloadProgress(
        trackId: track.id,
        totalBytes: track.sizeBytes,
        receivedBytes: track.sizeBytes,
        status: DownloadStatus.downloaded,
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

  Future<String> audioUrl(String trackId) async {
    _requireDatabase();
    return '${account!.server}/api/v1/tracks/${Uri.encodeComponent(trackId)}/audio';
  }

  Future<Map<String, String>> authorizationHeaders() {
    _requireDatabase();
    return _api.headers();
  }

  Future<AudioSource> _resolveSource(Track track, bool localFirst) async {
    _requireDatabase();
    if (localFirst) {
      final local = localPath(track.id);
      if (local != null) return AudioSource(local, local: true);
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
        if (localPath(result.id) != null) await _artwork?.get(result);
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
      if (!_locking && generation == _generation) await _reloadCache();
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
    await _closeAccount();
    await playback.shutdown();
    _disposed = true;
  }

  @override
  void dispose() {
    _notifierDisposed = true;
    playback.removeListener(_playbackChanged);
    unawaited(
      shutdown().catchError((Object e) {
        error = e.toString();
      }),
    );
    super.dispose();
  }
}
