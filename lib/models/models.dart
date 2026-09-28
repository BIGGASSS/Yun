import 'dart:convert';

int _int(dynamic value) => (value as num?)?.toInt() ?? 0;

class Account {
  const Account({
    required this.server,
    required this.userId,
    required this.username,
  });
  final String server, userId, username;
  Map<String, dynamic> toJson() => {
    'server': server,
    'user_id': userId,
    'username': username,
  };
  factory Account.fromJson(Map<String, dynamic> j) => Account(
    server: j['server'] as String,
    userId: j['user_id'] as String,
    username: j['username'] as String,
  );
}

class Track {
  const Track({
    required this.id,
    required this.title,
    this.artist = '',
    this.album = '',
    this.albumArtist = '',
    this.trackNumber,
    this.discNumber,
    this.durationMs = 0,
    this.sizeBytes = 0,
    this.sha256 = '',
    this.mimeType = 'audio/mpeg',
    this.hasArtwork = false,
    this.revision = 0,
    this.createdAt = 0,
  });
  final String id, title, artist, album, albumArtist, sha256, mimeType;
  final int? trackNumber, discNumber;
  final int durationMs, sizeBytes, revision, createdAt;
  final bool hasArtwork;
  Duration get duration => Duration(milliseconds: durationMs);
  factory Track.fromJson(Map<String, dynamic> j) => Track(
    id: j['id'] as String,
    title: j['title'] as String? ?? '',
    artist: j['artist'] as String? ?? '',
    album: j['album'] as String? ?? '',
    albumArtist: j['album_artist'] as String? ?? '',
    trackNumber: (j['track_number'] as num?)?.toInt(),
    discNumber: (j['disc_number'] as num?)?.toInt(),
    durationMs: _int(j['duration_ms']),
    sizeBytes: _int(j['size_bytes']),
    sha256: j['sha256'] as String? ?? '',
    mimeType: j['mime_type'] as String? ?? 'audio/mpeg',
    hasArtwork: j['has_artwork'] == true,
    revision: _int(j['revision']),
    createdAt: _int(j['created_at']),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'artist': artist,
    'album': album,
    'album_artist': albumArtist,
    'track_number': trackNumber,
    'disc_number': discNumber,
    'duration_ms': durationMs,
    'size_bytes': sizeBytes,
    'sha256': sha256,
    'mime_type': mimeType,
    'has_artwork': hasArtwork,
    'revision': revision,
    'created_at': createdAt,
  };
}

class PlaylistEntry {
  const PlaylistEntry({required this.id, required this.trackId});
  final String id, trackId;
  factory PlaylistEntry.fromJson(Map<String, dynamic> j) =>
      PlaylistEntry(id: j['id'] as String, trackId: j['track_id'] as String);
  Map<String, dynamic> toJson() => {'id': id, 'track_id': trackId};
}

class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    this.revision = 0,
    this.entries = const [],
    this.updatedAt = 0,
  });
  final String id, name;
  final int revision, updatedAt;
  final List<PlaylistEntry> entries;
  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
    id: j['id'] as String,
    name: j['name'] as String,
    revision: _int(j['revision']),
    updatedAt: _int(j['updated_at']),
    entries: (j['entries'] as List? ?? [])
        .map((e) => PlaylistEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'revision': revision,
    'updated_at': updatedAt,
    'entries': entries.map((e) => e.toJson()).toList(),
  };
}

class ListeningEvent {
  const ListeningEvent({
    required this.id,
    required this.deviceId,
    required this.sessionId,
    required this.trackId,
    required this.startedAt,
    required this.endedAt,
    required this.listenedMs,
    required this.timezoneOffsetMinutes,
  });
  final String id, deviceId, sessionId, trackId;
  final int startedAt, endedAt, listenedMs, timezoneOffsetMinutes;
  Map<String, dynamic> toJson() => {
    'id': id,
    'device_id': deviceId,
    'session_id': sessionId,
    'track_id': trackId,
    'started_at': startedAt,
    'ended_at': endedAt,
    'listened_ms': listenedMs,
    'timezone_offset_minutes': timezoneOffsetMinutes,
  };
}

class PinSelection {
  const PinSelection(this.type, this.id);
  final String type, id;
  Map<String, dynamic> toJson() => {'type': type, 'id': id};
  factory PinSelection.fromJson(Map<String, dynamic> j) =>
      PinSelection(j['type'] as String, j['id'] as String);
}

