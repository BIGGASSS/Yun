import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Picks data roots, retaining sandbox grants across launches on macOS.
class DataDirectoryPicker {
  DataDirectoryPicker({MethodChannel? channel, TargetPlatform? platform})
    : _channel = channel ?? const MethodChannel('yun/data_directory'),
      _platform = platform ?? defaultTargetPlatform;

  final MethodChannel _channel;
  final TargetPlatform _platform;

  bool get _isMacOS => !kIsWeb && _platform == TargetPlatform.macOS;

  /// Await before opening the data-directory controller or reading either a
  /// migration source or target. Native restoration tries every saved grant;
  /// obsolete/unavailable grants do not prevent opening an unrelated root.
  /// Filesystem validation must still check access to the roots actually used.
  Future<void> restoreAccess() async {
    if (!_isMacOS) return;
    // Native may return per-bookmark warnings rather than failing restoration.
    await _channel.invokeMethod<Object?>('restoreAccess');
  }

  /// Returns null on cancellation. macOS returns only after retaining access
  /// and acknowledging bookmark persistence; native failures are propagated.
  Future<String?> pickDirectory({String? initialDirectory}) {
    if (_isMacOS) {
      return _channel.invokeMethod<String>('pickDirectory', {
        'initialDirectory': initialDirectory,
      });
    }
    return FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose data directory',
      initialDirectory: initialDirectory,
    );
  }
}
