import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/playback_settings.dart';

abstract interface class PlaybackSettingsStore {
  Future<PlaybackSettings> read();
  Future<void> write(PlaybackSettings settings);
}

final class SharedPreferencesPlaybackSettingsStore
    implements PlaybackSettingsStore {
  SharedPreferencesPlaybackSettingsStore(this._preferences);

  static const String key = 'playback.settings';
  final SharedPreferences _preferences;

  @override
  Future<PlaybackSettings> read() async {
    // A previous or corrupt entry may have a different preferences type.
    final value = _preferences.get(key);
    if (value is! String) return const PlaybackSettings();
    try {
      final json = jsonDecode(value);
      return json is Map<String, dynamic>
          ? PlaybackSettings.fromJson(json)
          : const PlaybackSettings();
    } on FormatException {
      return const PlaybackSettings();
    }
  }

  @override
  Future<void> write(PlaybackSettings settings) async {
    // Keep mute and its restore level together in one preference update.
    final saved = await _preferences.setString(
      key,
      jsonEncode(settings.toJson()),
    );
    if (!saved) {
      throw StateError('Could not save playback settings');
    }
  }
}
