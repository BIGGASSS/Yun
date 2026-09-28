# 韵 · Yun

A quiet Material 3 music player for a private, self-hosted library. One Flutter
client targets **Linux x64, macOS ARM64, Android ARM64, and Windows x64**, backed
by an account-isolated Rust server. Flutter is pinned with FVM.

## What is implemented

- Adaptive mobile/desktop library, albums/artists/search, queue, shuffle/repeat,
  keyboard shortcuts, light/dark/system appearance, metadata and artwork editing.
- Admin-created accounts, Argon2id passwords, rotating/revocable sessions,
  authenticated original-file streaming with byte-range seeking.
- In-app file selection and desktop drop, durable resumable uploads, embedded
  tags/artwork, per-account deduplication, quotas and validation.
- Versioned playlists with conflict detection and incremental library sync.
- Explicit track/album/playlist offline selections, resumable checksum-verified
  downloads, account-scoped artwork, byte progress and storage management.
- Monotonic listening-time segments, durable offline outbox, idempotent server
  ingestion, listening history and personal track/artist/album rankings.
- Android foreground audio, macOS media controls, Linux MPRIS and Windows SMTC
  adapters; platform configurations and native artifact workflows.
- Container/HTTPS deployment, stopped-server backup/restore, unit/widget tests,
  real Rust↔Dart TCP integration tests, CI and private evaluation packaging.

**This is an evaluation candidate, not a certified four-platform release.**
Linux compilation and null-output libmpv decoding have been exercised locally.
Hardware playback, Android/macOS/Windows runtime behavior, production signing,
TLS deployment and redistribution-license review require the acceptance gates in
[docs/VALIDATION.md](docs/VALIDATION.md). No transcoding, public signup, social
features, DRM, or stats.fm service integration is included.

## Develop

Install [FVM](https://fvm.app/), Rust (see `rust-toolchain.toml`), and the native
Flutter toolchain for your host. Never replace the exact `.fvmrc` version with a
floating channel for release builds.

```sh
fvm install --skip-pub-get
fvm flutter pub get
cargo build --locked --manifest-path server/Cargo.toml

# Create an account; password is prompted privately (minimum 12 bytes).
# Stop the server before running administrative commands.
server/target/debug/yun-server --data-dir ./yun-data create-user alice
server/target/debug/yun-server --data-dir ./yun-data serve --insecure-loopback

# In a second terminal:
fvm flutter run -d linux
```

In **Settings**, connect to `http://127.0.0.1:8080` and sign in. HTTP is permitted
only on loopback. Use an HTTPS server URL for remote clients. An attached Android
device can use `adb reverse tcp:8080 tcp:8080` for local development; do not enable
global cleartext or bypass certificate validation.

Native prerequisites and caveats: [Linux](linux/README.md),
[Android](android/README.md), [macOS](macos/README.md),
[Windows](windows/README.md). Linux needs libmpv at runtime and an unlocked Secret
Service keyring for credentials. The Windows SMTC bridge requires Rust; its Dart
bridge version is deliberately pinned to the matching native generator.

## Verify

```sh
cargo fmt --manifest-path server/Cargo.toml --check
cargo test --manifest-path server/Cargo.toml --locked
cargo clippy --manifest-path server/Cargo.toml --locked --all-targets --all-features -- -D warnings
# Real-client integration tests use server/target/debug/yun-server by default.
fvm dart format --output=none --set-exit-if-changed lib test
fvm flutter analyze
fvm flutter test
python3 scripts/api_smoke.py
python3 scripts/test-release-tooling.py
# Requires libmpv; real decoding/transport with null audio, not hardware proof:
RUN_NATIVE_PLAYBACK=1 fvm flutter test test/services/native_playback_test.dart
```

Set `YUN_SERVER_BINARY` to test a different prebuilt server. CI passes the built
server artifact to Flutter tests so integration tests cannot silently be skipped.
The native smoke is opt-in locally, and enabled in Linux CI.

## Offline and privacy semantics

Download a track, album or playlist explicitly. Playlist selections follow server
changes when connected; overlapping selections share a single copy. Originals are
not silently evicted. Artwork has a separate bounded 128 MiB per-account cache.
Selected uploads are first copied into account-private staging storage (up to
1 GiB per file by default); successful/cancelled jobs remove only those staged
copies, never your originals. Allow staging space in addition to downloads.
Transfers run while the app process is available and resume later; the app does
not promise OS-scheduled background transfers after process termination.

Already signed-in accounts can browse/play cached music despite expired tokens or
no network. Playlist/metadata edits require connectivity. Sign-out stops playback,
removes credentials and hides the account, but **retains its downloaded files and
pending history**; signing back into the same server/account unlocks them. This is
app-level isolation, not encryption/DRM against the device owner. Offline logout
cannot revoke a remote session until the server is reachable; use password reset
to revoke all sessions if needed.

Listening counts only active, non-buffering playback, not skipped seek distance.
History checkpoints approximately every ten seconds and at transitions; abrupt
process/power loss can lose the final uncommitted segment. One play is counted per
session after `min(30 seconds, half the track duration)` of listening (at least
1 ms). Stats retain partial listening and acknowledge event IDs before deleting
local outbox records. See [API semantics](docs/API.md) and
[server details](server/README.md) for date-range and clock behavior.

## Structure

```text
lib/ui/          Adaptive Material 3 screens and player
lib/core/        Account lifecycle, sync coordination, playback, listening tracker
lib/services/    HTTP/auth, Drift cache, transfers, artwork, native adapters
lib/models/      Shared typed client models
server/          Rust service, migrations, CLI and integration tests
android/ linux/ macos/ windows/   Native runners
test/            Client unit/widget and real-server integration tests
deploy/          Non-root server container, Caddy and Compose
scripts/         Smoke tests, backup/restore and packaging
docs/            API contract, operations, release and validation records
```

The small client uses an injectable `ChangeNotifier` façade and Flutter navigation
rather than introducing Riverpod/go_router before there is a routing requirement.
Drift uses explicit transactional SQL without code generation. Server statistics
are derived directly from immutable events rather than premature aggregate tables.

## Deploy and distribute

Follow [OPERATIONS.md](docs/OPERATIONS.md) for Caddy/Compose, account management,
monitoring and verified backup/restore. **Do not publish the HTTP origin port.**
The server is for authenticated personal uploads, not hostile public hosting; its
bounded metadata parser is not an OS sandbox.

[RELEASE.md](docs/RELEASE.md) describes native evaluation artifacts and installation.
Workflows retain artifacts inside the private repository, not public Releases.
macOS/Windows artifacts are unsigned for distribution; Android evaluation APKs
use debug signing, with an opt-in fail-closed release-signing workflow for an
operator-supplied keystore. Production signing/notarization and dependency license/source
obligations are explicit release gates. No open-source license is granted for
this private project; third-party dependencies retain their respective licenses.
