# Yun API v1 contract

All routes except health/login/refresh require `Authorization: Bearer <access_token>`. JSON snake_case, timestamps Unix milliseconds, IDs UUID strings. HTTPS required except explicit loopback development. Errors: `{ "error": "message" }`, appropriate status codes. All resource queries MUST filter by authenticated user.

- GET /health -> {status:"ok"}
- POST /api/v1/auth/login {username,password,device_id} -> {access_token,refresh_token,user:{id,username},expires_at}
- POST /api/v1/auth/refresh {refresh_token} -> same; rotate refresh token atomically
- POST /api/v1/auth/logout {refresh_token} -> 204; revoke session
- GET /api/v1/library?cursor=<integer>&paged=true&page_token=<string> -> {cursor:integer,reset:bool,tracks:[Track],deleted_track_ids:[id],playlists:[Playlist],deleted_playlist_ids:[id],next_page_token?:string}. All query parameters are optional; `paged` is a boolean defaulting to `false`. Omit cursor on the first request for a full snapshot (`reset=true`); a cursor ahead of the account revision also resets. Cursor is account revision, not wall clock. Track/playlist mutations bump it transactionally. Tombstones are retained indefinitely. See pagination below.
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

## Library pagination

Pagination-capable clients must send **`paged=true` on the initial request**
(and should send it on every page request), for both full snapshots and deltas.
A valid `page_token` also implies pagination even if `paged` is omitted or false.
Without negotiation, a request that needs continuation returns **400** with
`{"error":"client upgrade required: library requires pagination; send paged=true and consume all next_page_token pages before saving cursor"}`,
not a truncated successful snapshot or a new cursor. Small legacy requests still
succeed unchanged, including small deltas from large libraries. Upgrade the client
to merge all pages; merely retrying with `paged=true` and ignoring tokens is unsafe.

Each page contains at most **256 total records**, counting tracks, deleted IDs,
playlist metadata objects, **and every playlist entry**. Small responses retain
the existing one-response shape (no `next_page_token`). A boundary page may be
followed by an empty final page; only absence/null of `next_page_token` ends sync.
Such boundary responses also require negotiation; do not infer compatibility from
record count alone (the SQL page budget is 128 rows, including joined entries).

Pass the opaque `next_page_token` as `page_token` until exhausted. The token
contains an account-bound snapshot revision, original effective cursor/reset,
and keyset position. Continuations may omit `cursor`; if provided for an
incremental snapshot it must match the original cursor. Tokens are not durable
sync cursors and clients must not interpret or edit them.

All pages carry the **same final snapshot `cursor` and `reset`**. Track and deleted
ID records do not repeat. A playlist may repeat across pages with **disjoint,
ordered entry fragments**; its other metadata stays identical. Merge fragments
by playlist ID, appending entries in page order (including repeated track IDs).
An empty playlist has an empty entries array. Collection ordering outside each
playlist's entries is unspecified.

Collect and merge all pages before atomically applying the snapshot/delta and
advancing the durable cache cursor. If the account revision changes between
pages, the server returns **409**: discard every collected page and restart from
the original durable cursor, retrying at most **three times**. Never apply partial
pages or advance to the response cursor before completing the snapshot. Invalid
or cross-account tokens return 400.

## Admission and cancellation

Limits are shared across router instances: 32 active requests, a 64 MiB raw-body
budget reserved **before reading** (using route maxima even for chunked bodies),
two parser workers, and 32 active audio/artwork response streams. Streams retain
their permits until EOF, error, or body drop. Capacity exhaustion returns 429;
clients should retry with backoff. Existing per-request body limits still apply.

**Streaming timeout limitation:** these permits bound concurrency, not duration.
The application body sees Hyper's demand for frames, not socket writes or client
consumption. Under network backpressure Hyper may stop polling the body entirely;
a timer checked in `poll_frame` cannot then close the connection. Releasing a
permit from a background timer without dropping the actual transport/body would
allow unbounded live streams and file handles. Consequently there is no claimed
application-level slow-reader idle timeout. Enforce and test downstream write/idle
timeouts and connection limits at the trusted reverse proxy (or a transport layer
that owns and can abort the connection); handler timeouts do not cover response
streaming. Slow readers can otherwise occupy all 32 stream slots indefinitely.

Upload writes, completion, and cancellation serialize per upload, not across all
uploads. Hashing (included in the 20-second cooperative parser budget), metadata
parsing, chunk writes/fsync, and artwork preparation run outside the global
publication lock. A timed-out/disconnected mutation may still finish safely;
resume using GET upload offset, retry completion idempotently, or fetch current
resource revision rather than assuming cancellation rolled it back. GC skips
busy uploads and checks file liveness immediately before deletion. Enable
`RUST_LOG=yun_server::locks=debug` to log global-lock wait/hold microseconds.

Statistics compute threshold crossings over the complete histories of sessions
represented in the requested range, ordered by `(started_at, ended_at, id)`;
only then do they select events by `started_at`. Late offline events can move a
session's counted play into an earlier range but cannot create a second play.

Client uses its own SQLite cache per (server,user). Library and playlist writes online only. Persistent outbox is acknowledged only after server confirms IDs. Offline files retained after logout but inaccessible through app until same account reauthenticates. Token expiry never prevents an already signed-in account playing downloaded files.
