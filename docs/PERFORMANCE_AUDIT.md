# Performance audit

Original audited revision: `1628b0b`. Scope: Flutter client and Rust server.
The original audit was read-only. The remediation below was subsequently
implemented; the remaining sections preserve the original findings and baseline
line references. This is not a production capacity or four-platform certification.

## Download write buffering

Audio reception now coalesces network fragments into a fixed 256 KiB write
buffer rather than awaiting a file write for every fragment. Byte-progress
notifications are coalesced into trailing 100 ms ticks; status transitions remain
immediate, and pending ticks are cancelled when reception ends. This reduces
main-isolate I/O wakeups and visible progress work, especially on Linux's GTK
task runner. A deterministic regression checks that 1,024 four-KiB fragments
produce 16 writes, not 1,024; this is not a measured end-to-end speedup.

Live received-byte progress includes the bounded in-memory tail. Resume and
persisted failure offsets always use the actual partial-file length. Normal EOF,
transport errors and oversized responses drain only previously accepted bytes;
close/unpin discards the unwritten tail. Entire oversized fragments are rejected,
failed file writes are not retried, and flush/checksum verification still precede
playable publication. Regression coverage includes buffer boundaries, large and
tiny fragments, error/short-body retries, overflow without EOF, cancellation and
notification timing/lifetime. This first fix did not change the transport or
worker-isolate architecture; follow-up measurements motivated the next change.

Local validation: **1,123 Flutter tests passed, 19 opt-in tests skipped**, including
17 new buffer/notification regressions and the real Rust/Dart TCP suite. Flutter
analysis, formatting, diff whitespace checks, Linux release build and bundled
tray-linkage verification passed. The installed desktop bundle was not replaced.

## Download reception isolate

Follow-up measurements of the buffered Linux release still showed about 1.74
MiB/s with Downloads visible and 1.9–2.2 MiB/s on Settings. The 256 KiB writes
were confirmed active, yet roughly 75–90 KiB stayed unread at the socket while
the main thread spent most sampled time waiting. Dart's small TLS buffers and
native-filter/timer events on the Linux GTK task runner are the leading suspected
bottleneck; individual event latency was not directly profiled.

The default client now keeps a persistent download isolate with its own Dio
connection pool. HTTP/TLS reception and bounded file writes both run there;
audio buffers never cross back to Flutter. Progress is coalesced every 100 ms,
with an acknowledgement bounding queued ordinary progress to one message plus
a terminal update. The root retains serialized credential refresh (one 401
retry), database publication and UI state. Only request-scoped access headers
are copied to the worker, never the credential store or refresh token. Existing
checksum verification still gates the final rename and offline publication.

Cancellation waits for the response and file to close; service shutdown joins
the worker's exit. IDs discard stale messages, fatal exits fail pending work
and allow a fresh worker on the next request, and failures preserve sanitized
HTTP/transport categories for offline/error handling. Injected Dio clients use
the same file-reception routine inline so custom adapters/interceptors/trust
settings are not silently discarded. Default root-client interceptors do not
observe worker audio requests; tests observe the receiver boundary instead.

New regressions cover real TCP transfers and Range retries, rejected audio
headers, authentication and account replacement, cancellation/reselection,
worker startup/exit/restart, progress acknowledgement and background error
classification. The affected Linux user confirmed that this build resolved the
slow downloads. No controlled post-change throughput figure was recorded, so
this is qualitative device confirmation, not a claimed speedup multiplier.

Local validation: **1,178 Flutter tests passed, 19 opt-in tests skipped**, including
55 new receiver, lifecycle, authentication and error-classification regressions.
Flutter analysis, formatting, whitespace checks, Linux release build and tray
linkage verification passed. The installed desktop bundle was not replaced.

## Follow-up snapshot review remediation

The ten follow-up findings against `0c5ca0b` are addressed:

- Album/playlist membership is indexed once per pin-expansion snapshot; deterministic
  traversal-count regressions cover libraries up to 40,000 tracks.
- Bulk track pins are persisted atomically, followed by one cache reload and
  reconciliation. Tests cover 1,000 tracks, duplicates, empty input and rollback.
- Shared admission reservations survive JSON response consumption and transport
  backpressure. Buffered JSON exceeding its request reservation acquires the excess
  from the shared 64 MiB budget or fails immediately with HTTP 429. Tests cover
  retained responses, large JSON byte saturation, final-frame ownership, bounded
  Hyper writes, disconnect recovery and streaming-media exemption.
