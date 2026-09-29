import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dbus/dbus.dart';
import 'package:path/path.dart' as p;

import 'linux_tray_availability.dart';

/// Injectable Linux-only adapter; no AppIndicator/native tray is created.
abstract interface class LinuxDesktopTray {
  Future<void> initialize({
    required void Function() onShow,
    required void Function() onQuit,
    required void Function(bool) onChanged,
    required void Function(Object) onError,
  });
  Future<bool> check();
  Future<void> dispose();
}

/// SNI uses network-order ARGB, not Flutter's raw RGBA byte order.
class LinuxTrayPixmap {
  LinuxTrayPixmap(this.width, this.height, List<int> argb)
    : argb = Uint8List.fromList(argb) {
    if (width <= 0 || height <= 0 || argb.length != width * height * 4) {
      throw ArgumentError('Invalid tray pixmap dimensions');
    }
  }

  factory LinuxTrayPixmap.fromRgba(int width, int height, List<int> rgba) {
    if (rgba.length != width * height * 4) {
      throw ArgumentError('Invalid RGBA length');
    }
    final argb = Uint8List(rgba.length);
    for (var i = 0; i < rgba.length; i += 4) {
      argb[i] = rgba[i + 3];
      argb[i + 1] = rgba[i];
      argb[i + 2] = rgba[i + 1];
      argb[i + 3] = rgba[i + 2];
    }
    return LinuxTrayPixmap(width, height, argb);
  }

  final int width;
  final int height;
  final Uint8List argb;

  DBusStruct get value =>
      DBusStruct([DBusInt32(width), DBusInt32(height), DBusArray.byte(argb)]);
}

/// Owns both bus connections (including a supplied availability monitor).
/// Availability requires an acknowledged registration with the *current*
/// watcher, as well as a real registered host. All probes fail closed.
class LinuxStatusNotifierTray implements LinuxDesktopTray {
  LinuxStatusNotifierTray({
    DBusClient? client,
    LinuxTrayAvailability? availability,
    String? iconPath,
    this._pixmap,
    this.timeout = const Duration(seconds: 2),
    this.pollInterval = const Duration(seconds: 5),
  }) : _client = client ?? DBusClient.session(),
       _availability = availability ?? LinuxTrayAvailability(),
       iconPath = p.absolute(
         iconPath ??
             p.join(
               p.dirname(Platform.resolvedExecutable),
               'data/flutter_assets/assets/tray_icons/yun_linux.png',
             ),
       );

  static const itemInterface = 'org.kde.StatusNotifierItem';
  static const menuInterface = 'com.canonical.dbusmenu';
  static final itemPath = DBusObjectPath('/StatusNotifierItem');
  static final menuPath = DBusObjectPath('/Menu');
  final DBusClient _client;
  final LinuxTrayAvailability _availability;
  final String iconPath;
  final LinuxTrayPixmap? _pixmap;
  final Duration timeout;
  final Duration pollInterval;
  _Item? _item;
  _Menu? _menu;
  StreamSubscription<dynamic>? _owners;
  Timer? _poll;
  Future<void>? _initialization;
  Future<void>? _disposal;
  Future<bool>? _checking;
  String? _registeredOwner;
  int _revision = 0;
  bool _ready = false;
  bool _disposed = false;
  bool? _available;
  void Function()? _onShow;
  void Function()? _onQuit;
  void Function(bool)? _onChanged;
  void Function(Object)? _onError;

  @override
  Future<void> initialize({
    required void Function() onShow,
    required void Function() onQuit,
    required void Function(bool) onChanged,
    required void Function(Object) onError,
  }) {
    if (_disposed) return Future.value();
    _onShow = onShow;
    _onQuit = onQuit;
    _onChanged = onChanged;
    _onError = onError;
    return _initialization ??= _initialize();
  }

