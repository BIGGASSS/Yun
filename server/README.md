# Yun Rust server

Real, standalone implementation of [`../docs/API.md`](../docs/API.md). Axum/Tokio,
SQLx SQLite (WAL, `synchronous=FULL`, foreign keys, embedded migrations), Lofty
metadata, Argon2id passwords, account-scoped opaque sessions. No external database,
FFmpeg, or other media service is required at runtime.

## Build and run

```sh
cd server
cargo build --release --locked
# Interactive password input is hidden. All admin commands require a stopped server.
./target/release/yun-server --data-dir ./yun-data create-user alice
./target/release/yun-server --data-dir ./yun-data serve --insecure-loopback
# http://127.0.0.1:8080/health
```

Use `--password-stdin` for automation; do not pass passwords on command lines.
Passwords must be 12–1024 bytes. Usernames are 1–128 bytes, case-insensitive for
ASCII (SQLite NOCASE). IDs submitted in bodies must be lowercase, hyphenated UUIDs.
The client chooses its device UUID and registers it through a successful login.

```sh
./target/release/yun-server --data-dir ./yun-data reset-password alice
./target/release/yun-server --data-dir ./yun-data backup /safe/backups/yun-2026-09-28
./target/release/yun-server serve --help
```

`YUN_DATA_DIR` and `YUN_BIND` are supported. `RUST_LOG` controls tracing. Tested
with Rust 1.98.1 on Linux. The server deliberately uses a single process per data
directory, enforced with an OS file lock. Use a local filesystem with working
SQLite locks, hard links, and file/directory fsync (not NFS/object storage).
Data and backup directories are set to mode 0700 on Unix. Run as a dedicated,
unprivileged OS user, and keep the data directory out of static web roots.

### Production HTTPS

TLS terminates at a **trusted HTTPS reverse proxy**. Run, for example:

```sh
./target/release/yun-server --data-dir /var/lib/yun serve \
  --bind 127.0.0.1:8080 --behind-tls-proxy
```

Example Caddy configuration:

