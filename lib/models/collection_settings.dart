enum TrackSort { original, title, artist, album, duration, added }

enum PlaylistSort { name, updated, count }

/// Each browsing surface remembers its own order, independent of collection IDs.
enum TrackSortSurface { library, album, artist, playlist, addTracks }

class TrackSortSelection {
  const TrackSortSelection(this.sort, {this.descending = false});

  final TrackSort sort;
  final bool descending;
}

class PlaylistSortSelection {
  const PlaylistSortSelection(this.sort, {this.descending = false});

  final PlaylistSort sort;
  final bool descending;
}

/// Device-local view preferences. No selection, account, or playback state is
/// stored, and sorting never rewrites the saved order of a playlist.
class CollectionSettings {
  CollectionSettings({
    Map<TrackSortSurface, TrackSortSelection> tracks = const {},
    this.playlists = const PlaylistSortSelection(PlaylistSort.name),
  }) : tracks = Map.unmodifiable(tracks);

  final Map<TrackSortSurface, TrackSortSelection> tracks;
  final PlaylistSortSelection playlists;

  TrackSortSelection trackSort(TrackSortSurface surface) =>
      tracks[surface] ??
      TrackSortSelection(switch (surface) {
        TrackSortSurface.album ||
        TrackSortSurface.playlist => TrackSort.original,
        _ => TrackSort.title,
      });

  factory CollectionSettings.fromJson(Map<String, dynamic> json) {
    final tracks = <TrackSortSurface, TrackSortSelection>{};
    final savedTracks = json['tracks'];
    if (savedTracks is Map) {
      for (final surface in TrackSortSurface.values) {
        final saved = savedTracks[surface.name];
        if (saved is! Map) continue;
        final sort = TrackSort.values
            .where((value) => value.name == saved['sort'])
            .firstOrNull;
        if (sort == null ||
            (sort == TrackSort.original &&
                surface != TrackSortSurface.album &&
                surface != TrackSortSurface.playlist)) {
          continue;
        }
        tracks[surface] = TrackSortSelection(
          sort,
          descending: saved['descending'] == true,
        );
      }
    }
    final savedPlaylists = json['playlists'];
    final playlistSort = savedPlaylists is Map
        ? PlaylistSort.values
              .where((value) => value.name == savedPlaylists['sort'])
              .firstOrNull
        : null;
    return CollectionSettings(
      tracks: tracks,
      playlists: PlaylistSortSelection(
        playlistSort ?? PlaylistSort.name,
        descending:
            playlistSort != null &&
            savedPlaylists is Map &&
            savedPlaylists['descending'] == true,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'tracks': {
      for (final entry in tracks.entries)
        entry.key.name: {
          'sort': entry.value.sort.name,
          'descending': entry.value.descending,
        },
    },
    'playlists': {
      'sort': playlists.sort.name,
      'descending': playlists.descending,
    },
  };
}
