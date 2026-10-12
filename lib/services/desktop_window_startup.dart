import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

const _startupChannel = MethodChannel('yun/desktop_startup');

bool get _isDesktop =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      _ => false,
    };

/// Defer native first-frame reveal until sizing completes, independently of
/// account/library startup. The launch callback also makes this order testable.
Future<void> launchWithDesktopWindow(VoidCallback runApplication) async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final desktop = _isDesktop;
  if (desktop) binding.deferFirstFrame();
  try {
    if (desktop) await configureDesktopWindow();
  } finally {
    // Sizing is best effort: never block the library or its recovery screen.
    try {
      runApplication();
    } finally {
      if (desktop) binding.allowFirstFrame();
    }
  }
  if (desktop) {
    unawaited(
      binding.waitUntilFirstFrameRasterized.then((_) => revealDesktopWindow()),
    );
  }
}

/// Initial geometry in logical pixels; never impose a minimum window size.
/// Windows/macOS bounds include decorations. GTK's size excludes its titlebar,
/// so reserve space for that within the same outer-window budget.
Rect initialDesktopWindowBounds(Display display, {bool gtk = false}) {
  final size = display.visibleSize ?? display.size;
  final origin = display.visiblePosition ?? Offset.zero;
  if (!size.width.isFinite ||
      !size.height.isFinite ||
      size.width <= 0 ||
      size.height <= 0 ||
      !origin.dx.isFinite ||
      !origin.dy.isFinite) {
    throw StateError('The desktop work area is invalid.');
  }

  final widthBudget = math.max(1.0, (size.width * .9).floorToDouble());
  final heightBudget = math.max(1.0, (size.height * .9).floorToDouble());
  final decorations = gtk ? math.min(48.0, heightBudget - 1) : 0.0;
  final width = math.min(1280.0, widthBudget);
  final height = math.min(720.0, heightBudget - decorations);
  return Rect.fromLTWH(
    origin.dx + (size.width - width) / 2,
    origin.dy + (size.height - height - decorations) / 2,
    width,
    height,
  );
}

/// Call before runApp, with the first frame deferred. Native runners provide a
/// fitted fallback, and still reveal the window if these optional plugins fail.
Future<void> configureDesktopWindow({
  Map<String, String>? environment,
  Duration timeout = const Duration(seconds: 3),
}) async {
  if (!_isDesktop) return;
  final platform = defaultTargetPlatform;

  // Keep all calculations on the primary display. windowManager.center() would
  // independently choose the cursor's monitor, possibly with a different DPI.
  var active = true;
  Future<void> configure() async {
    await windowManager.ensureInitialized();
    if (!active) return;
    final display = await screenRetriever.getPrimaryDisplay();
    if (!active) return;
    final bounds = initialDesktopWindowBounds(
      display,
      gtk: platform == TargetPlatform.linux,
    );
    final env = environment ?? Platform.environment;
    final wayland =
        platform == TargetPlatform.linux &&
        (env['XDG_SESSION_TYPE'] == 'wayland' ||
            (env['WAYLAND_DISPLAY']?.isNotEmpty ?? false));
    if (wayland) {
      // Wayland has no application-controlled absolute window placement.
      await windowManager.setSize(bounds.size);
    } else {
      await windowManager.setBounds(bounds);
    }
  }

  try {
    await configure().timeout(timeout);
  } catch (error) {
    debugPrint(
      'Desktop window sizing unavailable; using native defaults: $error',
    );
  } finally {
    // A slow display lookup must not move/resize a window after it is revealed.
    active = false;
  }
}

/// The macOS nib starts its engine while transparent. Reveal its already-sized
/// window only after the first Flutter frame; its native timer is a fail-safe.
Future<void> revealDesktopWindow() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) return;
  try {
    await _startupChannel.invokeMethod<void>('ready');
  } catch (error) {
    debugPrint('Desktop first-frame reveal unavailable: $error');
  }
}
