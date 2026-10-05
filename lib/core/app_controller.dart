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
export '../services/download_verification.dart'
    show DownloadVerificationProgress, VerificationStatus;
export '../services/transfer_service.dart'
    show DownloadProgress, DownloadStatus;
export 'playback_controller.dart'
    show PlaybackController, PlaybackQueueEntry, PlaybackSettings, RepeatMode;

/// Internal control flow, distinct from HTTP, parsing and storage failures.
class _AccountRefreshCancelled implements Exception {}

/// UI-facing, account-scoped application state. All writes except listening
/// segments, upload jobs and offline pins are online-only. See README.md.
class AppController extends ChangeNotifier implements SystemMediaArtwork {
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
      controls:
          systemControls ??
          (enableSystemControls
              ? NativeSystemMediaControls(artwork: this)
              : null),
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
  bool get hasRunningDownloads =>
      !_locking && !_shuttingDown && (_transfers?.hasRunningDownloads ?? false);
  ({int completed, int total}) get downloadBatchProgress =>
      !_locking && !_shuttingDown
      ? _transfers?.downloadBatchProgress ?? (completed: 0, total: 0)
      : (completed: 0, total: 0);
  int get downloadSectionsRevision =>
      !_locking ? _transfers?.downloadSectionsRevision ?? 0 : 0;
  final ChangeNotifier downloadChanges = ChangeNotifier();
  // Verification ticks must not rebuild the full download inventory.
  final ChangeNotifier verificationChanges = ChangeNotifier();
  final ChangeNotifier artworkChanges = ChangeNotifier();
  @override
  late final Listenable mediaArtworkChanges = Listenable.merge([
    this,
    artworkChanges,
  ]);
  int pendingEventCount = 0;
  ServerStats? stats;
  Timer? _retryTimer, _downloadRetryTimer;
  Future<void>? _initializing, _refreshing, _outboxRunning, _shutdownFuture;
  bool _disposed = false, _locking = false, _notifierDisposed = false;
  bool _shuttingDown = false;
  Future<void>? _accountTransition;
  final Set<Future<dynamic>> _onlineOperations = {};
  final Set<Future<void>> _uploadOperations = {};
  final Set<Future<void>> _downloadHistoryOperations = {};
  final Set<Future<void>> _downloadMaintenanceOperations = {};
  Future<void>? _redownloadingCorruptedFiles;
  final Map<String, Future<void>> _redownloadingTracks = {};
  Future<void>? _reloadRunning;
  bool _reloadRequested = false,
      _uploadsRequested = false,
      _filesRequested = false;
  int _generation = 0;
  String newId() => const Uuid().v4();
  void _notify() {
    if (!_shuttingDown && !_notifierDisposed) notifyListeners();
  }

  void _notifyDownloads() {
    if (!_disposed && !_notifierDisposed && !_locking) {
      downloadChanges.notifyListeners();
    }
  }

  void _notifyVerification() {
    if (!_disposed && !_notifierDisposed && !_locking && !_shuttingDown) {
      verificationChanges.notifyListeners();
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
      // UI/background boundary: surface failures through application state.
      // Explicit operations use _online and rethrow to their callers instead.
      _backgroundError(e);
    }
  }

  void _ensureActive() {
    if (_shuttingDown) throw StateError('Application has shut down');
  }