```caddyfile
yun.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

The `--behind-tls-proxy` flag is an operator assertion, not automatic TLS or
validation of `X-Forwarded-Proto`. Never expose the HTTP origin to untrusted
networks. Apply HTTPS/HSTS, per-IP authentication rate limiting, connection limits,
and request-body timeouts at the proxy. Allow 10 MiB artwork requests and 4 MiB
upload chunks. Forward Authorization, Range, If-Range, If-Match, and Upload-Offset
unchanged. Do not cache authenticated responses. No permissive CORS is enabled.
Direct HTTP is allowed only with explicit `--insecure-loopback` on a loopback bind.

## Behavior and guarantees

### Authentication and account isolation

* Passwords use salted Argon2id (v19, 19 MiB memory, 2 iterations, parallelism 1).
* Access and refresh tokens each contain 256 cryptographically random bits,
  encoded as 64 hex characters. Only SHA-256 token digests are stored: high-entropy
  opaque tokens do not need an expensive password KDF. There are no JWTs or
  client-visible database/session IDs in token values.
* Access expires after 15 minutes; refresh after 30 days of inactivity. Each
  successful refresh atomically replaces **both** token digests and extends the
  refresh lifetime. Exactly one concurrent use of a refresh token succeeds;
  previous access and refresh tokens immediately stop working.
* Logout requires the current access token and its matching refresh token. It
  revokes that session, not another device/account's session. Reset-password
  revokes every session for that user. Logging in again can create another session.
* Every resource lookup is scoped to the authenticated account. Foreign tracks,
  playlists, uploads, audio, and artwork are inaccessible. Events require both an
  owned device and owned live or tombstoned track. Cross-account playlist entries
  and events fail atomically. Identical audio in different accounts has distinct
  track IDs and storage; deduplication never reveals another account's library.
* Authentication admission limits: 10 attempts/username/minute (including success),
  120 login attempts globally/minute, 600 refresh attempts globally/minute,
  and 4 simultaneous password operations. Unknown-user attempts still run Argon2.
  Rate-limit counters are bounded and in memory, so restart resets them; use the
  proxy's persistent/per-IP limits for Internet exposure.

### Durable uploads, media, and quotas

* Upload creation reserves the **entire declared size**. Default maximum file is
  1 GiB; default account quota is 20 GiB, configurable with `--max-file-bytes` and
  `--quota-bytes`. Quota counts live original audio, current artwork, and full
  pending-upload reservations. Each account can have 100 pending uploads and
  50,000 live tracks. No disk path is derived from a submitted filename.
* PATCH requires the exact committed Upload-Offset; chunks are at most 4 MiB,
  nonempty, and cannot overrun the declared size. File writes, fsync, then SQLite
  FULL-synchronous commit occur in that order. GET's offset never reports
  uncommitted bytes. Retrying from an old offset returns 409; query GET to resume.
* An interrupted write may leave a file tail beyond the SQL offset. The next
  PATCH truncates that tail before writing. The filesystem writer retains the
  mutation lock even if its HTTP future is cancelled, preventing a retry from
  racing an in-flight write. Partial uploads survive process restarts.
* Completion requires every byte. Content is SHA-256 hashed and sniffed, not
  trusted from filename/MIME. Supported containers: MP3, AAC/ADTS, MP4/M4A,
  FLAC, Ogg Vorbis, Ogg Opus, WAV, AIFF. Lofty extracts title, artist, album,
  album artist, track/disc number, duration, and embedded artwork. Missing title
  falls back to filename stem; other missing text is empty.
* Before committing a new track, a hard link to its immutable original and any
  extracted artwork are fsynced into the media directory. The upload source is
  retained until the DB transaction commits. Crashes cannot create committed
  references to unsynced media; unreferenced files are garbage-collected.
* Matching live SHA-256 within an account returns the existing track without
  changing metadata/revision. Completed-upload receipts remain for 24 hours,
  so repeating completion safely returns the same track (including after a lost
  response or restart). A receipt does not reserve duplicate quota. If that track
  was deleted in the meantime, replay returns 404. DELETE of a receipt only removes
  the receipt, not its track.
* Abandoned uploads expire 24 hours after the last successful chunk; reading
  status does not renew them. Startup and hourly cleanup remove expired uploads,
  expired/revoked sessions, orphaned files, deleted originals, and replaced artwork.
  Track deletion and artwork replacement also attempt immediate post-commit unlink.
* Metadata edits and artwork replacement never rewrite original bytes or their
  SHA-256. Track PATCH is partial and revision checked; numeric track/disc fields
  accept null to clear. Text is bounded to 4096 bytes. Embedded text is trimmed to
  1024 Unicode scalars. Artwork PUT requires the quoted revision in If-Match
  (428 when missing/malformed, 409 when stale).
* Images are actually decoded, not accepted based on headers: JPEG/PNG only,
  at most 10 MiB compressed, 8192×8192 maximum dimensions, 64 MiB decode allocation
  limit. The first valid image among the first eight embedded pictures is used;
  invalid/unsupported embedded pictures are skipped. Invalid manual images fail.
* Audio streams from disk rather than buffering the full file. GET and HEAD
  provide Content-Length, Accept-Ranges, and quoted SHA-256 ETag. Single normal,
  open-ended, and suffix byte ranges return 206. Invalid/unsatisfiable or multipart
  ranges return 416 with `Content-Range: bytes */size`. If-Range must exactly match
  the strong ETag; weak tags, dates, or mismatches produce the whole representation.

### Revisions, playlists, and events

* Library cursors are per-account monotonic SQLite revisions, never timestamps.
  All mutations and their revision changes commit in one transaction. Snapshot
  reads are also transactional, so their cursor and rows describe the same state.
  Missing cursor means full snapshot/reset; a cursor ahead of the account also
  forces a full reset. Unchanged delta returns empty arrays and the current cursor.
* Track and playlist tombstones are retained indefinitely. Removing a track
  removes its playlist entries and bumps affected playlist revisions in the same
  transaction. Its identity/metadata survive for stats and delayed offline events.
* Playlist create/replace names are nonempty, at most 512 bytes. Replace/delete
  compare revisions, returning 409 on stale writes. Entry IDs must be unique within
  a playlist, while repeated track IDs are allowed and order is preserved. Maximum
  10,000 playlists/account and 10,000 entries/playlist.
* Event ingestion is append-only (also enforced by SQL triggers) and atomic for
  the entire batch of at most 500. Identical duplicate event IDs are acknowledged
  without insertion; reusing an ID with changed content returns 409. Unknown owned
  identities, a changed track within a device/session, or any invalid segment
  reject the whole batch. The same event ID in different accounts is independent.
* Segment wall duration must be 1–60,000 ms; listening time is nonnegative and at
  most wall duration + 2 seconds. End times up to 2 minutes in the future are
  tolerated. Any past nonnegative Unix timestamp is accepted. Timezone offsets
  are -840 through +840 minutes. Sessions are partitioned by device + session UUID.
* Stats are derived directly from immutable events, including partial listening;
  there is no fragile secondary counter to corrupt or rebuild. Ordered event-time
  cumulative playback counts a session once when reaching `min(30000,duration/2)`
  (minimum 1 ms). Offline out-of-order insertion is handled deterministically.
* Range semantics, where the contract leaves details open: include whole segments
  whose **started_at** is in `[from,to)`. Counted plays are attributed to the segment
  that first crosses the threshold over the *full* session, before range filtering.
  Thus splitting a session across day queries never counts it twice. History groups
  selected segments by device/session, returns their earliest selected start,
  and marks counted_play if the threshold-crossing segment is in that range.
  Totals/top lists use the same selection. Album grouping uses album artist,
  falling back to track artist. Metadata shown in history is current retained track
  metadata, not a frozen snapshot of text at playback time.

## Backup and restore

1. Stop the server cleanly (SIGINT or SIGTERM). Administrative commands refuse to
   open a data directory locked by another instance.
2. Run `yun-server --data-dir /var/lib/yun backup /safe/backups/new-directory`.
   The destination **must not exist**. The command uses SQLite `VACUUM INTO` for
   a consistent database and copies/fsyncs media and pending uploads. A failed
   backup can leave a partial destination: discard it and retry to a new path.
3. Keep encrypted off-machine copies. Backups include password/token hashes,
   personal listening history, music, and artwork.
4. To restore, stop the server and point `--data-dir` to the completed backup, or
   copy its entire contents into a new private directory, then start the server.
   SQLite recreates its WAL files; migrations run automatically. Token expiration
   timestamps and pending upload offsets are preserved. Uploads already past
   their abandonment TTL are cleaned at startup.

Never back up only the live `.sqlite3` file while ignoring its WAL or changing
media. An alternative is a full stopped-directory copy including SQLite sidecars.
Keep the prior version and a backup before upgrades; migrations are forward-only.

## Verification

```sh
cargo fmt --check
cargo test --locked
cargo clippy --locked --all-targets --all-features -- -D warnings
```

Nine end-to-end Axum integration tests plus range unit tests cover real SQLite and
filesystem operations: auth/expiry/rotation races/revocation/hash storage/rate
limits, account isolation across all resources, durable resumed writes and
uncommitted tails, concurrent chunk/playlist writes, repeat completion, quota
reservations, duplicate audio, GET/HEAD/ranges/If-Range, seven compressed/container
fixtures plus generated WAV, embedded tags/images, manual edits, malformed/oversized
payloads, cursor tombstones, atomic/idempotent/reordered offline events, deleted
track stats, restart, cleanup, and an actual backup restore. Synthetic fixture
regeneration is optional: `bash scripts/generate-fixtures.sh` (requires FFmpeg).

## Deliberate limits and remaining caveats

* Parser defenses: two concurrent media operations, Lofty strict mode, 16 MiB per
  tag-item allocation, 128 MiB total parser-read budget, 1 KiB junk scanning,
  20-second I/O/deadline checks, and 7-day maximum track duration. Compressed ID3
  frame support is disabled. These limits can reject unusually large/complex valid
  metadata and formats needing a full scan beyond the budget. Hashing original
  audio is streaming and separate from that read budget.
* Lofty validates format structure/properties, **not every decoded audio sample**.
  Damaged payloads with plausible structure may still fail in a player. The parser
  runs in a blocking thread, **not an OS sandbox**: deadlines are cooperative, not
  a hard kill or total process-memory guarantee. For hostile public uploads, add
  a resource-limited worker process/container and decoder validation. The service
  is intended for authenticated personal-library uploads, not anonymous hosting.
* One process, a global mutation lock, up to 32 admitted requests/responses, a
  shared 64 MiB request/response byte budget (64 KiB units), and a 60-second handler
  timeout. Requests reserve the route body maximum before body polling (normally
  2 MiB). Buffered JSON responses reserve any excess of their actual serialized
  body size over that request reservation, rounded up to 64 KiB. Either admission
  fails immediately with HTTP 429 rather than queueing; a JSON response that cannot
  acquire its excess budget is discarded and replaced with a small 429 response.
  Base and excess reservations survive handler completion until the response body
  and emitted bytes are consumed or dropped, including JSON queued behind socket
  backpressure in the built-in Axum/Tokio TCP transport. Streaming media's advertised
  Content-Length is not charged as buffered JSON; media also has a 32-stream limit.
  These bound admitted outstanding bodies, not transient handler/JSON serialization
  allocations (which occur before response admission), response write deadlines,
  or total process memory. Proxy connection/write/idle limits remain necessary;
  copying/buffering proxies or custom transports must enforce their own bounds.
* Full library responses have no pagination because the v1 contract has none.
  Stats recompute via SQL windows over the account's events, so queries get slower
  with a very large history. A materialized/rebuildable aggregate is a future
  optimization. Events/tombstones intentionally never expire; monitor database
  disk usage (metadata/history are not charged to the audio/artwork quota).
* Events are client-reported personal statistics, not anti-fraud telemetry; unique
  IDs prevent replay inflation, but the server cannot prove a client really played
  audio or detect fabricated nonduplicate segments.
* Single-range streaming is implemented; multipart range responses, date-form
  If-Range matching, in-process TLS, web signup, transcoding, automatic client codec
  compatibility conversion, and online administrative/backup APIs are not provided.
  MP4 files are accepted when Lofty finds valid audio properties; no remuxing strips
  other container tracks. Keep original uploads immutable.
