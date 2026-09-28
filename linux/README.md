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
(e.g. `libmpv2`), GTK 3 and `libsecret-1-0`, plus their transitive dependencies.
The runner links the plugin-provided mimalloc object as recommended by media_kit;
the default plugin build downloads its pinned source archive.

Secure storage needs an **unlocked Secret Service keyring** (GNOME Keyring,
KWallet with Secret Service support, or equivalent), not merely libsecret.
MPRIS media controls need a desktop D-Bus session. A headless build does not test
either integration; never replace unavailable secure storage with plaintext.

Ship the whole `build/linux/x64/release/bundle/`, not just `yun`. Its `share/`
contains a desktop entry and icon. A system packager should install those into
`share/applications` and `share/icons/hicolor/256x256/apps` under the chosen prefix,
and expose `yun` on PATH (or update the desktop entry's `Exec` to its installed
absolute path). The application ID and desktop filename are `app.yun.yun`.
The GTK window icon is also embedded as a GResource, so it does not depend on the
working directory. Icons are derived from the unchanged `assets/icon.png`.

This setup follows the installed `media_kit`, `media_kit_libs_linux`,
`flutter_secure_storage_linux`, and `audio_service_mpris` READMEs.