- Superseded download batches stop between tracks; losing the last pin reference
  cancels active network work or isolate verification. Overlapping pins retain work.
- Uploads have a finite send timeout; real non-reading-peer tests and uncertain
  write recovery tests preserve server-acknowledged offsets.
- Automatic checksums reuse the cancellable isolate verifier before publishing files.
- Upload/file deltas update controller inventories directly, including changes racing
  full cache loads. Read-only inventory views are live rather than copied per tick.
  Bulk history removal compacts/reindexes and notifies once.
- Playlist renames skip unchanged entry writes; a 10,000-entry regression verifies
  zero entry mutations, with separate coverage for identity/order/track changes.
- Track-picker derivations are cached independently of checkbox state; playlist
  chooser rows build lazily in a bounded viewport.

Local validation: **1,104 Flutter tests passed, 19 opt-in tests skipped**; separate
native playback run **18 passed, one external-network opt-in skipped**. **36 Rust
tests passed**, Flutter analysis, Rust strict Clippy and formatting passed, and
API smoke checks passed **65 real TCP requests**. These are regression/component
checks, not physical-device frame-time or production RSS guarantees. Admission
cannot bound transient allocations already made by handlers/serialization, and
buffering proxies/custom transports still require their own connection/write limits.

## Remediation implemented

All eight primary findings and the additional code-level risks have fixes and
regression coverage:

| Area | Implemented change |
| --- | --- |
| Collection work | Stable immutable snapshots, O(1) track lookup, captured download sets and cached library/playlist derivations |
| Notifications | Separate playback/download/artwork listeners; selective row/player updates instead of rebuilding collections on byte/position ticks |
| Persistence | Coalesced reload requests; upload/file-only refreshes; no-op sync skips full reload; unchanged reconciliation performs zero redundant puts/notifies; separate five-minute integrity checks |
| Server locking | Per-upload exclusion survives request cancellation; hashing/parsing/chunk fsync outside global publication lock; GC revalidates one file at a time and deletes indexed batches |
| Statistics | Range-indexed candidate sessions, full-session threshold calculation, one materialized result shared by five aggregates, improved window index |
| Library sync | Bounded composite-key pages including playlist-entry fragments, batched retrieval, revision-conflict restart and atomic client cursor application |
| Artwork | Three concurrent fetches, bounded 64-request admission, foreground priority over optional prefetch, one startup disk-index scan, incremental byte accounting/eviction and memory-only build-time path reads |
| Outbox | Indexed SQL LIMIT 500 and COUNT queries instead of decoding the entire outbox |
| Queue/native controls | Stable queue identity and latest-state coalescing; only changed Windows properties are sent |
| Server capacity | Shared pre-body request/byte admission, permits retained by detached mutation work, separate permits held for the complete response-body lifetime |
| Mutation cost | Batched playlist/event operations and validation limited to referenced IDs; unchanged playlist entries are not rewritten |
| Shutdown/account isolation | Cleanup continues after checkpoint failures; logout clears credentials and detaches recording before closing its database. Unsaved segments remain quarantined by normalized server/user and retry only when that account returns; in-flight saves retain their original destination |
| Upload badge | Narrow count subscription updates badge/tooltip on upload-only notifications; stable snapshots avoid rescanning uploads on download byte ticks |

### Post-fix validation

- **447 Flutter tests passed, one opt-in native-playback test skipped in the full suite.**
  The separate `RUN_NATIVE_PLAYBACK=1` test also **passed**, exercising real libmpv
  with null audio (not hardware playback). Includes real Rust/Dart TCP pagination,
  playlist-fragment merging, no-op resync, failed-logout account isolation and
  upload-only badge updates.
- **26 Rust tests passed** (10 unit, 16 API integration).
- Flutter analyzer, Rust Clippy (`--all-targets --all-features -- -D warnings`),
  formatting and diff whitespace checks passed.
- `scripts/api_smoke.py`: **65 real TCP requests passed**.
- Shell syntax, release tooling (3 tests) and Android signing tooling (7 tests)
  passed locally. Container, platform builds and other hosted checks run in CI.
- Additional artwork regressions cover concurrency/backlog bounds, foreground
  priority, startup-only indexing, external deletion recovery and close behavior.

Repeatable benchmarks are now committed:

