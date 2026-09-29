import 'package:yun/services/desktop_host.dart';

/// Native-boundary fake: policy tests intentionally do not model window-manager
/// details such as restoring an OS-minimized window or focusing it.
class FakeDesktopHost implements DesktopHost {
  FakeDesktopHost(this.events);

  final List<String> events;
  bool available = true;
  bool visible = true;
  Future<void> Function(String operation)? before;
  void Function()? onClose, onShow, onQuit;
  void Function(bool)? onTrayAvailabilityChanged;
  void Function(Object)? onError;

  Future<void> _call(String operation) async {
    events.add(operation);
    await before?.call(operation);
  }

  @override
  Future<void> initialize({
    required void Function() onClose,
    required void Function() onShow,
    required void Function() onQuit,
    required void Function(bool) onTrayAvailabilityChanged,
    required void Function(Object) onError,
  }) async {
    this.onClose = onClose;
    this.onShow = onShow;
    this.onQuit = onQuit;
    this.onTrayAvailabilityChanged = onTrayAvailabilityChanged;
    this.onError = onError;
    await _call('initialize');
  }

  @override
  Future<bool> checkTrayAvailability() async {
    await _call('availability');
    return available;
  }

  void changeAvailability(bool value) {
    available = value;
    onTrayAvailabilityChanged?.call(value);
  }

  @override
  Future<void> hide() async {
    await _call('hide');
    visible = false;
  }

  @override
  Future<void> show() async {
    await _call('show');
    visible = true;
  }

  @override
  Future<void> dispose() => _call('dispose');

  @override
  Future<void> exitApplication() => _call('exit');
}
