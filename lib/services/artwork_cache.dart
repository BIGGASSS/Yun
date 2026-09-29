import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../models/models.dart';
import 'api_client.dart';

class _ArtworkEntry {
  const _ArtworkEntry(this.path, this.bytes);
  final String path;
  final int bytes;
}

class _ArtworkRequest {
  _ArtworkRequest(this.track, this.online, this.background);
  final Track track;
  bool online, background;
  final result = Completer<String?>();
}

/// Durable, account/revision-scoped artwork. Reads during widget builds use an
/// in-memory index; startup scans disk once. Only commits/eviction are serialized,
/// not network requests. Optional prefetch cannot create an unbounded backlog.
class ArtworkCache {
  ArtworkCache({
    required this.api,
    required this.account,
    required Directory directory,
    this.onChanged,
    this.maxBytes = 1024 * 1024 * 1024,
    this.maxConcurrentRequests = 3,
    this.maxPendingRequests = 64,
  }) : assert(maxConcurrentRequests > 0),
       assert(maxPendingRequests >= maxConcurrentRequests),
       directory = Directory(
         p.join(directory.path, _hash([account.server, account.userId])),
       );

  final ApiClient api;
  final Account account;
  final Directory directory;
  final void Function()? onChanged;
  final int maxBytes, maxConcurrentRequests, maxPendingRequests;
  static const maxImageBytes = 10 * 1024 * 1024;
  final _token = CancelToken();
  final Map<String, _ArtworkRequest> _pending = {};
  final _foreground = ListQueue<_ArtworkRequest>();
  final _background = ListQueue<_ArtworkRequest>();
  final _entries = <String, _ArtworkEntry>{};
  Map<String, int> _revisions = {};
  Future<void> _tail = Future.value();
  Future<void>? _initializing, _closing;
  int _active = 0, _totalBytes = 0;
  bool _closed = false;

  static String _hash(List<Object> value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();
  String _key(Track track) => _hash([track.id, track.revision]);
  bool get _sameAccount =>
      !_closed &&
      api.session?.account.server == account.server &&
      api.session?.account.userId == account.userId;
  bool _valid(Track track) =>
      _sameAccount &&
      track.hasArtwork &&
      _revisions[track.id] == track.revision;

  /// Deleted tracks and superseded revisions become inaccessible immediately.
  void updateTracks(List<Track> tracks) {
    _revisions = {
      for (final track in tracks)
        if (track.hasArtwork) track.id: track.revision,
    };
  }

  /// No synchronous filesystem operations on the UI isolate. [get] validates
  /// availability asynchronously, including after an external file deletion.
  String? path(Track track) =>
      _valid(track) ? _entries[_key(track)]?.path : null;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _initialize() => _initializing ??= _serial(() async {
    if (_closed) return;
    if (!await directory.exists()) return;
    final found = <(String, _ArtworkEntry, DateTime)>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (_closed) return;
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (RegExp(r'^[a-f0-9]{64}\.image\.part$').hasMatch(name)) {
        await entity.delete();
      } else if (RegExp(r'^[a-f0-9]{64}\.image$').hasMatch(name)) {
        final stat = await entity.stat();
        if (stat.type != FileSystemEntityType.file) continue;
        found.add((
          name.substring(0, 64),
          _ArtworkEntry(entity.path, stat.size),
          stat.modified,
        ));
      }
    }
    found.sort((a, b) => a.$3.compareTo(b.$3));
    for (final (key, entry, _) in found) {
      _entries[key] = entry;
      _totalBytes += entry.bytes;
    }
    await _trim();
  });

  /// Local-first, deduplicated, bounded and foreground-prioritized. Background
  /// work is best-effort: a full queue drops prefetch instead of retaining the
  /// entire library. A foreground request may displace queued prefetch.
  Future<String?> get(
    Track track, {
    bool online = true,
    bool background = false,
  }) {
    if (!_valid(track)) return Future.value(null);
    final key = _key(track);
    final existing = _pending[key];
    if (existing != null) {
      existing.online |= online;
      if (!background && existing.background) {
        existing.background = false;
        if (_background.remove(existing)) _foreground.add(existing);
      }
      return existing.result.future;
    }
    if (_pending.length >= maxPendingRequests) {
      if (background || _background.isEmpty) return Future.value(null);
      final dropped = _background.removeLast();
      _pending.remove(_key(dropped.track));
      dropped.result.complete(null);
    }
    final request = _ArtworkRequest(track, online, background);
    _pending[key] = request;
    (background ? _background : _foreground).add(request);
    _pump();
    return request.result.future;
  }

