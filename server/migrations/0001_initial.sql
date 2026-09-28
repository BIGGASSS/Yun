CREATE TABLE users (
 id TEXT PRIMARY KEY, username TEXT NOT NULL UNIQUE COLLATE NOCASE,
 password_hash TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE devices (
 user_id TEXT NOT NULL REFERENCES users(id), id TEXT NOT NULL,
 PRIMARY KEY(user_id,id)
);
CREATE TABLE sessions (
 id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), device_id TEXT NOT NULL,
 access_hash TEXT NOT NULL UNIQUE, refresh_hash TEXT NOT NULL UNIQUE,
 access_expires INTEGER NOT NULL, refresh_expires INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0,
 FOREIGN KEY(user_id,device_id) REFERENCES devices(user_id,id)
);
CREATE INDEX sessions_user ON sessions(user_id);
CREATE TABLE tracks (
 id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id),
 title TEXT NOT NULL, artist TEXT NOT NULL, album TEXT NOT NULL, album_artist TEXT NOT NULL,
 track_number INTEGER, disc_number INTEGER, duration_ms INTEGER NOT NULL,
 size_bytes INTEGER NOT NULL, sha256 TEXT NOT NULL, mime_type TEXT NOT NULL,
 artwork_mime TEXT, artwork_path TEXT, artwork_size_bytes INTEGER NOT NULL DEFAULT 0, audio_path TEXT NOT NULL,
 revision INTEGER NOT NULL, created_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX tracks_revision ON tracks(user_id,revision);
CREATE UNIQUE INDEX tracks_live_hash ON tracks(user_id,sha256) WHERE deleted=0;
CREATE TABLE uploads (
 id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), filename TEXT NOT NULL,
 size_bytes INTEGER NOT NULL, offset INTEGER NOT NULL DEFAULT 0,
 updated_at INTEGER NOT NULL, completed_track_id TEXT REFERENCES tracks(id)
);
CREATE INDEX uploads_user ON uploads(user_id);
CREATE TABLE playlists (
 id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id), name TEXT NOT NULL,
 revision INTEGER NOT NULL, updated_at INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX playlists_revision ON playlists(user_id,revision);
CREATE TABLE playlist_entries (
 playlist_id TEXT NOT NULL REFERENCES playlists(id), id TEXT NOT NULL,
 track_id TEXT NOT NULL REFERENCES tracks(id), position INTEGER NOT NULL,
 PRIMARY KEY(playlist_id,id), UNIQUE(playlist_id,position)
);
CREATE INDEX entries_track ON playlist_entries(track_id);
CREATE TABLE listening_events (
 user_id TEXT NOT NULL REFERENCES users(id), id TEXT NOT NULL,
 device_id TEXT NOT NULL, session_id TEXT NOT NULL, track_id TEXT NOT NULL REFERENCES tracks(id),
 started_at INTEGER NOT NULL, ended_at INTEGER NOT NULL, listened_ms INTEGER NOT NULL,
 timezone_offset_minutes INTEGER NOT NULL,
 PRIMARY KEY(user_id,id),
 FOREIGN KEY(user_id,device_id) REFERENCES devices(user_id,id)
);
CREATE INDEX events_session ON listening_events(user_id,device_id,session_id,started_at,id);
CREATE INDEX events_range ON listening_events(user_id,started_at);
CREATE TRIGGER events_no_update BEFORE UPDATE ON listening_events BEGIN SELECT RAISE(ABORT,'events are append-only'); END;
CREATE TRIGGER events_no_delete BEFORE DELETE ON listening_events BEGIN SELECT RAISE(ABORT,'events are append-only'); END;
