# Releases and evaluation candidates

## Scope and provenance

Pushing a `v*` tag triggers **Release** (`.github/workflows/tag-release.yml`),
validates the source, builds all four
clients and the Linux server, and publishes their installers, AppImage, disk image,
APK and server archive plus `SHA256SUMS` to a GitHub Release with generated
release notes. Android uses the configured release keystore (no debug fallback);
macOS and Windows remain unsigned. All
builds must succeed before publication. Releases follow repository visibility;
review the acceptance and license gates below before pushing a release tag.

CI and the separate **Release candidates** workflow
(`.github/workflows/release.yml`) upload workflow artifacts only (14-day retention).
They do not publish a GitHub Release or upload to package/container registries.
These artifacts are publicly accessible when the repository is public; environment
approval does not make an artifact private. An artifact is **not** evidence of a
completed hardware, security, signing, or license review.

- `.fvmrc` is the Flutter version source of truth: currently **3.47.5**.
- `.github/actions/flutter/action.yml` first bootstraps that exact Flutter/Dart
  version via the vendored upstream `subosito/flutter-action` in
  `.github/actions/flutter-sdk`, then activates FVM **4.3.1** with Dart and runs
  `fvm install`. Every Flutter analyze/test/build subsequently uses FVM, not a
  floating runner SDK. Upstream vendor updates are manual; Dependabot handles
  nested cache pins. See [provenance and update instructions](../.github/actions/flutter-sdk/UPSTREAM.md).
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
four native client builds via `native-builds.yml`. Ubuntu 24.04 installs GTK3,
libmpv, libsecret, clang, CMake, Ninja, pkg-config, and liblzma development
dependencies. No Ayatana/AppIndicator library is required.
macOS uses the Apple Silicon `macos-15` runner (asserts arm64); Windows uses x64
MSVC on `windows-2022`; Android uses Java 17 plus the Android SDK.

Linux packaging uses **appimagetool 1.9.1** and the **type2 runtime 20251108**,
both version-pinned and SHA-256 verified before use. It preserves the Flutter
bundle directly, without linuxdeploy or vendoring system GTK3/libsecret/libmpv.
The Debian package uses `dpkg-dev`'s `dpkg-shlibdeps` to calculate shared-library
dependencies, plus an explicit `libmpv2` dependency because playback loads it
dynamically. Windows packaging uses `scripts/release/package-windows.ps1` and
Inno Setup 6.3+ (`ISCC.exe`, preinstalled on `windows-2022`; use `-IsccPath` or
`ISCC_PATH` for a nonstandard local installation).

To publish a release, update `pubspec.yaml`'s version/build number, commit the
reviewed changes, then push a tag such as:

```sh
git tag v1.0.0
git push origin v1.0.0
```

Tags do not override the version in `pubspec.yaml`. Allow `v*` tags in the
`release-signing` environment's deployment rules and approve its job if required.
Missing signing secrets or a failed validation/build prevents publication.

To make an artifact-only candidate, select **Actions → Release candidates → Run
workflow**, choosing the reviewed branch and `android_signing` mode
(default `debug-signed`; opt-in `release-signed` on `main` only). Manual candidate
packaging does not run the validation job: verify successful CI for the exact
commit first. Tag releases separately gate packaging on validation, including
Flutter tests against a freshly built actual server binary.
Download the per-target artifacts from that workflow run; manual dispatch does
not publish a GitHub Release. Check `SHA256SUMS` against the downloaded release
files, e.g. `sha256sum -c SHA256SUMS` (Linux) or
`shasum -a 256 -c SHA256SUMS` (macOS).
On Windows use `Get-FileHash -Algorithm SHA256 yun-windows-x64-unsigned.exe`
and compare explicitly.
Unsigned checksums catch corruption, not an attacker replacing both files.

