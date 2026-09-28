# Yun API v1 contract

All routes except health/login/refresh require `Authorization: Bearer <access_token>`. JSON snake_case, timestamps Unix milliseconds, IDs UUID strings. HTTPS required except explicit loopback development. Errors: `{ "error": "message" }`, appropriate status codes. All resource queries MUST filter by authenticated user.

- GET /health -> {status:"ok"}
- POST /api/v1/auth/login {username,password,device_id} -> {access_token,refresh_token,user:{id,username},expires_at}
- POST /api/v1/auth/refresh {refresh_token} -> same; rotate refresh token atomically
- POST /api/v1/auth/logout {refresh_token} -> 204; revoke session
- GET /api/v1/library?cursor=<integer> -> {cursor:integer,reset:bool,tracks:[Track],deleted_track_ids:[id],playlists:[Playlist],deleted_playlist_ids:[id]}. Omit cursor for full snapshot reset=true. Cursor is account revision, not wall clock. Track/playlist mutations bump it transactionally. Retain tombstones indefinitely initially.
- PATCH /api/v1/tracks/{id} {revision,title,artist,album,album_artist,track_number,disc_number} -> Track; 409 on stale revision. Partial fields allowed.
- DELETE /api/v1/tracks/{id} -> 204 (remove playlist entries, retain stats identity).
- GET /api/v1/tracks/{id}/audio -> original audio with Range/If-Range, ETag equal quoted sha256, Accept-Ranges and Content-Length. HEAD supported. 416 for invalid/unsatisfiable range.
- GET /api/v1/tracks/{id}/artwork -> artwork or 404
- PUT /api/v1/tracks/{id}/artwork raw image (JPEG/PNG <=10MiB) -> Track; If-Match header with quoted track revision required, 409 if stale.
- POST /api/v1/uploads {filename,size_bytes} -> {id,offset:0}; max file default 1GiB, account quota default 20GiB.
- GET /api/v1/uploads/{id} -> {id,offset,size_bytes,filename}
- PATCH /api/v1/uploads/{id} raw bytes, Upload-Offset header -> {id,offset}; max chunk 4MiB, 409 offset mismatch. Offset reflects durable bytes.
- DELETE /api/v1/uploads/{id} -> 204
- POST /api/v1/uploads/{id}/complete -> Track (deduplicate within account by sha256; validate supported audio, extract tags/duration/artwork, immutable original)
- POST /api/v1/playlists {name} -> Playlist
- PUT /api/v1/playlists/{id} {revision,name,entries:[{id,track_id}]} -> Playlist; 409 stale revision; entry IDs unique, repeated track IDs allowed
- DELETE /api/v1/playlists/{id}?revision=N -> 204; 409 stale revision
- POST /api/v1/listening-events {events:[Event]} -> {acknowledged_ids:[id]}; max 500; atomic validated batch; duplicate event IDs never increase totals
- GET /api/v1/stats?from=<ms>&to=<ms> -> {listened_ms,play_count,top_tracks:[{id,title,artist,listened_ms,play_count}],top_artists:[{name,listened_ms,play_count}],top_albums:[{name,artist,listened_ms,play_count}],history:[{session_id,track_id,title,artist,started_at,listened_ms,counted_play}]}; range defaults all, from inclusive/to exclusive, history newest 100; top lists capped 50. One counted play per device/session when cumulative real playback time reaches min(30000,duration_ms/2); include partial listening time. Stats are personal and not stats.fm integration.

Track = {id,title,artist,album,album_artist,track_number,disc_number,duration_ms,size_bytes,sha256,mime_type,has_artwork,revision,created_at}
Playlist = {id,name,revision,entries:[{id,track_id}],updated_at}
Event = {id,device_id,session_id,track_id,started_at,ended_at,listened_ms,timezone_offset_minutes}; segment duration >0 and <=60s, listened_ms <= elapsed wall time + small tolerance. Client persists segments every ~10s and on transitions, counts via monotonic clock only while actually playing (not buffering). Future timestamps beyond tolerance rejected; offline past events accepted. Device belongs to authenticated account. Original events retained; aggregates rebuildable. When a track is deleted, delayed events may reference its retained tombstone owned by the same account.

Client uses its own SQLite cache per (server,user). Library and playlist writes online only. Persistent outbox is acknowledged only after server confirms IDs. Offline files retained after logout but inaccessible through app until same account reauthenticates. Token expiry never prevents an already signed-in account playing downloaded files.