```sh
.fvm/flutter_sdk/bin/flutter test --no-pub test/performance/collection_benchmark.dart
python3 server/scripts/benchmark-stats.py
```

| Component / fixture | Original measurement | Post-fix measurement |
| --- | ---: | ---: |
| Downloads membership filter: 10k tracks, 5k downloads | 1,876.74 ms | 0.196 ms |
| 1k track lookups in a 10k-track library | 63.61 ms | 0.028 ms |
| Unchanged reconciliation: 5k downloads | 10k puts in the original seeded-file pass | 0 puts once status is established |
| Narrow-range statistics: 100k historical events, ten selected | 971.4 ms | 0.307 ms |

Client timings remain synthetic Flutter test/debug component measurements, not
frame times. The post-fix harness also reproduces copying the ID set per track
(1,828.88 ms at 10k/5k), excluding widget layout/paint. Both implementations now
use identical synthetic fixture sizes; cache/status initialization is excluded
from the zero-write reconciliation assertion. SQL timing includes aggregation
and JSON parsing but excludes HTTP/SQLx, disk and concurrent clients. Do not
interpret these ratios as whole-application speedups.

### Deployment and remaining validation

- **Update clients and server together.** The client requests `paged=true`.
  Small legacy requests remain compatible; large unnegotiated requests fail
  explicitly with HTTP 400 instead of silently returning an incomplete library.
  A changed revision during pagination yields 409; the client discards partial
  data and retries up to three times. See `docs/API.md`.
- Database indexes migrate automatically; retain the normal stopped-server
  backup procedure before deployment.
- If storage failure prevents the final listening checkpoint, its segments are
  retained only in account-scoped process memory until that account signs in
  again. These non-durable segments cannot survive process exit; existing durable
  outbox records remain unchanged and are never reassigned across accounts.
- Optional background artwork prefetch is bounded/best-effort: queued prefetch
  may be displaced or dropped when full. Foreground image requests take priority.
- Whole-history statistics still process the history once; persistent aggregates
  are unnecessary for the measured narrow-range bottleneck but remain an option
  if all-time queries become expensive.
- Publication still needs short rename/link/directory-sync and DB-commit critical
  sections to preserve crash safety. Measure lock wait/hold tracing under mixed
  traffic on real storage; do not infer a production playback-start latency SLO.
- Streaming permits cap resources, not slow-reader duration. A body wrapper
  cannot time out a socket when Hyper stops polling it under backpressure; use
  proxy/transport-level slow-reader controls as explained in `docs/API.md`.
- Physical-device frame/raster, RSS/battery, native media bridge and production
  mixed-load validation remain outstanding. Those require runtime measurements,
  not more speculative code changes.

## Original audit: executive summary

The highest-value work is eliminating repeated collection work in the client,
separating progress notifications from library rendering, and shortening the
server's global write-lock scope. The current implementation can become slow with
ordinary large personal libraries, without unusually high concurrent traffic.

| Priority | Finding | Evidence |
| --- | --- | --- |
| High | Downloads filtering repeatedly copies the entire downloaded-ID set | Measured 1,877 ms for one filter at 10k tracks / 5k downloads |
| High | Playback/transfer notifications rebuild collection screens; playlist lookups scan the library | Confirmed notification chain; measured 64 ms for 1k lookups at 10k tracks |
| High | Upload progress schedules full cache reloads; unchanged download reconciliation rewrites records | Measured 10k database puts for 5k already-downloaded tracks |
| High | Upload hashing/parsing and chunk fsync hold a global lock also needed to start playback | Confirmed lock scope; mixed-traffic latency not measured |
| High | Statistics recompute all historical events five times | Measured 971 ms at 100k events for a ten-event range |
| Medium | Library sync is unpaged and uses two extra queries per changed playlist | Confirmed query/allocation structure |
| Medium | Artwork retrieval serializes network work and scans the whole disk cache after every store | Confirmed code path; cold-grid latency not measured |
| Medium | Offline outbox reads/decodes all events to count or send a bounded batch | Confirmed algorithmic scaling |

## Measurements and limits

Validation on this Linux host:

- `cargo test --manifest-path server/Cargo.toml --locked`: **12 passed**.
- `.fvm/flutter_sdk/bin/flutter test`: **403 passed, one skipped**. Native playback
  is opt-in and was not exercised by this run.
