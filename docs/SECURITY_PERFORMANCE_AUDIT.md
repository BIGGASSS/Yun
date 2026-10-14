# Security, performance, and memory audit

## Scope and stopping point

Three source-review passes covered the first-party Flutter client, Rust server,
platform runners, local plugin modifications, deployment scripts, release tooling,
and workflows. Follow-up reviewers cross-checked the fixes and regression tests.
The final independent pass found no additional actionable defects in the reviewed
changes. This is not a claim that the application is vulnerability-free.

Generated code, unchanged third-party implementations (notably the bundled JSON
header), hardware behavior, production load, and exhaustive dependency analysis
were not audited line by line. No production data or credentials were used.

## Findings addressed

| Area | Finding | Remediation |
| --- | --- | --- |
| HTTP credentials | API and download transports followed redirects, including same-host redirects that can retain Authorization | Disable redirects per request for login, rotation, revocation, API calls, and both download transports; real TCP regressions cover default and injected clients |
| Resource routing | Track, playlist, and upload IDs were interpolated into some URLs | Shared component encoder rejects empty/dot IDs and escapes delimiters; regressions cover mutations, downloads, upload resume/chunks/completion/cancellation |
| Account isolation | Open menus, confirmations, metadata dialogs, and artwork pickers could apply an old account's selection after switching accounts | Capture the account identity and recheck it before actions and after asynchronous boundaries |
| Upload integrity | Concurrent imports using the same job ID raced on the same spool/rollback paths | Reserve import IDs synchronously and release them on success/failure; duplicate and retry regressions |
| Artwork memory | Picker materialized arbitrary-size files before checking the upload limit | Request a stream, reject oversized advertised lengths, and enforce the 10 MiB bound on actual bytes |
| Playback memory/CPU | Repeat-all shuffle retained and traversed a session-length history | Retain the latest max(1,000, collection size) source transitions with deque eviction; see [retention policy](PERFORMANCE_AUDIT.md#shuffle-previous-history-retention) |
| Playback correctness | A caller could mutate a queued collection while playback initialization awaited | Snapshot the collection at command submission |
| Update lifecycle | Late completions notified a disposed controller; reentrant listeners could start another check before coalescing was installed | Install the shared future before notification and guard disposal/completion |
| Linux tray memory | Timeout did not cancel D-Bus calls; polling could accumulate outstanding requests | Coalesce checks and retain at most one outstanding probe until it settles |
| Linux secure storage | Attribute keys used pointer equality instead of string equality | Use `g_str_equal` and prevent accidental copying of the owning table wrapper |
| Linux secure storage | Malformed method calls could hang without a reply or use wrong-type accessors; JSON exceptions leaked partially constructed maps | Always construct/respond once, validate types, and use scoped ownership during conversion |
| Linux secure storage | Reading a stored empty string returned null, conflating it with a missing key | Test presence separately from string content |
| Build integrity | Flutter SDK archives were extracted without checking the release manifest's digest | Fail on HTTP errors and verify SHA-256 before extraction, including portable `shasum` fallback |
| Server CLI | Oversized password input could silently accept a valid truncated prefix | Read a bounded sentinel byte and reject excess input before modifying credentials |
| Server auth | Extreme configured TTLs overflowed timestamp arithmetic | Saturate expiry additions in login and refresh |
| HTTP correctness | HEAD processed Range and could return 206/416 | Restrict byte-range processing to GET; preserve HEAD full-resource headers |
| Dependencies | Lockfile included yanked `yoke-derive` 0.8.3 | Update to 0.8.4 |

Detailed server reproductions and limitations are in
[server/SECURITY_AUDIT.md](../server/SECURITY_AUDIT.md). Vendored changes and
provenance are recorded in the secure-storage fork and Flutter action documents.
No visual layout changes were made.

## Dependency advisory triage

A fresh `cargo-audit` 0.22.2 scan of `server/Cargo.lock` used 1,314 RustSec
advisories and scanned 257 locked packages. The yanked version above was updated.
Two upstream reports remain, without suppressions added to the repository:

- **RUSTSEC-2023-0071 (`rsa` 0.9.10):** no fixed stable upgrade exists. It appears
  in the lockfile through SQLx's optional MySQL dependency but is **not in Yun's
  enabled dependency graph**, including all target platforms (`cargo tree
  --manifest-path server/Cargo.toml --target all -i rsa` prints no dependency).
  Yun enables SQLite only and does not perform RSA operations. The raw lockfile
  audit still exits nonzero; this is not an all-green advisory scan. Reassess if
  SQLx features change.
- **RUSTSEC-2024-0436 (`paste` 1.0.15):** unmaintained build-time procedural macro,
  pulled in by Lofty. This is a maintenance warning, not a reported runtime
  vulnerability. The current upstream Lofty release also depends on it; replacing
  the parser or privately patching its dependency solely to silence the warning
  was not justified. Track upstream maintenance.

Dart dependency resolution completed without an advisory warning. This does not
cover every bundled native binary or replace a software-composition/license audit.

## Verification

Local Linux results after the fixes:

- Rust: 52 tests; build, rustfmt, and all-target/all-feature Clippy with warnings
  denied; CLI/expiry regressions also tested in release mode.
- Flutter: 1,382 tests passed; 19 opt-in native tests skipped in the general run.
- Native libmpv/null-output playback: 18 passed; one public production-TLS probe
  skipped because its external endpoint was not configured.
- Flutter analysis and Dart formatting: clean.
- API smoke: 65 real TCP requests passed, including two-account isolation.
- Secure storage: 28 isolated private-bus tests and 3 native method-response tests
  passed, without contacting a host wallet.
- Android/audio-service JVM contracts: 59 passed.
- Release tooling: 4 tests; workflow policy: 11 tests; SDK digest success/failure,
  malformed/missing checksum, and portable fallback cases passed.
- Linux release build and tray-linkage validation passed during the audit.

CI additionally exercises the native build matrix and container backup/restore.
See the PR's checks for hosted results rather than treating local tests as proof
of four-platform runtime behavior.

## Remaining limitations

- Parser deadlines and admission limits are not an OS sandbox or hard RSS/CPU
  ceiling; hostile public hosting is outside the documented deployment model.
- Database history, devices, tombstones, and explicit user-selected collections
  can grow. Shuffle retention bounds session-driven growth, not library size.
- A permanently unanswered D-Bus probe fails closed; availability cannot recover
  until the request settles or the adapter is disposed/recreated.
- SDK integrity trusts the HTTPS release manifest and does not rehash existing
  runner caches.
- No physical-device profiling, fuzzing campaign, crash/power-loss campaign,
  production mixed-load benchmark, or local macOS/Windows runtime validation was
  performed. Slow-client occupancy still requires deployment/proxy timeouts.
