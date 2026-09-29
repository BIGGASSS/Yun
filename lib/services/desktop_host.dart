/// Native desktop integration, kept separate from close policy and persistence.
/// No implementation is constructed on Android, iOS, or the web.
abstract interface class DesktopHost {
  Future<void> initialize({
    required void Function() onClose,
    required void Function() onShow,
    required void Function() onQuit,
    required void Function(bool available) onTrayAvailabilityChanged,
    required void Function(Object error) onError,
  });

  /// Conservative availability check; called again immediately before hiding.
  Future<bool> checkTrayAvailability();
  Future<void> hide();
  Future<void> show();

  /// Remove listeners, tray icon, and bus connections; do not terminate yet.
  Future<void> dispose();

  /// Called only AFTER application shutdown and preference writes complete.
  Future<void> exitApplication();
}
