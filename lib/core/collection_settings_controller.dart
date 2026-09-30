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
  (Object, StackTrace)? _saveFailure;

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
    // A failed storage write must not block later full snapshots. Keep its
    // error for flush callers as well as the initiating caller; only a durable
    // snapshot resolves the failure.
    _writes = write.then<void>(
      (_) => _saveFailure = null,
      onError: (Object error, StackTrace stackTrace) {
        _saveFailure = (error, stackTrace);
      },
    );
    return write;
  }

  Future<void> flushSettings() async {
    await _writes;
    final failure = _saveFailure;
    if (failure != null) {
      Error.throwWithStackTrace(failure.$1, failure.$2);
    }
  }
}