| Artifact | Contents and current signing status |
| --- | --- |
| `yun-linux-x64` | `yun-linux-x64.AppImage` and `yun-linux-x64.deb`, each preserving the complete release-mode Flutter bundle, canonical desktop/icon assets, dependency inventory and review warning; Ubuntu 24.04 baseline, system native libraries required |
| `yun-macos-arm64-unsigned` | ARM64 release app in a drag-to-Applications DMG; **no Developer ID signing/notarization**, at most Flutter's ad-hoc signatures |
| `yun-windows-x64-unsigned` | `yun-windows-x64-unsigned.exe`, an Inno Setup wizard containing the complete Flutter release bundle and inventory; per-user install with registered uninstall/upgrade; **no Authenticode signing** |
| `yun-android-arm64-debug-signed` | Default: **debug-mode, debug-key-signed** ARM64 APK, not a production/Play release |
| `yun-android-arm64-release-signed` | Tag releases or manual opt-in: release-mode ARM64 APK signed with the operator's keystore; signature verified with `apksigner`, still subject to acceptance/license gates |
| `yun-server-linux-x64` | Locked Rust server release binary (CI), or tar.gz with server operations docs and Cargo dependency inventory (release/candidate workflows) |

Android release signing runs automatically for tag releases and is opt-in for
manual candidates; configuration alone is not evidence that a signed build has
been executed or accepted. Windows Authenticode and macOS Developer
ID signing/notarization remain operator-only procedures below; their workflow
artifacts remain explicitly unsigned. Play App Signing/AAB publication is not
implemented. Never commit signing keys, passwords, or notarization credentials.

## Android release media-resource validation

Every Android native-build job checks the final optimized release APK, including
pull requests that otherwise produce a debug-mode evaluation APK. PR/debug jobs
also build an **unsigned release-mode** APK with code/resource shrinking enabled,
audit it, and upload `yun-android-arm64-release-validation-unsigned` separately
from distribution artifacts. It is inspection evidence, not an installable
candidate, and uses no release-signing credentials.

`scripts/release/verify-android-resources.py FINAL.apk` uses the Android SDK's
`aapt2` to check the final resource table, nonzero drawable IDs, and their actual
packaged assets. It fails closed if required `audio_service_*` icons are missing
or cannot be validated. Signed release builds run the same audit before copying
anything to `dist/`. Set `--aapt2` explicitly if the SDK is not on PATH or in
`ANDROID_SDK_ROOT`/`ANDROID_HOME`.

The narrow `android/app/src/main/res/raw/yun_audio_service_keep.xml` rule retains
icons whose names cross from Dart to Android at runtime. The release shrinker
cannot infer those references. In particular, Android 13+ requires a valid icon
for the Stop custom action; dropping it throws before foreground-service startup.
Run `python3 scripts/release/test-android-resources.py` for the verifier regressions
and `python3 scripts/release/test-android-signing.py` for fail-closed build ordering.
APK inspection does not replace first-play/lock-screen testing on an Android 13+
device, and does not certify audio focus or vendor background-policy behavior.

## Repository and workflow protections

GitHub settings are not defined by workflow YAML. Keep these controls enabled:

- An active `main` ruleset requires a pull request, resolved review conversations,
  code-owner review for sensitive paths, and successful Rust, Flutter, deployment,
  keyring, and all four native-build checks. Stale approvals are dismissed and
  the branch must be up to date. Force pushes and deletion are blocked.
- An active `v*` tag ruleset restricts tag creation, movement, and deletion to
  repository administrators. Both rulesets retain an explicit administrator
  bypass for the solo maintainer; use it only deliberately, not as a routine
  substitute for CI. No independent approving review is required for ordinary
  solo-maintainer PRs. `.github/CODEOWNERS` requests owner review of workflows,
  release scripts, and Android signing configuration.
