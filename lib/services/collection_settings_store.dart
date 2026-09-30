import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/collection_settings.dart';

class SharedPreferencesCollectionSettingsStore {
  SharedPreferencesCollectionSettingsStore(this.preferences);

  static const key = 'collections.sorting';
  final SharedPreferences preferences;

  Future<CollectionSettings> read() async {
    final saved = preferences.get(key);
    if (saved is! String) return CollectionSettings();
    try {
      final json = jsonDecode(saved);
      return json is Map<String, dynamic>
          ? CollectionSettings.fromJson(json)
          : CollectionSettings();
    } on FormatException {
      return CollectionSettings();
    }
  }

  Future<void> write(CollectionSettings settings) async {
    if (!await preferences.setString(key, jsonEncode(settings.toJson()))) {
      throw StateError('Could not save sorting preferences');
    }
  }
}
