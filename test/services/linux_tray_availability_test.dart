import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/services/linux_tray_availability.dart';

const _property = 'IsStatusNotifierHostRegistered';

class _Watcher extends DBusObject {
  _Watcher() : super(LinuxTrayAvailability.watcherPath);

  DBusValue value = const DBusBoolean(false);
  Future<DBusValue> Function()? readValue;
  int reads = 0;

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    if (interface != LinuxTrayAvailability.watcherInterface ||
        name != _property) {
      return DBusMethodErrorResponse.unknownProperty();
    }
    reads++;
    return DBusGetPropertyResponse(
      await (readValue?.call() ?? Future.value(value)),
    );
  }

  Future<void> signal(String name) =>
      emitSignal(LinuxTrayAvailability.watcherInterface, name);
}

Future<void> _eventually(FutureOr<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for bus event');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  // Every connection uses this in-process private bus. Never use the user's
  // session bus (or its watcher, wallet, or native desktop plugins).
  late DBusServer server;
  late DBusAddress address;
  late DBusClient provider;
  late DBusClient client;
  late _Watcher watcher;
  late LinuxTrayAvailability availability;
  late List<bool> changes;
  late List<Object> errors;

  Future<void> start({Duration poll = const Duration(hours: 1)}) async {
    availability = LinuxTrayAvailability(
      client: client,
      timeout: const Duration(milliseconds: 250),
      pollInterval: poll,
    );
    await availability.initialize(onChanged: changes.add, onError: errors.add);
  }

  Future<void> ownWatcher() =>
      provider.requestName(LinuxTrayAvailability.watcherName).then((_) {});

  setUp(() async {
    server = DBusServer();
    address = await server.listenAddress(DBusAddress.tcp('127.0.0.1', port: 0));
    provider = DBusClient(address);
    client = DBusClient(address);
    watcher = _Watcher();
    changes = [];
    errors = [];
    availability = LinuxTrayAvailability(client: client);
    await provider.registerObject(watcher);
  });

  tearDown(() async {
    await availability.dispose();
    await provider.close();
    await server.close();
  });

  test('a watcher owner AND a registered host are required', () async {
    await start();
    expect(await availability.check(), isFalse);
    expect(changes, [false]);
    expect(watcher.reads, 0);

    await ownWatcher();
    expect(await availability.check(), isFalse);
    expect(watcher.reads, greaterThan(0));
    watcher.value = const DBusBoolean(true);
    expect(await availability.check(), isTrue);
    expect(errors, isEmpty);
  });

  for (final signal in [
    'StatusNotifierHostRegistered',
    'StatusNotifierHostUnregistered',
    'property changed',
    'property invalidated',
  ]) {
    test('$signal updates availability without polling', () async {
      final registered = signal == 'StatusNotifierHostRegistered';
      watcher.value = DBusBoolean(!registered);
      await ownWatcher();
      await start();
      expect(changes.last, !registered);
      watcher.value = DBusBoolean(registered);
      switch (signal) {
        case 'property changed':
          await watcher.emitPropertiesChanged(
            LinuxTrayAvailability.watcherInterface,
            changedProperties: {_property: watcher.value},
          );
        case 'property invalidated':
          await watcher.emitPropertiesChanged(
            LinuxTrayAvailability.watcherInterface,
            invalidatedProperties: [_property],
          );
        default:
          await watcher.signal(signal);
      }
      await _eventually(() => changes.last == registered);
      expect(errors, isEmpty);
    });
  }

  test('watcher loss immediately invalidates without polling', () async {
    watcher.value = const DBusBoolean(true);
    await ownWatcher();
    await start();
    expect(changes.last, isTrue);
    await provider.releaseName(LinuxTrayAvailability.watcherName);
    await _eventually(() => !changes.last);
  });

  test('a new watcher owner triggers a probe without polling', () async {
    watcher.value = const DBusBoolean(true);
    await start();
    expect(changes.last, isFalse);
    await ownWatcher();
    await _eventually(() => changes.last);
  });

  test('malformed properties and timed-out probes fail closed', () async {
    await ownWatcher();
    await start();
    watcher.value = const DBusString('not a boolean');
    expect(await availability.check(), isFalse);
    expect(errors, isNotEmpty);
    errors.clear();

    final reply = Completer<DBusValue>();
    watcher.readValue = () => reply.future;
    try {
      expect(
        await availability.check().timeout(const Duration(seconds: 2)),
        isFalse,
      );
      expect(errors.whereType<TimeoutException>(), hasLength(1));
    } finally {
      reply.complete(const DBusBoolean(true));
    }
  });

  test('polling detects host changes without any watcher signal', () async {
    await ownWatcher();
    await start(poll: const Duration(milliseconds: 30));
    watcher.value = const DBusBoolean(true);
    await _eventually(() => changes.last);
    watcher.value = const DBusBoolean(false);
    await _eventually(() => !changes.last);
    expect(errors, isEmpty);
  });

  test('each check is fresh and rejects an owner replaced during its probe', () async {
    await ownWatcher();
    // Do not initialize subscriptions: the owner recheck itself must catch this
    // race, independently of NameOwnerChanged signal delivery/revision tracking.
    final entered = Completer<void>();
    final reply = Completer<DBusValue>();
    watcher.readValue = () {
      entered.complete();
      return reply.future;
    };
    final replacement = DBusClient(address);
    final replacementWatcher = _Watcher()..value = const DBusBoolean(true);
    try {
      await replacement.registerObject(replacementWatcher);
      final checking = availability.check();
      await entered.future;
      await provider.releaseName(LinuxTrayAvailability.watcherName);
      await replacement.requestName(LinuxTrayAvailability.watcherName);
      reply.complete(const DBusBoolean(true));
      expect(await checking, isFalse);
      expect(await availability.check(), isTrue);
      replacementWatcher.value = const DBusBoolean(false);
      expect(await availability.check(), isFalse);
      expect(replacementWatcher.reads, 2);
    } finally {
      if (!reply.isCompleted) reply.complete(const DBusBoolean(false));
      await replacement.close();
    }
  });

  test(
    'disposal suppresses an in-flight probe result and diagnostics',
    () async {
      watcher.value = const DBusBoolean(true);
      await ownWatcher();
      await start();
      final entered = Completer<void>();
      final reply = Completer<DBusValue>();
      watcher.readValue = () {
        entered.complete();
        return reply.future;
      };
      final checking = availability.check();
      await entered.future;
      final snapshot = List<bool>.of(changes);
      try {
        await availability.dispose();
        reply.complete(const DBusBoolean(false));
        expect(await checking, isFalse);
        expect(changes, snapshot);
        expect(errors, isEmpty);
      } finally {
        if (!reply.isCompleted) reply.complete(const DBusBoolean(false));
      }
    },
  );

  test(
    'disposal closes the owned client and stops polls and notifications',
    () async {
      watcher.value = const DBusBoolean(true);
      await ownWatcher();
      await start(poll: const Duration(milliseconds: 30));
      final clientName = client.uniqueName;
      expect(await provider.getNameOwner(clientName), clientName);
      await availability.dispose();
      await availability.dispose();
      // Local close completes before the bus necessarily processes socket EOF;
      // a query on the provider's separate connection can otherwise race it.
      await _eventually(
        () async => await provider.getNameOwner(clientName) == null,
      );
      final snapshot = List<bool>.of(changes);
      final reads = watcher.reads;
      watcher.value = const DBusBoolean(false);
      await watcher.signal('StatusNotifierHostUnregistered');
      await provider.releaseName(LinuxTrayAvailability.watcherName);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await availability.check(), isFalse);
      expect(changes, snapshot);
      expect(watcher.reads, reads);
      expect(errors, isEmpty);
    },
  );
}