- Actions use a read-only default token and cannot approve PRs. Allow GitHub-owned
  actions plus the explicitly selected Android, Rust-toolchain, and Rust-cache
  actions; require full commit SHAs (including nested cache actions). All checkouts disable persisted
  credentials. Dependabot proposes weekly action updates for review.
- Require approval for workflow runs from **all external contributors**. Fork PRs
  must never receive signing secrets. Enable secret scanning, push protection,
  and dependency vulnerability alerts on the public repository.
- The `release-signing` environment has the separate approval/ref restrictions
  below. Environment secrets are not ordinary repository secrets. A public
  repository does not make secret values public, but executing untrusted code
  with them can disclose them.

Run `python3 scripts/release/test-workflow-policy.py` to check the local policy
invariants. It cannot verify remote rulesets, secret placement, or environment
settings; inspect those through GitHub settings/API after changes.

## Android release signing gate

Before running `release-signed`:

1. Configure the GitHub environment **`release-signing`** with required reviewer
   **`BIGGASSS`**, no administrator approval bypass, and custom deployment rules
   allowing only the **branch `main`** and **tags `v*`**. The chosen solo-maintainer
   policy permits self-approval; this is a manual gate, not independent review.
   Add a second trusted maintainer and prevent self-approval if independent review
   becomes possible. Configure these controls **before** the first run: naming an
   environment in YAML does not protect it. If the GitHub plan cannot enforce
   approval rules, do not enable hosted signing.
