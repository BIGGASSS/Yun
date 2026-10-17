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
The runner links the plugin-provided mimalloc object as recommended by media_kit;
the default plugin build downloads its pinned source archive.

## Release packages

Linux x64 releases provide **`yun-linux-x64.AppImage`** and
**`yun-linux-x64.deb`**, replacing the client tar.gz. Both preserve the entire
Flutter release bundle, including all plugins, native bundle files, assets and
`share/` contents, and include the dependency inventory, lockfile, build
provenance, release/validation docs and notices warning. They use an **Ubuntu
24.04 baseline**; compatibility with older glibc distributions is not guaranteed.
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

Removal preserves user data, the offline library and keyring entries. Neither
release format provides an automatic updater. Both still need a desktop D-Bus
session and a Secret Service provider for secure storage (see below); runtime
library dependencies do not install or configure a working keyring session.

### Packaging tools

`scripts/release/package-linux.sh` uses **appimagetool 1.9.1** and the **type2
runtime 20251108**, both pinned and SHA-256 verified before use. Debian packaging
requires `dpkg-dev`: `dpkg-shlibdeps` calculates shared-library dependencies,
with an explicit `libmpv2` dependency added because media_kit loads it dynamically
rather than linking it. Both formats retain the complete Flutter bundle rather
than copying just the runner executable.

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
assets. The application ID and desktop/icon basename are `app.yun.yun`.
The GTK window icon is also embedded as a GResource, so it does not depend on the
working directory. Application icons are derived from the unchanged
`assets/icon.png`, including the full-color tray derivatives in `assets/tray_icons/`.
Regenerate them with `python3 scripts/generate-tray-icons.py` (requires Pillow),
and validate with `python3 scripts/test-tray-icons.py`. PNGs are 64px for Linux
and 36px for macOS's 18-point/Retina icon; Windows gets a multi-size ICO. macOS
uses full-color mode, not template tinting.

This setup follows the installed `media_kit`, `media_kit_libs_linux`,
`flutter_secure_storage_linux`, and `audio_service_mpris` READMEs.
