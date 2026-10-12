import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/models.dart';
import 'cache_database.dart';

/// Local bytes eligible for reclamation, or actually reclaimed by a purge.
/// Only an unchanged preview issued by the same transfer service authorizes
/// deletion. Constructing this value does not confer that authorization.
class UnusedDownloadPreview {
  const UnusedDownloadPreview({
    required this.fileCount,
    required this.totalBytes,
  });

  final int fileCount;
  final int totalBytes;
}

/// Internal committed deltas, published by TransferService after the transaction.
class DownloadCleanupResult {
  DownloadCleanupResult(
    this.summary,
    this.fileIds,
    this.downloadIds,
    this.trackIds,
    this.protectedIds,
    this.remainingDownloadIds,
    this.needsRetry,
  );
  final UnusedDownloadPreview summary;
  final Set<String> fileIds, downloadIds, trackIds;
  final Set<String> protectedIds, remainingDownloadIds;
  final bool needsRetry;
}

class DownloadCleanupCancelled implements Exception {}

typedef DownloadReferences = Map<String, int> Function(
  List<PinSelection>,
  List<Track>,
  List<Playlist>,
);

/// Local-only implementation shared by explicit cleanup and reconciliation.
/// Never creates directories, reads audio contents, or contacts the server.
/// Preview authorization is an identity-keyed, weakly retained snapshot: neither
/// public totals nor paths supplied by a caller are trusted at confirmation.
class DownloadCleanup {
  DownloadCleanup({
    required this.database,
    required Directory directory,
    required this.references,
    required this.isClosed,
    this.currentTrackId,
    this.currentOwner,
  }) : root = p.normalize(directory.absolute.path);

  final CacheDatabase database;
  final String root;
  final DownloadReferences references;
  final bool Function() isClosed;
  final String? Function()? currentTrackId;
  final Object? Function()? currentOwner;
  final _snapshots = Expando<_Snapshot>();
  String? _resolvedRoot;

  void _checkOpen() {
    if (isClosed()) throw DownloadCleanupCancelled();
  }

  Future<_Inventory> _inventory() async {
    final tracks = await database.list('track');
    final playlists = await database.list('playlist');
    final pins = await database.list('pin');
    final files = await database.list('file');
    final downloads = await database.list('download');
    final uploads = await database.list('upload');
    _checkOpen();
    return _Inventory(
      tracks,
      files,
      downloads,
      {
        for (final upload in uploads)
          if (upload['local_path'] case final String path) _path(path),
      },
      references(
        pins.map(PinSelection.fromJson).toList(),
        tracks.map(Track.fromJson).toList(),
        playlists.map(Playlist.fromJson).toList(),
      ).keys.toSet(),
    );
  }

  String _path(String path) => p.normalize(p.absolute(path));
  List<String> _standardPaths(String id) => [
    p.join(root, '${Uri.encodeComponent(id)}.audio'),
    p.join(root, '${Uri.encodeComponent(id)}.audio.part'),
  ];

  // A recorded legacy name may lack an audio suffix, but must still be a direct
  // child of the private audio directory. Never treat artwork or upload sources
  // as audio, even if a malformed file record names them.
  bool _owned(String path) =>
      p.dirname(path) == root &&
      !RegExp(
        r'\.(?:jpe?g|png|gif|webp|bmp|avif|heic|tiff?|ico|svg|image(?:\.part)?|source(?:\.part)?)$',
        caseSensitive: false,
      ).hasMatch(path);