2. Store these four secrets **only** on that environment, never as repository or
   organization secrets. The two release callers explicitly bind just these four
   names, and `native-builds.yml` declares them optional so debug/CI callers do not
   require signing credentials. These bindings do not transfer environment values
   from the caller: the called Android job still selects `release-signing`, waits
   for its approval/ref gates, and resolves its environment secrets there. CI has
   no secret mappings and uses `native-evaluation`, never the release environment.
   Manual debug candidates map empty values. Do not add repository/org copies as
   a workaround or replace the explicit mapping with `secrets: inherit`.

   | Secret | Value |
   | --- | --- |
   | `ANDROID_KEYSTORE_BASE64` | Base64 of the operator-controlled JKS/PKCS12 signing keystore (not the debug keystore) |
   | `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
   | `ANDROID_KEY_ALIAS` | Private-key entry alias |
   | `ANDROID_KEY_PASSWORD` | Private-key password |

   Base64 is encoding, **not encryption**. To upload an existing keystore without
   printing it or writing a base64 file, on a trusted operator machine with `gh`
   authenticated to the intended repository:

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
3. Push a reviewed `v*` tag, or run **Release candidates** on `main` with
   `release-signed`. Inspect the exact source commit and workflow/dependency
   changes, and manually approve the environment job. Only manual dispatch on
   `main` or a `v*` tag push may request signing. Before build tools run, the job
   checks that its commit is reachable from `origin/main`; tags on divergent
   commits fail closed. Do not approve untrusted code: Gradle/plugins/build scripts
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

### Reusable-workflow secret resolution verification

The explicit four-name contract is a bounded compatibility workaround for empty
signing values in a called workflow. [GitHub documents job-level environment
secrets taking precedence](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows#using-inputs-and-secrets-in-a-reusable-workflow),
while [actions/runner#1490](https://github.com/actions/runner/issues/1490) reports
empty environment secrets and explicit caller bindings as a workaround. This
report is supporting evidence, not proof of the cause or fix in Yun. Optional
secret declarations preserve unsigned CI; the signing script still requires all
four nonempty values and fails closed. Offline tests cannot emulate GitHub's
secret-resolution service or verify actual environment settings.

After review and merging, a separately authorized **Release candidates** run on
`main` with `release-signed` can verify the changed workflow without publishing a
GitHub Release. Approve only the intended source commit; check the signed APK and
its independent certificate fingerprint as above. Do not print secret values or
lengths to diagnose resolution. A rerun of an old tag keeps its original source
and workflow; merging this change does not repair that tag's workflow snapshot.
Any new release tag or existing-tag change requires a separate release decision.

## Windows Authenticode: secure operator procedure (not automated)

Use an isolated trusted Windows signing workstation and Windows SDK `signtool`.
Obtain a valid code-signing identity; provision its private key through the issuing
CA's approved hardware token/HSM or protected certificate-store process. Do not
export an unencrypted PFX or pass its password using `signtool /p`. The example
uses an already provisioned **CurrentUser\\My** certificate; a hardware provider
may prompt for authorization. Certificate thumbprints are public identifiers.

Work from the reviewed source checkout with a freshly built complete release
bundle in `build/windows/x64/runner/Release` and its dependency inventory,
`pubspec.lock`, and `BUILD.txt` prepared in `dist/` as in `native-builds.yml`.
Inventory all PE files; preserve third-party signatures and follow their
redistribution terms. The commands sign Yun's executable and the final installer,
**not a claim that all bundled DLLs are publisher-signed**. Sign additional
first-party PE binaries only after review. Run from the checkout root in
PowerShell 7 with Inno Setup 6.3+ installed:

```powershell
$ErrorActionPreference = 'Stop'
$Thumbprint = Read-Host 'Approved code-signing certificate SHA-1 thumbprint'
$Exe = 'build/windows/x64/runner/Release/yun.exe'
signtool sign /s My /sha1 $Thumbprint /fd SHA256 /tr https://timestamp.digicert.com /td SHA256 $Exe
if ($LASTEXITCODE -ne 0) { throw 'Signing failed' }
signtool verify /pa /all /v $Exe
if ($LASTEXITCODE -ne 0) { throw 'Signature verification failed' }
Get-AuthenticodeSignature $Exe | Format-List Status,SignerCertificate,TimeStamperCertificate
# Compare publisher/certificate to the independently approved identity.
Add-Content dist/BUILD.txt 'Operator Authenticode signing of yun.exe and installer; uninstaller remains unsigned. Retain certificate/timestamp evidence separately.'
# The bundle-preserving packaging helper performs no signing itself.
./scripts/release/package-windows.ps1
$Installer = 'dist/yun-windows-x64-authenticode.exe'
Move-Item dist/yun-windows-x64-unsigned.exe $Installer
signtool sign /s My /sha1 $Thumbprint /fd SHA256 /tr https://timestamp.digicert.com /td SHA256 $Installer
if ($LASTEXITCODE -ne 0) { throw 'Installer signing failed' }
signtool verify /pa /all /v $Installer
if ($LASTEXITCODE -ne 0) { throw 'Installer signature verification failed' }
Get-AuthenticodeSignature $Installer | Format-List Status,SignerCertificate,TimeStamperCertificate
python scripts/release/checksums.py # Only AFTER signing changed the installer bytes.
if ($LASTEXITCODE -ne 0) { throw 'Checksum generation failed' }
Get-FileHash -Algorithm SHA256 $Installer
```

Signing the final installer does not sign Inno Setup's generated uninstaller;
the default packaging configuration leaves that uninstaller unsigned. A signed
uninstaller requires a separately reviewed Inno Setup signing configuration.
Use the CA-approved RFC3161 timestamp service if different. Verify installation,
upgrade and uninstall on a clean Windows machine, including timestamp/certificate
chain and SmartScreen behavior; signing does not guarantee reputation or remove
prompts. Preserve signed installer hashes and verification evidence privately;
never relabel the original unsigned workflow artifact as signed.

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

Choose `yun-linux-x64.AppImage` or `yun-linux-x64.deb`; these replace the client
tar.gz. Both contain the **whole** Flutter release bundle, dependency inventory,
lockfile, build provenance, release/validation docs and notices warning. Do not
extract or move only the `yun` executable. Both are built on the **Ubuntu 24.04
baseline**; older glibc distributions are not guaranteed.

#### AppImage

The AppImage is **not a universal standalone binary**: it intentionally relies
on system GTK3, libsecret and libmpv2, plus their transitive dependencies. No
linuxdeploy step vendors those libraries. On Ubuntu 24.04:

```sh
sudo apt update
sudo apt install libgtk-3-0t64 libsecret-1-0 libmpv2
chmod +x yun-linux-x64.AppImage
./yun-linux-x64.AppImage
```

The image contains a root `AppRun` launcher that starts the bundled `yun`.
If FUSE is unavailable, the pinned runtime supports this FUSE-free alternative:

```sh
./yun-linux-x64.AppImage --appimage-extract-and-run
```

Quit Yun before replacing the AppImage with a newer verified download. Delete
the AppImage to remove its binaries; user data and keyring entries are separate.

#### Debian package

Use APT so native runtime dependencies are resolved automatically:

```sh
sudo apt update
sudo apt install ./yun-linux-x64.deb
yun
```

The package installs the complete bundle into `/usr/lib/yun`, provides the
`/usr/bin/yun` symlink, and installs the canonical
`/usr/share/applications/app.yun.yun.desktop` and
`/usr/share/icons/hicolor/256x256/apps/app.yun.yun.png` assets. Quit Yun before
upgrading with the same `apt install ./yun-linux-x64.deb` command for the newer
package. Uninstall with:

```sh
sudo apt remove yun
```

Removal preserves application data, the offline library and keyring credentials.
Neither format provides an automatic updater.

Both formats need a desktop D-Bus session and a user Secret Service/keyring
(e.g. GNOME Keyring or KWallet) for secure storage; installing libsecret alone
is not sufficient. Yun uses D-Bus directly for its Linux tray; no
Ayatana/AppIndicator library is required. Tray display additionally needs a
StatusNotifier host (for example KDE Plasma). Without one Yun remains usable but
will not hide to the tray. Closing quits by default; **Settings → Window
behavior** can opt into close-to-tray. Use **Quit Yun** before upgrading or
removing binaries when that preference is enabled. Desktop/keyring/media behavior
still requires real-desktop validation; packaging is not evidence of that testing.

### macOS ARM64

Open the DMG and drag `Yun.app` to Applications. Minimum deployment target currently
is macOS 12; confirm the actual runner project and plugin requirements for each
candidate. Gatekeeper may block this **unnotarized** build. For a trusted private
test candidate, use Apple's per-app Privacy & Security/Open Anyway process; do
not disable Gatekeeper globally. No Intel-only build is promised. Quit before
replacing the app; remove the app to uninstall binaries, retaining user data unless
you explicitly choose to remove it. Keychain, background playback, notifications,
and lock-screen/media controls require real-device validation.

### Windows x64

Install the [Microsoft Visual C++ 2015–2022 x64 Redistributable](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist)
from Microsoft if not already installed. Yun's installer does **not** download or
install this runtime automatically.

Run `yun-windows-x64-unsigned.exe` and follow the Inno Setup wizard. Yun installs
per-user into `%LOCALAPPDATA%\Programs\Yun` without administrator privileges,
including every Flutter DLL, plugin, `data` directory, native media file and
release inventory. The wizard creates a Start Menu shortcut and offers an
optional desktop shortcut. Launch Yun from the shortcut or the installed
`yun.exe`; do not move the executable away from its bundle.

Quit Yun before running a newer installer to upgrade the registered installation.
Use Windows Settings → Apps → Yun → Uninstall to remove the installed files and
shortcuts. Application data and secure-storage credentials are separate and are
preserved by uninstall. SmartScreen may warn because this installer is unsigned;
verify source/checksum and follow organizational policy rather than bypassing
system-wide protections. Installation, upgrade, uninstall, playback and Windows
System Media Transport Controls still require validation on a real Windows machine.

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
native binary pulled by plugins. Evaluation artifact upload does not itself satisfy
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
