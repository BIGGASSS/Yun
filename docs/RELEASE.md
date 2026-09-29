# Releases and private candidates

## Scope and provenance

Pushing a `v*` tag triggers **Release** (`.github/workflows/tag-release.yml`),
validates the source, builds all four
clients and the Linux server, and publishes their archives/APK plus `SHA256SUMS`
to a GitHub Release with generated release notes. Android uses the configured
release keystore (no debug fallback); macOS and Windows remain unsigned. All
builds must succeed before publication. Releases follow repository visibility;
review the acceptance and license gates below before pushing a release tag.

CI and the separate **Private release candidates** workflow
(`.github/workflows/release.yml`) upload workflow artifacts only (14-day retention).
They do not publish a GitHub Release, packages, or container images. An artifact
is **not** evidence of a completed hardware, security, signing, or license review.

- `.fvmrc` is the Flutter version source of truth: currently **3.47.5**.
- `.github/actions/flutter/action.yml` first bootstraps that exact Flutter/Dart
  version, then activates FVM **4.3.1** with Dart and runs `fvm install`. Every
  Flutter analyze/test/build subsequently uses FVM, not a floating runner SDK.
- Rust is pinned to **1.98.1**, including Windows (needed by `smtc_windows`/
  Cargokit native builds), server CI, and the Docker build stage.
- Commit the reviewed `pubspec.lock` and `server/Cargo.lock`. The workflows run
  `flutter pub get`, not a dependency upgrade. Check any resolution changes when
  editing `pubspec.yaml`; Rust builds use `--locked`.
- Build names/numbers come from `pubspec.yaml`. Record the source commit, workflow
  run, lockfiles, tool versions, and checksums. Runner/base OS and native dependency
  downloads are not fully hermetic; these scripts do not promise reproducible bytes.

## Tag releases and manual candidate builds

`CI` runs Flutter analyze/test; Rust fmt/test/clippy (`-D warnings`) and release
build; shell lint, Docker/Caddy configuration and container smoke checks; and all
four native client builds via `native-builds.yml`. Ubuntu installs GTK3, libmpv,
libsecret, Ayatana AppIndicator, clang, CMake, Ninja, pkg-config, and liblzma
development dependencies.
macOS uses the Apple Silicon `macos-15` runner (asserts arm64); Windows uses x64
MSVC on `windows-2022`; Android uses Java 17 plus the Android SDK.

To publish a release, update `pubspec.yaml`'s version/build number, commit the
reviewed changes, then push a tag such as:

```sh
git tag v1.0.0
git push origin v1.0.0
```

Tags do not override the version in `pubspec.yaml`. Allow `v*` tags in the
`release-signing` environment's deployment rules and approve its job if required.
Missing signing secrets or a failed validation/build prevents publication.

To make an artifact-only candidate, select **Actions → Private release candidates → Run
workflow**, choosing the reviewed branch/commit and `android_signing` mode
(default `debug-signed`; opt-in `release-signed`). Validation gates client/server
packaging, including Flutter tests against a freshly built actual server binary.
Download the per-target artifacts from that workflow run; manual dispatch does
not publish a GitHub Release. Check `SHA256SUMS` against the contained archives, e.g.
`sha256sum -c SHA256SUMS` (Linux) or `shasum -a 256 -c SHA256SUMS` (macOS).
On Windows use `Get-FileHash -Algorithm SHA256 <archive>` and compare explicitly.
Unsigned checksums catch corruption, not an attacker replacing both files.

