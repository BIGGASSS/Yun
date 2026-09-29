import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:yun/core/desktop_controller.dart';
import 'package:yun/core/playback_controller.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/desktop_settings_store.dart';

import 'fake_desktop_host.dart';
import 'fakes.dart';

class _Settings implements DesktopSettingsStore {
  _Settings(this.events, this.saved);
  final List<String> events;
  DesktopCloseBehavior saved;
  Object? readError;
  Future<void> Function(DesktopCloseBehavior)? beforeWrite;

  @override
  Future<DesktopCloseBehavior> readCloseBehavior() async {
    if (readError case final error?) throw error;
    return saved;
  }

  @override
  Future<void> writeCloseBehavior(DesktopCloseBehavior behavior) async {
    events.add('write:${behavior.name}');
    await beforeWrite?.call(behavior);
    saved = behavior;
    events.add('saved:${behavior.name}');
  }
}

class _RejectingPreferencesStore extends InMemorySharedPreferencesStore {
  _RejectingPreferencesStore() : super.empty();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

class _Rig {
  _Rig({
    DesktopCloseBehavior saved = DesktopCloseBehavior.quit,
    DesktopSettingsStore? store,
  }) {
    host = FakeDesktopHost(events);
    settings = _Settings(events, saved);
    controller = DesktopController(
      host: host,
      settings: store ?? settings,
      shutdown: () async {
        events.add('shutdown');
        await shutdown?.call();
        events.add('durable');
      },
      checkpoint: () async {
        events.add('checkpoint');
        await checkpoint?.call();
        events.add('checkpointed');
      },
    );
    addTearDown(dispose);
  }

  final events = <String>[];
  late final FakeDesktopHost host;
  late final _Settings settings;
  late final DesktopController controller;
  Future<void> Function()? shutdown, checkpoint;
  bool disposed = false;

  Future<void> initialize() async {
    await controller.initialize();
    events.clear();
  }

