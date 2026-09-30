import '../models/collection_settings.dart';

export '../models/collection_settings.dart';

/// Share view preferences across screen recreation. Updates are immediate and
/// complete snapshots are saved in order, without waiting for application exit.
class CollectionSettingsController {
  CollectionSettingsController({
    CollectionSettings? initialSettings,
    this._saveSettings,
  }) : _settings = initialSettings ?? CollectionSettings();

  CollectionSettings _settings;
  CollectionSettings get settings => _settings;
  final Future<void> Function(CollectionSettings)? _saveSettings;
  Future<void> _writes = Future.value();

  Future<void> setTrackSort(
    TrackSortSurface surface,
    TrackSort sort, {
    required bool descending,
  }) {
    _settings = CollectionSettings(
      tracks: {
        ...settings.tracks,
        surface: TrackSortSelection(sort, descending: descending),
      },
      playlists: settings.playlists,
    );
    return _persist();
  }

  Future<void> setPlaylistSort(PlaylistSort sort, {required bool descending}) {
    _settings = CollectionSettings(
      tracks: settings.tracks,
      playlists: PlaylistSortSelection(sort, descending: descending),
    );
    return _persist();
  }

  Future<void> _persist() {
    final save = _saveSettings;
    if (save == null) return Future.value();
    final snapshot = settings;
    final write = _writes.then((_) => save(snapshot));
    // The caller surfaces the failure, but it must not block subsequent edits.
    _writes = write.catchError((Object _) {});
    return write;
  }

  Future<void> flushSettings() => _writes;
}