| Artifact | Contents and current signing status |
| --- | --- |
| `yun-linux-x64` | Release-mode complete Flutter bundle in `yun-linux-x64.tar.gz`, installer, `.desktop`, icon, dependency inventory and review warning |
| `yun-macos-arm64-unsigned` | ARM64 release app in a drag-to-Applications DMG; **no Developer ID signing/notarization**, at most Flutter's ad-hoc signatures |
| `yun-windows-x64-unsigned` | Complete release bundle ZIP; **no Authenticode signing**, portable executable with adjacent DLLs/data |
| `yun-android-arm64-debug-signed` | Default: **debug-mode, debug-key-signed** ARM64 APK, not a production/Play release |
| `yun-android-arm64-release-signed` | Tag releases or manual opt-in: release-mode ARM64 APK signed with the operator's keystore; signature verified with `apksigner`, still subject to acceptance/license gates |
| `yun-server-linux-x64` | Locked Rust server release binary (CI), or tar.gz with server operations docs and Cargo dependency inventory (release/candidate workflows) |

Android release signing runs automatically for tag releases and is opt-in for
manual candidates; configuration alone is not evidence that a signed build has
been executed or accepted. Windows Authenticode and macOS Developer
ID signing/notarization remain operator-only procedures below; their workflow
artifacts remain explicitly unsigned. Play App Signing/AAB publication is not
implemented. Never commit signing keys, passwords, or notarization credentials.

## Android release signing gate

Before running `release-signed`:

1. Create the GitHub environment **`release-signing`**, restrict it to reviewed
   release branches/tags, require independent reviewers, and prevent self-approval
   where available. Configure these controls **before** the first run: naming an
   environment in YAML does not automatically protect it. If your GitHub plan
   cannot enforce the required approval rules, do not enable hosted signing.