  bool _safeDirectory() {
    // macOS /var and user-chosen home directories may have symlink ancestors.
    // Accept their stable canonical location, but never a symlink at the audio
    // directory itself or an ancestor retargeted after we captured ownership.
    final type = FileSystemEntity.typeSync(root, followLinks: false);
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.notFound) {
      return false;
    }
    try {
      final resolved = type == FileSystemEntityType.directory
          ? Directory(root).resolveSymbolicLinksSync()
          : p.join(
              Directory(p.dirname(root)).resolveSymbolicLinksSync(),
              p.basename(root),
            );
      _resolvedRoot ??= resolved;
      return _resolvedRoot == resolved;
    } on FileSystemException {
      return false;
    }
  }

  // Callers validate the directory once per scan/batch and immediately before
  // unlinking. Repeating ancestor resolution for every preview stat is costly.
  FileStat? _stat(String path) {
    if (!_owned(path)) return null;
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      return null;
    }
    final stat = File(path).statSync();
    return stat.type == type ? stat : null;
  }

  /// Shared deletion boundary for legacy-file invalidation as well as purge.
  /// An unsafe recorded path must not confer ownership of either bytes or its
  /// record, even when startup discovers that its track metadata disappeared.
  bool canManageRecordedPath(Object? path) =>
      path is String && _safeDirectory() && _stat(_path(path)) != null;

  void deleteOwnedRecordedFile(String path) {
    if (!_safeDirectory()) return;
    final normalized = _path(path);
    if (_stat(normalized)?.type == FileSystemEntityType.file) {
      File(normalized).deleteSync();
    }
  }

  Set<String> _protectedIds(
    _Inventory inventory,
    String? id,
    Set<String> extra,
  ) => {
    ...inventory.selected,
    ...extra,
    ?id,
    if (currentTrackId?.call() case final String playing) playing,
  };

  Set<String> _protectedPaths(_Inventory inventory, Set<String> ids) => {
    ...inventory.uploadPaths,
    for (final id in ids) ..._standardPaths(id),
    for (final id in ids)
      if (inventory.files[id]?['path'] case final String path) _path(path),
  };

  List<String> _pathsFor(_Inventory inventory, String id) => [
    ..._standardPaths(id),
    if (inventory.files[id]?['path'] case final String path) _path(path),
  ];

  /// Cheap reconciliation fast path: use its existing file/progress inventory
  /// to decide whether an authoritative cleanup scan is needed at all. This
  /// does not authorize deletion; any actual cleanup still reads the live DB.
  bool hasUnusedCandidates(
    List<Map<String, dynamic>> files,
    List<Map<String, dynamic>> downloads,
    Set<String> selected,
  ) {
    final inventory = _Inventory(
      const [],
      files,
      downloads,
      const {},
      selected,
    );
    final ids = _protectedIds(inventory, null, const {});
    final paths = _protectedPaths(inventory, ids);
    if (!_safeDirectory()) return false;
    if (FileSystemEntity.typeSync(root, followLinks: false) ==
        FileSystemEntityType.directory) {
      for (final entity in Directory(root).listSync(followLinks: false)) {
        final path = _path(entity.path);
        if ((path.endsWith('.audio') || path.endsWith('.audio.part')) &&
            !paths.contains(path) &&
            _stat(path)?.type == FileSystemEntityType.file) {
          return true;
        }
      }
    }
    for (final id in {...inventory.files.keys, ...inventory.downloads.keys}) {
      if (ids.contains(id) ||
          (inventory.files.containsKey(id) &&
              inventory.files[id]?['path'] is! String)) {
        continue;
      }
      if (_pathsFor(
        inventory,
        id,
      ).every((path) => !paths.contains(path) && _stat(path) != null)) {
        return true;
      }
    }
    return false;
  }

  /// [additionalProtectedIds] is used only by automatic reconciliation, whose
  /// in-flight selection can be newer than the database snapshot it started on.
  Future<UnusedDownloadPreview> preview({
    String? protectedTrackId,
    Set<String> additionalProtectedIds = const {},
  }) async {
    _checkOpen();
    final owner = currentOwner?.call();
    late _Snapshot snapshot;
    await database.transaction(() async {
      final inventory = await _inventory();
      final ids = _protectedIds(
        inventory,
        protectedTrackId,
        additionalProtectedIds,
      );
      final protectedPaths = _protectedPaths(inventory, ids);
      final candidates = <String, FileStat>{};
      final recordIds = <String>{};
      if (_safeDirectory()) {
        // No recursion and no link following. Missing directories are empty.
        final entities =
            FileSystemEntity.typeSync(root, followLinks: false) ==
                FileSystemEntityType.directory
            ? Directory(root).list(followLinks: false)
            : const Stream<FileSystemEntity>.empty();
        var inspectedFiles = 0;
        await for (final entity in entities) {
          _checkOpen();
          if (++inspectedFiles % 64 == 0) {
            await Future<void>.delayed(Duration.zero);
            if (!_safeDirectory()) {
              throw StateError(
                'Audio directory changed during cleanup preview',
              );
            }
          }
          final path = _path(entity.path);
          if (path.endsWith('.audio') || path.endsWith('.audio.part')) {
            final stat = _stat(path);
            if (stat != null && !protectedPaths.contains(path)) {
              candidates[path] = stat;
            }
          }
        }
        var inspected = 0;
        for (final id in {
          ...inventory.files.keys,
          ...inventory.downloads.keys,
        }) {
          if (++inspected % 64 == 0) {
            await Future<void>.delayed(Duration.zero);
            _checkOpen();
            if (!_safeDirectory()) {
              throw StateError(
                'Audio directory changed during cleanup preview',
              );
            }
          }
          if (ids.contains(id) ||
              (inventory.files.containsKey(id) &&
                  inventory.files[id]?['path'] is! String)) {
            continue;
          }
          final paths = _pathsFor(inventory, id);
          final stats = {for (final path in paths) path: _stat(path)};
          // Leave unsafe records (including their progress) entirely alone.
          if (stats.entries.any(
            (entry) =>
                entry.value == null || protectedPaths.contains(entry.key),
          )) {
            continue;
          }
          recordIds.add(id);
          for (final entry in stats.entries) {
            candidates[entry.key] = entry.value!;
          }
        }
      }
      // Remember path ownership as well as stat evidence. A newly recorded
      // orphan, or changed library identity, is not the file the user reviewed.
      snapshot = _Snapshot(inventory, candidates, recordIds, owner);
    });
    _checkOpen();
    if (owner != currentOwner?.call()) {
      throw StateError('Account changed during download cleanup preview');
    }
    final existing = snapshot.paths.values.where(
      (stat) => stat.type == FileSystemEntityType.file,
    );
    final preview = UnusedDownloadPreview(
      fileCount: existing.length,
      totalBytes: existing.fold(0, (total, stat) => total + stat.size),
    );
    _snapshots[preview] = snapshot;
    return preview;
  }

  /// Re-read pins/metadata and delete under the same database transaction as
  /// local pin writes. Only the confirmed paths with unchanged stat signatures
  /// can be unlinked. Missing candidates permit stale-record cleanup, but never
  /// authorize deleting a file which appeared after preview. A preview remains
  /// usable for a retry/no-op if interruption occurred after an unlink.
  Future<DownloadCleanupResult> purge(
    UnusedDownloadPreview preview, {
    String? protectedTrackId,
    Set<String> additionalProtectedIds = const {},
    bool keepLiveRepairs = false,
    bool Function()? canContinue,
  }) async {
    _checkOpen();
    final snapshot = _snapshots[preview];
    if (snapshot == null || snapshot.owner != currentOwner?.call()) {
      throw StateError('Download cleanup preview belongs to another service');
    }
    var count = 0, bytes = 0;
    var needsRetry = false;
    final removedFiles = <String>{}, removedDownloads = <String>{};
    late _Inventory current;
    await database.transaction(() async {
      current = await _inventory();
      if (snapshot.owner != currentOwner?.call()) {
        throw StateError('Account changed during download cleanup');
      }
      final ids = _protectedIds(
        current,
        protectedTrackId,
        additionalProtectedIds,
      );
      final protectedPaths = _protectedPaths(current, ids);
      bool unchangedId(String id) =>
          !ids.contains(id) &&
          _same(snapshot.inventory.tracks[id], current.tracks[id]) &&
          _same(snapshot.inventory.files[id], current.files[id]) &&
          _same(snapshot.inventory.downloads[id], current.downloads[id]);
      bool playingPath(String path) {
        final playing = currentTrackId?.call();
        if (playing == null) return false;
        return _pathsFor(current, playing).contains(path);
      }

      var inspected = 0;
      for (final entry in snapshot.paths.entries) {
        if (++inspected % 64 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
        // Do not roll back record removals for files already unlinked on close.
        if (isClosed() ||
            snapshot.owner != currentOwner?.call() ||
            canContinue?.call() == false) {
          break;
        }
        final path = entry.key;
        if (!_safeDirectory() ||
            protectedPaths.contains(path) ||
            playingPath(path)) {
          continue;
        }
        final owners = snapshot.inventory.owners(path, root);
        if (!_same(
              owners.toList()..sort(),
              current.owners(path, root).toList()..sort(),
            ) ||
            owners.any((id) => !unchangedId(id))) {
          continue;
        }
        final stat = _stat(path);
        if (stat == null ||
            !_sameStat(entry.value, stat) ||
            stat.type != FileSystemEntityType.file) {
          continue;
        }
        // Scope/type/stat checks and unlink are synchronous, with no event-loop
        // yield between validation and deletion (Dart has no portable unlinkat).
        try {
          File(path).deleteSync();
          count++;
          bytes += stat.size;
        } on FileSystemException {
          // Missing or inaccessible candidates do not inflate the actual result.
          // Keep their records unless all relevant paths really are now absent.
          needsRetry |=
              FileSystemEntity.typeSync(path, followLinks: false) !=
              FileSystemEntityType.notFound;
        }
      }
      for (final id in snapshot.recordIds) {
        if (!unchangedId(id)) continue;
        final paths = _pathsFor(current, id);
        if (canContinue?.call() == false) continue;
        if (!_safeDirectory() ||
            paths.any(
              (path) =>
                  protectedPaths.contains(path) ||
                  playingPath(path) ||
                  !snapshot.paths.containsKey(path) ||
                  _stat(path)?.type != FileSystemEntityType.notFound,
            )) {
          continue;
        }
        if (current.files.containsKey(id)) {
          await database.remove('file', id);
          removedFiles.add(id);
        }
        if (current.downloads.containsKey(id) &&
            !(keepLiveRepairs &&
                current.tracks.containsKey(id) &&
                current.downloads[id]?['repair_required'] == true)) {
          await database.remove('download', id);
          removedDownloads.add(id);
        }
      }
    });
    return DownloadCleanupResult(
      UnusedDownloadPreview(fileCount: count, totalBytes: bytes),
      removedFiles,
      removedDownloads,
      current.tracks.keys.toSet(),
      _protectedIds(current, protectedTrackId, additionalProtectedIds),
      current.downloads.keys.toSet().difference(removedDownloads),
      needsRetry,
    );
  }

  bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
  bool _sameStat(FileStat a, FileStat b) =>
      a.type == b.type &&
      a.size == b.size &&
      a.modified == b.modified &&
      a.changed == b.changed &&
      a.mode == b.mode;
}

