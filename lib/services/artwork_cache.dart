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

class _ArtworkDemand {
  int consumers = 0;
}

class _ArtworkRequest {
  _ArtworkRequest(this.track, this.online, this.background);
  final Track track;
  bool online, background;
  final token = CancelToken();
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
    this.maxBytes = defaultMaxBytes,
    this.maxConcurrentRequests = 3,
    this.maxPendingRequests = 64,
  }) : assert(maxBytes >= 0),
       assert(maxConcurrentRequests > 0),
       assert(maxPendingRequests >= maxConcurrentRequests),
       directory = Directory(
         p.join(directory.path, _hash([account.server, account.userId])),
       );

  final ApiClient api;
  final Account account;
  final Directory directory;
  final void Function()? onChanged;
  final int maxBytes, maxConcurrentRequests, maxPendingRequests;
  static const defaultMaxBytes = 1024 * 1024 * 1024;
  static const maxImageBytes = 10 * 1024 * 1024;
  final Map<String, _ArtworkRequest> _pending = {};
  final _foreground = ListQueue<_ArtworkRequest>();
  final _background = ListQueue<_ArtworkRequest>();
  final _entries = <String, _ArtworkEntry>{};
  final _demands = <String, _ArtworkDemand>{};
  // Missing due to capacity is not fresh fetch intent. Keep these markers for
  // the revision, not on a timer that would merely restart the eviction loop.
  final _budgetMisses = <String>{};
  final _tooLarge = <String>{};
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
    if (_budgetMisses.isNotEmpty ||
        _tooLarge.isNotEmpty ||
        _demands.isNotEmpty) {
      final validKeys = {
        for (final track in tracks)
          if (_valid(track)) _key(track),
      };
      _budgetMisses.retainWhere(validKeys.contains);
      _tooLarge.retainWhere(validKeys.contains);
      _demands.removeWhere((key, _) => !validKeys.contains(key));
    }
  }

  /// Protect resident artwork for a continuous foreground demand (e.g. a
  /// mounted widget). Multiple consumers share admission state. Only a genuinely
  /// new demand may retry a capacity miss; oversized revisions stay suppressed.
  /// Release is idempotent and does not initiate network work.
  void Function()? retain(Track track) {
    if (!_valid(track)) return null;
    final key = _key(track);
    final demand = _demands.putIfAbsent(key, () {
      _budgetMisses.remove(key);
      return _ArtworkDemand();
    });
    demand.consumers++;
    var released = false;
    return () {
      if (released) return;
      released = true;
      demand.consumers--;
      if (demand.consumers == 0 && identical(_demands[key], demand)) {
        _demands.remove(key);
      }
    };
  }

  int _protectedBytesExcept(String key) => _demands.keys
      .where((demandKey) => demandKey != key)
      .fold(0, (bytes, demandKey) => bytes + (_entries[demandKey]?.bytes ?? 0));

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
  /// entire library. A foreground request may displace queued prefetch. Budget
  /// misses do not automatically refill: use [retain] for new foreground demand,
  /// or [retry] for a deliberate user retry, never for polling/notifications.
  Future<String?> get(
    Track track, {
    bool online = true,
    bool background = false,
    bool retry = false,
  }) {
    if (!_valid(track)) return Future.value(null);
    final key = _key(track);
    if (retry) {
      _budgetMisses.remove(key);
      _tooLarge.remove(key);
    }
    final existing = _pending[key];
    if (existing != null) {
      existing.online |= online;
      if (!background && existing.background) {
        existing.background = false;
        if (_background.remove(existing)) _foreground.add(existing);
      }
      return existing.result.future;
    }
    final entry = _entries[key];
    if (entry != null) {
      // Cached reads need no network admission slot, even with a full queue.
      return _cachedOrGet(track, entry, online: online, background: background);
    }
    if (maxBytes == 0 ||
        _budgetMisses.contains(key) ||
        _tooLarge.contains(key)) {
      return Future.value(null);
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

  Future<String?> _cachedOrGet(
    Track track,
    _ArtworkEntry entry, {
    required bool online,
    required bool background,
  }) async {
    try {
      final path = await _cachedPath(track, entry);
      if (!_valid(track)) return null;
      return path ?? await get(track, online: online, background: background);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _cachedPath(Track track, _ArtworkEntry entry) async {
    final key = _key(track);
    if (await File(entry.path).exists()) {
      return identical(_entries[key], entry) ? entry.path : null;
    }
    await _serial(() async {
      if (identical(_entries[key], entry)) {
        _entries.remove(key);
        _totalBytes -= entry.bytes;
        if (_valid(track)) onChanged?.call();
      }
    });
    return null;
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
      // Cancelling a subscription to Dio's response wrapper alone does not
      // necessarily close its underlying transport. Use a per-request token.
      request.token.cancel('Artwork request finished');
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
      final path = await _cachedPath(track, entry);
      if (path != null) return path;
    }
    if (!request.online ||
        !_valid(track) ||
        maxBytes == 0 ||
        _budgetMisses.contains(key) ||
        _tooLarge.contains(key)) {
      return null;
    }
    if (_protectedBytesExcept(key) >= maxBytes) {
      _budgetMisses.add(key);
      return null;
    }
    final response = await api.request(
      '/tracks/${Uri.encodeComponent(track.id)}/artwork',
      query: {'revision': track.revision},
      responseType: ResponseType.stream,
      cancelToken: request.token,
    );
    final stream = (response.data as ResponseBody).stream;
    final limit = maxBytes < maxImageBytes ? maxBytes : maxImageBytes;
    final length = int.tryParse(response.headers.value('content-length') ?? '');
    final tooLarge = length != null && length > limit;
    final cannotFit =
        length != null && length + _protectedBytesExcept(key) > maxBytes;
    if (!_valid(track) || tooLarge || cannotFit) {
      if (_valid(track)) {
        (tooLarge ? _tooLarge : _budgetMisses).add(key);
      }
      await stream.listen(null).cancel();
      return null;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (!_valid(track)) return null;
      if (bytes.length + chunk.length > limit) {
        _tooLarge.add(key);
        return null;
      }
      bytes.add(chunk);
    }
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
    if (!_valid(track) || bytes.isEmpty) return null;
    final key = _key(track);
    if (bytes.length > maxImageBytes || bytes.length > maxBytes) {
      _tooLarge.add(key);
      return null;
    }
    if (bytes.length + _protectedBytesExcept(key) > maxBytes) {
      _budgetMisses.add(key);
      return null;
    }
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, '$key.image'));
    final partial = File('${file.path}.part');
    try {
      await partial.writeAsBytes(bytes, flush: true);
      if (!_valid(track)) return null;
      // Reserve capacity before publishing. If eviction fails, the partial is
      // discarded rather than leaving an over-budget committed image/index.
      if (!await _trim(incoming: track, bytes: bytes.length) ||
          !_valid(track)) {
        return null;
      }
      await partial.rename(file.path);
      if (!_valid(track)) {
        _totalBytes -= _entries.remove(key)?.bytes ?? 0;
        await file.delete();
        return null;
      }
      _totalBytes -= _entries.remove(key)?.bytes ?? 0;
      _entries[key] = _ArtworkEntry(file.path, bytes.length);
      _totalBytes += bytes.length;
      _budgetMisses.remove(key);
      _tooLarge.remove(key);
      onChanged?.call();
      return file.path;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  /// Walk the age-ordered in-memory index, never scanning the directory per
  /// image. Prefer idle entries; speculative work cannot evict demanded artwork.
  /// Startup must still enforce the hard cap on an already oversized disk cache.
  Future<bool> _trim({Track? incoming, int bytes = 0}) async {
    final incomingKey = incoming == null ? null : _key(incoming);
    var changed = false;
    try {
      while (_totalBytes - (_entries[incomingKey]?.bytes ?? 0) + bytes >
          maxBytes) {
        if (incoming != null && !_valid(incoming)) return false;
        final idle = _entries.keys.where(
          (key) => key != incomingKey && !_demands.containsKey(key),
        );
        if (idle.isEmpty && incomingKey != null) {
          _budgetMisses.add(incomingKey);
          return false;
        }
        final key = idle.isNotEmpty ? idle.first : _entries.keys.first;
        // Make eviction visible before awaiting unlink. A retain arriving during
        // deletion establishes a new demand; do not overwrite its admission.
        final entry = _entries.remove(key)!;
        _totalBytes -= entry.bytes;
        _budgetMisses.add(key);
        try {
          await File(entry.path).delete();
        } on FileSystemException {
          if (await File(entry.path).exists()) {
            _entries[key] = entry;
            _totalBytes += entry.bytes;
            _budgetMisses.remove(key);
            rethrow;
          }
        }
        changed = true;
      }
      return true;
    } finally {
      if (changed && incoming != null && !_closed) onChanged?.call();
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _revisions.clear();
    for (final request in _pending.values) {
      request.token.cancel('Account locked');
    }
    for (final request in [..._foreground, ..._background]) {
      _pending.remove(_key(request.track));
      request.result.complete(null);
    }
    _foreground.clear();
    _background.clear();
    await Future.wait(_pending.values.map((r) => r.result.future));
    await _tail;
    _entries.clear();
    _demands.clear();
    _budgetMisses.clear();
    _tooLarge.clear();
    _totalBytes = 0;
  }
}
