# Windows runner

Build on Windows with `fvm flutter build windows --release` from the repository
root. Use the Flutter-supported Visual Studio installation with:

- Desktop development with C++, MSVC tools, CMake and the Windows SDK.
- **C++ ATL** for the selected architecture/toolset (required by
  `flutter_secure_storage_windows`, and not always installed by default).
- **Rust installed through rustup**, with `rustup` and `cargo` on PATH. For x64,
  install the `stable-x86_64-pc-windows-msvc` toolchain; use a matching MSVC target
  for other supported architectures. Do not use the GNU Rust toolchain.

`smtc_windows` builds its native Rust code through cargokit; internet access may
be required for Rust crates and toolchains. CMake checks for rustup/cargo before
building plugins. Keep the Dart `flutter_rust_bridge` runtime aligned with the
plugin's generated/native bridge: smtc_windows 1.1.0 was generated with 2.11.1
and pins its Rust crate to that exact version. Its Dart caret constraint can
resolve to a newer, incompatible runtime; pin 2.11.1 in the app dependency
resolution until the plugin updates both sides together.

The Windows media integration targets Windows 10 or newer
(SystemMediaTransportControls), regardless of older OS support in media_kit.
`media_kit_libs_windows_audio` supplies native audio DLLs; distribute the complete
Flutter release directory, not just `yun.exe`.

Secure storage uses Windows Credential Manager and encrypted per-user files.
Native media controls and secure storage must be smoke-tested in a real Windows
user session. A build alone does not verify them.

The window/resource display name is Yun. `runner/resources/app_icon.ico` contains
16–256px images generated from the unchanged `assets/icon.png`.

Requirements above come from the installed `smtc_windows`,
`flutter_secure_storage_windows`, and `media_kit` READMEs.