2. Store these four secrets on that environment (preferred). Explicit repository/
   organization secret forwarding is also supported, but lacks environment-only
   secret isolation. CI uses `native-evaluation`, never the release environment.

   | Secret | Value |
   | --- | --- |
   | `ANDROID_KEYSTORE_BASE64` | Base64 of the operator-controlled JKS/PKCS12 signing keystore (not the debug keystore) |
   | `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
   | `ANDROID_KEY_ALIAS` | Private-key entry alias |
   | `ANDROID_KEY_PASSWORD` | Private-key password |

   Base64 is encoding, **not encryption**. To upload an existing keystore without
   printing it or writing a base64 file, on a trusted operator machine with `gh`
   authenticated to the intended private repository:

   ```sh
   set +x
   base64 < /secure/private/yun-release.jks | gh secret set ANDROID_KEYSTORE_BASE64 --env release-signing
   gh secret set ANDROID_KEYSTORE_PASSWORD --env release-signing
   gh secret set ANDROID_KEY_ALIAS --env release-signing
   gh secret set ANDROID_KEY_PASSWORD --env release-signing
   ```

   The last three commands prompt for values. Do not put secrets in shell history,
   command arguments, logs, repository files, or shared temporary storage. Keep an
   encrypted offline keystore backup and independently record its certificate
   SHA-256 fingerprint; future APK updates require the same key. Check application
   ID, version code, certificate expiry, and key ownership before approval.
3. Push a reviewed `v*` tag, or run **Private release candidates** with `release-signed`.
   Inspect the exact source commit and workflow/dependency changes, and approve
   the environment job. Only manual dispatch or a `v*` tag push may request
   release signing. Do not approve untrusted code: Gradle/plugins/build scripts
   can access the process environment and key.
4. `scripts/release/build-android.sh` fails on absent secrets, invalid base64,
   Gradle signing/build errors, or failed `apksigner verify`; there is **no debug
   fallback**. It uses an owner-only temporary directory on the ephemeral runner,
   a mode-0600 keystore, masked step-scoped environment values (not `GITHUB_ENV` or
   `key.properties`), and an exit/signal cleanup trap. Only `dist/` is uploaded;
   keys are never placed there. Hard termination cannot guarantee trap execution:
   use disposable hosted runners, not persistent/shared signing workers.
5. Download `yun-android-arm64-release-signed`, check checksums, and independently
   run the Android SDK command below. Compare its signer SHA-256 fingerprint to
   the approved certificate, not merely a fingerprint from the same workflow log.

   ```sh
   "$ANDROID_SDK_ROOT/build-tools/<installed-version>/apksigner" verify --verbose --print-certs yun-android-arm64-release-signed.apk
   adb install -r yun-android-arm64-release-signed.apk
   ```

   Test fresh install and upgrade from the previous approved release. A debug-key
   install cannot normally be upgraded with a release key; preserve data before
   uninstalling. Signing does not establish Play readiness, license compliance,
   runtime correctness, or that the supplied keystore was an appropriate release
   identity. Local `flutter build apk --release` without explicit signing variables
   is unsigned, never silently debug-signed. For local signing use the same script
   with the four secrets securely injected into its environment.

## Windows Authenticode: secure operator procedure (not automated)

Use an isolated trusted Windows signing workstation and Windows SDK `signtool`.
Obtain a valid code-signing identity; provision its private key through the issuing
CA's approved hardware token/HSM or protected certificate-store process. Do not
export an unencrypted PFX or pass its password using `signtool /p`. The example
uses an already provisioned **CurrentUser\\My** certificate; a hardware provider
may prompt for authorization. Certificate thumbprints are public identifiers.

Extract the verified unsigned ZIP to a clean private staging directory. Inventory
all PE files; preserve third-party signatures and follow their redistribution
terms. The commands sign Yun's executable, **not a claim that all bundled DLLs
are publisher-signed**. Sign additional first-party PE binaries only after review.
From that staging directory, with `Yun/` containing the full bundle:

```powershell
$ErrorActionPreference = 'Stop'
$Thumbprint = Read-Host 'Approved code-signing certificate SHA-1 thumbprint'
signtool sign /s My /sha1 $Thumbprint /fd SHA256 /tr https://timestamp.digicert.com /td SHA256 Yun\yun.exe
if ($LASTEXITCODE -ne 0) { throw 'Signing failed' }
signtool verify /pa /all /v Yun\yun.exe
if ($LASTEXITCODE -ne 0) { throw 'Signature verification failed' }
Get-AuthenticodeSignature Yun\yun.exe | Format-List Status,SignerCertificate,TimeStamperCertificate
# Compare publisher/certificate to the independently approved identity.
Add-Content Yun\BUILD.txt 'Operator Authenticode signing applied; retain certificate/timestamp evidence separately.'
New-Item -ItemType Directory -Path dist -Force | Out-Null
Compress-Archive -Path Yun -DestinationPath dist/yun-windows-x64-authenticode.zip -Force
Get-FileHash -Algorithm SHA256 dist/yun-windows-x64-authenticode.zip
```

Use the CA-approved RFC3161 timestamp service if different. Verify on a clean
Windows machine, including timestamp/certificate chain and SmartScreen behavior;
signing does not guarantee reputation or remove prompts. Preserve signed ZIP
hashes and verification evidence privately; never relabel the original unsigned
workflow artifact as signed.

## macOS Developer ID + notarization: secure operator procedure (not automated)

Requires a paid Apple developer team, **Developer ID Application** certificate with
private key, and notarization authorization (e.g. Apple ID app-specific password).
On a trusted Mac, provision the signing identity using Keychain Access or your
organization's secure signing service. Do not put `.p12` passwords in `security
import -P` arguments. Use a dedicated locked keychain/signing account, not a shared
runner. `security find-identity -v -p codesigning` lists public identity identifiers.
Store notarization credentials interactively in Keychain, not scripts/history:

```sh
xcrun notarytool store-credentials yun-notary
```

Work from the reviewed source commit with a freshly built ARM64 release app (or
an intact app copied from the verified DMG). First review
`macos/Runner/Release.entitlements`: sandbox/network/file access, keychain groups,
team/bundle IDs and all helpers must match the release identity. Do not blindly add
disable-library-validation or debug/get-task-allow entitlements to pass signing.
Inventory nested frameworks/dylibs/helper apps and produce a reviewed
`sign-order.txt`: one path **relative to the app** per line, deepest nested code
first, containing every nested code object that needs re-signing; exclude the
outer app. Helper apps requiring their own entitlements must be signed separately
with reviewed entitlements before their enclosing bundle. Do not use `--deep` to
sign: it is not a substitute for this inside-out review.

The following commands assume the inventory and entitlements review is complete,
no helper requires separate entitlements in this loop, `dist/` contains the build
inventory from the candidate, and run from the source checkout on the signing Mac:

```sh
set -euo pipefail
APP=build/macos/Build/Products/Release/Yun.app # Set to actual built app path.
IDENTITY='Developer ID Application: YOUR LEGAL NAME (TEAMID)'
test -d "$APP"
test -f sign-order.txt
while IFS= read -r component || [[ -n "$component" ]]; do
  test -n "$component"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/$component"
