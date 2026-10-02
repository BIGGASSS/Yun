# 韵 · Yun

A quiet Material 3 music player for a private, self-hosted library. One Flutter
client targets **Linux x64, macOS ARM64, Android ARM64, and Windows x64**, backed
by an account-isolated Rust server. Flutter is pinned with FVM.

## Screenshots

Rendered from the Flutter UI with a demo library and original sample artwork.

| Desktop · Library & queue (dark) | Desktop · Albums (light) |
| --- | --- |
| ![Yun desktop library with playback controls and an open queue in dark mode](docs/screenshots/desktop-library-dark.png) | ![Yun desktop album grid in light mode](docs/screenshots/desktop-albums-light.png) |

| Mobile · Library | Mobile · Now playing |
| --- | --- |
| <img src="docs/screenshots/mobile-library-dark.png" alt="Yun mobile library in dark mode with downloaded tracks and a mini player" width="260"> | <img src="docs/screenshots/mobile-now-playing-dark.png" alt="Yun mobile now playing screen with album artwork and playback controls" width="260"> |

## What is implemented

- Adaptive mobile/desktop library, albums/artists/search, queue, shuffle/repeat,
  keyboard shortcuts, light/dark/system appearance, metadata and artwork editing.
- Desktop app-volume slider and mute, including compact windows and now playing;
  volume/mute, shuffle, and repeat survive app restarts. Android retains system
  volume and remembers shuffle/repeat.
- Branded desktop tray: left-click restores Yun, right-click opens Show/Quit.
  **Settings → Window behavior** remembers close to quit (default) or minimize
  to tray without stopping music.
  Android/iOS behavior is unchanged; an unavailable tray never hides the window.
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
  real Rust↔Dart TCP integration tests, CI and evaluation packaging.

**This is an evaluation candidate, not a certified four-platform release.**
[Hosted CI](https://github.com/BIGGASSS/Yun/actions/workflows/ci.yml) builds all
four native packages and runs Flutter/Rust tests, TCP integration, null-output
libmpv playback, container backup/restore, and isolated keyring tests. Choose a
successful run for the version you want; its publicly accessible evaluation artifacts have
14-day retention. See [validation evidence](docs/VALIDATION.md) for the tested
scope and version-specific results.

Hardware playback, Android/macOS/Windows runtime behavior, production signing,
public TLS deployment and redistribution-license review still require the gates in
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
global cleartext or bypass certificate validation. Remote audio is fetched by
Dart with certificate verification and streamed to the decoder over a private
loopback relay; account tokens never reach the native decoder. Audio redirects
are rejected: use the final server URL. See [playback TLS](docs/PLAYBACK_TLS.md).

Native prerequisites and caveats: [Linux](linux/README.md),
[Android](android/README.md), [macOS](macos/README.md),
[Windows](windows/README.md). Linux needs libmpv at runtime and an unlocked Secret
Service keyring for credentials. KWallet's `org.kde.secretservicecompat` endpoint
is supported when the standard `org.freedesktop.secrets` name is absent—no separate
GNOME Keyring installation is required. See [Linux setup](linux/README.md).
The Windows SMTC bridge requires Rust; its Dart
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
# Android-free registration/cancellation contracts (JDK 17+):
bash android/test-audio-focus.sh
bash packages/audio_service/android/test-connection.sh
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
not silently evicted. Artwork has a separate bounded 1 GiB per-account cache.
Mounted artwork consumers protect resident images from speculative eviction. If
artwork cannot fit, placeholders are used instead of repeatedly downloading and
evicting it; a new foreground demand or revision can retry capacity misses.
Selected uploads are first copied into account-private staging storage (up to
1 GiB per file by default); successful/cancelled jobs remove only those staged
copies, never your originals. Allow staging space in addition to downloads.
Transfers run while the app process is available and resume later; the app does
not promise OS-scheduled background transfers after process termination.

Already signed-in accounts can browse/play cached music despite expired tokens or
no network. Completed downloads always play from the device, including repeated
Play attempts and failed or interrupted repairs. A missing, unreadable, or
undecodable local copy shows a playback error instead of silently streaming.
Choose **Redownload** in the player or beside a failed download to explicitly
replace it when connected; playback does not restart automatically. Decoder
errors alone never delete downloaded bytes. Tracks whose first download is only
queued can still stream normally. Playlist/metadata edits require connectivity. Sign-out stops playback,
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

[RELEASE.md](docs/RELEASE.md) describes releases, evaluation artifacts and installation.
Push a `v*` tag (for example `v1.0.0`) to validate, build all clients and the Linux
server, and publish a GitHub Release with checksums. Tag releases use the configured
Android release signing; macOS/Windows artifacts remain unsigned. CI and the separate
**Release candidates** workflow retain publicly accessible workflow artifacts only; candidates default to debug-signed
Android APKs with opt-in fail-closed release signing. Production signing/notarization and dependency license/source
obligations are explicit release gates.

## License

Yun's first-party material is licensed under the [MIT License](LICENSE),
copyright © 2026 BIGGASSS. Third-party components are excluded from this grant
and retain their own licenses and notices, including the vendored
[Linux secure-storage plugin's BSD-3-Clause license](packages/flutter_secure_storage_linux/LICENSE),
[nlohmann/json notices and licenses](packages/flutter_secure_storage_linux/linux/include/json.NOTICES.md),
and [Flutter SDK action's MIT license](.github/actions/flutter-sdk/LICENSE)
([upstream provenance](.github/actions/flutter-sdk/UPSTREAM.md)).

This source-license choice does not complete the binary redistribution review.
The actual bundled dependencies (including mpv/FFmpeg), notices, and any source
obligations still require the [release license gates](docs/RELEASE.md#dependencylicense-redistribution-gate).

### Verify downloaded audio

In **Downloads**, choose **Verify downloads** to check existing cached audio
against its SHA-256 checksum, including older downloads without Activity entries.
The local-only scan works offline, runs hashing in a background isolate, and shows
byte progress, checked-file counts and an estimated time remaining once measured
throughput is available. Cancel stops the scan; checks already completed remain
applied, and leaving Downloads does not interrupt it.

Startup, ordinary sync and retry passes check recorded identity, file existence
and size without rehashing the whole library. New and resumed downloads still
pass full checksum verification before becoming playable. Same-size damage to
existing files is therefore detected when you explicitly run verification.

Results distinguish valid, invalid and skipped files. Invalid audio is removed
from playable storage; offline selections are retained. Choose **Redownload
corrupted files** when connected to repair those files through the normal download
queue. Verification itself does not redownload anything, and unrepaired failures
remain held across restarts. Repair preserves existing selections and adds a track
selection only for a damaged file that had no remaining selection. Unreadable or
concurrently changed files are skipped so they can be checked again safely.
