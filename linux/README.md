# Linux runner

Build from the repository root with `fvm flutter build linux --release`.
On Debian/Ubuntu, install the Flutter native toolchain and plugin dependencies:

```sh
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev \
  libglib2.0-dev libsecret-1-dev libmpv-dev mpv
```

`media_kit_libs_linux` does **not** bundle libmpv: playback dynamically loads the
system `libmpv.so.2` (or `.so.1`). A build can succeed without it, but playback
cannot. Distribution packages must depend on the appropriate libmpv runtime
(e.g. `libmpv2`), GTK 3, and `libsecret-1-0`, plus their transitive dependencies.
No Ayatana/AppIndicator library is required by Yun.

## Allocator selection

The runner uses the **system allocator by default** (`YUN_USE_MIMALLOC=OFF`).
The production `media_kit_libs_linux` dependency remains enabled for playback;
OFF skips its static mimalloc download/build and does not link mimalloc, even if
the plugin discovers a system shared mimalloc library. This avoids imposing a
process-wide allocator override on the Flutter runner. It is not a claim that
all native libraries use the same allocator or that every memory issue is fixed.

To restore the prior media_kit-provided static mimalloc behavior, opt in with
`YUN_USE_MIMALLOC=ON`. Its pinned source archive is downloaded and its object
linked into `yun`; a missing allocator export fails configuration rather than
silently falling back. Download, compilation and link failures also fail the build.

Flutter 3.47.5's Linux build command does **not** accept arbitrary CMake `-D`
arguments (nor forward `CMAKE_ARGS`). Yun instead accepts an environment value
of exactly `ON` or `OFF` as the CMake option's initial default. An existing
`CMakeCache.txt` value or an explicit CMake `-DYUN_USE_MIMALLOC=...` takes priority;
changing or unsetting the environment alone does **not** change a cached choice.
When switching allocator variants, remove the generated build directory for the
architecture/mode being built (below: x64 release), or use `fvm flutter clean`
for all configurations. Do not do this while another build is running.

```sh
# Reproduce the default release/CI variant, including after a mimalloc build:
rm -rf build/linux/x64/release
YUN_USE_MIMALLOC=OFF fvm flutter build linux --release --target-platform linux-x64
python3 scripts/verify-linux-allocator.py --binary build/linux/x64/release/bundle/yun --expect system

# Optional compatibility/comparison build using the prior allocator:
rm -rf build/linux/x64/release
YUN_USE_MIMALLOC=ON fvm flutter build linux --release --target-platform linux-x64
python3 scripts/verify-linux-allocator.py --binary build/linux/x64/release/bundle/yun --expect mimalloc
```

Both variants use the same release packaging command:
`bash scripts/release/package-linux.sh`. Rebuild before packaging after changing
the allocator; packaging alone does not rebuild the bundle. Release CI explicitly
selects OFF, checks the built runner's dynamic exports/dependencies before
packaging, and records the allocator in `dist/BUILD.txt`.

Run the offline CMake/linkage regressions with
`python3 scripts/test-linux-allocator.py` (CMake, Ninja, a C++ compiler and binutils
required; no Flutter build or network access). These exercise the actual project
CMake with fixture plugins, not a full playback/desktop test.

## Release packages

Linux x64 releases provide **`yun-linux-x64.AppImage`**,
**`yun-linux-x64.deb`** and the original **`yun-linux-x64.tar.gz`** with
**`install.sh`**. AppImage and Debian packages are additional options, not
replacements for the tarball installer. All three preserve the entire Flutter
release bundle, including all plugins, native bundle files, assets and `share/`
contents, and include the dependency inventory, lockfile, build provenance,
release/validation docs, `LICENSE` and notices warning. All use an **Ubuntu 24.04
baseline** and the same system GTK3, libsecret and libmpv2 runtime libraries;
compatibility with older glibc distributions is not guaranteed. Quit Yun before
installing or upgrading any format. User data, the offline library and keyring
credentials are kept outside the binary locations.
See [release and acceptance gates](../docs/RELEASE.md) before redistribution.
Packaging does not establish real-desktop or hardware validation.

### AppImage

This is **not a universal standalone AppImage**. System GTK3, libsecret and
libmpv2 (and their transitive dependencies) are intentionally not vendored; there
is no linuxdeploy step. On Ubuntu 24.04, install the runtime libraries, then run:

```sh
sudo apt update
sudo apt install libgtk-3-0t64 libsecret-1-0 libmpv2
chmod +x yun-linux-x64.AppImage
./yun-linux-x64.AppImage
```

The image contains a root `AppRun` launcher that starts the bundled `yun`.
When FUSE is unavailable, use the runtime's FUSE-free extraction-and-run mode:

```sh
./yun-linux-x64.AppImage --appimage-extract-and-run
```

Quit Yun before replacing the image for an upgrade. Delete the AppImage to
remove its binaries; application data and keyring credentials remain separate.

### Debian package

APT resolves native runtime dependencies when installing the local package:

```sh
sudo apt update
sudo apt install ./yun-linux-x64.deb
yun
```

The complete bundle lives in `/usr/lib/yun`, with `/usr/bin/yun` symlinked to
its executable. Desktop integration uses the canonical
`/usr/share/applications/app.yun.yun.desktop` and
`/usr/share/icons/hicolor/256x256/apps/app.yun.yun.png` assets. Quit Yun before
upgrading with `sudo apt install ./yun-linux-x64.deb` for a newer package.
Uninstall using:

```sh
sudo apt remove yun
```

Removal preserves user data, the offline library and keyring entries.