- `.fvm/flutter_sdk/bin/flutter analyze`: **no issues**.
- Dart SDK: **3.13.4**; Python SQLite: **3.53.4**.

Client component measurements used the actual `AppController`, an in-memory
`CacheDatabase`, synthetic tracks, fake playback/credentials, and a temporary
local file representing available downloads. Timings are medians of three runs
after two warmups in **Flutter test/debug mode**, not release/profile frame times.
Database seeding and filesystem reconciliation are excluded from the lookup
measurements. The alternative expressions were tested in the harness only.

| Library tracks / downloads | Current Downloads filter | Capture ID set once | 1,000 `trackById` lookups | Build map + same lookups |
| --- | ---: | ---: | ---: | ---: |
| 1,000 / 500 | 13.84 ms | 0.11 ms | 2.02 ms | 0.12 ms |
| 5,000 / 2,500 | 462.63 ms | 0.29 ms | 17.31 ms | 0.38 ms |
| 10,000 / 5,000 | 1,876.74 ms | 0.42 ms | 63.61 ms | 0.85 ms |

The Downloads measurement evaluates the membership predicate across every track;
widget layout, painting, other filters and image work are not included. Playlist
lookups target the final 1,000 tracks in title order; positions affect linear-scan
cost. These numbers demonstrate scaling, not universal speedup guarantees.

Server measurements executed the five exact statistics SQL statements extracted
from `server/src/events.rs`, using the production migration in SQLite `:memory:`.
Synthetic data: one user/device/track, ten-second events, 18 events per session;
the requested range contains only the last ten events. One warmup, then median
of three complete five-query runs:

| Historical events | Five-query median |
| --- | ---: |
| 10,000 | 99.4 ms |
| 100,000 | 971.4 ms |

These exclude Rust/SQLx overhead, HTTP, disk I/O and concurrent clients. The query
plan uses `events_session` over the user's history and a temporary B-tree for
part of the window ordering.

Temporary audit harnesses and logs on this host (not committed):

```sh
.fvm/flutter_sdk/bin/flutter test --no-pub --reporter expanded /tmp/yun_performance_audit_test.dart
python3 /tmp/yun_stats_audit.py
# /tmp/yun-audit-microbench.log
# /tmp/yun-audit-stats.log
# /tmp/yun-audit-flutter-tests.log
# /tmp/yun-audit-analyze.log
```

No production data was accessed. No actual GPU/frame timeline, physical-device
battery/RSS measurements, native bridge latency, or mixed-traffic HTTP load test
was collected. Functional tests do not establish performance budgets.

## Detailed findings

### 1. High: Downloads has an accidental quadratic filter

**Locations:** `lib/core/app_controller.dart:77`;
`lib/ui/downloads_screen.dart:15–17,52–58`.

`downloadedTrackIds` constructs a new `Set.unmodifiable(_files.keys)` each time.
The screen calls that getter inside each track predicate, producing O(N × D)
copying/hashing for N library tracks and D downloads. The pending filter repeats
this for selected tracks. This work occurs before lazy rows can help.

**Fix:** capture the downloaded-ID set once per build immediately. Longer term,
expose a stable immutable snapshot, or an O(1) membership method, updating it only
when file availability changes. Add a large-library regression benchmark.

### 2. High: High-frequency notifications repeat expensive library work

**Locations:** `lib/services/playback_engine.dart:113–120`;
`lib/core/playback_controller.dart:177–227`;
`lib/core/app_controller.dart:51,92–94,198–199,398–403`;
`lib/ui/app.dart:143–146,238–282`;
`lib/ui/library_screen.dart:133–169`;
`lib/ui/playlist_screen.dart:430–450,478–489`.

Playback state/position reaches the general app notifier, which rebuilds the
shell and current collection screen. Downloads notify on every received chunk
(`lib/services/transfer_service.dart:709–714`). Filtering, grouping and sorting
then repeat even though the library has not changed. Flutter can coalesce
notifications within a frame, but the invalidation scope is still too broad.

Playlist detail eagerly resolves every entry using linear `trackById()`;
non-original sorting resolves tracks inside comparisons. For M playlist entries
and N library tracks, these are O(M × N) and O(M log M × N), respectively.

**Fix:** split library, playback-position and transfer-progress observables;
listen narrowly in the player/progress widgets. Maintain an ID-to-track map and
cache derived collection views by library revision, query and sort settings.
Throttling alone would mask, not remove, the collection costs.

