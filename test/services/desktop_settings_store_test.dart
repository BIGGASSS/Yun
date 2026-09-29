import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Exercise the plugin's existing platform mock, not a production dependency.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:yun/services/desktop_settings_store.dart';

class _RejectingPreferencesStore extends InMemorySharedPreferencesStore {
  _RejectingPreferencesStore() : super.empty();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = SharedPreferencesDesktopSettingsStore.closeBehaviorKey;
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<SharedPreferencesDesktopSettingsStore> store() async =>
      SharedPreferencesDesktopSettingsStore(
        await SharedPreferences.getInstance(),
      );

  test('missing preference defaults to quit without writing', () async {
    expect(
      await (await store()).readCloseBehavior(),
      DesktopCloseBehavior.quit,
    );
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test(
    'unknown, malformed and wrong-type values default without rewriting',
    () async {
      for (final value in <Object>[
        '',
        'QUIT',
        'minimize',
        'futurePolicy',
        '{bad',
        '"minimizeToTray"',
        '{"behavior":"minimizeToTray"}',
        42,
        1.5,
        true,
        <String>['minimizeToTray'],
      ]) {
        SharedPreferences.setMockInitialValues({key: value});
        expect(
          await (await store()).readCloseBehavior(),
          DesktopCloseBehavior.quit,
          reason: 'stored value: $value',
        );
        expect((await SharedPreferences.getInstance()).get(key), value);
      }
    },
  );

  for (final behavior in DesktopCloseBehavior.values) {
    test(
      '${behavior.name} survives store recreation and disk reload',
      () async {
        await (await store()).writeCloseBehavior(behavior);
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getString(key), behavior.name);
        expect(preferences.getKeys(), {key});
        // Reload discards the instance cache and reads the platform backing store.
        await preferences.reload();
        expect(await (await store()).readCloseBehavior(), behavior);
      },
    );
  }

  test(
    'preference is device-local and independent of account credentials',
    () async {
      SharedPreferences.setMockInitialValues({
        'account.id': 'first',
        'account.token': 'secret',
        'playback.settings': '{}',
      });
      final preferences = await SharedPreferences.getInstance();
      await (await store()).writeCloseBehavior(
        DesktopCloseBehavior.minimizeToTray,
      );
      expect(preferences.getString('account.token'), 'secret');
      expect(preferences.getString('playback.settings'), '{}');
      await preferences.remove('account.token');
      await preferences.setString('account.id', 'second');
      expect(
        await (await store()).readCloseBehavior(),
        DesktopCloseBehavior.minimizeToTray,
      );
      // A different device's empty preferences do not inherit the first device.
      SharedPreferences.setMockInitialValues({'account.id': 'second'});
      expect(
        await (await store()).readCloseBehavior(),
        DesktopCloseBehavior.quit,
      );
    },
  );

  test('rejected platform write throws and does not become durable', () async {
    final adapter = await store();
    final original = SharedPreferencesStorePlatform.instance;
    addTearDown(() => SharedPreferencesStorePlatform.instance = original);
    SharedPreferencesStorePlatform.instance = _RejectingPreferencesStore();
    await expectLater(
      adapter.writeCloseBehavior(DesktopCloseBehavior.minimizeToTray),
      throwsStateError,
    );
    await adapter.preferences.reload();
    expect(await adapter.readCloseBehavior(), DesktopCloseBehavior.quit);
  });
}
