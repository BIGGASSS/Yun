import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Exercise the plugin's platform mock without adding a production dependency.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:yun/core/collection_settings_controller.dart';
import 'package:yun/services/collection_settings_store.dart';

class _RejectingPreferencesStore extends InMemorySharedPreferencesStore {
  _RejectingPreferencesStore() : super.empty();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const key = SharedPreferencesCollectionSettingsStore.key;
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<SharedPreferencesCollectionSettingsStore> store() async =>
      SharedPreferencesCollectionSettingsStore(
        await SharedPreferences.getInstance(),
      );

  test(
    'first run keeps existing orders and does not create preferences',
    () async {
      final saved = await (await store()).read();
      expect(saved.trackSort(TrackSortSurface.library).sort, TrackSort.title);
      expect(saved.trackSort(TrackSortSurface.album).sort, TrackSort.original);
      expect(saved.trackSort(TrackSortSurface.artist).sort, TrackSort.title);
      expect(
        saved.trackSort(TrackSortSurface.playlist).sort,
        TrackSort.original,
      );
      expect(saved.trackSort(TrackSortSurface.addTracks).sort, TrackSort.title);
      expect(saved.playlists.sort, PlaylistSort.name);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    },
  );

  test(
    'all surfaces survive recreation without changing account or playback',
    () async {
      SharedPreferences.setMockInitialValues({
        'account.id': 'first',
        'account.token': 'secret',
        'playback.settings': '{"shuffle":true}',
      });
      final adapter = await store();
      final settings = CollectionSettingsController(
        saveSettings: adapter.write,
      );
      for (final surface in TrackSortSurface.values) {
        await settings.setTrackSort(
          surface,
          TrackSort.duration,
          descending: true,
        );
      }
      await settings.setPlaylistSort(PlaylistSort.updated, descending: true);
      await settings.flushSettings();
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString('account.token'), 'secret');
      expect(preferences.getString('playback.settings'), '{"shuffle":true}');
      await preferences.setString('account.id', 'second');
      await preferences.reload();
      final restored = CollectionSettingsController(
        initialSettings: await (await store()).read(),
      );
      for (final surface in TrackSortSurface.values) {
        expect(restored.settings.trackSort(surface).sort, TrackSort.duration);
        expect(restored.settings.trackSort(surface).descending, isTrue);
      }
      expect(restored.settings.playlists.sort, PlaylistSort.updated);
      expect(restored.settings.playlists.descending, isTrue);
      expect(preferences.getKeys(), {
        key,
        'account.id',
        'account.token',
        'playback.settings',
      });
    },
  );

  test('corrupt or wrong-type data fails without rewriting', () async {
    for (final value in <Object>[
      '{broken',
      'null',
      '[]',
      '42',
      42,
      true,
      ['title'],
    ]) {
      SharedPreferences.setMockInitialValues({key: value});
      await expectLater((await store()).read(), throwsFormatException);
      expect((await SharedPreferences.getInstance()).get(key), value);
    }
  });

  test(
    'invalid entries fall back independently while retaining valid choices',
    () async {
      SharedPreferences.setMockInitialValues({
        key: jsonEncode({
          'tracks': {
            'library': {'sort': 'futureOrder', 'descending': true},
            'album': {'sort': 'duration', 'descending': true},
            'artist': {'sort': 'original', 'descending': true},
            'playlist': {'sort': 'artist', 'descending': 'true'},
            'addTracks': 15,
            'futureSurface': {'sort': 'title'},
          },
          'playlists': {'sort': 'unknown', 'descending': true},
        }),
      });
      final saved = await (await store()).read();
      expect(saved.trackSort(TrackSortSurface.library).sort, TrackSort.title);
      expect(saved.trackSort(TrackSortSurface.library).descending, isFalse);
      expect(saved.trackSort(TrackSortSurface.album).sort, TrackSort.duration);
      expect(saved.trackSort(TrackSortSurface.album).descending, isTrue);
      expect(saved.trackSort(TrackSortSurface.artist).sort, TrackSort.title);
      expect(saved.trackSort(TrackSortSurface.playlist).sort, TrackSort.artist);
      expect(saved.trackSort(TrackSortSurface.playlist).descending, isFalse);
      expect(saved.trackSort(TrackSortSurface.addTracks).sort, TrackSort.title);
      expect(saved.playlists.sort, PlaylistSort.name);
      expect(saved.playlists.descending, isFalse);
    },
  );

  test(
    'rapid edits are immediate and persist in order through slow writes',
    () async {
      final gate = Completer<void>();
      final adapter = await store();
      var writes = 0;
      final settings = CollectionSettingsController(
        saveSettings: (snapshot) async {
          writes++;
          if (writes == 1) await gate.future;
          await adapter.write(snapshot);
        },
      );
      final first = settings.setTrackSort(
        TrackSortSurface.library,
        TrackSort.artist,
        descending: false,
      );
      final second = settings.setTrackSort(
        TrackSortSurface.library,
        TrackSort.added,
        descending: true,
      );
      final third = settings.setPlaylistSort(
        PlaylistSort.count,
        descending: true,
      );
      expect(
        settings.settings.trackSort(TrackSortSurface.library).sort,
        TrackSort.added,
      );
      expect(settings.settings.playlists.sort, PlaylistSort.count);
      await Future<void>.delayed(Duration.zero);
      expect(writes, 1);
      gate.complete();
      await Future.wait([first, second, third]);
      await settings.flushSettings();
      final restored = await (await store()).read();
      expect(
        restored.trackSort(TrackSortSurface.library).sort,
        TrackSort.added,
      );
      expect(restored.trackSort(TrackSortSurface.library).descending, isTrue);
      expect(restored.playlists.sort, PlaylistSort.count);
      expect(restored.playlists.descending, isTrue);
    },
  );

  test(
    'failed saves remain visible to flush until a later snapshot persists',
    () async {
      final adapter = await store();
      var reject = true;
      final failure = StateError('disk unavailable');
      final stack = StackTrace.current;
      final recoveryGate = Completer<void>();
      final settings = CollectionSettingsController(
        saveSettings: (snapshot) async {
          if (reject) Error.throwWithStackTrace(failure, stack);
          await recoveryGate.future;
          await adapter.write(snapshot);
        },
      );
      await expectLater(
        settings.setTrackSort(
          TrackSortSurface.album,
          TrackSort.added,
          descending: true,
        ),
        throwsA(same(failure)),
      );
      for (var i = 0; i < 2; i++) {
        await expectLater(settings.flushSettings(), throwsA(same(failure)));
      }
      await settings.flushSettings().then<void>(
        (_) => fail('Expected the retained save failure'),
        onError: (Object error, StackTrace trace) {
          expect(error, same(failure));
          expect(trace, same(stack));
        },
      );
      reject = false;
      final recovery = settings.setPlaylistSort(
        PlaylistSort.count,
        descending: false,
      );
      var flushed = false;
      final flushing = settings.flushSettings().then((_) => flushed = true);
      await Future<void>.delayed(Duration.zero);
      expect(flushed, isFalse);
      recoveryGate.complete();
      await recovery;
      await flushing;
      await settings.flushSettings();
      final restored = await (await store()).read();
      expect(restored.trackSort(TrackSortSurface.album).sort, TrackSort.added);
      expect(restored.trackSort(TrackSortSurface.album).descending, isTrue);
      expect(restored.playlists.sort, PlaylistSort.count);
    },
  );

  test(
    'platform rejection is not restored from the preferences cache',
    () async {
      final adapter = await store();
      final original = SharedPreferencesStorePlatform.instance;
      addTearDown(() => SharedPreferencesStorePlatform.instance = original);
      SharedPreferencesStorePlatform.instance = _RejectingPreferencesStore();
      await expectLater(
        adapter.write(
          CollectionSettings(
            playlists: const PlaylistSortSelection(PlaylistSort.count),
          ),
        ),
        throwsStateError,
      );
      await adapter.preferences.reload();
      expect((await adapter.read()).playlists.sort, PlaylistSort.name);
    },
  );
}