### 3. High: Transfer updates and no-op polling cause redundant persistence work

**Locations:** `lib/core/app_controller.dart:145–146,188–190,210–248,346–358`;
`lib/services/transfer_service.dart:335–337,420–442,590–637`.

Each acknowledged upload chunk saves its job and invokes `onChanged`, scheduling
another full `_reloadCache()`. A 100 MiB file uses about 25 four-MiB chunks, hence
about 25 full reloads plus transition-related reloads. Each reload reads/decodes
all tracks, playlists, uploads, pins, file records and pending events, sorts
tracks, and sequentially validates every cached audio path. `_reloadTail`
serializes requests but does not coalesce obsolete ones, so a backlog can form.

Separately, every successful periodic refresh reconciles downloads even when
nothing changed. Reconciliation rewrites every selected file's reference record,
then saves every already-downloaded track's status and emits progress. The
harness confirmed **5,000 file puts + 5,000 download puts** for an unchanged
5,000-download selection. This counts application database writes, not measured
physical disk writes/fsyncs. The timer runs every 30 seconds while active and
signed in; refresh/reconciliation already prevent overlapping active passes.

**Fix:** update upload state independently; coalesce full reload requests. Skip
unchanged file/reference/status writes and progress notifications. Reconcile
changed selections/library revisions, with a separate deliberate integrity or
retry pass so missing-file detection and failed downloads still recover.

### 4. High: A global server lock couples ingestion to playback-start latency

**Locations:** `server/src/uploads.rs:127–172,204–230,288–313`;
`server/src/media.rs:79–99,305,372`;
`server/src/auth.rs:207,245`.

Upload completion holds the application-wide write mutex and a DB transaction
while hashing the entire file and parsing metadata. Hashing precedes the
parser's 20-second budget; files may be up to 1 GiB by default. Chunk writes hold
the same mutex through blocking file writes, fsync and DB commit. Audio/artwork
opening and successful login/refresh also need it. Moving work to
`spawn_blocking` avoids blocking Tokio workers, but does not release this mutex.

**Impact:** large uploads or slow storage can queue new playback requests and
mutations across users. Already-open audio streams do not hold this lock for
their whole lifetime. Maintenance also scans/unlinks under this lock, creating
another storage-size-dependent pause.

**Fix:** per-upload exclusion for file mutation; bounded hashing/parsing outside
the global critical section; short revalidation/commit phases. Preserve
cancellation safety, committed upload offsets, quota/deduplication checks and
GC/open-file coordination. Batch maintenance rather than holding the lock for a
whole directory sweep.

### 5. High: Statistics latency grows with total history, not selected range

**Locations:** `server/src/events.rs:155–182`;
`server/migrations/0001_initial.sql:43–54`.

Each of five result queries repeats the all-history cumulative window before
applying the time range. A ten-event range still took approximately 971 ms at
100,000 historical events in the synthetic SQL test. The ordering index also
omits `ended_at`, requiring temporary ordering work.

**Fix:** use the range index to find candidate sessions, then compute complete
histories for those sessions; reuse that result across aggregates. For all-time
statistics, consider rebuildable per-session summaries. Add an appropriate
window-order index and verify the plan, but indexing alone will not remove five
recomputations. **Do not simply push the date predicate inside the cumulative
window:** that changes threshold-crossing/play-count semantics. Preserve
offline reordering and sessions spanning range boundaries.

### 6. Medium: Initial/stale-cursor library sync has no response bound

**Locations:** `server/src/library.rs:74–89`;
`server/src/playlists.rs:30–39`;
`lib/services/cache_database.dart:61–79`.

The server fetches all matching tracks and playlist IDs, then executes two extra
queries per changed playlist and retains the complete response. At the allowed
10,000 playlists, that can mean 20,000 additional queries. Large playlist entry
lists compound allocation/serialization costs. The client applies documents
serially, then reloads the complete cache.

**Fix:** batch playlist/entry retrieval first. Add bounded, revision-consistent
pagination for tracks, playlists, entries and tombstones; advance the durable
client cursor only after a complete consistent synchronization. Benchmark both
cold sync and small incremental updates on a large library.

### 7. Medium: Artwork cache fills become progressively more expensive

**Locations:** `lib/services/artwork_cache.dart:64–109,118–158`;
`lib/services/transfer_service.dart:637,652`.

