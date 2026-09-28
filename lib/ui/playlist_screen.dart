import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import 'widgets.dart';

class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key, required this.app});
  final AppController app;

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  String? _selectedId;
  bool _saving = false;

  Future<void> _create() async {
    final name = await askForName(context, title: 'New playlist');
    if (name == null || !mounted) return;
    await runUiAction(context, () async {
      final playlist = await widget.app.createPlaylist(name);
      if (mounted) setState(() => _selectedId = playlist.id);
    });
  }

  Future<void> _saveEntries(
    Playlist playlist,
    List<PlaylistEntry> entries,
  ) async {
    setState(() => _saving = true);
    await runUiAction(context, () async {
      await widget.app.savePlaylist(playlist, entries: entries);
    });
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _addTracks(Playlist playlist) async {
    final result = await showDialog<List<String>>(
      context: context,
      builder: (_) => _AddTracksDialog(app: widget.app),
    );
    if (result == null || result.isEmpty || !mounted) return;
    // Read the latest revision after the chooser closes.
    final current = widget.app.playlists
        .where((item) => item.id == playlist.id)
        .firstOrNull;
    if (current != null) {
      await _saveEntries(current, [
        ...current.entries,
        for (final id in result)
          PlaylistEntry(id: widget.app.newId(), trackId: id),
      ]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final selected = app.playlists
        .where((item) => item.id == _selectedId)
        .firstOrNull;
    if (selected != null) return _detail(context, selected);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(
          'Playlists',
          subtitle: 'Put things in your own order',
          actions: [
            FilledButton.tonalIcon(
              onPressed: app.isAuthenticated ? _create : null,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New playlist'),
            ),
          ],
        ),
        Expanded(
          child: app.playlists.isEmpty
              ? EmptyState(
                  icon: Icons.queue_music_rounded,
                  title: 'Make a little collection',
                  message: 'Create playlists for a mood, a moment, or a favorite album. A track can appear more than once.',
                  action: app.isAuthenticated
                      ? OutlinedButton(
                          onPressed: _create,
                          child: const Text('Create playlist'),
                        )
                      : null,
                )
              : ListView.builder(
                  itemCount: app.playlists.length,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemBuilder: (context, index) {
                    final playlist = app.playlists[index];
                    return ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.queue_music_rounded),
                      ),
                      title: Text(playlist.name),
                      subtitle: Text(
                        '${playlist.entries.length} entries${app.isPinned('playlist', playlist.id) ? ' · Kept offline' : ''}',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => setState(() => _selectedId = playlist.id),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _detail(BuildContext context, Playlist playlist) {
    final app = widget.app;
    final queue = [
      for (final entry in playlist.entries)
        if (app.trackById(entry.trackId) case final Track track) track,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 24, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _selectedId = null),
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('Playlists'),
            ),
          ),
        ),
        SectionHeading(
          playlist.name,
          subtitle:
              '${playlist.entries.length} entries · Drag handles or use entry menus to reorder',
          actions: [
            FilledButton.tonalIcon(
              onPressed: queue.isEmpty
                  ? null
                  : () => runUiAction(
                      context,
                      () => app.playback.playQueue(queue),
                    ),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Play'),
            ),
            OutlinedButton.icon(
              onPressed: _saving ? null : () => _addTracks(playlist),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add tracks'),
            ),
            PopupMenuButton<String>(
              tooltip: 'Playlist options',
              onSelected: (value) => runUiAction(context, () async {
                switch (value) {
                  case 'rename':
                    final name = await askForName(
                      context,
                      title: 'Rename playlist',
                      initial: playlist.name,
                    );
                    if (name != null) {
                      await app.savePlaylist(playlist, name: name);
                    }
                  case 'pin':
                    await app.pinPlaylist(
                      playlist.id,
                      pinned: !app.isPinned('playlist', playlist.id),
                    );
                  case 'delete':
                    if (await confirmAction(
                      context,
                      title: 'Delete playlist?',
                      message:
                          'Delete “${playlist.name}”? Your tracks will stay in your library.',
                    )) {
                      await app.deletePlaylist(playlist);
                    }
                }
              }),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                PopupMenuItem(
                  value: 'pin',
                  child: Text(
                    app.isPinned('playlist', playlist.id)
                        ? 'Stop keeping offline'
                        : 'Keep playlist offline',
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Text('Delete playlist'),
                ),
              ],
            ),
          ],
        ),
        if (_saving) const QuietProgress(label: 'Saving playlist order'),
        Expanded(
          child: playlist.entries.isEmpty
              ? EmptyState(
                  icon: Icons.playlist_add_rounded,
                  title: 'Room for your favorites',
                  message: 'Add tracks from your library. Repeated tracks are welcome.',
                  action: FilledButton.tonal(
                    onPressed: () => _addTracks(playlist),
                    child: const Text('Add tracks'),
                  ),
                )
              : ReorderableListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                  buildDefaultDragHandles: false,
                  itemCount: playlist.entries.length,
                  onReorderItem: (oldIndex, newIndex) {
                    if (_saving) return;
                    final entries = [...playlist.entries];
                    entries.insert(newIndex, entries.removeAt(oldIndex));
                    _saveEntries(playlist, entries);
                  },
                  itemBuilder: (context, index) {
                    final entry = playlist.entries[index];
                    final track = app.trackById(entry.trackId);
                    return ListTile(
                      key: ValueKey(entry.id),
                      leading: ReorderableDragStartListener(
                        index: index,
                        enabled: !_saving,
                        child: Tooltip(
                          message: 'Drag to reorder',
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Icon(
                              Icons.drag_handle_rounded,
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        ),
                      ),
                      title: Text(
                        '${index + 1}. ${track?.title ?? 'Unavailable track'}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(track?.artist ?? 'Removed from library'),
                      onTap: track == null
                          ? null
                          : () => runUiAction(
                              context,
                              () => app.playback.playQueue(
                                queue,
                                index: playlist.entries
                                    .take(index)
                                    .where(
                                      (item) =>
                                          app.trackById(item.trackId) != null,
                                    )
                                    .length,
                              ),
                            ),
                      trailing: PopupMenuButton<String>(
                        enabled: !_saving,
                        tooltip: 'Entry ${index + 1} options',
                        onSelected: (value) {
                          final entries = [...playlist.entries];
                          switch (value) {
                            case 'up':
                              entries.insert(
                                index - 1,
                                entries.removeAt(index),
                              );
                            case 'down':
                              entries.insert(
                                index + 1,
                                entries.removeAt(index),
                              );
                            case 'duplicate':
                              entries.insert(
                                index + 1,
                                PlaylistEntry(
                                  id: app.newId(),
                                  trackId: entry.trackId,
                                ),
                              );
                            case 'remove':
                              entries.removeAt(index);
                          }
                          _saveEntries(playlist, entries);
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'up',
                            enabled: index > 0,
                            child: const Text('Move up'),
                          ),
                          PopupMenuItem(
                            value: 'down',
                            enabled: index < playlist.entries.length - 1,
                            child: const Text('Move down'),
                          ),
                          const PopupMenuItem(
                            value: 'duplicate',
                            child: Text('Repeat this track'),
                          ),
                          const PopupMenuItem(
                            value: 'remove',
                            child: Text('Remove entry'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _AddTracksDialog extends StatefulWidget {
  const _AddTracksDialog({required this.app});
  final AppController app;
  @override
  State<_AddTracksDialog> createState() => _AddTracksDialogState();
}

class _AddTracksDialogState extends State<_AddTracksDialog> {
  String _query = '';
  final List<String> _selected = [];

  @override
  Widget build(BuildContext context) {
    final tracks = widget.app.tracks
        .where(
          (track) => '${track.title} ${track.artist} ${track.album}'
              .toLowerCase()
              .contains(_query),
        )
        .toList();
    return AlertDialog(
      title: const Text('Add tracks'),
      content: SizedBox(
        width: 480,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search your library',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (value) =>
                  setState(() => _query = value.toLowerCase()),
            ),
            const SizedBox(height: 8),
            const Text('Tap ＋ again to add another occurrence.'),
            Expanded(
              child: tracks.isEmpty
                  ? const Center(child: Text('No matching tracks'))
                  : ListView.builder(
                      itemCount: tracks.length,
                      itemBuilder: (context, index) {
                        final track = tracks[index];
                        final count = _selected
                            .where((id) => id == track.id)
                            .length;
                        return ListTile(
                          title: Text(track.title, maxLines: 2),
                          subtitle: Text(track.artist, maxLines: 1),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (count > 0)
                                IconButton(
                                  tooltip: 'Remove one ${track.title}',
                                  onPressed: () => setState(
                                    () => _selected.remove(track.id),
                                  ),
                                  icon: const Icon(
                                    Icons.remove_circle_outline_rounded,
                                  ),
                                ),
                              if (count > 0) Text('$count'),
                              IconButton(
                                tooltip: 'Add ${track.title}',
                                onPressed: () =>
                                    setState(() => _selected.add(track.id)),
                                icon: const Icon(
                                  Icons.add_circle_outline_rounded,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, _selected),
          child: Text('Add ${_selected.length}'),
        ),
      ],
    );
  }
}
