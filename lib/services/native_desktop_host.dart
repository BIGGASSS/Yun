import 'dart:async';
import 'dart:ui' show AppExitResponse, AppExitType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop_host.dart';
import 'linux_tray_availability.dart';

/// Production desktop adapter. Construct only on Linux, macOS or Windows.
/// Close policy, application shutdown and persistence belong to the controller.
class NativeDesktopHost
    with WindowListener, TrayListener
    implements DesktopHost {
  NativeDesktopHost({this._linuxAvailability, TargetPlatform? platform})
    : _platform = platform ?? defaultTargetPlatform;

  static const _closeChannel = MethodChannel('yun/desktop_close');
  final TargetPlatform _platform;
  bool get _isLinux => _platform == TargetPlatform.linux;
  bool get _isMacOS => _platform == TargetPlatform.macOS;
  bool get _isWindows => _platform == TargetPlatform.windows;
  LinuxTrayAvailability? _linuxAvailability;
  Timer? _windowsTrayPoll;
  void Function()? _onClose;
  void Function()? _onShow;
  void Function()? _onQuit;
  void Function(bool)? _onAvailability;
  void Function(Object)? _onError;
  Future<void>? _initialization;
  Future<void>? _disposal;
  bool _disposed = false;
  bool _windowReady = false;
  // Interception can be released while the native window still exists. A failed
  // exit after disposal must be able to restore that window without a new tray.
  bool _canShowWindow = false;
  bool _hidden = false;
  bool _windowListenerAdded = false;
  bool _preventCloseAttempted = false;
  bool _bridgeAttempted = false;
  bool _trayListenerAdded = false;
  bool _trayAttempted = false;
  bool _trayCreated = false;
  bool? _available;

  @override
  Future<void> initialize({
    required void Function() onClose,
    required void Function() onShow,
    required void Function() onQuit,
    required void Function(bool available) onTrayAvailabilityChanged,
    required void Function(Object error) onError,
  }) {
    if (_disposed) return Future.value();
    _onClose = onClose;
    _onShow = onShow;
    _onQuit = onQuit;
    _onAvailability = onTrayAvailabilityChanged;
    _onError = onError;
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    _publishAvailability(false);
    try {
      await windowManager.ensureInitialized();
      _canShowWindow = true;
      windowManager.addListener(this);
      _windowListenerAdded = true;
      _preventCloseAttempted = true;
      await windowManager.setPreventClose(true);
      if (_isWindows) {
        _closeChannel.setMethodCallHandler((call) async {
          if (call.method == 'onClose') _dispatch(_onClose);
        });
        _bridgeAttempted = true;
        // The runner intercepts WM_CLOSE BEFORE Flutter's lifecycle handler.
        // Until this handshake, ordinary startup/close behavior is unchanged.
        await _closeChannel.invokeMethod<void>('setEnabled', true);
      }
      _windowReady = true;
    } catch (error) {
      _report(error);
      await _releaseWindowInterception();
      _publishAvailability(false);
      return;
    }
    if (_disposed) return;

    try {
      trayManager.addListener(this);
      _trayListenerAdded = true;
      _trayAttempted = true;
      // Linux's AppIndicator must exist before setContextMenu is called.
      await trayManager.setIcon(
        _isWindows
            ? 'assets/tray_icons/yun.ico'
            : _isMacOS
            ? 'assets/tray_icons/yun_macos.png'
            : 'assets/tray_icons/yun_linux.png',
        isTemplate: _isMacOS,
      );
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'Show Yun'),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: 'Quit Yun'),
          ],
        ),
      );
      // Neither tooltips nor programmatic context menus are supported on Linux.
      if (!_isLinux) await trayManager.setToolTip('Yun');
      _trayCreated = true;
      if (_isLinux) {
        final availability = _linuxAvailability ??= LinuxTrayAvailability();
        await availability.initialize(
          onChanged: _publishAvailability,
          onError: _report,
        );
      } else if (_isWindows) {
        // tray_manager 0.5.3 reports success even if Shell_NotifyIcon fails.
        await checkTrayAvailability();
        if (!_disposed) {
          // Explorer can lose the icon while hidden. Notify the controller so
          // it can restore the window; keep probing while visible as well.
          _windowsTrayPoll = Timer.periodic(const Duration(seconds: 5), (_) {
            unawaited(checkTrayAvailability());
          });
        }
      } else {
        _publishAvailability(true);
      }
    } catch (error) {
      _trayCreated = false;
      _publishAvailability(false);
      _report(error);
      await _releaseTray();
      // Deliberately retain window-close interception after tray failure.
    }
  }

  void _publishAvailability(bool available) {
    if (_disposed) return;
    available = available && _trayCreated && _windowReady;
    if (_available == available) return;
    _available = available;
    _dispatch(() => _onAvailability?.call(available));
  }

  void _dispatch(FutureOr<void> Function()? callback) {
    if (_disposed || callback == null) return;
    unawaited(
      Future<void>.sync(callback).catchError((Object error) {
        _report(error);
      }),
    );
  }

  void _report(Object error) {
    unawaited(
      Future<void>.sync(() => _onError?.call(error))
          .catchError((Object reportingError) {
            debugPrint('Desktop error reporter failed: $reportingError');
          }),
    );
  }

  @override
  void onWindowClose() {
    // Windows closes come exclusively through the pre-Flutter runner bridge.
    if (!_isWindows) _dispatch(_onClose);
  }

  @override
  void onWindowFocus() {
    // The macOS Dock can reopen the window without going through the controller.
    // Reconcile its hidden state once, but never feed our own show back to it.
    if (!_hidden) return;
    _hidden = false;
    _dispatch(_onShow);
  }

  @override
  void onTrayIconMouseDown() {
    if (!_isLinux) _dispatch(_onShow);
  }

  @override
  void onTrayIconRightMouseDown() {
    if (!_isLinux) {
      _dispatch(() async => trayManager.popUpContextMenu());
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _dispatch(_onShow);
      case 'quit':
        _dispatch(_onQuit);
    }
  }

  @override
  Future<bool> checkTrayAvailability() async {
    if (_disposed || !_windowReady || !_trayCreated) return false;
    var available = true;
    if (_isLinux) {
      available = await _linuxAvailability?.check() ?? false;
    } else if (_isWindows) {
      available = false;
      try {
        available =
            await _closeChannel
                .invokeMethod<bool>('hasTrayIcon')
                .timeout(const Duration(seconds: 2)) ??
            false;
      } catch (error) {
        if (!_disposed) _report(error);
      }
    }
    available = available && !_disposed && _trayCreated;
    _publishAvailability(available);
    return available;
  }

  @override
  Future<void> hide() async {
    // Check here too: callers cannot accidentally hide using a cached result.
    if (!await checkTrayAvailability()) {
      throw StateError('No usable system tray is available.');
    }
    _hidden = true;
    try {
      await windowManager.hide();
    } catch (_) {
      _hidden = false;
      rethrow;
    }
  }

  @override
  Future<void> show() async {
    if (!_canShowWindow) return;
    _hidden = false;
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _cleanup(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      _report(error);
    }
  }

  Future<void> _releaseWindowInterception() async {
    _windowReady = false;
    if (_bridgeAttempted) {
      await _cleanup(
        () => _closeChannel.invokeMethod<void>('setEnabled', false),
      );
      _closeChannel.setMethodCallHandler(null);
      _bridgeAttempted = false;
    }
    if (_windowListenerAdded) {
      windowManager.removeListener(this);
      _windowListenerAdded = false;
    }
    if (_preventCloseAttempted) {
      await _cleanup(() => windowManager.setPreventClose(false));
      _preventCloseAttempted = false;
    }
  }

  Future<void> _releaseTray() async {
    _windowsTrayPoll?.cancel();
    _windowsTrayPoll = null;
    _trayCreated = false;
    if (_trayListenerAdded) {
      trayManager.removeListener(this);
      _trayListenerAdded = false;
    }
    final availability = _linuxAvailability;
    _linuxAvailability = null;
    if (availability != null) await _cleanup(availability.dispose);
    if (_trayAttempted) {
      await _cleanup(trayManager.destroy);
      _trayAttempted = false;
    }
  }

  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _windowsTrayPoll?.cancel();
    // If startup is in flight, let it finish before releasing its resources.
    await _initialization;
    await _releaseTray();
    await _releaseWindowInterception();
  }

  @override
  Future<void> exitApplication() async {
    final response = await ServicesBinding.instance.exitApplication(
      AppExitType.required,
    );
    if (response == AppExitResponse.cancel) {
      throw StateError('The operating system canceled the required exit.');
    }
  }
}