done < sign-order.txt
codesign --force --options runtime --timestamp --sign "$IDENTITY" \
  --entitlements macos/Runner/Release.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --display --entitlements :- "$APP"
# Package the signed app with the existing bundle-preserving DMG helper.
# Its unsigned filename/volume label is conservative; it performs no signing itself.
bash scripts/release/package-macos.sh
mv dist/yun-macos-arm64-unsigned.dmg dist/yun-macos-arm64-developer-id.dmg
DMG=dist/yun-macos-arm64-developer-id.dmg
codesign --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile yun-notary --wait \
  --output-format json > dist/notarization.json
python3 -c 'import json, sys; r = json.load(open("dist/notarization.json")); sys.exit(0 if r.get("status") == "Accepted" else "Notarization not Accepted: stop")'
# Retain submission ID + log; use
# `xcrun notarytool log <ID> --keychain-profile yun-notary` to inspect failures.
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --verbose=2 "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
python3 scripts/release/checksums.py # Only AFTER signing/stapling changed bytes.
```

Record actual team identity, certificate fingerprint, entitlements, submission ID,
and Accepted log in private release evidence. Validate the installed app with
`spctl --assess --type execute --verbose=2 /Applications/Yun.app` and test a fresh
quarantined download on a clean Mac, including offline Gatekeeper behavior. The
DMG is stapled here, not a separately redistributed `.app`; submit/staple the app
separately if distributing it outside that DMG. Lock/remove the temporary signing
keychain and revoke short-lived credentials according to operator policy. None
of these native/operator steps has been executed by the host-only tooling tests.

## Installation and removal

### Linux x64

Built on Ubuntu 24.04; older glibc distributions are not guaranteed. Install runtime
dependencies on Ubuntu 24.04:

```sh
sudo apt-get update
sudo apt-get install libgtk-3-0t64 libmpv2 libsecret-1-0 libayatana-appindicator3-1
# A running user Secret Service/keyring (e.g. GNOME Keyring) is also required.
tar -xzf yun-linux-x64.tar.gz
bash yun/install.sh
```

Tray display additionally needs a StatusNotifier host (for example KDE Plasma).
Without one Yun remains usable but will not hide to the tray. Closing quits by
default; **Settings → Window behavior** can opt into close-to-tray. Use **Quit Yun**
before replacing binaries when that preference is enabled.

The installer requires Bash/Python 3 and installs the **whole** bundle into
`~/.local/opt/yun`, with a desktop entry in
`${XDG_DATA_HOME:-~/.local/share}/applications/yun.desktop`. Close Yun before
updating; the previous bundle is kept at `~/.local/opt/yun.previous`. You can also
run `./yun/yun` directly from the extracted archive. Do not move only the executable.
Remove those install/desktop paths to uninstall binaries; do not delete application
data or keyring entries without deciding whether to preserve your offline library
and credentials. No root-level install or automatic updater is provided.

### macOS ARM64

Open the DMG and drag `Yun.app` to Applications. Minimum deployment target currently
is macOS 12; confirm the actual runner project and plugin requirements for each
candidate. Gatekeeper may block this **unnotarized** build. For a trusted private
test candidate, use Apple's per-app Privacy & Security/Open Anyway process; do
not disable Gatekeeper globally. No Intel-only build is promised. Quit before
replacing the app; remove the app to uninstall binaries, retaining user data unless
you explicitly choose to remove it. Keychain, background playback, notifications,
and lock-screen/media controls require real-device validation.

### Windows x64 portable

Install the Microsoft Visual C++ 2015–2022 x64 Redistributable from Microsoft if
not already installed. Extract the entire ZIP into a writable folder such as
`%LOCALAPPDATA%\Programs\Yun`; run `Yun\yun.exe` (or extract the inner `Yun`
folder there). Keep every DLL, plugin, `data` directory, and native media file
beside the executable. Create a normal shortcut if desired; no installer, service,
or PATH change is required. Quit before replacing the directory. SmartScreen may
warn because this is unsigned; verify source/checksum and follow organizational
policy rather than bypassing system-wide protections. Delete the bundle to
uninstall binaries. Application data and secure-storage credentials are separate
and are not erased by removing the portable folder. Validate playback and Windows
System Media Transport Controls on a real Windows machine.

### Android ARM64 evaluation APK

Install on a trusted ARM64 device using `adb install -r
yun-android-arm64-debug-signed.apk` or Android's per-source install UI. The filename
intentionally states **debug-signed**; this is also a debug-mode build. Hosted
runners can generate different debug keys across runs, so upgrading may fail with
a signature mismatch. Uninstalling first removes application data: export/preserve
what you need before doing so. This artifact is not suitable for Play publication
or a production update channel. Do not distribute the debug keystore as a release
credential. Background/lock-screen playback, notification permissions, battery
restrictions, audio focus, and actual codec support still need device testing.

## Dependency/license redistribution gate

`NOTICES.txt` is a warning/checklist pointer, **not a complete notices bundle**.
The Dart inventory and lockfile are supplied with client artifacts; both release
and candidate server archives include Cargo metadata. These inventories do not enumerate every
native binary pulled by plugins. Private artifact upload does not itself satisfy
third-party obligations. Before sharing a candidate beyond authorized evaluation:

- [ ] Identify the applicable Yun source license and include its actual license
  text; do not assume the server crate's manifest license covers the whole app.
- [ ] Review every locked Dart and Cargo dependency and its transitive dependencies;
  collect exact license texts, copyrights, NOTICE files, and attribution requirements.
- [ ] Inventory actual linked/bundled native libraries per OS/architecture, including
  Flutter/Dart, media_kit binaries, **mpv, FFmpeg**, libass, codecs, crypto, SQLite,
  Rust SMTC binaries, and OS/runtime redistribution terms. Record binary hashes,
  download/source URLs, versions, build options, and corresponding source revisions.
- [ ] Determine the effective licenses of the **actual mpv/FFmpeg builds**: mpv is
  commonly GPL with LGPL configurations possible; FFmpeg varies between LGPL/GPL
  depending on enabled components, and `nonfree` builds may not be redistributable.
  Do not infer binary terms from a Flutter wrapper's permissive license.
- [ ] Fulfill applicable source/build-script/source-offer and LGPL relinking or
  modification requirements, retaining notices and any required installation
  information. Ensure the selected native configuration is compatible with the
  intended distribution. Obtain legal review where needed.
- [ ] Review codec patent/jurisdiction issues separately from copyright licenses.
  Using the system libmpv on Linux does not resolve obligations for bundled binaries
  on Windows, macOS, or Android.
- [ ] Replace the warning-only notices file with the reviewed license/notice bundle
  and retain the audit/source materials privately alongside the candidate.
- [ ] Complete the runtime/signing checklist in [VALIDATION.md](VALIDATION.md).

License review, release signing/notarization, and cross-platform hardware validation
are explicitly **not complete** merely because automated builds pass.