  Future<void> initialize() {
    _ensureActive();
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    busy = true;
    _notify();
    try {
      _root = await _storageDirectory();
      if (_shuttingDown) return;
      await _root!.create(recursive: true);
      if (_shuttingDown) return;
      _deviceId = await _api.credentials.read('yun.device_id');
      if (_shuttingDown) return;
      if (_deviceId == null) {
        _deviceId = newId();
        await _api.credentials.write('yun.device_id', _deviceId!);
      }
      if (_shuttingDown) return;
      final restored = await _api.restore();
      if (_shuttingDown) return;
      if (restored != null) await _openAccount(restored.account);
      if (_shuttingDown) return;
      initialized = true;
      if (automaticRefresh) {
        _retryTimer = Timer.periodic(const Duration(seconds: 30), (_) {
          if (isAuthenticated && !_locking) unawaited(_background(refresh()));
        });
        _downloadRetryTimer = Timer.periodic(const Duration(minutes: 5), (_) {
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
    if (_shuttingDown) return;
    final key = sha256
        .convert(
          utf8.encode(
            jsonEncode([normalizeServer(value.server), value.userId]),
          ),
        )
        .toString();
    final directory = Directory(p.join(_root!.path, 'accounts', key));
    await directory.create(recursive: true);
    if (_shuttingDown) return;
    final db = _databaseFactory(File(p.join(directory.path, 'cache.sqlite')));
    _database = db;
    account = value;
    _generation++;
    final generation = _generation;
    final libraryEpoch = await db.libraryEpoch;
    playback.configureRecording(_deviceId!, (event) async {
      await db.enqueueEvent(event);
      final pending = await db.eventCount();
      if (generation == _generation && !_shuttingDown) {
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
        // Transfer callbacks do not carry a request-time timeline token. After
        // a rollback, discover uploads via authoritative sync instead of ever
        // trusting a response that might belong to the previous timeline.
        if (await _publishRecord(db, libraryEpoch, 'track', track.toJson())) {
          await _reloadCache();
        } else if (_canPublish(db) && await db.libraryEpoch != libraryEpoch) {
          await _refreshing;
          await refresh();
        }
      },
      onError: _backgroundError,
      onDownloadChanged: () {
        if (generation == _generation) _notifyDownloads();
      },
      onVerificationChanged: () {
        if (generation == _generation) _notifyVerification();
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
    if (_shuttingDown) return;
    await _transfers!.restoreDownloads();
    if (_shuttingDown) return;
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
          if (generation != _generation || _shuttingDown) continue;
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
    if (generation != _generation || _shuttingDown) return;
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

  Future<void> _changeAccount(Future<void> Function() action) {
    _ensureActive();
    if (_accountTransition != null || _locking) {
      throw StateError('An account change is already in progress');
    }
    _locking = true;
    return _accountTransition = action().whenComplete(() {
      _locking = _shuttingDown;
      _accountTransition = null;
    });
  }

  Future<void> login(String server, String username, String password) =>
      _changeAccount(() => _login(server, username, password));

  Future<void> _login(String server, String username, String password) async {
    await initialize();
    if (_shuttingDown) return;
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
      if (_shuttingDown) return;
      final value = await _api.login(server, username, password, _deviceId!);
      if (_shuttingDown) return;
      await _openAccount(value);
      if (_shuttingDown) return;
      isOffline = false;
    } catch (e) {
      error = e.toString();
      rethrow;
    } finally {
      _locking = _shuttingDown;
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

    // Observe owners before any cleanup await: their completion callbacks
    // remove them from these fields/sets, including when they fail. Cleanup
    // still drains every owner and rethrows the first failure after closure.
    final drainingOperations = cleanup(() async {
      await Future.wait<dynamic>([
        ?_refreshing,
        ?_outboxRunning,
        ..._onlineOperations,
        // Closing transfers deliberately cancels an unfinished picker copy.
        // The initiating caller still receives cancellation; account cleanup
        // treats only this typed cancellation as successful drainage.
        ..._uploadOperations.map(
          (operation) => operation.onError<TransferCancelled>((_, _) {}),
        ),
      ]);
    });

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
    await drainingOperations;
    // History and verification/repair operations must finish before DB closure.
    // cleanup boundary still closes resources, then rethrows any failure.
    await cleanup(() async {
      await Future.wait([
        ..._downloadHistoryOperations,
        ..._downloadMaintenanceOperations,
      ]);
    });
    await cleanup(() async {
      await _reloadRunning;
    });
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

  Future<void> logout() => _changeAccount(_logout);

  Future<void> _logout() async {
    // Initialization may itself be opening a restored account. A logout
    // already requested must still erase credentials if shutdown follows it.
    _locking = true;
    busy = true;
    _notify();
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

    try {
      // Initialization can fail after opening the database or configuring
      // recording. Drain it, but never let that failure bypass local cleanup.
      await cleanup(() async => await _initializing);
      await cleanup(_closeAccount);
      await cleanup(_api.logout);
      isOffline = false;
      if (failure != null) {
        error = failure.toString();
        Error.throwWithStackTrace(failure!, failureStack!);
      }
      error = null;
    } finally {
      _locking = _shuttingDown;
      busy = false;
      _notify();
    }
  }

  CacheDatabase _requireDatabase() {
    if (_database == null || account == null || _locking || _shuttingDown) {
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
      // Only deletions acknowledged before this request can be confirmed by
      // its snapshot. A staged reset may omit a not-yet-published creation.
      final deletionSequence = await db.deletionSequence;
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
      if (changed || result['cursor'] != cursor) {
        await db.transaction(() async {
          if (_canPublish(db)) {
            await db.applyLibrary(
              result,
              confirmedDeletionSequence: deletionSequence,
            );
          }
        });
      }
      if (!_canPublish(db)) return;
      if (changed) await _reloadCache();
      if (!_canPublish(db)) return;
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
    } on _AccountRefreshCancelled {
      // Account transitions drain refreshes; expected cancellation must not
      // turn a successful login/logout into a cleanup failure.
      return;
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
          if (_locking || _disposed) throw _AccountRefreshCancelled();
          final beforeRecords = recordCount();
          final result = await _api.json(
            '/library',
            query: {'paged': true, 'cursor': ?cursor, 'page_token': ?token},
          );
          if (_locking || _disposed) throw _AccountRefreshCancelled();
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
      final pending = await db.eventCount();
      if (_canPublish(db)) {
        pendingEventCount = pending;
        _notify();
      }
      if (ack.length < batch.length) break;
    }
  }

  Track? trackById(String id) => _tracksById[id];

  String? localPath(String trackId) {
    if (!isAuthenticated || _locking) return null;
    return _files[trackId];
  }

  @override
  Track? mediaArtworkTrack(Track track) =>
      isAuthenticated && !_locking ? trackById(track.id) : null;

  @override
  String? artworkPath(Track track) {
    if (!isAuthenticated || _locking) return null;
    return _artwork?.path(track);
  }

  /// Keep artwork resident for a mounted foreground consumer. Release on
  /// account/track/revision change or disposal; callbacks capture their cache.
  @override
  VoidCallback? retainArtwork(Track track) {
    if (!isAuthenticated || _locking) return null;
    return _artwork?.retain(track);
  }

  @override
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
    if (progress != null &&
        (selected || progress.requiresOfflinePlayback) &&
        progress.status != DownloadStatus.downloaded) {
      return progress;
    }
    return DownloadProgress(
      trackId: track.id,
      totalBytes: track.sizeBytes,
      status: selected ? DownloadStatus.queued : DownloadStatus.availableOnline,
    );
  }

  DownloadVerificationProgress? get verificationProgress =>
      !_locking && !_shuttingDown ? _transfers?.verificationProgress : null;

  bool get redownloadingCorruptedFiles =>
      !_locking && _redownloadingCorruptedFiles != null;

  /// Explicit local-only integrity check, available without a connection.
  Future<void> verifyDownloads() {
    _requireDatabase();
    final transfers = _transfers!;
    final generation = _generation;
    final operation = () async {
      await transfers.verifyDownloads();
      if (generation == _generation && !_locking && !_shuttingDown) {
        await _reloadFiles();
      }
    }();
    _downloadMaintenanceOperations.add(operation);
    return operation.whenComplete(
      () => _downloadMaintenanceOperations.remove(operation),
    );
  }

  void cancelVerification() {
    if (!_locking && !_shuttingDown) _transfers?.cancelVerification();
  }

  bool isRedownloadingTrack(String trackId) =>
      !_locking && _redownloadingTracks.containsKey(trackId);

  /// Explicit network repair, never an automatic consequence of decoding.
  /// Coalesce repeated clicks and keep the operation bound to this account.
  Future<void> redownloadTrack(Track track) {
    final db = _requireDatabase();
    if (isOffline) throw StateError('Connect to redownload this track');
    final running = _redownloadingTracks[track.id];
    if (running != null) return running;
    final current = trackById(track.id);
    if (current == null || current.sha256 != track.sha256) {
      throw StateError('Track changed; choose it again from your library');
    }
    final transfers = _transfers!;
    final generation = _generation;
    final operation = () async {
      await db.transaction(() async {
        if (!_canPublish(db) || generation != _generation) return;
        final currentTracks = (await db.list('track'))
            .map(Track.fromJson)
            .toList();
        if (!currentTracks.any(
          (current) =>
              current.id == track.id &&
              current.sha256 == track.sha256 &&
              current.sizeBytes == track.sizeBytes,
        )) {
          throw StateError('Track changed; choose it again from your library');
        }
        final currentPlaylists = (await db.list('playlist'))
            .map(Playlist.fromJson)
            .toList();
        final currentPins = (await db.list('pin'))
            .map(PinSelection.fromJson)
            .toList();
        final references = pinReferences(
          currentPins,
          currentTracks,
          currentPlaylists,
        );
        if (!references.containsKey(track.id)) {
          await db.put(
            'pin',
            jsonEncode(['track', track.id]),
            PinSelection('track', track.id).toJson(),
          );
        }
      });
      if (!_canPublish(db) || generation != _generation) return;
      // Drain a queued failure-stop before replacing its file. Preserve the
      // selected track/queue so the user can explicitly retry Play afterward.
      await playback.flushSettings();
      if (!_canPublish(db) || generation != _generation) return;
      // Release native file handles without clearing the queue or touching a
      // newer track. The next explicit Play must reopen the verified copy.
      await playback.prepareLocalRepair(track.id);
      if (!_canPublish(db) || generation != _generation) return;
      await _reloadCache();
      if (!_canPublish(db) || generation != _generation) return;
      await transfers.redownloadTrack(track, tracks, playlists, pins);
      if (!_canPublish(db) || generation != _generation) return;
      await _reloadFiles();
      final progress = transfers.progressFor(track.id);
      if (progress?.status != DownloadStatus.downloaded) {
        throw StateError(
          progress?.error ?? 'Redownload did not finish. Try again.',
        );
      }
    }();
    _redownloadingTracks[track.id] = operation;
    _downloadMaintenanceOperations.add(operation);
    _notifyDownloads();
    return operation.whenComplete(() {
      _downloadMaintenanceOperations.remove(operation);
      if (identical(_redownloadingTracks[track.id], operation)) {
        _redownloadingTracks.remove(track.id);
      }
      if (generation == _generation) _notifyDownloads();
    });
  }

  /// Repair is a separate, deliberate network action after local verification.
  Future<void> redownloadCorruptedFiles() {
    final db = _requireDatabase();
    if (isOffline) throw StateError('Connect to redownload corrupted files');
    final running = _redownloadingCorruptedFiles;
    if (running != null) return running;
    final progress = verificationProgress;
    if (progress == null || progress.invalidTrackIds.isEmpty) {
      return Future.value();
    }
    if (progress.isRunning) {
      throw StateError('Wait for download verification to finish');
    }
    final transfers = _transfers!;
    final generation = _generation;
    final invalidIds = List<String>.of(progress.invalidTrackIds);
    final operation = () async {
      // Preserve existing album/playlist selections. Previously unselected
      // downloads need a durable track pin so repair can resume after restart.
      await db.transaction(() async {
        if (!_canPublish(db) || generation != _generation) return;
        final currentTracks = (await db.list('track'))
            .map(Track.fromJson)
            .toList();
        final currentPlaylists = (await db.list('playlist'))
            .map(Playlist.fromJson)
            .toList();
        final currentPins = (await db.list('pin'))
            .map(PinSelection.fromJson)
            .toList();
        final knownIds = currentTracks.map((track) => track.id).toSet();
        final references = pinReferences(
          currentPins,
          currentTracks,
          currentPlaylists,
        );
        for (final id in invalidIds) {
          if (knownIds.contains(id) && !references.containsKey(id)) {
            await db.put(
              'pin',
              jsonEncode(['track', id]),
              PinSelection('track', id).toJson(),
            );
          }
        }
      });
      if (!_canPublish(db) || generation != _generation) return;
      await _reloadCache();
      if (!_canPublish(db) || generation != _generation) return;
      await transfers.redownloadCorruptedFiles(tracks, playlists, pins);
    }();
    _redownloadingCorruptedFiles = operation;
    _downloadMaintenanceOperations.add(operation);
    _notifyVerification();
    return operation.whenComplete(() {
      _downloadMaintenanceOperations.remove(operation);
      if (identical(_redownloadingCorruptedFiles, operation)) {
        _redownloadingCorruptedFiles = null;
      }
      if (generation == _generation) _notifyVerification();
    });
  }

  Future<void> retryDownloads() async {
    _requireDatabase();
    await _transfers!.reconcile(tracks, playlists, pins);
  }

  Future<void> clearDoneDownloads() async {
    _requireDatabase();
    final operation = _transfers!.clearDoneDownloads(
      tracks.where((track) => _downloadedTrackIds.contains(track.id)).toList(),
    );
    _downloadHistoryOperations.add(operation);
    await operation.whenComplete(
      () => _downloadHistoryOperations.remove(operation),
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
    final generation = _generation;
    final transfers = _transfers!;
    void requireNotRepairing() {
      if (_redownloadingTracks.containsKey(track.id)) {
        throw const LocalAudioUnavailable(
          'Redownload in progress. Finish the download before playing.',
        );
      }
    }

    requireNotRepairing();
    // Resolve from durable download evidence, not just the visible file map.
    // Queued first-time pins may stream; completed/repairing downloads may not.
    final record = await db.get('file', track.id);
    if (!_canPublish(db) || generation != _generation) {
      throw StateError('Account changed during playback');
    }
    var progress = transfers.progressFor(track.id);
    Future<AudioSource?> localSource(Map<String, dynamic>? candidate) async {
      requireNotRepairing();
      if (candidate == null ||
          transfers.progressFor(track.id)?.repairRequired == true) {
        return null;
      }
      final path = candidate['path'] as String;
      try {
        final stat = await File(path).stat();
        if (!_canPublish(db) || generation != _generation) {
          throw StateError('Account changed during playback');
        }
        requireNotRepairing();
        if (candidate['sha256'] == track.sha256 &&
            stat.type == FileSystemEntityType.file &&
            stat.size == track.sizeBytes) {
          return AudioSource(path, local: true);
        }
      } on FileSystemException catch (e) {
        throw LocalAudioUnavailable('Downloaded audio could not be read: $e');
      }
      return null;
    }

    final source = await localSource(record);
    if (source != null) return source;
    if (record != null || progress?.requiresOfflinePlayback == true) {
      final held = await transfers.holdUnavailableDownload(track);
      if (!_canPublish(db) || generation != _generation) {
        throw StateError('Account changed during playback');
      }
      if (!held) {
        // The transactional hold may have observed a newer verified copy.
        // Revalidate once rather than hiding it or reporting a stale failure.
        final replacement = await localSource(await db.get('file', track.id));
        if (replacement != null) return replacement;
      }
      if (held || record == null) {
        _setFiles(Map.of(_files)..remove(track.id));
        _notifyDownloads();
      }
      progress = transfers.progressFor(track.id);
      throw LocalAudioUnavailable(
        progress?.repairRequired == true
            ? progress?.error ??
                  'Downloaded audio is unavailable. Redownload to repair.'
            : 'Downloaded audio is unavailable while its replacement is pending. '
                  'Finish the download before playing.',
      );
    }
    requireNotRepairing();
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

  Future<void> queueNext(Track track) async {
    _requireDatabase();
    await playback.queueNext(track);
  }

  bool _canPublish(CacheDatabase db) =>
      !_shuttingDown && !_locking && identical(db, _database);

  Future<bool> _publishRecord(
    CacheDatabase db,
    int epoch,
    String kind,
    Map<String, dynamic> record,
  ) => db.transaction(() async {
    if (!_canPublish(db)) return false;
    return db.publishLibraryRecord(kind, record, expectedEpoch: epoch);
  });

  Future<bool> _publishDeletion(
    CacheDatabase db,
    int epoch,
    String kind,
    String id,
  ) => db.transaction(() async {
    if (!_canPublish(db)) return false;
    return db.deleteLibraryRecord(kind, id, expectedEpoch: epoch);
  });

  Future<T> _online<T>(Future<T> Function(CacheDatabase, int) action) {
    final db = _requireDatabase();
    final operation = () async {
      try {
        final epoch = await db.libraryEpoch;
        final result = await action(db, epoch);
        if (_canPublish(db)) {
          isOffline = false;
          error = null;
          _notify();
        }
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
      _online((db, epoch) async {
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
        final published = await _publishRecord(
          db,
          epoch,
          'track',
          result.toJson(),
        );
        if (published) await _reloadCache();
        if (published &&
            _canPublish(db) &&
            trackById(result.id)?.revision == result.revision &&
            localPath(result.id) != null) {
          await _artwork?.get(result, background: true);
        }
        return result;
      });
  Future<void> deleteTrack(String id) => _online((db, epoch) async {
    await _api.request('/tracks/$id', method: 'DELETE');
    if (!await _publishDeletion(db, epoch, 'track', id)) return;
    if (_canPublish(db) && playback.currentTrack?.id == id) {
      await playback.stop();
    }
    await _reloadCache();
    await refresh();
  });
  Future<Track> setArtwork(
    Track track,
    Uint8List bytes, {
    String mimeType = 'image/jpeg',
  }) => _online((db, epoch) async {
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
    if (await _publishRecord(db, epoch, 'track', result.toJson())) {
      await _reloadCache();
      if (_canPublish(db) &&
          trackById(result.id)?.revision == result.revision) {
        await _artwork?.put(result, bytes);
      }
    }
    return result;
  });
  Future<Playlist> createPlaylist(String name) => _online((db, epoch) async {
    final result = Playlist.fromJson(
      await _api.json('/playlists', method: 'POST', data: {'name': name}),
    );
    if (await _publishRecord(db, epoch, 'playlist', result.toJson())) {
      await _reloadCache();
    }
    return result;
  });
  Future<Playlist> savePlaylist(
    Playlist playlist, {
    String? name,
    List<PlaylistEntry>? entries,
  }) => _online((db, epoch) async {
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
    if (await _publishRecord(db, epoch, 'playlist', result.toJson())) {
      await _reloadCache();
      if (_canPublish(db)) {
        unawaited(_background(_transfers!.reconcile(tracks, playlists, pins)));
      }
    }
    return result;
  });
  Future<void> deletePlaylist(Playlist playlist) => _online((db, epoch) async {
    await _api.request(
      '/playlists/${playlist.id}',
      method: 'DELETE',
      query: {'revision': playlist.revision},
    );
    if (!await _publishDeletion(db, epoch, 'playlist', playlist.id)) return;
    await _reloadCache();
    if (_canPublish(db)) {
      unawaited(_background(_transfers!.reconcile(tracks, playlists, pins)));
    }
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
      _online((db, epoch) async {
        final result = ServerStats.fromJson(
          await _api.json(
            '/stats',
            query: {
              if (from != null) 'from': from.millisecondsSinceEpoch,
              if (to != null) 'to': to.millisecondsSinceEpoch,
            },
          ),
        );
        if (_canPublish(db)) {
          stats = result;
          _notify();
        }
        return result;
      });

  /// Call and await at orderly shutdown; credentials remain for offline restore.
  Future<void> shutdown() {
    // Terminal synchronously, before any in-flight transition can resume.
    _shuttingDown = true;
    _locking = true;
    return _shutdownFuture ??= _shutdown();
  }

  Future<void> _shutdown() async {
    if (_disposed) return;
    _locking = true;
    Object? failure;
    StackTrace? failureStack;
    Future<void> drain(Future<void>? operation) async {
      try {
        await operation;
      } catch (e, stack) {
        // Shutdown is a cleanup boundary: drain every owner before closing
        // resources, then report the first failure rather than swallowing it.
        failure ??= e;
        failureStack ??= stack;
      }
    }

    await drain(_initializing);
    await drain(_accountTransition);
    _retryTimer?.cancel();
    _downloadRetryTimer?.cancel();
    await drain(_closeAccount());
    try {
      await playback.shutdown();
    } catch (e, stack) {
      failure ??= e;
      failureStack ??= stack;
    } finally {
      _disposed = true;
    }
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  }

  @override
  void dispose() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    downloadChanges.dispose();
    verificationChanges.dispose();
    artworkChanges.dispose();
    unawaited(
      shutdown().catchError((Object e) {
        // ChangeNotifier.dispose cannot return a Future. Retain failures for
        // inspection; orderly owners must await shutdown to receive the error.
        error = e.toString();
      }),
    );
    super.dispose();
  }
}
