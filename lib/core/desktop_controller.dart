import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/desktop_host.dart';
import '../services/desktop_settings_store.dart';

export '../services/desktop_settings_store.dart' show DesktopCloseBehavior;

bool get isDesktopPlatform =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      _ => false,
    };

/// Owns window-close policy, not playback. Hiding never shuts down the account,
/// stops the engine, or changes the queue. Explicit application quit always
/// checkpoints/shuts down, regardless of the saved window-close preference.
class DesktopController extends ChangeNotifier {
  DesktopController({
    required this._host,
    required this._settings,
    required this._shutdown,
    required this._checkpoint,
  });

  final DesktopHost _host;
  final DesktopSettingsStore _settings;
  final Future<void> Function() _shutdown;
  final Future<void> Function() _checkpoint;
  DesktopCloseBehavior _closeBehavior = DesktopCloseBehavior.quit;
  bool _trayAvailable = false;
  bool _hidden = false;
  bool _quitting = false;
  bool _disposed = false;
  int _pendingWrites = 0;
  String? _error;
  String? _shutdownError;
  Future<void>? _initializing,
      _writes,
      _visibility,
      _closeRequest,
      _quitRequest;
  Future<bool>? _shutdownRequest;
  Future<void>? _detachment;

  DesktopCloseBehavior get closeBehavior => _closeBehavior;
  bool get trayAvailable => _trayAvailable;
  bool get canMinimize =>
      _trayAvailable && !_quitting && _shutdownError == null;
  bool get isHidden => _hidden;
  bool get isQuitting => _quitting;
  bool get isSaving => _pendingWrites > 0;
  String? get error => _error;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    try {
      _closeBehavior = await _settings.readCloseBehavior();
    } catch (error) {
      _setError('Could not read desktop settings: $error');
    }
    if (_disposed) return;
    try {
      await _host.initialize(
        onClose: () => unawaited(requestWindowClose()),
        onShow: () => unawaited(showWindow()),
        onQuit: () => unawaited(quit()),
        onTrayAvailabilityChanged: _availabilityChanged,
        onError: (error) => _setError('Desktop integration: $error'),
      );
      if (!_disposed) {
        _availabilityChanged(await _host.checkTrayAvailability());
      }
    } catch (error) {
      _availabilityChanged(false);
      _setError('Desktop integration is unavailable: $error');
    }
    _notify();
  }

  Future<void> setCloseBehavior(DesktopCloseBehavior behavior) {
    if (_disposed || _quitting) return Future.value();
    _pendingWrites++;
    _notify();
    return _writes = (_writes ?? Future<void>.value()).then((_) async {
      try {
        await _settings.writeCloseBehavior(behavior);
        _closeBehavior = behavior;
        _error = null;
      } catch (error) {
        _setError('Could not save close behavior: $error');
      } finally {
        _pendingWrites--;
        _notify();
      }
    });
  }

  Future<void> flushSettings() async => await _writes;

  /// Await native teardown before a bootstrap retry creates a replacement.
  Future<void> detach() => _detachment ??= _host.dispose();

  void _availabilityChanged(bool available) {
    if (_disposed) return;
    _trayAvailable = available;
    _notify();
    if (!available && _hidden && !_quitting) {
      _setError('The system tray became unavailable. Yun has been restored.');
      unawaited(showWindow());
    }
  }

  /// Duplicate native events for one close gesture share a single operation.
  Future<void> requestWindowClose() {
    if (_disposed || _quitting) return Future.value();
    return _closeRequest ??= () async {
      // Honor a preference change already in flight before deciding to quit.
      await _writes;
      if (_disposed || _quitting) return;
      if (_closeBehavior == DesktopCloseBehavior.minimizeToTray) {
        await minimizeToTray();
      } else {
        await quit();
      }
    }().whenComplete(() => _closeRequest = null);
  }

  Future<void> _queueVisibility(Future<void> Function() action) {
    if (_disposed || _quitting) return Future.value();
    return _visibility = (_visibility ?? Future<void>.value()).then((_) async {
      if (_disposed || _quitting) return;
      try {
        await action();
      } catch (error) {
        _setError('Could not change window visibility: $error');
        // hide() can fail after partially hiding the window. Always try to
        // restore the only non-tray recovery path, even if our state says shown.
        try {
          await _host.show();
          _hidden = false;
        } catch (restoreError) {
          _setError('Could not restore the window: $restoreError');
        }
      }
      _notify();
    });
  }

  Future<void> minimizeToTray() => _queueVisibility(() async {
    // The account controller memoizes shutdown, including failure. Never hide
    // its partly shut-down UI again: later Quit cannot retry that durable work.
    if (_shutdownError != null) {
      _setError(_shutdownError!);
      await _host.show();
      _hidden = false;
      return;
    }
    if (_hidden) return;
    await _checkpoint();
    final available = await _host.checkTrayAvailability();
    _availabilityChanged(available);
    if (_disposed || _quitting) return;
    if (!available) {
      _setError(
        'No usable system tray is available. Yun was not hidden. '
        'You can still quit from Settings.',
      );
      return;
    }
    // Mark hidden before awaiting native hide so a concurrent watcher-loss
    // notification queues a restore AFTER this operation, never before it.
    _hidden = true;
    await _host.hide();
  });

  Future<void> showWindow() => _queueVisibility(() async {
    await _host.show();
    _hidden = false;
  });

  /// macOS Cmd-Q / Dock Quit and framework application exits bypass close-to-
  /// tray. The caller returns exit/cancel to Flutter after this future resolves.
  Future<bool> requestApplicationExit() =>
      _shutdownRequest ??= _prepareToExit();

  Future<bool> _prepareToExit() async {
    _quitting = true;
    _notify();
    try {
      await _initializing;
      await _visibility;
      await _writes;
      await _shutdown();
    } catch (error) {
      _quitting = false;
      _shutdownError = 'Could not quit safely: $error';
      _setError(_shutdownError!);
      await showWindow();
      return false;
    }
    // Failure to remove an icon must not prevent exit after durable shutdown.
    try {
      await detach();
    } catch (error) {
      _setError('Could not release desktop integration: $error');
    }
    return true;
  }

  /// Tray/Settings Quit: await all durable work, then request a REQUIRED platform
  /// exit. This avoids re-entering onExitRequested or the window-close policy.
  Future<void> quit() {
    if (_disposed) return Future.value();
    return _quitRequest ??= () async {
      if (!await requestApplicationExit()) return;
      try {
        await _host.exitApplication();
      } catch (error) {
        _quitting = false;
        _setError('Could not exit Yun: $error');
        await showWindow();
      }
    }().whenComplete(() => _quitRequest = null);
  }

  void clearError() {
    _error = null;
    _notify();
  }

  void _setError(String error) {
    if (_disposed) return;
    _error = error;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // Widget detachment is not an application exit. The bootstrap separately
    // owns account disposal; here release only desktop resources/listeners.
    unawaited(detach().catchError((Object _) {}));
    super.dispose();
  }
}
