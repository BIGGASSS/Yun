# Validation status and acceptance checklist

This document separates implemented automation from executed evidence. A green
compiler/unit-test run does not certify audio playback, background behavior,
secure storage, recovery, signing, or third-party redistribution rights.

## KDE keyring follow-up

The Linux-only secure-storage fork now supports `org.kde.secretservicecompat`
when `org.freedesktop.secrets` is neither running nor activatable. Local validation:
27 isolated real-libsecret/private-D-Bus tests passed, including the plugin's
exact registration sequence, read/write/delete, provider discovery/activation,
standard-provider preference, account isolation, locked/failed providers, and
ambiguous-write handling. The suite passed against libsecret 0.20.5, 0.21.4, and
0.21.8.2. Flutter analysis, all 115 Flutter tests, and the Linux release build also
passed. CI now runs these native tests on Ubuntu 22.04 and 24.04.

No real user wallet was opened or modified during these tests; the mocks run on
private buses with no host activation directories. Actual desktop unlock prompts
remain a manual acceptance check. See the fork's
[provenance and compatibility notes](../packages/flutter_secure_storage_linux/YUN_FORK.md).
The historical hosted evidence below applies to the explicitly identified earlier
code commit, not this follow-up.

## Hosted evidence — 2026-09-28

**All seven CI jobs passed** for code commit
[`bc3a93d`](https://github.com/BIGGASSS/Yun/commit/bc3a93d):
[CI run 36472384273](https://github.com/BIGGASSS/Yun/actions/runs/36472384273).
Subsequent evidence-only documentation updates do not change that tested code.

- Rust: format, 10 tests, strict Clippy, release build.
- Flutter: format, analysis, 115 tests including actual Rust↔Dart TCP regressions,
  separate real libmpv/null-output test, and the 65-request TCP API smoke.
- Deployment: image build, Compose validation, non-root container health/locking,
  real stopped-server backup and restore, Caddy configuration, and host tooling tests.
- Native builds and packaging: Linux x64 tar archive, macOS ARM64 DMG,
  Windows x64 ZIP, and Android ARM64 debug-signed APK.

Five private artifacts are attached to that run: `yun-server-linux-x64`,
`yun-linux-x64`, `yun-macos-arm64-unsigned`, `yun-windows-x64-unsigned`, and
`yun-android-arm64-debug-signed`. Client artifacts include checksums and dependency
inventories. Artifacts expire after 14 days; the workflows can reproduce them.

This is compilation/automated evidence, **not** audible-device, native system-
controls, production-signing, public TLS, or license-review certification.

## Integrated local evidence — 2026-09-28

Executed against the integrated implementation on Linux x64 (Flutter 3.47.5,
Dart 3.13.4, Rust 1.98.1):

| Check | Result |
| --- | --- |
| Dart formatting and `fvm flutter analyze` | Clean |
| `fvm flutter test` | 115 passed; native smoke skipped here and run separately below |
| Real Rust↔Dart integration/regression tests | Included in the 115; actual disposable TCP servers |
| `cargo fmt`, `cargo test`, strict Clippy | Clean; 10 tests passed |
| Rust release build | Passed |
| Python API smoke against release server | 65 real TCP requests passed |
| Linux Flutter release bundle | Built successfully |
| Real Linux libmpv null-output smoke | Passed: decode/seek/pause/completion/listening accounting |
| Deployment/release host tests | 3 passed |
| Android signing control-flow tests (doubles, not actual signing) | 6 passed |
| actionlint / ShellCheck | Passed |

The host lacks an installed libmpv. For the native smoke only, compatible native
libraries were extracted to `/tmp/yun-native-mpv` and exposed through
`LIBMPV_PATH` and `LD_LIBRARY_PATH`. This exercised the real decoder with **null
audio**, not audible output or OS controls. Users must install their distribution's
libmpv; temporary test libraries are not shipped in the repository or release.

## Evidence for the deployment/release tooling change

Executed locally in this Linux workspace:

- Bash syntax checks and ShellCheck 0.10.0 for the new shell scripts.
- GitHub Actions workflow validation with actionlint 1.7.7.
- YAML parsing for workflows, the local Flutter setup action, and Compose;
  Compose 2.39.4 `config --quiet` and Caddy 2.10.2 `validate` both passed locally.
- Host-only `python3 scripts/test-release-tooling.py`: user-local Linux installer
  fresh install/upgrade (including paths with spaces and full asset preservation),
  archive checksums, and rejection of unsafe/non-backup restore archives (3 tests).
- Host-only `python3 scripts/release/test-android-signing.py` (6 tests): explicit
  debug/release mode selection; each missing secret and invalid base64 fail before
  build; temporary keystore/directory permissions and cleanup on success/failure;
  build/signature-verification errors never package an APK. Flutter and `apksigner`
  are **test doubles**: this verifies control flow, not actual Gradle/signing.

**Not executed locally:** Docker runtime or non-Linux packaging; these were
subsequently executed by the hosted CI run recorded above. **Still not executed:**
public DNS/ACME issuance/renewal, production signing/notarization, real-device audio,
native hardware controls, and redistribution-license review.

## Automated checks to run on the final integrated tree

```sh
fvm install --skip-pub-get
fvm flutter pub get
fvm dart format --output=none --set-exit-if-changed lib test
fvm flutter analyze
cargo fmt --manifest-path server/Cargo.toml --check
cargo test --manifest-path server/Cargo.toml --locked
cargo clippy --manifest-path server/Cargo.toml --locked --all-targets --all-features -- -D warnings
cargo build --manifest-path server/Cargo.toml --release --locked
YUN_SERVER_BINARY="$PWD/server/target/release/yun-server" fvm flutter test
RUN_NATIVE_PLAYBACK=1 fvm flutter test test/services/native_playback_test.dart
python3 scripts/api_smoke.py --binary server/target/release/yun-server
python3 scripts/test-release-tooling.py
python3 scripts/release/test-android-signing.py
for script in scripts/*.sh scripts/release/*.sh; do bash -n "$script"; done
shellcheck scripts/*.sh scripts/release/*.sh
actionlint
YUN_DOMAIN=music.example.com ACME_EMAIL=ci@example.com docker compose -f deploy/compose.yaml config --quiet
docker build -f deploy/Dockerfile -t yun-server:ci server
bash scripts/test-container.sh
```

`test-container.sh` creates isolated disposable named volumes, creates a real
account, starts the non-root server, checks health/UID, verifies the live-process
lock rejects backup, stops it, invokes the CLI backup, starts the snapshot as a
restored data directory, and validates the Caddyfile. It does **not** provision a
public certificate, test clients, or prove semantic restoration of a full library.
The CI also builds Linux x64, macOS ARM64, Windows x64, and Android ARM64 artifacts
using the exact `.fvmrc` version. CI Android artifacts are explicitly debug-signed;
manual release dispatch can opt into protected-environment Android release signing.
Artifacts contain inventories, not a license audit. The manual candidate workflow
builds the actual server before Flutter integration tests, rather than allowing
those tests to skip for lack of a binary.

## Required before accepting a private candidate

Record commit, workflow run, artifact checksum, OS/device model, test identity,
result, and reproducible failure details. Use synthetic/private test music only;
do not publish credentials, listening history, personal library files, or tokens.

### Every client platform: Linux, macOS ARM64, Windows x64, Android ARM64

- [ ] Clean installation, launch, upgrade, and uninstallation; no missing native
  DLL/framework/shared-library errors. Verify the claimed CPU architecture.
- [ ] Actual audible playback of representative MP3, AAC/ADTS, M4A/MP4, FLAC,
  Vorbis, Opus, WAV, and AIFF files. Distinguish server metadata acceptance from
  client decoder support; verify embedded and manually changed artwork.
- [ ] Play/pause/seek/next/previous, queue/repeat/shuffle, volume, end-of-track,
  rapid command changes, gap/error recovery, and correct displayed metadata.
- [ ] Media keys/system transport controls and lock-screen controls. Linux MPRIS,
  macOS Now Playing, Windows SMTC, and Android notification controls need native
  runtime observation; Dart mocks cannot establish those behaviors.
- [ ] Background/minimized/locked playback, resume after interruption, headphone/
  Bluetooth transitions, Android audio focus and battery/background constraints.
- [ ] Secure storage on the actual OS: Linux Secret Service/keyring, macOS Keychain,
  Windows protected storage, Android Keystore; logout/account switching remove
  inappropriate credentials/cache and never expose another account's resources.
- [ ] TLS/login/token refresh/revocation, expired sessions, invalid certificates,
  offline restart/cache, reconnect, network loss and resumed chunk uploads.
- [ ] Playlist conflicts/tombstones, multi-device sync, and offline event retry
  idempotence; statistics reflect listening rather than download time.
- [ ] UI scaling/window sizes, keyboard/focus/navigation, Android lifecycle,
  accessibility labels/contrast, and failure states on slow/no-network devices.

### Server and deployment

- [ ] Correct ownership/modes on newly initialized and restored volumes;
  both long-running containers are non-root and origin 8080 has no host mapping.
- [ ] Only authorized proxy-network peers can reach the HTTP origin; HTTPS redirect,
  certificate trust/renewal, HSTS, and authentication/range headers work end to end.
- [ ] Edge per-IP authentication limits, connection/body/time limits, and firewall
  rules are configured/tested before public exposure. Stock Caddy alone is not
  represented as providing all these controls.
- [ ] Account isolation, refresh races/revocation, ranged streaming, quota checks,
  partial upload recovery, process restart, and malformed/oversized requests pass
  against the actual proxy/origin deployment, not only in-process tests.
- [ ] Run the operational backup script on representative data; restore to a new
  volume/host using the restore script, verify actual music, artwork, playlists,
  statistics, account isolation, and pending upload offsets. Measure recovery time.
- [ ] Exercise failed backup, failed restore, full disk, process crash, service
  restart, forward migration and old-image/old-backup rollback procedures.
- [ ] Off-machine encryption/retention, available disk/inodes, certificate expiry,
  health/restart monitoring, and protection of operational secrets are in place.

### Packaging and distribution

- [x] All target workflows pass on the **same code commit**, `bc3a93d` (linked above).
- [ ] Inspect dependency inventories and full archives and complete the license
  review before distributing them; build success alone is not this review.
- [ ] Verify Linux installer/desktop launch, macOS DMG install/Gatekeeper behavior,
  Windows portable launch/SMTC, and Android ARM64 sideload on real target hardware.
- [ ] Configure and independently review the `release-signing` environment's
  reviewers and branch restrictions **before** storing keys or approving a job.
  Confirm debug/CI jobs cannot access signing secrets, and approve only reviewed
  source/dependency/workflow changes (build scripts can access signing credentials).
- [ ] Run the opt-in Android `release-signed` workflow with the real approved key;
  verify its certificate SHA-256 fingerprint independently with `apksigner`, APK
  release mode/ARM64, application ID/version, install, and upgrade from the previous
  release. Missing/wrong secrets must fail, never fall back to debug signing.
  Confirm no key/password/property files appear in artifacts or logs. Host mocks
  do not prove real Gradle configuration or APK signatures.
- [ ] Complete Windows Authenticode and macOS Developer ID/notarization operator
  procedures in [RELEASE.md](RELEASE.md), recording signer identity, timestamp,
  entitlements, notarization Accepted status/staple validation, and clean-machine
  trust checks. Recompute hashes after signing/stapling. Their workflow artifacts
  remain unsigned for distribution; Android defaults to debug-mode/debug-key-signed.
  No executed production signing/notarization is claimed by this documentation.
- [ ] Complete the native mpv/FFmpeg and other dependency-license/notices/source
  obligations in [RELEASE.md](RELEASE.md) before redistribution.

All unchecked runtime, recovery, signing, and licensing gates are **pending**.
