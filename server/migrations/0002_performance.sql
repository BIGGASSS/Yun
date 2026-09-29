-- Range selection is covering; session histories follow exact window order.
DROP INDEX events_session;
CREATE INDEX events_session ON listening_events(user_id,device_id,session_id,started_at,ended_at,id);
DROP INDEX events_range;
CREATE INDEX events_range ON listening_events(user_id,started_at,device_id,session_id);
-- Bounded GC existence checks must not scan the live library for each file.
CREATE INDEX tracks_live_audio ON tracks(audio_path) WHERE deleted=0;
CREATE INDEX tracks_live_artwork ON tracks(artwork_path) WHERE deleted=0 AND artwork_path IS NOT NULL;
CREATE INDEX uploads_expiry ON uploads(updated_at,id);
CREATE INDEX sessions_revoked_gc ON sessions(id) WHERE revoked=1;
CREATE INDEX sessions_expiry_gc ON sessions(refresh_expires,id);
-- Keyset pages (including playlist entry fragments) never need OFFSET.
CREATE INDEX tracks_sync_key ON tracks(user_id,deleted,revision,id);
CREATE INDEX playlists_sync_key ON playlists(user_id,deleted,revision,id);
