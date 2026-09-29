import 'package:shared_preferences/shared_preferences.dart';

enum DesktopCloseBehavior { quit, minimizeToTray }

abstract interface class DesktopSettingsStore {
  Future<DesktopCloseBehavior> readCloseBehavior();
  Future<void> writeCloseBehavior(DesktopCloseBehavior behavior);
}

/// Device-local, account-independent preference. Unknown values fail safely to
/// the existing quit behavior; only successful writes change the active policy.
class SharedPreferencesDesktopSettingsStore implements DesktopSettingsStore {
  SharedPreferencesDesktopSettingsStore(this.preferences);

  static const closeBehaviorKey = 'desktop.closeBehavior';
  final SharedPreferences preferences;

  @override
  Future<DesktopCloseBehavior> readCloseBehavior() async {
    // SharedPreferences updates its cache even when a platform write fails.
    // A bootstrap retry must restore the durable value, not that rejected edit.
    await preferences.reload();
    final saved = preferences.get(closeBehaviorKey);
    return DesktopCloseBehavior.values.firstWhere(
      (value) => value.name == saved,
      orElse: () => DesktopCloseBehavior.quit,
    );
  }

  @override
  Future<void> writeCloseBehavior(DesktopCloseBehavior behavior) async {
    if (!await preferences.setString(closeBehaviorKey, behavior.name)) {
      throw StateError('Could not save desktop close behavior');
    }
  }
}
