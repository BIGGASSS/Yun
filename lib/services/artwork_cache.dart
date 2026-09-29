import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../models/models.dart';
import 'api_client.dart';

/// Durable, private artwork. Filenames include account and track revision;
/// neither HTTP nor Flutter's shared network image cache is used.
class ArtworkCache {
  ArtworkCache({
    required this.api,
    required this.account,
    required Directory directory,
    this.onChanged,
    this.maxBytes = 1024 * 1024 * 1024,
  }) : directory = Directory(
         p.join(directory.path, _hash([account.server, account.userId])),
       );

  final ApiClient api;
  final Account account;
  final Directory directory;
  final void Function()? onChanged;
  final int maxBytes;
  static const maxImageBytes = 10 * 1024 * 1024;
  final _token = CancelToken();
  final Map<String, Future<String?>> _pending = {};
  Map<String, int> _revisions = {};
  Future<void> _tail = Future.value();
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

  /// Immediately makes deleted tracks and superseded revisions inaccessible,
  /// including requests already in flight. Old disk entries age out under budget.
  void updateTracks(List<Track> tracks) {
    _revisions = {
      for (final track in tracks)
        if (track.hasArtwork) track.id: track.revision,
    };
  }

  String? path(Track track) {
    if (!_valid(track)) return null;
    final file = File(p.join(directory.path, '${_key(track)}.image'));
    return file.existsSync() ? file.path : null;
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Local-first even without connectivity. Failures leave no readable partial.
  /// Serial requests bound memory/disk usage and coalesce repeated UI requests.
  Future<String?> get(Track track, {bool online = true}) {
    final local = path(track);
    if (local != null || !online || !_valid(track)) {
      return Future.value(local);
    }
    final key = _key(track);
    return _pending[key] ??=
        _serial(() async {
          if (!_valid(track)) return null;
          final local = path(track);
          if (local != null) return local;
          try {
            final response = await api.request(
              '/tracks/${Uri.encodeComponent(track.id)}/artwork',
              query: {'revision': track.revision},
              responseType: ResponseType.stream,
              cancelToken: _token,
            );
            final bytes = <int>[];
            await for (final chunk in (response.data as ResponseBody).stream) {
              if (!_valid(track)) return null;
              if (bytes.length + chunk.length > maxImageBytes) {
                throw StateError('Artwork exceeds 10 MiB');
              }
              bytes.addAll(chunk);
            }
            final length = int.tryParse(
              response.headers.value('content-length') ?? '',
            );
            if (length != null && length != bytes.length) return null;
            return await _store(track, bytes);
          } catch (_) {
            // Artwork is optional; audio and offline browsing remain usable.
            return null;
          }
        }).whenComplete(() {
          _pending.remove(key);
        });
  }

  /// Cache a successful manual replacement without needing another GET.
  Future<String?> put(Track track, List<int> bytes) =>
      _serial(() => _store(track, bytes));

  Future<String?> _store(Track track, List<int> bytes) async {
    if (!_valid(track) ||
        bytes.isEmpty ||
        bytes.length > maxImageBytes ||
        bytes.length > maxBytes) {
      return null;
    }
    await directory.create(recursive: true);
    final file = File(p.join(directory.path, '${_key(track)}.image'));
    final partial = File('${file.path}.part');
    try {
      await partial.writeAsBytes(bytes, flush: true);
      if (!_valid(track)) return null;
      await partial.rename(file.path);
      await _trim(file.path);
      if (!_valid(track)) return null;
      onChanged?.call();
      return file.path;
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> _trim(String keep) async {
    final entries = <(File, FileStat)>[];
    var total = 0;
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      if (entity.path.endsWith('.part')) {
        await entity.delete();
      } else if (entity.path.endsWith('.image')) {
        final stat = await entity.stat();
        total += stat.size;
        entries.add((entity, stat));
      }
    }
    entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    for (final (file, stat) in entries) {
      if (total <= maxBytes) break;
      if (file.path == keep) continue;
      await file.delete();
      total -= stat.size;
    }
  }

  Future<void> close() async {
    _closed = true;
    _revisions.clear();
    _token.cancel('Account locked');
    await _tail;
  }
}