  void dispose() {
    if (disposed) return;
    disposed = true;
    controller.dispose();
  }
}

// These are ordinary async tests, not testWidgets/FakeAsync. A turn of the event
// loop drains fire-and-forget native callbacks; gates hold specific operations.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'default native close waits for durable shutdown before dispose/exit',
    () async {
      final rig = _Rig();
      final gate = Completer<void>();
      rig.shutdown = () => gate.future;
      await rig.initialize();
      expect(rig.controller.closeBehavior, DesktopCloseBehavior.quit);
      rig.host.onClose!();
      await _settle();
      expect(rig.events, ['shutdown']);
      expect(rig.controller.isQuitting, isTrue);
      gate.complete();
      await _settle();
      expect(rig.events, ['shutdown', 'durable', 'dispose', 'exit']);
    },
  );

  test(
    'saved minimize checkpoints before hiding and leaves playback alone',
    () async {
      final engine = FakeEngine();
      final player = PlaybackController(
        engine: engine,
        enableSystemControls: false,
        resolveSource: (track, _) async => AudioSource('/fake/${track.id}'),
      );
      addTearDown(() async {
        await player.shutdown();
        player.dispose();
      });
      const tracks = [Track(id: 'a', title: 'A'), Track(id: 'b', title: 'B')];
      await player.playQueue(tracks);
      final calls = List<String>.of(engine.calls);
      final rig = _Rig(saved: DesktopCloseBehavior.minimizeToTray);
      final gate = Completer<void>();
      rig.checkpoint = () async {
        await gate.future;
        await player.checkpoint();
      };
      rig.shutdown = player.shutdown;
      await rig.initialize();
      final close = rig.controller.requestWindowClose();
      await _settle();
      expect(rig.events, ['checkpoint']);
      expect(rig.host.visible, isTrue);
      gate.complete();
      await close;
      expect(rig.events, [
        'checkpoint',
        'checkpointed',
        'availability',
        'hide',
      ]);
      expect(rig.controller.isHidden, isTrue);
      expect(rig.controller.isQuitting, isFalse);
      expect(player.isPlaying, isTrue);
      expect(player.queue, tracks);
      expect(player.currentTrack?.id, 'a');
      expect(engine.calls, calls);
    },
  );

  test(
    'saved policy survives controller recreation and native failures',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final first = _Rig(
        store: SharedPreferencesDesktopSettingsStore(preferences),
      );
      await first.initialize();
      await first.controller.setCloseBehavior(
        DesktopCloseBehavior.minimizeToTray,
      );
      first.host.before = (operation) async {
        if (operation == 'hide') throw StateError('native hide failed');
      };
      await first.controller.requestWindowClose();
      expect(first.controller.error, contains('native hide failed'));
      expect(
        first.controller.closeBehavior,
        DesktopCloseBehavior.minimizeToTray,
      );
      first.dispose();
      await preferences.reload();
      final second = _Rig(
        store: SharedPreferencesDesktopSettingsStore(preferences),
      );
      await second.initialize();
      expect(
        second.controller.closeBehavior,
        DesktopCloseBehavior.minimizeToTray,
      );
      await second.controller.requestWindowClose();
      expect(second.controller.isHidden, isTrue);
      expect(second.events, isNot(contains('shutdown')));
    },
  );

  test(
    'rejected real preference write retains active and durable old policy',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final rig = _Rig(
        store: SharedPreferencesDesktopSettingsStore(preferences),
      );
      await rig.initialize();
      final platform = SharedPreferencesStorePlatform.instance;
      addTearDown(() => SharedPreferencesStorePlatform.instance = platform);
      SharedPreferencesStorePlatform.instance = _RejectingPreferencesStore();
      await rig.controller.setCloseBehavior(
        DesktopCloseBehavior.minimizeToTray,
      );
      expect(rig.controller.closeBehavior, DesktopCloseBehavior.quit);
      expect(rig.controller.error, contains('Could not save'));
      expect(rig.controller.isSaving, isFalse);
      await preferences.reload();
      final next = _Rig(
        store: SharedPreferencesDesktopSettingsStore(preferences),
      );
      await next.initialize();
      expect(next.controller.closeBehavior, DesktopCloseBehavior.quit);
      await rig.controller.requestWindowClose();
      expect(rig.events, ['shutdown', 'durable', 'dispose', 'exit']);
    },
  );

  test(
    'slow settings writes serialize and close waits for the final policy',
    () async {
      final rig = _Rig();
      await rig.initialize();
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();
      var writes = 0;
      rig.settings.beforeWrite = (_) =>
          ++writes == 1 ? firstGate.future : secondGate.future;
      final first = rig.controller.setCloseBehavior(DesktopCloseBehavior.quit);
      final second = rig.controller.setCloseBehavior(
        DesktopCloseBehavior.minimizeToTray,
      );
      final close = rig.controller.requestWindowClose();
      await _settle();
      expect(rig.events, ['write:quit']);
      expect(rig.controller.isSaving, isTrue);
      firstGate.complete();
      await first;
      await _settle();
      expect(rig.events, ['write:quit', 'saved:quit', 'write:minimizeToTray']);
      expect(rig.controller.isSaving, isTrue);
      expect(rig.controller.closeBehavior, DesktopCloseBehavior.quit);
      secondGate.complete();
      await Future.wait([second, close]);
      expect(rig.controller.isSaving, isFalse);
      expect(rig.controller.closeBehavior, DesktopCloseBehavior.minimizeToTray);
      expect(rig.events, [
        'write:quit',
        'saved:quit',
        'write:minimizeToTray',
        'saved:minimizeToTray',
        'checkpoint',
        'checkpointed',
        'availability',
        'hide',
      ]);
    },
  );

  test(
    'a failed save preserves previous minimize policy and queue can recover',
    () async {
      final rig = _Rig(saved: DesktopCloseBehavior.minimizeToTray);
      await rig.initialize();
      rig.settings.beforeWrite = (_) async => throw StateError('disk full');
      await rig.controller.setCloseBehavior(DesktopCloseBehavior.quit);
      expect(rig.controller.closeBehavior, DesktopCloseBehavior.minimizeToTray);
      expect(rig.controller.error, contains('disk full'));
      await rig.controller.requestWindowClose();
      expect(rig.controller.isHidden, isTrue);
      expect(rig.events, isNot(contains('shutdown')));
      rig.settings.beforeWrite = null;
      await rig.controller.setCloseBehavior(DesktopCloseBehavior.quit);
      expect(rig.controller.error, isNull);
      expect(rig.controller.isSaving, isFalse);
      expect(rig.settings.saved, DesktopCloseBehavior.quit);
    },
  );

  test('quit waits for in-flight settings and refuses new writes', () async {
    final rig = _Rig();
    await rig.initialize();
    final gate = Completer<void>();
    rig.settings.beforeWrite = (_) => gate.future;
    final write = rig.controller.setCloseBehavior(
      DesktopCloseBehavior.minimizeToTray,
    );
    await _settle();
    final quit = rig.controller.quit();
    await rig.controller.setCloseBehavior(DesktopCloseBehavior.quit);
    await _settle();
    expect(rig.events, ['write:minimizeToTray']);
    expect(rig.controller.isQuitting, isTrue);
    gate.complete();
    await Future.wait([write, quit]);
    expect(rig.events, [
      'write:minimizeToTray',
      'saved:minimizeToTray',
      'shutdown',
      'durable',
      'dispose',
      'exit',
    ]);
  });

  for (final frameworkExit in [false, true]) {
    test(
      '${frameworkExit ? 'OS application exit' : 'explicit quit'} ignores minimize policy',
      () async {
        final rig = _Rig(saved: DesktopCloseBehavior.minimizeToTray);
        await rig.initialize();
        if (frameworkExit) {
          expect(await rig.controller.requestApplicationExit(), isTrue);
          // Flutter owns the exit in this path; do not recursively request it.
          expect(rig.events, ['shutdown', 'durable', 'dispose']);
        } else {
          rig.host.onQuit!();
          await _settle();
          expect(rig.events, ['shutdown', 'durable', 'dispose', 'exit']);
        }
      },
    );
  }

  test('duplicate native closes share a single checkpoint/hide', () async {
    final rig = _Rig(saved: DesktopCloseBehavior.minimizeToTray);
    await rig.initialize();
    final gate = Completer<void>();
    rig.checkpoint = () => gate.future;
    final first = rig.controller.requestWindowClose();
    final second = rig.controller.requestWindowClose();
    expect(identical(first, second), isTrue);
    rig.host.onClose!();
    await _settle();
    expect(rig.events, ['checkpoint']);
    gate.complete();
    await Future.wait([first, second]);
    await rig.controller.requestWindowClose();
    expect(rig.events, ['checkpoint', 'checkpointed', 'availability', 'hide']);
  });

  test(
    'concurrent default close, explicit quit and OS exit share shutdown',
    () async {
      final rig = _Rig();
      await rig.initialize();
      final gate = Completer<void>();
      rig.shutdown = () => gate.future;
      final close = rig.controller.requestWindowClose();
      await _settle();
      final quit = rig.controller.quit();
      final duplicate = rig.controller.quit();
      final osExit = rig.controller.requestApplicationExit();
      expect(identical(quit, duplicate), isTrue);
      await _settle();
      expect(rig.events, ['shutdown']);
      gate.complete();
      await Future.wait([close, quit, duplicate]);
      expect(await osExit, isTrue);
      expect(rig.events, ['shutdown', 'durable', 'dispose', 'exit']);
    },
  );

  test(
    'quit waits for an in-flight hide before disposing native resources',
    () async {
      final rig = _Rig(saved: DesktopCloseBehavior.minimizeToTray);
      await rig.initialize();
      final gate = Completer<void>();
      rig.host.before = (operation) async {
        if (operation == 'hide') await gate.future;
      };
      final close = rig.controller.requestWindowClose();
      await _settle();
      final quit = rig.controller.quit();
      await _settle();
      expect(rig.events, [
        'checkpoint',
        'checkpointed',
        'availability',
        'hide',
      ]);
      gate.complete();
      await Future.wait([close, quit]);
      expect(rig.events, [
        'checkpoint',
        'checkpointed',
        'availability',
        'hide',
        'shutdown',
        'durable',
        'dispose',
        'exit',
      ]);
    },
  );

  test(
    'visibility operations serialize hide/show/hide without stale state',
    () async {
      final rig = _Rig();
      await rig.initialize();
      final gate = Completer<void>();
      var hides = 0;
      rig.host.before = (operation) async {
        if (operation == 'hide' && ++hides == 1) await gate.future;
      };
      final hide = rig.controller.minimizeToTray();
      await _settle();
      final show = rig.controller.showWindow();
      final hideAgain = rig.controller.minimizeToTray();
      await _settle();
      expect(rig.events, isNot(contains('show')));
      gate.complete();
      await Future.wait([hide, show, hideAgain]);
      expect(rig.events, [
        'checkpoint',
        'checkpointed',
        'availability',
        'hide',
        'show',
        'checkpoint',
        'checkpointed',
        'availability',
        'hide',
      ]);
      expect(rig.controller.isHidden, isTrue);
      expect(rig.host.visible, isFalse);
    },
  );

  test(
    'fresh false availability never hides even after a positive startup',
    () async {
      final rig = _Rig(saved: DesktopCloseBehavior.minimizeToTray);
      await rig.initialize();
      expect(rig.controller.trayAvailable, isTrue);
      rig.host.available =
          false; // No watcher notification: fresh probe is required.
      await rig.controller.requestWindowClose();
      expect(rig.events, ['checkpoint', 'checkpointed', 'availability']);
      expect(rig.controller.trayAvailable, isFalse);
      expect(rig.controller.isHidden, isFalse);
      expect(rig.host.visible, isTrue);
      expect(rig.controller.error, contains('not hidden'));
      expect(rig.controller.closeBehavior, DesktopCloseBehavior.minimizeToTray);
    },
  );

  test('watcher loss while hidden restores without shutdown', () async {
    final rig = _Rig();
    await rig.initialize();
    await rig.controller.minimizeToTray();
    rig.events.clear();
    rig.host.changeAvailability(false);
    await _settle();
    expect(rig.events, ['show']);
    expect(rig.controller.isHidden, isFalse);
    expect(rig.host.visible, isTrue);
    expect(rig.controller.error, contains('tray became unavailable'));
  });

  test(
    'watcher loss during hide queues restoration after hide completes',
    () async {
      final rig = _Rig();
      await rig.initialize();
      final gate = Completer<void>();
      rig.host.before = (operation) async {
        if (operation == 'hide') await gate.future;
      };
      final hide = rig.controller.minimizeToTray();
      await _settle();
      rig.host.changeAvailability(false);
      await _settle();
      expect(rig.events, isNot(contains('show')));
      gate.complete();
      await hide;
      await _settle();
      expect(rig.events, [
        'checkpoint',
        'checkpointed',
        'availability',
        'hide',
        'show',
      ]);
      expect(rig.host.visible, isTrue);
      expect(rig.controller.isHidden, isFalse);
      expect(rig.controller.trayAvailable, isFalse);
      expect(rig.controller.error, isNotNull);
    },
  );

  test('show callback always calls host, including externally minimized windows', () async {
    final rig = _Rig();
    await rig.initialize();
    // The controller does not know OS-minimized state. The native adapter owns
    // restore/focus; this test verifies that it always gets a show request.
    rig.host.visible = false;
    expect(rig.controller.isHidden, isFalse);
    rig.host.onShow!();
    await _settle();
    expect(rig.events, ['show']);
    expect(rig.host.visible, isTrue);
    await rig.controller.minimizeToTray();
    rig.host.onShow!();
    await _settle();
    expect(rig.controller.isHidden, isFalse);
  });

  test(
    'settings read failure keeps safe default and still initializes host',
    () async {
      final rig = _Rig();
      rig.settings.readError = StateError('read failed');
      await rig.initialize();
      expect(rig.controller.closeBehavior, DesktopCloseBehavior.quit);
      expect(rig.controller.trayAvailable, isTrue);
      expect(rig.controller.error, contains('read failed'));
      await rig.controller.requestWindowClose();
      expect(rig.events, ['shutdown', 'durable', 'dispose', 'exit']);
    },
  );

  for (final operation in ['initialize', 'availability']) {
    test(
      'startup $operation failure is graceful and explicit quit still works',
      () async {
        final rig = _Rig(saved: DesktopCloseBehavior.minimizeToTray);
        rig.host.before = (call) async {
          if (call == operation) throw StateError('startup failed');
        };
        await rig.initialize();
        expect(rig.controller.trayAvailable, isFalse);
        expect(rig.controller.isHidden, isFalse);
        expect(rig.controller.error, contains('startup failed'));
        await rig.controller.quit();
        expect(rig.events, ['shutdown', 'durable', 'dispose', 'exit']);
      },
    );
  }

  for (final operation in ['checkpoint', 'availability', 'hide', 'show']) {
    test(
      '$operation failure reports error, tries recovery and never exits',
      () async {
        final rig = _Rig();
        await rig.initialize();
        if (operation == 'checkpoint') {
          rig.checkpoint = () async => throw StateError('checkpoint failed');
        } else {
          rig.host.before = (call) async {
            if (call == operation) {
              if (call == 'hide') {
                rig.host.visible = false; // Partial native hide.
              }
              throw StateError('$operation failed');
            }
          };
        }
        if (operation == 'show') {
          await rig.controller.showWindow();
          expect(rig.events, ['show', 'show']);
        } else {
          await rig.controller.minimizeToTray();
          expect(rig.events.last, 'show');
          expect(rig.host.visible, isTrue);
        }
        expect(rig.controller.error, contains('$operation failed'));
        expect(rig.controller.isHidden, isFalse);
        expect(rig.events, isNot(contains('shutdown')));
        expect(rig.events, isNot(contains('exit')));
      },
    );
  }

  test('failed recovery from partial hide also surfaces its error', () async {
    final rig = _Rig();
    await rig.initialize();
    rig.host.before = (operation) async {
      if (operation == 'hide' || operation == 'show') {
        throw StateError(operation);
      }
    };
    await rig.controller.minimizeToTray();
    expect(rig.controller.error, contains('Could not restore the window'));
    expect(rig.events.last, 'show');
    expect(rig.events, isNot(contains('exit')));
  });

  test(
    'shutdown failure is memoized, restores window and never retries/exits',
    () async {
      final rig = _Rig(saved: DesktopCloseBehavior.minimizeToTray);
      await rig.initialize();
      await rig.controller.minimizeToTray();
      rig.events.clear();
      // AppController.shutdown and PlaybackController.shutdown memoize their
      // futures too. Retrying a freshly successful fake would misrepresent the
      // real core: after failure it cannot certify a new durable shutdown.
      rig.shutdown = () async => throw StateError('durable write failed');
      final first = rig.controller.requestApplicationExit();
      expect(await first, isFalse);
      expect(rig.events, ['shutdown', 'show']);
      expect(rig.controller.isHidden, isFalse);
      expect(rig.controller.isQuitting, isFalse);
      expect(rig.host.visible, isTrue);
      expect(rig.controller.canMinimize, isFalse);
      expect(rig.controller.error, contains('durable write failed'));
      rig.shutdown = () async {};
      expect(identical(first, rig.controller.requestApplicationExit()), isTrue);
      await rig.controller.quit();

      // Clearing the notice must not clear the failed-shutdown safety latch.
      rig.controller.clearError();
      expect(rig.controller.canMinimize, isFalse);
      await rig.controller.minimizeToTray();
      expect(rig.host.visible, isTrue);
      expect(rig.controller.isHidden, isFalse);
      expect(rig.controller.error, contains('durable write failed'));
      await rig.controller.requestWindowClose();
      expect(rig.host.visible, isTrue);
      expect(rig.controller.isHidden, isFalse);

      // Another tray Quit observes the cached false result. Neither visibility
      // path may hide a window that this permanently failed core cannot exit.
      rig.host.onQuit!();
      await _settle();
      expect(await rig.controller.requestApplicationExit(), isFalse);
      expect(rig.host.visible, isTrue);
      expect(rig.controller.canMinimize, isFalse);
      expect(rig.controller.isQuitting, isFalse);
      expect(rig.events, ['shutdown', 'show', 'show', 'show']);
      expect(rig.events, isNot(contains('hide')));
      expect(rig.events, isNot(contains('exit')));
      expect(rig.events, isNot(contains('dispose')));
    },
  );

  test(
    'tray disposal failure cannot veto exit after durable shutdown',
    () async {
      final rig = _Rig();
      await rig.initialize();
      rig.host.before = (operation) async {
        if (operation == 'dispose') throw StateError('tray cleanup failed');
      };
      await rig.controller.quit();
      expect(rig.events, ['shutdown', 'durable', 'dispose', 'exit']);
      expect(rig.controller.error, contains('tray cleanup failed'));
    },
  );

  test(
    'exit failure attempts recovery instead of stranding a hidden window',
    () async {
      final rig = _Rig();
      await rig.initialize();
      await rig.controller.minimizeToTray();
      rig.events.clear();
      rig.host.before = (operation) async {
        if (operation == 'exit') throw StateError('platform exit failed');
      };
      await rig.controller.quit();
      expect(rig.events, ['shutdown', 'durable', 'dispose', 'exit', 'show']);
      expect(rig.controller.isQuitting, isFalse);
      expect(rig.controller.isHidden, isFalse);
      expect(rig.controller.error, contains('platform exit failed'));
    },
  );

  test(
    'initialize is idempotent; native errors notify and can be cleared',
    () async {
      final rig = _Rig();
      final first = rig.controller.initialize();
      expect(identical(first, rig.controller.initialize()), isTrue);
      await first;
      expect(rig.events, ['initialize', 'availability']);
      var notifications = 0;
      rig.controller.addListener(() => notifications++);
      rig.host.onError!(StateError('native callback failed'));
      expect(rig.controller.error, contains('native callback failed'));
      expect(notifications, 1);
      rig.controller.clearError();
      expect(rig.controller.error, isNull);
      expect(notifications, 2);
    },
  );

  test(
    'late native callbacks after disposal do not notify or do work',
    () async {
      final rig = _Rig();
      await rig.initialize();
      var notifications = 0;
      rig.controller.addListener(() => notifications++);
      rig.host.before = (operation) async {
        if (operation == 'dispose') throw StateError('cleanup failed');
      };
      rig.dispose();
      rig.events.clear();
      rig.host.onClose!();
      rig.host.onShow!();
      rig.host.onQuit!();
      rig.host.changeAvailability(false);
      rig.host.onError!(StateError('late error'));
      await rig.controller.setCloseBehavior(
        DesktopCloseBehavior.minimizeToTray,
      );
      await _settle();
      expect(rig.events, isEmpty);
      expect(notifications, 0);
      expect(rig.controller.error, isNull);
    },
  );

  test(
    'pending native initialization can finish after disposal safely',
    () async {
      final rig = _Rig();
      final gate = Completer<void>();
      rig.host.before = (operation) async {
        if (operation == 'initialize') await gate.future;
      };
      final initialization = rig.controller.initialize();
      await _settle();
      rig.dispose();
      gate.complete();
      await initialization;
      expect(rig.events, ['initialize', 'dispose']);
      expect(rig.controller.trayAvailable, isFalse);
    },
  );
}
