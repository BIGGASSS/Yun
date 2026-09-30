import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/collection_settings.dart';

class SharedPreferencesCollectionSettingsStore {
  SharedPreferencesCollectionSettingsStore(this.preferences);

  static const key = 'collections.sorting';
  final SharedPreferences preferences;

  Future<CollectionSettings> read() async {
    final saved = preferences.get(key);
    if (saved == null) return CollectionSettings();
    if (saved is! String) {
      throw const FormatException('Sorting preferences must be a JSON string');
    }
    final json = jsonDecode(saved);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Sorting preferences must be a JSON object');
    }
    return CollectionSettings.fromJson(json);
  }

  Future<void> write(CollectionSettings settings) async {
    if (!await preferences.setString(key, jsonEncode(settings.toJson()))) {
      throw StateError('Could not save sorting preferences');
    }
  }
}
