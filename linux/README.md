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

Ship the whole `build/linux/x64/release/bundle/`, not just `yun`. Its `share/`
contains a desktop entry and icon. A system packager should install those into
`share/applications` and `share/icons/hicolor/256x256/apps` under the chosen prefix,
and expose `yun` on PATH (or update the desktop entry's `Exec` to its installed
absolute path). The application ID and desktop filename are `app.yun.yun`.
The GTK window icon is also embedded as a GResource, so it does not depend on the
working directory. Application icons are derived from the unchanged
`assets/icon.png`, including the full-color tray derivatives in `assets/tray_icons/`.
Regenerate them with `python3 scripts/generate-tray-icons.py` (requires Pillow),
and validate with `python3 scripts/test-tray-icons.py`. PNGs are 64px for Linux
and 36px for macOS's 18-point/Retina icon; Windows gets a multi-size ICO. macOS
uses full-color mode, not template tinting.

This setup follows the installed `media_kit`, `media_kit_libs_linux`,
`flutter_secure_storage_linux`, and `audio_service_mpris` READMEs.
