import 'dart:async';

import 'package:dbus/dbus.dart';

/// Checks for a real StatusNotifier host, not merely an installed tray plugin.
///
/// A supplied [client] may connect to a private bus in tests. This object owns
/// that connection and closes it on disposal. No native tray APIs are used here.
class LinuxTrayAvailability {
  LinuxTrayAvailability({
    DBusClient? client,
    this.timeout = const Duration(seconds: 2),
    this.pollInterval = const Duration(seconds: 5),
  }) : _client = client ?? DBusClient.session();

  static const watcherName = 'org.kde.StatusNotifierWatcher';
  static const watcherInterface = 'org.kde.StatusNotifierWatcher';
  static final watcherPath = DBusObjectPath('/StatusNotifierWatcher');

  final DBusClient _client;
  final Duration timeout;
  final Duration pollInterval;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _poll;
  void Function(bool)? _onChanged;
  void Function(Object)? _onError;
  bool? _available;
  bool _disposed = false;
  bool _started = false;
  bool _refreshing = false;
  int _revision = 0;
  Future<void>? _disposal;

  Future<void> initialize({
    required void Function(bool) onChanged,
    required void Function(Object) onError,
  }) async {
    if (_started || _disposed) return;
    _started = true;
    _onChanged = onChanged;
    _onError = onError;

    // dbus 0.7 also starts asynchronous AddMatch requests from Stream.listen.
    // Keep even those subscription-setup errors inside our error boundary.
    runZonedGuarded(() {
      _subscriptions.add(
        _client.nameOwnerChanged.listen((event) {
          if (event.name == watcherName) _invalidate();
        }, onError: _busError),
      );
      final watcher = DBusRemoteObject(
        _client,
        name: watcherName,
        path: watcherPath,
      );
      _subscriptions.add(
        watcher.propertiesChanged.listen((signal) {
          if (signal.propertiesInterface == watcherInterface &&
              (signal.changedProperties.containsKey(
                    'IsStatusNotifierHostRegistered',
                  ) ||
                  signal.invalidatedProperties.contains(
                    'IsStatusNotifierHostRegistered',
                  ))) {
            _invalidate();
          }
        }, onError: _busError),
      );
      _subscriptions.add(
        DBusSignalStream(
          _client,
          sender: watcherName,
          path: watcherPath,
          interface: watcherInterface,
        ).listen((signal) {
          if (signal.name == 'StatusNotifierHostRegistered' ||
              signal.name == 'StatusNotifierHostUnregistered') {
            _invalidate();
          }
        }, onError: _busError),
      );
    }, (error, stack) => _busError(error));

    // Some watcher implementations never emit host-unregistered or property
    // signals. Poll for the lifetime of the process, even while visible.
    _poll = Timer.periodic(pollInterval, (_) => _refresh());
    await check();
  }

  void _invalidate() {
    if (_disposed) return;
    _revision++;
    // Restore promptly on loss/uncertainty, before waiting on another bus call.
    _publish(false);
    _refresh();
  }

  void _busError(Object error) {
    if (_disposed) return;
    _revision++;
    _publish(false);
    _report(error);
  }

  void _refresh() {
    if (_disposed || _refreshing) return;
    _refreshing = true;
    unawaited(() async {
      try {
        await check();
      } finally {
        _refreshing = false;
      }
    }());
  }

  /// Always probes the bus afresh, with a deadline for the entire probe.
  Future<bool> check() async {
    if (_disposed) return false;
    final revision = _revision;
    var available = false;
    try {
      available = await _probe().timeout(timeout);
    } catch (error) {
      // Missing watchers are normal; getNameOwner returns null in that case.
      // Malformed properties, a disconnected bus and timeouts are diagnostics.
      if (!_disposed) _report(error);
    }
    if (_disposed) return false;
    available = available && revision == _revision;
    _publish(available);
    return available;
  }

  Future<bool> _probe() async {
    final owner = await _client.getNameOwner(watcherName);
    if (owner == null || owner.isEmpty || _disposed) return false;
    // Query the unique owner so a restarted watcher cannot answer a probe
    // intended for its predecessor.
    final watcher = DBusRemoteObject(_client, name: owner, path: watcherPath);
    final registered = await watcher.getProperty(
      watcherInterface,
      'IsStatusNotifierHostRegistered',
      signature: DBusSignature('b'),
    );
    if (!registered.asBoolean() || _disposed) return false;
    return await _client.getNameOwner(watcherName) == owner;
  }

  void _publish(bool available) {
    if (_disposed || _available == available) return;
    _available = available;
    unawaited(
      Future<void>.sync(() => _onChanged?.call(available))
          .catchError((Object error) => _report(error)),
    );
  }

  void _report(Object error) {
    // The application's error reporter must not create another unhandled error.
    unawaited(
      Future<void>.sync(() => _onError?.call(error)).catchError((Object _) {}),
    );
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _revision++;
    _poll?.cancel();
    for (final subscription in _subscriptions) {
      try {
        await subscription.cancel().timeout(timeout);
      } catch (error) {
        _report(error);
      }
    }
    _subscriptions.clear();
    try {
      await _client.close().timeout(timeout);
    } catch (error) {
      _report(error);
    }
  }
}
