# Rust server security/correctness audit

## Scope

Reviewed all first-party Rust sources in `src/` and `tests/`, the SQLite migrations,
router configuration, and dependency declarations. Context included the API
contract, server README, and existing performance-audit notes. Focus: account
isolation, token handling, filesystem publication/cancellation, quota and body
bounds, parser admission, pagination, SQL aggregation, and administrative commands.

No new high-severity remotely exploitable defect was confirmed. This is a source
review with regression testing, not a proof of security. The subsequent
[repository-wide audit](../docs/SECURITY_PERFORMANCE_AUDIT.md) includes dependency
advisory triage.

## Confirmed findings and fixes

### 1. CLI password input silently accepted a truncated prefix (low)

- **Path/function:** `src/main.rs`, `password`.
- **Reproduction:** pipe 1024 password bytes, CRLF, then more bytes to
  `create-user --password-stdin`. The 1026-byte read cap discarded the suffix;
  trimming CRLF made the truncated prefix pass password validation. The same
  reader is used by `reset-password`.
- **Impact:** local administrative automation could install a password different
  from its supplied input. This is not a remote authentication bypass.
- **Fix:** read one sentinel byte beyond password-plus-CRLF capacity and reject
  excess input before trimming or changing credentials. Memory remains bounded.
- **Regression:** `tests/security_regressions.rs`:
  `password_stdin_rejects_a_valid_prefix_followed_by_truncated_input` invokes the
  actual CLI, verifies rejection creates no account, then accepts the exact
  maximum plus CRLF. Failed on the old code; passes after the fix.

### 2. Token expiry arithmetic overflowed accepted configuration (low)

- **Path/functions:** `src/auth.rs`, `login`, `refresh`.
- **Reproduction:** public `Config` accepts positive TTLs including `i64::MAX`.
  Adding the current timestamp panicked with overflow checks and wrapped to a
  negative expiry in release builds.
- **Impact:** login/refresh failed or issued already-expired tokens under extreme
  application-supplied configuration. Network clients cannot choose these TTLs;
  ordinary defaults are unaffected.
- **Fix:** saturating addition for both access and refresh expiry, on both login
  and rotation. Unrepresentably distant expiry becomes `i64::MAX`.
- **Regression:** `maximum_token_ttls_never_overflow_or_issue_expired_tokens` in
  `tests/security_regressions.rs` exercises login, refresh, and authenticated
  library access. Failed on the old code; passes in debug and release builds.

### 3. HEAD incorrectly processed byte ranges (low, protocol correctness)

- **Path/function:** `src/media.rs`, `audio`.
- **Reproduction:** HEAD with `Range: bytes=0-9` returned 206 and length 10;
  invalid/unsatisfiable ranges returned 416. RFC 9110 section 14.2 defines Range
  handling for GET, not HEAD.
- **Fix:** only GET applies Range/If-Range. HEAD reports 200, the full resource
  length, and unchanged validators without a response body.
- **Regression:** extended
  `durable_resumable_upload_dedup_audio_ranges_and_isolation` in `tests/api.rs`
  with valid, malformed, and unsatisfiable HEAD ranges. Failed on the old code;
  passes after the fix alongside the existing GET/range/isolation assertions.

The README also corrects stale claims about absent pagination, global upload
locking, and the integration-test count, and documents HEAD range behavior.

## Re-audit and validation

Re-read the final changed code and tests. Checked all four token-expiry additions,
raw byte limits and maximum-length password acceptance, GET behavior preservation,
HEAD body/headers, and that no lock, resource-permit, SQL, or publication lifetime
was changed. No further defect was found in those changes.

Passed from `server/`:

- `cargo fmt --check`
- `cargo test --locked` — 52 tests passed
- `cargo clippy --locked --all-targets --all-features -- -D warnings`
- `cargo test --locked --release --test security_regressions` — 2 tests passed

Each new regression was run against the unfixed behavior and failed as described.
No migrations changed. The repository-wide follow-up updated yanked
`yoke-derive` 0.8.3 to 0.8.4 and reran the debug tests, build, and Clippy.

## Residual risks / limits

- Media parsers remain in-process, with cooperative deadlines and allocation/read
  limits, not an OS sandbox or hard CPU/RSS ceiling. Hostile public uploads need
  resource-isolated workers and deployment-level limits.
- Admission bounds requests, buffered response ownership, and streams, not socket
  duration or all transient allocations. Slow readers can occupy slots; enforce
  reverse-proxy connection/write/idle limits. In-memory authentication counters
  reset on restart and do not replace per-IP edge limits.
- Statistics over large complete histories still require substantial SQLite work.
  Events, devices, and tombstones can grow indefinitely; history/metadata are not
  charged to the audio quota. Monitor database size and query latency.
- Backup and bitrate maintenance are offline APIs. The CLI process lock prevents
  another process serving the same directory; embedders must honor the offline
  requirement rather than invoke maintenance beside active request handlers.
- The repository-wide follow-up ran a fresh RustSec scan; see its advisory
  triage for disabled SQLx/MySQL's RSA dependency and Lofty's unmaintained
  build-time `paste` dependency. No parser fuzzing, production load/RSS benchmark,
  or crash/power-loss fault campaign was performed. Existing cancellation,
  admission, query-plan, migration, and filesystem integration regressions passed.
