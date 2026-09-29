import 'package:flutter/material.dart';

import '../models/models.dart';

enum TrackSort { original, title, artist, album, duration, added }

extension on TrackSort {
  String get label => switch (this) {
    TrackSort.original => 'Playlist order',
    TrackSort.title => 'Title',
    TrackSort.artist => 'Artist',
    TrackSort.album => 'Album',
    TrackSort.duration => 'Duration',
    TrackSort.added => 'Date added',
  };
}

int compareTracks(Track a, Track b, TrackSort sort) {
  int text(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
  final result = switch (sort) {
    TrackSort.original => 0,
    TrackSort.title => text(a.title, b.title),
    TrackSort.artist => text(a.artist, b.artist),
    TrackSort.album => text(a.album, b.album),
    TrackSort.duration => a.durationMs.compareTo(b.durationMs),
    TrackSort.added => a.createdAt.compareTo(b.createdAt),
  };
  if (sort == TrackSort.original) return 0;
  if (result != 0) return result;
  final title = text(a.title, b.title);
  return title != 0 ? title : a.id.compareTo(b.id);
}

/// Returns a copy; sorting never changes the library or saved playlist order.
List<Track> sortTracks(
  Iterable<Track> tracks,
  TrackSort sort, {
  bool descending = false,
}) {
  final result = tracks.toList();
  if (sort != TrackSort.original) {
    result.sort((a, b) => compareTracks(a, b, sort));
  }
  return descending ? result.reversed.toList() : result;
}

class TrackSortControl extends StatelessWidget {
  const TrackSortControl({
    super.key,
    required this.value,
    required this.descending,
    required this.onChanged,
    required this.onToggleDirection,
    this.allowOriginal = false,
    this.enabled = true,
    this.originalLabel = 'Playlist order',
  });

  final TrackSort value;
  final String originalLabel;
  final bool descending, allowOriginal, enabled;
  final ValueChanged<TrackSort> onChanged;
  final VoidCallback onToggleDirection;

  @override
  Widget build(BuildContext context) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      PopupMenuButton<TrackSort>(
        tooltip: 'Sort by',
        enabled: enabled,
        initialValue: value,
        onSelected: onChanged,
        itemBuilder: (_) => [
          for (final sort in TrackSort.values)
            if (allowOriginal || sort != TrackSort.original)
              PopupMenuItem(
                value: sort,
                child: Text(
                  sort == TrackSort.original ? originalLabel : sort.label,
                ),
              ),
        ],
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sort_rounded),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  value == TrackSort.original ? originalLabel : value.label,
                ),
              ),
              const Icon(Icons.arrow_drop_down_rounded),
            ],
          ),
        ),
      ),
      IconButton(
        tooltip: descending ? 'Sort ascending' : 'Sort descending',
        onPressed: enabled ? onToggleDirection : null,
        icon: Icon(descending ? Icons.arrow_downward : Icons.arrow_upward),
      ),
    ],
  );
}

class SelectionControls extends StatelessWidget {
  const SelectionControls({
    super.key,
    required this.selectedCount,
    required this.allSelected,
    required this.onSelectAll,
    required this.onClear,
    this.actions = const [],
  });

  final int selectedCount;
  final bool allSelected;
  final VoidCallback? onSelectAll, onClear;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      TextButton.icon(
        onPressed: onSelectAll,
        icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
        label: Text(allSelected ? 'Deselect all' : 'Select all'),
      ),
      Text('$selectedCount selected'),
      if (selectedCount > 0)
        TextButton(onPressed: onClear, child: const Text('Clear selection')),
      ...actions,
    ],
  );
}