All artwork network requests share one serial queue. A slow request delays
unrelated visible covers. Each successful store lists and stats the entire cache
and sorts entries, even when under budget: filling K covers entails roughly
K(K+1)/2 file-stat visits, plus repeated sorting. Download reconciliation awaits
artwork for each track before progressing to the next track.

**Fix:** retain bounded memory but use a small bounded fetch pool with visible
items prioritized; serialize only cache commits/eviction. Maintain a byte/entry
index and trim in batches. Keep optional artwork off the audio-download critical
path. Rebuild the index safely after crashes.

### 8. Medium: Offline event growth causes repeated full outbox decoding

**Locations:** `lib/core/app_controller.dart:170–173,374–392`;
`lib/services/cache_database.dart:37–47`.

Recording a listening checkpoint loads all event JSON to calculate a count.
Flushing loads the entire outbox before taking 500 entries, then loads the
remaining outbox again to count it. Across E events and fixed-size batches,
replay performs O(E² / 500) document processing rather than O(E).

**Fix:** use SQL `COUNT(*)` and an ordered SQL `LIMIT 500` query; maintain the
visible pending count incrementally where safe. Preserve acknowledgement-only
removal and idempotency. Exercise several days of offline listening in tests.

## Additional risks to include in profiling

- **Synchronous file checks in build paths:** artwork `path()` and track
  `downloadProgress()` call `existsSync()` (`lib/services/artwork_cache.dart:58–61`,
  `lib/core/app_controller.dart:405–408,423–424`). Render from cached availability;
  validate asynchronously at reconciliation/open/error boundaries.
- **Repeated queue copies / stale native updates:** `playback.queue` copies the
  list, including per-row QueuePanel access (`lib/core/playback_controller.dart:52`,
  `lib/ui/player.dart:781–790`). System controls serialize every snapshot without
  coalescing (`lib/services/system_media_controls.dart:119–134,200–239`). Use a
  stable queue snapshot/version and latest-state coalescing; a native backlog is
  conditional on bridge latency exceeding the notification rate, not measured.
- **Aggregate server memory/admission:** `Bytes` request extractors buffer bodies
  before upload/parser admission; the per-service concurrency limit is 128
  (`server/src/lib.rs:180,188,207–212`). 128 ten-MiB artwork bodies alone represent
  1.25 GiB, excluding decoding/response overhead. Tower's response-future permit
  does not bound the lifetime of streaming bodies. Use shared admission before
  body collection, byte budgets and separate lifetime-bound stream permits.
  This is a capacity risk, not observed RSS.
- **Long mutations under the global lock:** playlist replacement validates against
  the whole live library and inserts entries individually; event ingestion makes
  repeated validation queries for each event (`server/src/playlists.rs:115–154`,
  `server/src/events.rs:61–97`). Batch operations and validate only needed IDs.

## Recommended order and acceptance checks

1. **Low-risk client fixes:** capture ID sets/queue snapshots, index tracks, use
   bounded outbox queries, skip unchanged reconciliation writes. Require lookup
   work to scale approximately linearly and unchanged reconciliation to perform
   zero redundant file/download puts.
2. **Client state boundaries:** narrow progress subscriptions and coalesce cache
   reloads. A playback-position tick should not rebuild/re-sort the library;
   transfers should not create an unbounded reload/native-update backlog.
3. **Server critical sections:** instrument lock wait/hold time, then isolate
   uploads and GC. Measure playback-open p50/p95/p99 under simultaneous uploads,
   completion, stats and cleanup on realistic storage.
4. **Stats/sync/artwork:** implement measured query/cache changes, preserving
   protocol semantics. Re-run SQL plans and cold/incremental library scenarios.
5. **Device validation:** profile 1k/10k/50k-track libraries, 5k downloads, a
   1k-entry sorted playlist, long queues and cold cover grids on desktop and a
   representative Android device. Record build/raster p95/p99, missed frames,
   allocations/GC, peak RSS, startup time and time-to-first-audio. For a 60 Hz
   target, verify both UI and raster work fit the 16.7 ms frame budget.

Useful existing foundations: lazy collection builders; background-isolate SQLite;
streamed audio/downloads; resumable, verified transfers; retained artwork futures
and decode-size hints; bounded Argon2/parser workers; incremental library cursors;
and extensive functional regression tests. Keep those guarantees while removing
redundant work rather than replacing the architecture wholesale.