### Original tarball and install.sh

`yun-linux-x64.tar.gz` extracts into `yun/` with the complete Flutter bundle,
metadata/docs and `LICENSE`. The original `scripts/release/install-linux.sh` is
included unchanged as `install.sh`, alongside `scripts/release/yun.desktop` as
`yun.desktop` and `assets/icon.png` as `yun.png`. Install the same runtime libraries
listed above for AppImage, and have Bash and Python 3 available. Quit Yun and
extract each new archive outside the install directory before installing or
upgrading:

```sh
tar -xzf yun-linux-x64.tar.gz
bash yun/install.sh
"$HOME/.local/opt/yun/yun"
```

The installer runs **without sudo**, copies the entire extracted bundle into
`~/.local/opt/yun`, and keeps the immediately previous bundle in
`~/.local/opt/yun.previous` (replacing any older backup). Its desktop entry is
`${XDG_DATA_HOME:-$HOME/.local/share}/applications/yun.desktop`, defaulting to
`~/.local/share/applications/yun.desktop`. To uninstall, remove the installed
bundle, its `.previous` backup if present, and that user-local desktop entry;
user data and keyring entries remain separate.

None of the three release formats provides an automatic updater. All three need
a desktop D-Bus session and a Secret Service provider for secure storage (see
below); runtime library dependencies do not install or configure a working
keyring session.

### Packaging tools

`scripts/release/package-linux.sh` uses **appimagetool 1.9.1** and the **type2
runtime 20251108**, both pinned and SHA-256 verified before use. Debian packaging
requires `dpkg-dev`: `dpkg-shlibdeps` calculates shared-library dependencies,
with an explicit `libmpv2` dependency added because media_kit loads it dynamically
rather than linking it. All three formats retain the complete Flutter bundle
rather than copying just the runner executable.

## System tray

**Settings → Window behavior** controls whether closing quits (default) or hides
Yun to the tray while playback and transfers continue. Settings also offers
explicit Minimize to tray and Quit actions. Left-click restores/focuses Yun;
right-click opens the Show Yun / Quit Yun menu. Linux exports a StatusNotifierItem
with `ItemIsMenu=false` and a DBusMenu directly, rather than AppIndicator's
menu-only primary-click behavior. The title-bar Minimize button keeps its ordinary
window-manager behavior.

Tray display requires a StatusNotifier host (provided by KDE Plasma; GNOME may
need its AppIndicator extension). Yun does not install or start one. Before
hiding, it checks its registration with the current watcher and the host on the
session bus; when unavailable it
keeps the window visible and reports an error. Watcher/host loss restores a
hidden window, with polling for implementations missing loss signals. These
checks are conservative, not proof that every desktop rendered the icon.

The Dart-only [`yun_tray_manager_linux`](../packages/yun_tray_manager_linux/README.md)
platform selection excludes the unused upstream native Linux tray plugin from
registration, linking, and bundling. Windows/macOS retain upstream `tray_manager`.
CI verifies plugin selection and the Linux bundle's native dependencies with
`python3 scripts/verify-linux-tray-linkage.py --bundle build/linux/x64/release/bundle`.

## Secure storage

Secure storage needs a Secret Service provider (KWallet, GNOME Keyring, or
an equivalent), not merely libsecret. Yun first checks the session bus for a
running or activatable `org.freedesktop.secrets`. If that name is absent, it uses
KWallet's `org.kde.secretservicecompat` instead, including read/write/unlock/delete.
Normal D-Bus activation may start the installed KDE provider when necessary;
Yun runs no daemon commands, requires no second keyring installation, and does
not modify your wallet configuration or use a plaintext/session-only fallback.
A locked or failing standard provider is not silently replaced with another store.

The Linux plugin is patched locally in
[`packages/flutter_secure_storage_linux`](../packages/flutter_secure_storage_linux/YUN_FORK.md);
other platforms still use the upstream packages. Run the isolated tests with:

```sh
bash packages/flutter_secure_storage_linux/linux/test/run_private_bus_tests.sh
```

These tests exercise libsecret against a private mock D-Bus service, not your
wallet. MPRIS media controls still need a desktop D-Bus session; a headless build
is not a test of the real desktop's unlock prompts or media controls.

## Bundle and desktop identity

Ship the whole `build/linux/x64/release/bundle/`, not just `yun`. Its `share/`
contains the canonical `app.yun.yun.desktop` entry and `app.yun.yun.png` icon.
The Debian package installs copies under `/usr/share/applications` and
`/usr/share/icons/hicolor/256x256/apps` and exposes `/usr/bin/yun`; the AppImage
retains the complete bundle and supplies its root `AppRun` launcher and desktop
assets. The tarball also preserves `share/` and adds the original `install.sh`,
`yun.desktop` and `yun.png` for user-local installation as described above.
The application ID and canonical desktop/icon basename are `app.yun.yun`.
The GTK window icon is also embedded as a GResource, so it does not depend on the
working directory. Application icons are derived from the unchanged
`assets/icon.png`, including the full-color tray derivatives in `assets/tray_icons/`.
Regenerate them with `python3 scripts/generate-tray-icons.py` (requires Pillow),
and validate with `python3 scripts/test-tray-icons.py`. PNGs are 64px for Linux
and 36px for macOS's 18-point/Retina icon; Windows gets a multi-size ICO. macOS
uses full-color mode, not template tinting.

This setup follows the installed `media_kit`, `media_kit_libs_linux`,
`flutter_secure_storage_linux`, and `audio_service_mpris` READMEs.
