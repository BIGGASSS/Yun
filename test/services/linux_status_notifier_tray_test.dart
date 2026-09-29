import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/services/linux_status_notifier_tray.dart';
import 'package:yun/services/linux_tray_availability.dart';

const _sni = LinuxStatusNotifierTray.itemInterface;
const _menu = LinuxStatusNotifierTray.menuInterface;
const _watcher = LinuxTrayAvailability.watcherInterface;

class _Watcher extends DBusObject {
  _Watcher() : super(LinuxTrayAvailability.watcherPath);
  DBusValue host = const DBusBoolean(true);
  final registrations = <DBusMethodCall>[];
  Completer<void>? registrationGate;
  bool reject = false;

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != _watcher || name != 'IsStatusNotifierHostRegistered') {
      return DBusMethodErrorResponse.unknownProperty();
    }
    return DBusGetPropertyResponse(host);
  }

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != _watcher ||
        call.name != 'RegisterStatusNotifierItem') {
      return DBusMethodErrorResponse.unknownMethod();
    }
    if (call.signature != DBusSignature('s')) {
      return DBusMethodErrorResponse.invalidArgs();
    }
    registrations.add(call);
    await registrationGate?.future;
    return reject
        ? DBusMethodErrorResponse.failed()
        : DBusMethodSuccessResponse();
  }

  Future<void> hostChanged() => emitPropertiesChanged(
    _watcher,
    changedProperties: {'IsStatusNotifierHostRegistered': host},
  );
}

Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for private bus');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Matcher _error(String name) => throwsA(
  isA<DBusMethodResponseException>().having(
    (error) => error.errorName,
    'errorName',
    'org.freedesktop.DBus.Error.$name',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Every connection is to this private server, never the host session bus.
  late DBusServer server;
  late DBusAddress address;
  late DBusClient provider;
  late DBusClient client;
  late DBusClient availabilityClient;
  late _Watcher watcher;
  late LinuxStatusNotifierTray tray;
  late List<bool> changes;
  late List<Object> errors;
  late int shows;
  late int quits;

  LinuxStatusNotifierTray createTray({
    bool decodePng = false,
    String? iconPath,
    Duration timeout = const Duration(seconds: 3),
    Duration poll = const Duration(hours: 1),
  }) => LinuxStatusNotifierTray(
    client: client,
    availability: LinuxTrayAvailability(
      client: availabilityClient,
      timeout: const Duration(seconds: 2),
      pollInterval: poll,
    ),
    iconPath: iconPath ?? File('assets/tray_icons/yun_linux.png').absolute.path,
    pixmap: decodePng
        ? null
        : LinuxTrayPixmap.fromRgba(2, 1, [
            0x12,
            0x34,
            0x56,
            0xff,
            0x78,
            0x9a,
            0xbc,
            0x80,
          ]),
    timeout: timeout,
    pollInterval: poll,
  );

  Future<void> start() => tray.initialize(
    onShow: () => shows++,
    onQuit: () => quits++,
    onChanged: changes.add,
    onError: errors.add,
  );

  Future<void> ownWatcher() async {
    await provider.requestName(LinuxTrayAvailability.watcherName);
  }

  DBusRemoteObject remote(DBusObjectPath path) =>
      DBusRemoteObject(provider, name: client.uniqueName, path: path);

  Future<DBusMethodSuccessResponse> itemCall(
    String name,
    List<DBusValue> values,
  ) => remote(LinuxStatusNotifierTray.itemPath).callMethod(_sni, name, values);
  Future<DBusMethodSuccessResponse> menuCall(
    String name,
    List<DBusValue> values,
  ) => remote(LinuxStatusNotifierTray.menuPath).callMethod(_menu, name, values);

  List<DBusValue> event(int id, String name) => [
    DBusInt32(id),
    DBusString(name),
    const DBusVariant(DBusString('untrusted payload: quit')),
    const DBusUint32(0),
  ];

  setUp(() async {
    server = DBusServer();
    address = await server.listenAddress(DBusAddress.tcp('127.0.0.1', port: 0));
    provider = DBusClient(address);
    client = DBusClient(address);
    availabilityClient = DBusClient(address);
    watcher = _Watcher();
    await provider.registerObject(watcher);
    changes = [];
    errors = [];
    shows = quits = 0;
    tray = createTray();
  });

  tearDown(() async {
    if (watcher.registrationGate case final gate? when !gate.isCompleted) {
      gate.complete();
    }
    await tray.dispose();
    await provider.close();
    await server.close();
  });

  test(
    'registers item and advertises non-menu SNI with full-color ARGB',
    () async {
      await ownWatcher();
      await start();
      expect(await tray.check(), isTrue);
      expect(changes.last, isTrue);
      expect(watcher.registrations, hasLength(1));
      expect(watcher.registrations.single.sender, client.uniqueName);
      expect(watcher.registrations.single.values, [
        DBusString('/StatusNotifierItem'),
      ]);
      final properties = await remote(LinuxStatusNotifierTray.itemPath)
          .getAllProperties(_sni);
      expect(properties['Id'], const DBusString('yun'));
      expect(properties['Title'], const DBusString('Yun'));
      expect(properties['Category'], const DBusString('ApplicationStatus'));
      expect(properties['Status'], const DBusString('Active'));
      expect(properties['ItemIsMenu'], const DBusBoolean(false));
      expect(properties['Menu'], LinuxStatusNotifierTray.menuPath);
      expect(
        properties['IconName'],
        DBusString(File('assets/tray_icons/yun_linux.png').absolute.path),
      );
      expect(properties['IconPixmap']!.signature, DBusSignature('a(iiay)'));
      final pixmap = properties['IconPixmap']!.asArray().single.asStruct();
      expect(pixmap.take(2), [const DBusInt32(2), const DBusInt32(1)]);
      expect(pixmap[2].asByteArray(), [
        0xff,
        0x12,
        0x34,
        0x56,
        0x80,
        0x78,
        0x9a,
        0xbc,
      ]);
      expect(properties['ToolTip']!.signature, DBusSignature('(sa(iiay)ss)'));
      expect(errors, isEmpty);
    },
  );

  test(
    'decodes the actual bundled PNG for hosts that require IconPixmap',
    () async {
      tray = createTray(decodePng: true);
      await ownWatcher();
      await start();
      final pixmaps = await remote(LinuxStatusNotifierTray.itemPath)
          .getProperty(_sni, 'IconPixmap');
      final fields = pixmaps.asArray().single.asStruct();
      expect(fields[0].asInt32(), 64);
      expect(fields[1].asInt32(), 64);
      expect(fields[2].asByteArray().length, 64 * 64 * 4);
      expect(fields[2].asByteArray().toSet().length, greaterThan(30));
    },
  );

  test(
    'decoded translucent colors use straight ARGB, not premultiplied',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'yun-tray-pixel-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final image = File('${directory.path}/red.png');
      // One RGBA pixel: red=255, green=blue=0, alpha=128.
      await image.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DQAAAEgQGALFXOsAAAAABJRU5ErkJggg==',
        ),
      );
      tray = createTray(decodePng: true, iconPath: image.path);
      await ownWatcher();
      await start();
      final pixmaps = await remote(LinuxStatusNotifierTray.itemPath)
          .getProperty(_sni, 'IconPixmap');
      final fields = pixmaps.asArray().single.asStruct();
      expect(fields[2].asByteArray(), [128, 255, 0, 0]);
    },
  );

  test(
    'primary activation restores only; right click does not show or quit',
    () async {
      await ownWatcher();
      await start();
      await itemCall('Activate', [const DBusInt32(-10), const DBusInt32(20)]);
      expect([shows, quits], [1, 0]);
      await itemCall('ContextMenu', [const DBusInt32(10), const DBusInt32(20)]);
      expect([shows, quits], [1, 0]);
      await itemCall('SecondaryActivate', [
        const DBusInt32(0),
        const DBusInt32(0),
      ]);
      expect([shows, quits], [2, 0]);
      for (final name in ['opened', 'closed', 'hovered', 'quit', 'Activate']) {
        await menuCall('Event', event(2, name));
      }
      expect(quits, 0);
      await menuCall('Event', event(1, 'clicked'));
      expect([shows, quits], [3, 0]);
      await menuCall('Event', event(2, 'clicked'));
      expect([shows, quits], [3, 1]);
    },
  );

  test(
    'DBusMenu layout, filters, properties and recursive variant signatures',
    () async {
      await start();
      final result = await menuCall('GetLayout', [
        const DBusInt32(0),
        const DBusInt32(-1),
        DBusArray.string([]),
      ]);
      expect(result.signature, DBusSignature('u(ia{sv}av)'));
      expect(result.returnValues[0], const DBusUint32(1));
      final root = result.returnValues[1].asStruct();
      expect(root[0], const DBusInt32(0));
      expect(
        root[1].asStringVariantDict()['children-display'],
        const DBusString('submenu'),
      );
      final children = root[2]
          .asArray()
          .map((v) => v.asVariant().asStruct())
          .toList();
      expect(children.map((c) => c[0].asInt32()), [1, 2]);
      expect(
        children.map((c) => c[1].asStringVariantDict()['label']!.asString()),
        ['Show Yun', 'Quit Yun'],
      );
      expect(children.every((c) => c[2].asArray().isEmpty), isTrue);
      final shallow = await menuCall('GetLayout', [
        const DBusInt32(0),
        const DBusInt32(0),
        DBusArray.string(['label']),
      ]);
      expect(
        shallow.returnValues[1].asStruct()[1].asStringVariantDict(),
        isEmpty,
      );
      expect(shallow.returnValues[1].asStruct()[2].asArray(), isEmpty);
      final groups = await menuCall('GetGroupProperties', [
        DBusArray.int32([1, 2, 100]),
        DBusArray.string(['label', 'nonexistent']),
      ]);
      expect(groups.signature, DBusSignature('a(ia{sv})'));
      expect(groups.returnValues.single.asArray(), hasLength(2));
      for (final entry in groups.returnValues.single.asArray()) {
        expect(entry.asStruct()[1].asStringVariantDict().keys, ['label']);
      }
      final all = await menuCall('GetGroupProperties', [
        DBusArray.int32([]),
        DBusArray.string([]),
      ]);
      expect(all.returnValues.single.asArray(), hasLength(3));
      final label = await menuCall('GetProperty', [
        const DBusInt32(2),
        const DBusString('label'),
      ]);
      expect(
        label.returnValues.single,
        const DBusVariant(DBusString('Quit Yun')),
      );
      final menuProperties = await remote(LinuxStatusNotifierTray.menuPath)
          .getAllProperties(_menu);
      expect(menuProperties['Version'], const DBusUint32(3));
      expect(menuProperties['TextDirection'], const DBusString('ltr'));
    },
  );

  test('group events and about-to-show report invalid IDs without dispatching them', () async {
    await start();
    final events = await menuCall('EventGroup', [
      DBusArray(DBusSignature('(isvu)'), [
        DBusStruct(event(999, 'clicked')),
        DBusStruct(event(2, 'hovered')),
        DBusStruct(event(1, 'clicked')),
      ]),
    ]);
    expect(events.returnValues.single.asInt32Array(), [999]);
    expect([shows, quits], [1, 0]);
    await menuCall('Event', event(0, 'clicked'));
    expect([shows, quits], [1, 0]);
    final about = await menuCall('AboutToShow', [const DBusInt32(0)]);
    expect(about.returnValues, [const DBusBoolean(false)]);
    final group = await menuCall('AboutToShowGroup', [
      DBusArray.int32([0, 1, 2, -1, 999]),
    ]);
    expect(group.signature, DBusSignature('aiai'));
    expect(group.returnValues[0].asInt32Array(), isEmpty);
    expect(group.returnValues[1].asInt32Array(), [-1, 999]);
  });

  test(
    'introspection is complete and all method signatures are validated',
    () async {
      await start();
      for (final path in [
        LinuxStatusNotifierTray.itemPath,
        LinuxStatusNotifierTray.menuPath,
      ]) {
        final object = remote(path);
        final interface = path == LinuxStatusNotifierTray.itemPath
            ? _sni
            : _menu;
        final node = await object.introspect();
        final exported = node.interfaces.singleWhere(
          (i) => i.name == interface,
        );
        expect(exported.methods, isNotEmpty);
        expect(exported.properties, isNotEmpty);
        for (final method in exported.methods) {
          await expectLater(
            object.callMethod(interface, method.name, [
              const DBusBoolean(true),
            ]),
            _error('InvalidArgs'),
          );
        }
        await expectLater(
          object.callMethod(interface, 'RunCommand', [
            const DBusString('quit'),
          ]),
          _error('UnknownMethod'),
        );
        await expectLater(
          object.callMethod('yun.Untrusted', 'Activate', []),
          _error('UnknownInterface'),
        );
        await expectLater(
          object.getProperty(interface, 'Unknown'),
          _error('UnknownProperty'),
        );
        await expectLater(
          object.getAllProperties('yun.Untrusted'),
          _error('UnknownInterface'),
        );
        await expectLater(
          object.setProperty(
            interface,
            exported.properties.first.name,
            const DBusString('modified'),
          ),
          _error('PropertyReadOnly'),
        );
      }
      await expectLater(
        itemCall('Scroll', [const DBusInt32(1), const DBusString('vertical')]),
        _error('NotSupported'),
      );
      for (final (method, values) in <(String, List<DBusValue>)>[
        (
          'GetLayout',
          [const DBusInt32(99), const DBusInt32(-1), DBusArray.string([])],
        ),
        (
          'GetLayout',
          [const DBusInt32(0), const DBusInt32(-2), DBusArray.string([])],
        ),
        ('GetProperty', [const DBusInt32(99), const DBusString('label')]),
        ('Event', event(99, 'clicked')),
        ('AboutToShow', [const DBusInt32(99)]),
      ]) {
        await expectLater(menuCall(method, values), _error('InvalidArgs'));
      }
      await expectLater(
        menuCall('GetProperty', [
          const DBusInt32(1),
          const DBusString('nonexistent'),
        ]),
        _error('UnknownProperty'),
      );
      expect([shows, quits], [0, 0]);
    },
  );

  test(
    'startup without watcher stays unavailable; later watcher registers',
    () async {
      await start();
      expect(changes, [false]);
      expect(await tray.check(), isFalse);
      expect(watcher.registrations, isEmpty);
      await ownWatcher();
      await _eventually(() => changes.last);
      expect(watcher.registrations, hasLength(1));
      expect(errors, isEmpty);
    },
  );

  test(
    'a registered item without a host cannot enable hiding; signals recover',
    () async {
      watcher.host = const DBusBoolean(false);
      await ownWatcher();
      await start();
      expect(watcher.registrations, hasLength(1));
      expect(await tray.check(), isFalse);
      expect(changes, [false]);
      watcher.host = const DBusBoolean(true);
      await watcher.hostChanged();
      await _eventually(() => changes.last);
      watcher.host = const DBusBoolean(false);
      await watcher.hostChanged();
      await _eventually(() => !changes.last);
      expect(await tray.check(), isFalse);
    },
  );

  test('registration refusal and timeout never imply availability; polling retries', () async {
    watcher.reject = true;
    tray = createTray(
      poll: const Duration(milliseconds: 40),
      timeout: const Duration(milliseconds: 350),
    );
    await ownWatcher();
    await start();
    expect(changes, [false]);
    expect(await tray.check(), isFalse);
    expect(errors, isNotEmpty);
    watcher.reject = false;
    watcher.registrationGate = Completer<void>();
    expect(await tray.check(), isFalse);
    expect(errors.whereType<TimeoutException>(), isNotEmpty);
    expect(changes, [false]);
    watcher.registrationGate!.complete();
    await _eventually(() => changes.last);
    expect(await tray.check(), isTrue);
  });

  test('malformed host properties fail closed', () async {
    watcher.host = const DBusString('true');
    await ownWatcher();
    await start();
    expect(await tray.check(), isFalse);
    expect(changes, [false]);
    expect(errors, isNotEmpty);
  });

  test(
    'watcher restart invalidates immediately and re-registers with new owner',
    () async {
      await ownWatcher();
      await start();
      expect(changes.last, isTrue);
      final replacement = DBusClient(address);
      final replacementWatcher = _Watcher()
        ..registrationGate = Completer<void>();
      try {
        await replacement.registerObject(replacementWatcher);
        await provider.releaseName(LinuxTrayAvailability.watcherName);
        await _eventually(() => !changes.last);
        await replacement.requestName(LinuxTrayAvailability.watcherName);
        await _eventually(() => replacementWatcher.registrations.isNotEmpty);
        expect(
          changes.last,
          isFalse,
        ); // Host exists; our registration is pending.
        replacementWatcher.registrationGate!.complete();
        await _eventually(() => changes.last);
        expect(
          replacementWatcher.registrations.single.sender,
          client.uniqueName,
        );
        expect(watcher.registrations, hasLength(1));
      } finally {
        if (!replacementWatcher.registrationGate!.isCompleted) {
          replacementWatcher.registrationGate!.complete();
        }
        await replacement.close();
      }
    },
  );

  test(
    'disposal closes both owned connections and suppresses late registration',
    () async {
      await ownWatcher();
      watcher.registrationGate = Completer<void>();
      final starting = start();
      await _eventually(() => watcher.registrations.isNotEmpty);
      final itemName = client.uniqueName;
      final monitorName = availabilityClient.uniqueName;
      final snapshot = List<bool>.of(changes);
      final disposing = tray.dispose();
      expect(identical(disposing, tray.dispose()), isTrue);
      watcher.registrationGate!.complete();
      await starting;
      await disposing;
      expect(await provider.getNameOwner(itemName), isNull);
      expect(await provider.getNameOwner(monitorName), isNull);
      expect(await tray.check(), isFalse);
      expect(changes, snapshot);
      expect([shows, quits], [0, 0]);
      await expectLater(
        itemCall('Activate', [const DBusInt32(0), const DBusInt32(0)]),
        throwsA(isA<DBusMethodResponseException>()),
      );
      expect(errors, isEmpty);
    },
  );

  test(
    'disposal cancels lifetime polling and is safe before initialization',
    () async {
      tray = createTray(poll: const Duration(milliseconds: 30));
      await ownWatcher();
      await start();
      await tray.dispose();
      final count = watcher.registrations.length;
      final snapshot = List<bool>.of(changes);
      await provider.releaseName(LinuxTrayAvailability.watcherName);
      await ownWatcher();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(watcher.registrations, hasLength(count));
      expect(changes, snapshot);
      final unusedClient = DBusClient(address);
      final unusedAvailabilityClient = DBusClient(address);
      final unused = LinuxStatusNotifierTray(
        client: unusedClient,
        availability: LinuxTrayAvailability(client: unusedAvailabilityClient),
      );
      await unused.dispose();
      await unused.initialize(
        onShow: () => fail('disposed'),
        onQuit: () => fail('disposed'),
        onChanged: (_) => fail('disposed'),
        onError: (_) => fail('disposed'),
      );
      expect(await unused.check(), isFalse);
    },
  );
}