class _Inventory {
  _Inventory(
    List<Map<String, dynamic>> tracks,
    List<Map<String, dynamic>> files,
    List<Map<String, dynamic>> downloads,
    this.uploadPaths,
    this.selected,
  ) : tracks = {for (final record in tracks) record['id'] as String: record},
      files = {for (final record in files) record['id'] as String: record},
      downloads = {
        for (final record in downloads) record['id'] as String: record,
      } {
    for (final entry in this.files.entries) {
      final path = entry.value['path'];
      if (path is String) {
        (fileOwners[p.normalize(p.absolute(path))] ??= {}).add(entry.key);
      }
    }
  }
  final Map<String, Map<String, dynamic>> tracks, files, downloads;
  final Set<String> selected, uploadPaths;
  final Map<String, Set<String>> fileOwners = {};

  Set<String> owners(String path, String root) {
    final ids = <String>{...fileOwners[path] ?? const <String>{}};
    final name = p.basename(path);
    final suffix = name.endsWith('.audio.part') ? '.audio.part' : '.audio';
    if (p.dirname(path) == root && name.endsWith(suffix)) {
      try {
        ids.add(
          Uri.decodeComponent(name.substring(0, name.length - suffix.length)),
        );
      } on FormatException {
        // An unparseable orphan still has path/stat evidence, but no track ID.
      }
    }
    return ids;
  }
}

class _Snapshot {
  _Snapshot(this.inventory, this.paths, this.recordIds, this.owner);
  final Object? owner;
  final _Inventory inventory;
  final Map<String, FileStat> paths;
  final Set<String> recordIds;
}