  Future<LinuxTrayPixmap> _loadPixmap() async {
    final codec = await ui.instantiateImageCodec(
      await File(iconPath).readAsBytes(),
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final bytes = await frame.image.toByteData(
          // SNI consumers use straight ARGB32, not premultiplied colors.
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        if (bytes == null) throw StateError('Cannot decode tray PNG');
        return LinuxTrayPixmap.fromRgba(
          frame.image.width,
          frame.image.height,
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  Future<void> _initialize() async {
    _publish(false);
    final pixmap = _pixmap ?? await _loadPixmap().timeout(timeout);
    if (_disposed) return;
    _item = _Item(iconPath, pixmap, () => _dispatch(_onShow));
    _menu = _Menu(() => _dispatch(_onShow), () => _dispatch(_onQuit));
    await _client.registerObject(_item!).timeout(timeout);
    if (_disposed) return;
    await _client.registerObject(_menu!).timeout(timeout);
    if (_disposed) return;
    // dbus starts AddMatch asynchronously when a stream is listened to.
    runZonedGuarded(() {
      _owners = _client.nameOwnerChanged.listen((event) {
        if (event.name != LinuxTrayAvailability.watcherName || _disposed) {
          return;
        }
        _revision++;
        _registeredOwner = null;
        _publish(false);
        // A previous owner's in-flight registration cannot satisfy this one.
        unawaited(check().then((_) => _refresh()));
      }, onError: _busError);
    }, (error, stack) => _busError(error));
    await _availability.initialize(
      onChanged: (available) {
        if (!available) _publish(false);
        _refresh();
      },
      onError: _busError,
    );
    if (_disposed) return;
    _ready = true;
    _poll = Timer.periodic(pollInterval, (_) => _refresh());
    await check();
  }

  void _refresh() {
    if (!_ready || _disposed) return;
    unawaited(check());
  }

  void _busError(Object error) {
    if (_disposed) return;
    _revision++;
    _registeredOwner = null;
    _publish(false);
    _report(error);
  }

  @override
  Future<bool> check() {
    if (_disposed || !_ready) return Future.value(false);
    return _checking ??= _check().whenComplete(() => _checking = null);
  }

  Future<bool> _check() async {
    final revision = _revision;
    var available = false;
    try {
      available = await _probe(revision).timeout(timeout);
    } catch (error) {
      if (!_disposed) {
        // A timed-out registration must not later mark itself successful.
        _revision++;
        _registeredOwner = null;
        _report(error);
      }
    }
    available = available && !_disposed && revision == _revision;
    _publish(available);
    return available;
  }

  bool _current(int revision) => !_disposed && revision == _revision;

  Future<bool> _probe(int revision) async {
    final owner = await _client.getNameOwner(LinuxTrayAvailability.watcherName);
    if (!_current(revision) || owner == null || owner.isEmpty) return false;
    if (_registeredOwner != owner) {
      _registeredOwner = null;
      final watcher = DBusRemoteObject(
        _client,
        name: owner,
        path: LinuxTrayAvailability.watcherPath,
      );
      await watcher.callMethod(
        LinuxTrayAvailability.watcherInterface,
        'RegisterStatusNotifierItem',
        [DBusString(itemPath.value)],
        replySignature: DBusSignature(''),
      );
      if (!_current(revision)) return false;
      if (await _client.getNameOwner(LinuxTrayAvailability.watcherName) !=
              owner ||
          !_current(revision)) {
        return false;
      }
      _registeredOwner = owner;
    }
    if (!await _availability.check() || !_current(revision)) return false;
    return await _client.getNameOwner(LinuxTrayAvailability.watcherName) ==
            owner &&
        _current(revision) &&
        _registeredOwner == owner;
  }

  void _dispatch(void Function()? callback) {
    if (_disposed) return;
    unawaited(Future<void>.sync(() => callback?.call()).catchError(_report));
  }

  void _publish(bool available) {
    if (_disposed || _available == available) return;
    _available = available;
    _dispatch(() => _onChanged?.call(available));
  }

  void _report(Object error) {
    if (_disposed) return;
    unawaited(
      Future<void>.sync(() => _onError?.call(error)).catchError((Object _) {}),
    );
  }

  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _revision++;
    _ready = false;
    _poll?.cancel();
    // Startup has bounded awaits and checks disposal before adding resources.
    try {
      await _initialization;
    } catch (_) {
      /* Caller reports setup failure. */
    }
    try {
      await _owners?.cancel().timeout(timeout);
    } catch (_) {
      /* Close below. */
    }
    try {
      await _availability.dispose();
    } finally {
      // Closing the connection removes both exported objects and registration.
      await _client.close().timeout(timeout);
    }
  }
}

/// Shared strict dispatch and read-only Properties/Introspectable support.
abstract class _Export extends DBusObject {
  _Export(super.path, this.interface, this.properties, this.methods);
  final String interface;
  final Map<String, DBusValue> properties;
  final Map<String, (String, String)> methods;

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      interface,
      properties: properties.entries
          .map(
            (e) => DBusIntrospectProperty(
              e.key,
              e.value.signature,
              access: DBusPropertyAccess.read,
            ),
          )
          .toList(),
      methods: methods.entries
          .map(
            (e) => DBusIntrospectMethod(
              e.key,
              args: [
                ...DBusSignature(e.value.$1).split().map(
                  (s) => DBusIntrospectArgument(s, DBusArgumentDirection.in_),
                ),
                ...DBusSignature(e.value.$2).split().map(
                  (s) => DBusIntrospectArgument(s, DBusArgumentDirection.out),
                ),
              ],
            ),
          )
          .toList(),
    ),
  ];

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != this.interface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final value = properties[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async =>
      interface == this.interface
      ? DBusGetAllPropertiesResponse(properties)
      : DBusMethodErrorResponse.unknownInterface();

  @override
  Future<DBusMethodResponse> setProperty(
    String interface,
    String name,
    DBusValue value,
  ) async {
    if (interface != this.interface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    return properties.containsKey(name)
        ? DBusMethodErrorResponse.propertyReadOnly()
        : DBusMethodErrorResponse.unknownProperty();
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != null && call.interface != interface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    final method = methods[call.name];
    if (method == null) return DBusMethodErrorResponse.unknownMethod();
    if (call.signature != DBusSignature(method.$1)) {
      return DBusMethodErrorResponse.invalidArgs();
    }
    return invoke(call.name, call.values);
  }

  DBusMethodResponse invoke(String name, List<DBusValue> values);
}

DBusArray _pixmaps(LinuxTrayPixmap pixmap) =>
    DBusArray(DBusSignature('(iiay)'), [pixmap.value]);

class _Item extends _Export {
  _Item(String icon, LinuxTrayPixmap pixmap, this.show)
    : super(
        LinuxStatusNotifierTray.itemPath,
        LinuxStatusNotifierTray.itemInterface,
        {
          'Category': const DBusString('ApplicationStatus'),
          'Id': const DBusString('yun'),
          'Title': const DBusString('Yun'),
          'Status': const DBusString('Active'),
          'WindowId': const DBusUint32(0),
          'IconName': DBusString(icon),
          'IconPixmap': _pixmaps(pixmap),
          'OverlayIconName': const DBusString(''),
          'OverlayIconPixmap': DBusArray(DBusSignature('(iiay)'), []),
          'AttentionIconName': const DBusString(''),
          'AttentionIconPixmap': DBusArray(DBusSignature('(iiay)'), []),
          'AttentionMovieName': const DBusString(''),
          'ToolTip': DBusStruct([
            DBusString(icon),
            _pixmaps(pixmap),
            const DBusString('Yun'),
            const DBusString(''),
          ]),
          'ItemIsMenu': const DBusBoolean(false),
          'Menu': LinuxStatusNotifierTray.menuPath,
        },
        {
          'Activate': ('ii', ''),
          'SecondaryActivate': ('ii', ''),
          'ContextMenu': ('ii', ''),
          'Scroll': ('is', ''),
        },
      );
  final void Function() show;

  @override
  DBusMethodResponse invoke(String name, List<DBusValue> values) {
    if (name == 'Activate' || name == 'SecondaryActivate') show();
    // Hosts render the advertised DBusMenu on right-click. ContextMenu must
    // never accidentally activate Show or Quit; there is no native popup API.
    if (name == 'Scroll') return DBusMethodErrorResponse.notSupported();
    return DBusMethodSuccessResponse();
  }
}

class _Menu extends _Export {
  _Menu(this.show, this.quit)
    : super(
        LinuxStatusNotifierTray.menuPath,
        LinuxStatusNotifierTray.menuInterface,
        {
          'Version': const DBusUint32(3),
          'TextDirection': const DBusString('ltr'),
          'Status': const DBusString('normal'),
          'IconThemePath': DBusArray.string([]),
        },
        {
          'GetLayout': ('iias', 'u(ia{sv}av)'),
          'GetGroupProperties': ('aias', 'a(ia{sv})'),
          'GetProperty': ('is', 'v'),
          'Event': ('isvu', ''),
          'EventGroup': ('a(isvu)', 'ai'),
          'AboutToShow': ('i', 'b'),
          'AboutToShowGroup': ('ai', 'aiai'),
        },
      );
  final void Function() show;
  final void Function() quit;
  // Stable IDs: root=0, Show=1, Quit=2. No dynamic/untrusted action lookup.
  static const _nodes = <int, Map<String, DBusValue>>{
    0: {'children-display': DBusString('submenu')},
    1: {
      'label': DBusString('Show Yun'),
      'enabled': DBusBoolean(true),
      'visible': DBusBoolean(true),
    },
    2: {
      'label': DBusString('Quit Yun'),
      'enabled': DBusBoolean(true),
      'visible': DBusBoolean(true),
    },
  };

  DBusDict _properties(int id, List<String> filter) => DBusDict.stringVariant({
    for (final entry in _nodes[id]!.entries)
      if (filter.isEmpty || filter.contains(entry.key)) entry.key: entry.value,
  });

  DBusStruct _layout(int id, int depth, List<String> filter) => DBusStruct([
    DBusInt32(id),
    _properties(id, filter),
    DBusArray(DBusSignature('v'), [
      if (id == 0 && depth != 0)
        for (final child in [1, 2])
          DBusVariant(_layout(child, depth < 0 ? -1 : depth - 1, filter)),
    ]),
  ]);

  bool _event(List<DBusValue> values) {
    final id = values[0].asInt32();
    if (!_nodes.containsKey(id)) return false;
    if (values[1].asString() == 'clicked') {
      if (id == 1) show();
      if (id == 2) quit();
    }
    return true;
  }

  @override
  DBusMethodResponse invoke(String name, List<DBusValue> values) {
    DBusMethodResponse success(List<DBusValue> values) =>
        DBusMethodSuccessResponse(values);
    final badId = DBusMethodErrorResponse.invalidArgs('Unknown menu ID');
    switch (name) {
      case 'GetLayout':
        final id = values[0].asInt32();
        final depth = values[1].asInt32();
        if (!_nodes.containsKey(id)) return badId;
        if (depth < -1) {
          return DBusMethodErrorResponse.invalidArgs('Invalid recursion depth');
        }
        return success([
          const DBusUint32(1),
          _layout(id, depth, values[2].asStringArray().toList()),
        ]);
      case 'GetGroupProperties':
        final requested = values[0].asInt32Array().toList();
        final ids = requested.isEmpty ? _nodes.keys.toList() : requested;
        final filter = values[1].asStringArray().toList();
        // Per DBusMenu, invalid IDs are omitted from this group response.
        return success([
          DBusArray(DBusSignature('(ia{sv})'), [
            for (final id in ids)
              if (_nodes.containsKey(id))
                DBusStruct([DBusInt32(id), _properties(id, filter)]),
          ]),
        ]);
      case 'GetProperty':
        final id = values[0].asInt32();
        if (!_nodes.containsKey(id)) return badId;
        final property = _nodes[id]![values[1].asString()];
        return property == null
            ? DBusMethodErrorResponse.unknownProperty()
            : success([DBusVariant(property)]);
      case 'Event':
        return _event(values) ? success([]) : badId;
      case 'EventGroup':
        final errors = <int>[];
        for (final event in values[0].asArray()) {
          final fields = event.asStruct();
          if (!_event(fields)) errors.add(fields[0].asInt32());
        }
        return success([DBusArray.int32(errors)]);
      case 'AboutToShow':
        if (!_nodes.containsKey(values[0].asInt32())) return badId;
        return success([const DBusBoolean(false)]);
      case 'AboutToShowGroup':
        return success([
          DBusArray.int32([]),
          DBusArray.int32([
            for (final id in values[0].asInt32Array())
              if (!_nodes.containsKey(id)) id,
          ]),
        ]);
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }
}