String albumPinId(String album, String artist) => jsonEncode([album, artist]);

class UploadJob {
  const UploadJob({
    required this.id,
    required this.localPath,
    required this.filename,
    required this.sizeBytes,
    this.offset = 0,
    this.remoteId,
    this.status = 'queued',
    this.error,
    this.modifiedAtMs,
    this.ownedSource = false,
  });
  final String id, localPath, filename, status;
  final String? remoteId, error;
  final int sizeBytes, offset;
  final int? modifiedAtMs;

  /// Only true for a validated copy in the account's private upload spool.
  /// Legacy jobs reference external originals and must never delete them.
  final bool ownedSource;
  double get progress => sizeBytes == 0 ? 0 : (offset / sizeBytes).clamp(0, 1);
  UploadJob copyWith({
    int? offset,
    String? remoteId,
    bool clearRemoteId = false,
    String? status,
    String? error,
  }) => UploadJob(
    id: id,
    localPath: localPath,
    filename: filename,
    sizeBytes: sizeBytes,
    offset: offset ?? this.offset,
    remoteId: clearRemoteId ? null : remoteId ?? this.remoteId,
    status: status ?? this.status,
    error: error,
    modifiedAtMs: modifiedAtMs,
    ownedSource: ownedSource,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'local_path': localPath,
    'filename': filename,
    'size_bytes': sizeBytes,
    'offset': offset,
    'remote_id': remoteId,
    'status': status,
    'error': error,
    'modified_at_ms': modifiedAtMs,
    'owned_source': ownedSource,
  };
  factory UploadJob.fromJson(Map<String, dynamic> j) => UploadJob(
    id: j['id'] as String,
    localPath: j['local_path'] as String,
    filename: j['filename'] as String,
    sizeBytes: _int(j['size_bytes']),
    offset: _int(j['offset']),
    remoteId: j['remote_id'] as String?,
    status: j['status'] as String? ?? 'queued',
    error: j['error'] as String?,
    modifiedAtMs: (j['modified_at_ms'] as num?)?.toInt(),
    ownedSource: j['owned_source'] == true,
  );
}

class StatsItem {
  const StatsItem({
    this.id = '',
    this.name = '',
    this.title = '',
    this.artist = '',
    this.listenedMs = 0,
    this.playCount = 0,
  });
  final String id, name, title, artist;
  final int listenedMs, playCount;
  factory StatsItem.fromJson(Map<String, dynamic> j) => StatsItem(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    title: j['title'] as String? ?? '',
    artist: j['artist'] as String? ?? '',
    listenedMs: _int(j['listened_ms']),
    playCount: _int(j['play_count']),
  );
}

class HistoryItem {
  const HistoryItem({
    required this.sessionId,
    required this.trackId,
    required this.title,
    required this.artist,
    required this.startedAt,
    required this.listenedMs,
    required this.countedPlay,
  });
  final String sessionId, trackId, title, artist;
  final int startedAt, listenedMs;
  final bool countedPlay;
  factory HistoryItem.fromJson(Map<String, dynamic> j) => HistoryItem(
    sessionId: j['session_id'] as String,
    trackId: j['track_id'] as String,
    title: j['title'] as String? ?? '',
    artist: j['artist'] as String? ?? '',
    startedAt: _int(j['started_at']),
    listenedMs: _int(j['listened_ms']),
    countedPlay: j['counted_play'] == true,
  );
}

class ServerStats {
  const ServerStats({
    this.listenedMs = 0,
    this.playCount = 0,
    this.topTracks = const [],
    this.topArtists = const [],
    this.topAlbums = const [],
    this.history = const [],
  });
  final int listenedMs, playCount;
  final List<StatsItem> topTracks, topArtists, topAlbums;
  final List<HistoryItem> history;
  factory ServerStats.fromJson(Map<String, dynamic> j) {
    List<StatsItem> items(String key) => (j[key] as List? ?? [])
        .map((e) => StatsItem.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    return ServerStats(
      listenedMs: _int(j['listened_ms']),
      playCount: _int(j['play_count']),
      topTracks: items('top_tracks'),
      topArtists: items('top_artists'),
      topAlbums: items('top_albums'),
      history: (j['history'] as List? ?? [])
          .map((e) => HistoryItem.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}
