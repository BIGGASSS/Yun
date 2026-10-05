/// Selects Dart-only Linux support instead of tray_manager's native plugin.
///
/// Yun creates its StatusNotifierItem through LinuxStatusNotifierTray in the
/// application. No native method-channel implementation is needed on Linux.
class YunTrayManagerLinux {
  static void registerWith() {
    // Registration is intentionally empty: the app owns the Linux tray lifecycle.
  }
}
