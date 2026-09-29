import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Use the existing plugin's platform mock without adding a production dependency.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:yun/models/playback_settings.dart';
import 'package:yun/services/playback_settings_store.dart';

void expectDefaults(PlaybackSettings settings) {
  expect(settings.volume, isNull);
  expect(settings.lastPositiveVolume, 100);
  expect(settings.shuffle, isFalse);
  expect(settings.repeatMode, RepeatMode.off);
}

class _RejectingPreferencesStore extends InMemorySharedPreferencesStore {
  _RejectingPreferencesStore() : super.empty();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlaybackSettings', () {
    test('defaults preserve the untouched native volume', () {
      const settings = PlaybackSettings();
      expectDefaults(settings);
      expect(settings.toJson(), {
        'version': 1,
        'volume': null,
        'lastPositiveVolume': 100.0,
        'shuffle': false,
        'repeatMode': 'off',
      });
      expectDefaults(PlaybackSettings.fromJson(settings.toJson()));
    });

    test('missing version accepts the original schema', () {
      final settings = PlaybackSettings.fromJson({
        'volume': 25,
        'shuffle': true,
        'repeatMode': 'all',
      });
      expect(settings.volume, 25.0);
      expect(settings.lastPositiveVolume, 25.0);
      expect(settings.shuffle, isTrue);
      expect(settings.repeatMode, RepeatMode.all);
    });

    test('unknown and incorrectly typed versions discard the record', () {
      for (final version in [null, 0, 2, -1, '1', true, 1.0, [], {}]) {
        expectDefaults(
          PlaybackSettings.fromJson({
            'version': version,
            'volume': 30,
            'lastPositiveVolume': 40,
            'shuffle': true,
            'repeatMode': 'one',
          }),
        );
      }
    });

    test('invalid volumes do not discard other valid preferences', () {
      for (final volume in [
        null,
        '40',
        true,
        [],
        {},
        -0.1,
        100.1,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        final settings = PlaybackSettings.fromJson({
          'volume': volume,
          'lastPositiveVolume': 45.5,
          'shuffle': true,
          'repeatMode': 'all',
        });
        expect(settings.volume, isNull);
        expect(settings.lastPositiveVolume, 45.5);
        expect(settings.shuffle, isTrue);
        expect(settings.repeatMode, RepeatMode.all);
      }
    });

    test('invalid previous levels fall back independently while muted', () {
      for (final level in [
        null,
        '40',
        true,
        [],
        {},
        -1,
        0,
        100.1,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        final settings = PlaybackSettings.fromJson({
          'volume': 0,
          'lastPositiveVolume': level,
          'shuffle': true,
          'repeatMode': 'one',
        });
        expect(settings.volume, 0);
        expect(settings.lastPositiveVolume, 100);
        expect(settings.shuffle, isTrue);
        expect(settings.repeatMode, RepeatMode.one);
      }
    });

    test('positive volume becomes the restore level including boundaries', () {
      for (final volume in [0.01, 37.25, 100]) {
        for (final oldLevel in [null, 0, 70, 'bad']) {
          final settings = PlaybackSettings.fromJson({
            'volume': volume,
            'lastPositiveVolume': oldLevel,
          });
          expect(settings.volume, volume);
          expect(settings.lastPositiveVolume, volume);
        }
      }
    });

    test('invalid shuffle and repeat types are ignored independently', () {
      for (final value in [null, 1, true, 'true', 'unknown', [], {}]) {
        final settings = PlaybackSettings.fromJson({
          'volume': 0,
          'lastPositiveVolume': 62.5,
          'shuffle': value,
          'repeatMode': value,
        });
        expect(settings.volume, 0);
        expect(settings.lastPositiveVolume, 62.5);
        expect(settings.shuffle, value == true);
        expect(settings.repeatMode, RepeatMode.off);
      }
      final settings = PlaybackSettings.fromJson({'repeatMode': 'all'});
      expect(settings.shuffle, isFalse);
      expect(settings.repeatMode, RepeatMode.all);
    });

    test('unrelated state cannot enter the serialized preferences', () {
      final settings = PlaybackSettings.fromJson({
        'tracks': ['track'],
        'account': {'username': 'someone'},
        'position': 123,
      });
      expectDefaults(settings);
      expect(
        settings.toJson().keys,
        unorderedEquals([
          'version',
          'volume',
          'lastPositiveVolume',
          'shuffle',
          'repeatMode',
        ]),
      );
    });
  });

  group('SharedPreferencesPlaybackSettingsStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<SharedPreferencesPlaybackSettingsStore> store() async =>
        SharedPreferencesPlaybackSettingsStore(
          await SharedPreferences.getInstance(),
        );

    test(
      'missing preferences leave native volume untouched without writing',
      () async {
        expectDefaults(await (await store()).read());
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.containsKey('playback.settings'), isFalse);
      },
    );

    test(
      'legacy unrelated preferences do not override native volume',
      () async {
        SharedPreferences.setMockInitialValues({
          'volume': 10.0,
          'shuffle': true,
        });
        final adapter = await store();
        final settings = await adapter.read();
        expectDefaults(settings);
        await adapter.write(settings);
        final preferences = await SharedPreferences.getInstance();
        final json = jsonDecode(preferences.getString('playback.settings')!);
        expect(json['volume'], isNull);
        expect(preferences.getDouble('volume'), 10.0);
        expectDefaults(await adapter.read());
      },
    );

    for (final repeatMode in RepeatMode.values) {
      for (final volume in [0.0, 37.25, 100.0]) {
        for (final shuffle in [false, true]) {
          test(
            'round trip ${repeatMode.name}, volume $volume, shuffle $shuffle',
            () async {
              final adapter = await store();
              final settings = PlaybackSettings(
                volume: volume,
                lastPositiveVolume: volume > 0 ? volume : 63.75,
                shuffle: shuffle,
                repeatMode: repeatMode,
              );
              await adapter.write(settings);
              final restored = await (await store()).read();
              expect(restored.toJson(), settings.toJson());
              final preferences = await SharedPreferences.getInstance();
              expect(preferences.getKeys(), {'playback.settings'});
              expect(
                jsonDecode(preferences.getString('playback.settings')!),
                settings.toJson(),
              );
            },
          );
        }
      }
    }

    test(
      'non-string, malformed, and non-object JSON entries default',
      () async {
        for (final value in <Object>[
          42,
          12.5,
          true,
          <String>['bad'],
          '',
          '{bad',
          '[1,2]',
          'null',
          'true',
          '42',
          '"text"',
        ]) {
          SharedPreferences.setMockInitialValues({'playback.settings': value});
          expectDefaults(await (await store()).read());
        }
      },
    );

    test('valid JSON with bad fields is sanitized independently', () async {
      SharedPreferences.setMockInitialValues({
        'playback.settings': jsonEncode({
          'version': 1,
          'volume': 'bad',
          'lastPositiveVolume': 42.5,
          'shuffle': true,
          'repeatMode': 2,
        }),
      });
      final settings = await (await store()).read();
      expect(settings.volume, isNull);
      expect(settings.lastPositiveVolume, 42.5);
      expect(settings.shuffle, isTrue);
      expect(settings.repeatMode, RepeatMode.off);
    });

    test('unknown stored version defaults', () async {
      SharedPreferences.setMockInitialValues({
        'playback.settings': '{"version":2,"volume":20,"shuffle":true}',
      });
      expectDefaults(await (await store()).read());
    });

    test('a rejected platform write throws StateError', () async {
      final adapter = await store();
      final originalPlatform = SharedPreferencesStorePlatform.instance;
      addTearDown(
        () => SharedPreferencesStorePlatform.instance = originalPlatform,
      );
      SharedPreferencesStorePlatform.instance = _RejectingPreferencesStore();
      await expectLater(
        adapter.write(
          const PlaybackSettings(volume: 0, lastPositiveVolume: 55),
        ),
        throwsStateError,
      );
    });
  });
}