  void _pump() {
    while (!_closed &&
        _active < maxConcurrentRequests &&
        (_foreground.isNotEmpty || _background.isNotEmpty)) {
      final request = (_foreground.isNotEmpty ? _foreground : _background)
          .removeFirst();
      _active++;
      unawaited(_run(request));
    }
  }

  Future<void> _run(_ArtworkRequest request) async {
    String? result;
    try {
      await _initialize();
      if (_valid(request.track)) {
        result = await _read(request);
      }
    } catch (_) {
      // Optional artwork must not interrupt audio or offline browsing.
    } finally {
      _pending.remove(_key(request.track));
      _active--;
      request.result.complete(_valid(request.track) ? result : null);
      _pump();
    }
  }

  Future<String?> _read(_ArtworkRequest request) async {
    final track = request.track;
    final key = _key(track);
    final entry = _entries[key];
    if (entry != null) {
      if (await File(entry.path).exists()) return entry.path;
      await _serial(() async {
        if (identical(_entries[key], entry)) {
          _entries.remove(key);
          _totalBytes -= entry.bytes;
          if (_valid(track)) onChanged?.call();
        }
      });
    }
    if (!request.online || !_valid(track)) return null;
    final response = await api.request(
      '/tracks/${Uri.encodeComponent(track.id)}/artwork',
      query: {'revision': track.revision},
      responseType: ResponseType.stream,
      cancelToken: _token,
    );
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in (response.data as ResponseBody).stream) {
      if (!_valid(track)) return null;
      if (bytes.length + chunk.length > maxImageBytes) {
        throw StateError('Artwork exceeds 10 MiB');
      }
      bytes.add(chunk);
    }
    final length = int.tryParse(response.headers.value('content-length') ?? '');
    if (length != null && length != bytes.length) return null;
    return _serial(() => _store(track, bytes.takeBytes()));
  }

  /// Manual replacements share the commit queue, not network-fetch admission.
  Future<String?> put(Track track, List<int> bytes) async {
    if (!_valid(track)) return null;
    await _initialize();
    return _serial(() => _store(track, bytes));
  }

  Future<String?> _store(Track track, List<int> bytes) async {
    if (!_valid(track) ||
        bytes.isEmpty ||
        bytes.length > maxImageBytes ||
        bytes.length > maxBytes) {
      return null;
    }
    await directory.create(recursive: true);
    final key = _key(track);
    final file = File(p.join(directory.path, '$key.image'));
    final partial = File('${file.path}.part');
    try {
      await partial.writeAsBytes(bytes, flush: true);
      if (!_valid(track)) return null;
      await partial.rename(file.path);
      _totalBytes -= _entries.remove(key)?.bytes ?? 0;
      _entries[key] = _ArtworkEntry(file.path, bytes.length);
      _totalBytes += bytes.length;
      await _trim();
      if (!_valid(track)) return null;
      onChanged?.call();
      return file.path;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  /// The index is insertion-ordered by age. No directory scans/stats/sorts per
  /// image; each eviction is O(1) bookkeeping plus its asynchronous unlink.
  Future<void> _trim() async {
    while (_totalBytes > maxBytes && _entries.isNotEmpty) {
      final key = _entries.keys.first;
      final entry = _entries[key]!;
      try {
        await File(entry.path).delete();
      } on FileSystemException {
        if (await File(entry.path).exists()) rethrow;
      }
      _entries.remove(key);
      _totalBytes -= entry.bytes;
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _revisions.clear();
    _token.cancel('Account locked');
    for (final request in [..._foreground, ..._background]) {
      _pending.remove(_key(request.track));
      request.result.complete(null);
    }
    _foreground.clear();
    _background.clear();
    await Future.wait(_pending.values.map((r) => r.result.future));
    await _tail;
    _entries.clear();
    _totalBytes = 0;
  }
}
