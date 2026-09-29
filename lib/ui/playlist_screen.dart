import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import 'collection_controls.dart';
import 'widgets.dart';

enum _PlaylistSort { name, updated, count }

/// Capture identity, not just collection IDs (which can coincide across users).
class _PlaylistScope {
  _PlaylistScope(this.app)
    : server = app.account?.server,
      userId = app.account?.userId;

  final AppController app;
  final String? server, userId;

  bool matches(AppController current) =>
      identical(app, current) &&
      server == current.account?.server &&
      userId == current.account?.userId;
}

class PlaylistsScreen extends StatefulWidget {
  const PlaylistsScreen({super.key, required this.app});
  final AppController app;

  @override
  State<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends State<PlaylistsScreen> {
  String? _selectedId;
  bool _saving = false;
  final _selectedPlaylists = <String>{};
  final _selectedEntries = <String>{};
  _PlaylistSort _playlistSort = _PlaylistSort.name;
  bool _playlistDescending = false;
  TrackSort _trackSort = TrackSort.original;
  bool _trackDescending = false;

  late _PlaylistScope _scope;

  @override
  void initState() {
    super.initState();
    _scope = _PlaylistScope(widget.app);
    widget.app.addListener(_appChanged);
  }

  @override
  void didUpdateWidget(covariant PlaylistsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.app, widget.app)) {
      oldWidget.app.removeListener(_appChanged);
      widget.app.addListener(_appChanged);
    }
    _syncScope();
  }

  @override
  void dispose() {
    widget.app.removeListener(_appChanged);
    super.dispose();
  }

  void _syncScope() {
    if (_scope.matches(widget.app)) return;
    // A new token also invalidates intents if the user switches away and back.
    _scope = _PlaylistScope(widget.app);
    _selectedId = null;
    _selectedPlaylists.clear();
    _selectedEntries.clear();
    _trackSort = TrackSort.original;
    _trackDescending = false;
    _saving = false;
  }

  void _appChanged() => setState(_syncScope);

  bool _isCurrent(_PlaylistScope scope) =>
      mounted && identical(scope, _scope) && scope.matches(widget.app);

  void _guard(_PlaylistScope scope, VoidCallback action) {
    if (_isCurrent(scope)) action();
  }

  Playlist? _latest(String id) =>
      widget.app.playlists.where((item) => item.id == id).firstOrNull;

  Future<void> _mutate(
    _PlaylistScope scope,
    Future<void> Function() action,
  ) async {
    if (!_isCurrent(scope) || _saving) return;
    setState(() => _saving = true);
    try {
      await runUiAction(context, action);
    } finally {
      if (_isCurrent(scope)) setState(() => _saving = false);
    }
  }

  void _open(_PlaylistScope scope, String? id) => _guard(scope, () {
    setState(() {
      _selectedId = id;
      _selectedEntries.clear();
      _trackSort = TrackSort.original;
      _trackDescending = false;
    });
  });

  Future<void> _create(_PlaylistScope scope) => _mutate(scope, () async {
    final name = await askForName(context, title: 'New playlist');
    if (name == null || !_isCurrent(scope)) return;
    final playlist = await scope.app.createPlaylist(name);
    _open(scope, playlist.id);
  });

  Future<void> _addTracks(_PlaylistScope scope, Playlist playlist) =>
      _mutate(scope, () async {
        final result = await showDialog<Set<String>>(
          context: context,
          builder: (_) => _AddTracksDialog(
            app: scope.app,
            playlistId: playlist.id,
            isCurrent: () => _isCurrent(scope),
          ),
        );
        if (result == null || result.isEmpty || !_isCurrent(scope)) return;
        // Both the revision and membership may change while the modal is open.
        final current = _latest(playlist.id);
        if (current == null) return;
        final existing = current.entries.map((entry) => entry.trackId).toSet();
        final available = widget.app.tracks.map((track) => track.id).toSet();
        final additions = result
            .where((id) => available.contains(id) && existing.add(id))
            .toList();
        if (additions.isEmpty) return;
        await widget.app.savePlaylist(
          current,
          entries: [
            ...current.entries,
            for (final id in additions)
              PlaylistEntry(id: widget.app.newId(), trackId: id),
          ],
        );
      });

  Future<void> _bulkPlaylists(
    _PlaylistScope scope, {
    required bool delete,
  }) => _mutate(scope, () async {
    final ids = {..._selectedPlaylists};
    if (delete &&
        !await confirmAction(
          context,
          title: 'Delete selected playlists?',
          message:
              'Delete ${ids.length} playlists? Your tracks will stay in your library.',
        )) {
      return;
    }
    for (final id in ids) {
      if (!_isCurrent(scope)) return;
      final current = _latest(id);
      if (current == null) continue;
      if (delete) {
        await widget.app.deletePlaylist(current);
      } else {
        await widget.app.pinPlaylist(id);
      }
    }
    if (_isCurrent(scope)) setState(_selectedPlaylists.clear);
  });

  Future<void> _removeEntries(
    _PlaylistScope scope,
    Playlist playlist,
    Set<String> ids,
  ) => _mutate(scope, () async {
    if (!await confirmAction(
          context,
          title: 'Remove selected entries?',
          message:
              'Remove ${ids.length} entries from this playlist? Your tracks will stay in your library.',
          confirmLabel: 'Remove',
        ) ||
        !_isCurrent(scope)) {
      return;
    }
    final current = _latest(playlist.id);
    if (current == null) return;
    await widget.app.savePlaylist(
      current,
      entries: [
        for (final entry in current.entries)
          if (!ids.contains(entry.id)) entry,
      ],
    );
    if (_isCurrent(scope)) setState(() => _selectedEntries.removeAll(ids));
  });

  Future<void> _playlistAction(
    _PlaylistScope scope,
    Playlist playlist,
    String action,
  ) => _mutate(scope, () async {
    switch (action) {
      case 'rename':
        final name = await askForName(
          context,
          title: 'Rename playlist',
          initial: playlist.name,
        );
        if (!_isCurrent(scope)) return;
        final current = _latest(playlist.id);
        if (name != null && current != null) {
          await widget.app.savePlaylist(current, name: name);
        }
      case 'pin':
        if (_latest(playlist.id) == null) return;
        await widget.app.pinPlaylist(
          playlist.id,
          pinned: !widget.app.isPinned('playlist', playlist.id),
        );
      case 'delete':
        if (!await confirmAction(
              context,
              title: 'Delete playlist?',
              message:
                  'Delete “${playlist.name}”? Your tracks will stay in your library.',
            ) ||
            !_isCurrent(scope)) {
          return;
        }
        final current = _latest(playlist.id);
        if (current != null) await widget.app.deletePlaylist(current);
    }
  });

  void _toggle(_PlaylistScope scope, Set<String> selection, String id) =>
      _guard(
        scope,
        () => setState(() {
          if (!selection.add(id)) selection.remove(id);
        }),
      );

  Widget _selection(
    Set<String> selection,
    Iterable<String> visible, {
    List<Widget> actions = const [],
  }) {
    final scope = _scope;
    final ids = visible.toSet();
    final all = ids.isNotEmpty && ids.every(selection.contains);
    return SelectionControls(
      selectedCount: selection.length,
      allSelected: all,
      onSelectAll: _saving || ids.isEmpty
          ? null
          : () => _guard(
              scope,
              () => setState(() {
                if (all) {
                  selection.removeAll(ids);
                } else {
                  selection.addAll(ids);
                }
              }),
            ),
      onClear: _saving || selection.isEmpty
          ? null
          : () => _guard(scope, () => setState(selection.clear)),
      actions: actions,
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncScope();
    final scope = _scope;
    final app = widget.app;
    _selectedPlaylists.retainAll(app.playlists.map((item) => item.id));
    final selected = _selectedId == null ? null : _latest(_selectedId!);
    if (selected != null) return _detail(context, selected);
    _selectedId = null;
    _selectedEntries.clear();
    final playlists = [...app.playlists]
      ..sort((a, b) {
        final comparison = switch (_playlistSort) {
          _PlaylistSort.name => a.name.toLowerCase().compareTo(
            b.name.toLowerCase(),
          ),
          _PlaylistSort.updated => a.updatedAt.compareTo(b.updatedAt),
          _PlaylistSort.count => a.entries.length.compareTo(b.entries.length),
        };
        final result = comparison == 0 ? a.id.compareTo(b.id) : comparison;
        return _playlistDescending ? -result : result;
      });
    return _CollectionLayout(
      header: [
        SectionHeading(
          'Playlists',
          subtitle: 'Put things in your own order',
          actions: [
            FilledButton.tonalIcon(
              onPressed: app.isAuthenticated && !_saving
                  ? () => _create(scope)
                  : null,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New playlist'),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PopupMenuButton<_PlaylistSort>(
                tooltip: 'Sort by',
                enabled: !_saving,
                initialValue: _playlistSort,
                onSelected: (value) =>
                    _guard(scope, () => setState(() => _playlistSort = value)),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: _PlaylistSort.name, child: Text('Name')),
                  PopupMenuItem(
                    value: _PlaylistSort.updated,
                    child: Text('Date updated'),
                  ),
                  PopupMenuItem(
                    value: _PlaylistSort.count,
                    child: Text('Track count'),
                  ),
                ],
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Sort by: ${switch (_playlistSort) {
                      _PlaylistSort.name => 'Name',
                      _PlaylistSort.updated => 'Date updated',
                      _PlaylistSort.count => 'Track count',
                    }}',
                  ),
                ),
              ),
              IconButton(
                tooltip: _playlistDescending
                    ? 'Sort ascending'
                    : 'Sort descending',
                onPressed: _saving
                    ? null
                    : () => _guard(
                        scope,
                        () => setState(
                          () => _playlistDescending = !_playlistDescending,
                        ),
                      ),
                icon: Icon(
                  _playlistDescending
                      ? Icons.arrow_downward
                      : Icons.arrow_upward,
                ),
              ),
            ],
          ),
        ),
        _selection(
          _selectedPlaylists,
          playlists.map((item) => item.id),
          actions: [
            if (_selectedPlaylists.isNotEmpty) ...[
              TextButton.icon(
                onPressed: _saving
                    ? null
                    : () => _bulkPlaylists(scope, delete: false),
                icon: const Icon(Icons.download_outlined),
                label: const Text('Keep offline'),
              ),
              TextButton.icon(
                onPressed: _saving
                    ? null
                    : () => _bulkPlaylists(scope, delete: true),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete selected'),
              ),
            ],
          ],
        ),
        if (_saving && ModalRoute.isCurrentOf(context) == true)
          const QuietProgress(label: 'Saving playlists'),
      ],
      body: playlists.isEmpty
          ? const EmptyState(
              icon: Icons.queue_music_rounded,
              title: 'Make a little collection',
              message:
                  'Create playlists for a mood, a moment, or a favorite album.',
            )
          : ListView.builder(
              itemCount: playlists.length,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemBuilder: (context, index) {
                final playlist = playlists[index];
                return ListTile(
                  key: ValueKey('playlist-${playlist.id}'),
                  leading: Checkbox(
                    semanticLabel: 'Select ${playlist.name}',
                    value: _selectedPlaylists.contains(playlist.id),
                    onChanged: _saving
                        ? null
                        : (_) =>
                              _toggle(scope, _selectedPlaylists, playlist.id),
                  ),
                  title: Text(playlist.name),
                  subtitle: Text(
                    '${playlist.entries.length} entries${app.isPinned('playlist', playlist.id) ? ' · Kept offline' : ''}',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _saving ? null : () => _open(scope, playlist.id),
                );
              },
            ),
    );
  }

  List<PlaylistEntry> _displayEntries(Playlist playlist) {
    final entries = [...playlist.entries];
    if (_trackSort == TrackSort.original) {
      return _trackDescending ? entries.reversed.toList() : entries;
    }
    final positions = {
      for (var i = 0; i < entries.length; i++) entries[i].id: i,
    };
    entries.sort((a, b) {
      final left = widget.app.trackById(a.trackId);
      final right = widget.app.trackById(b.trackId);
      // Missing tracks remain visible and removable, always after playable ones.
      if (left == null || right == null) {
        if (left != null) return -1;
        if (right != null) return 1;
        return positions[a.id]!.compareTo(positions[b.id]!);
      }
      final result = compareTracks(left, right, _trackSort);
      if (result == 0) return positions[a.id]!.compareTo(positions[b.id]!);
      return _trackDescending ? -result : result;
    });
    return entries;
  }

  Future<void> _move(
    _PlaylistScope scope,
    Playlist playlist,
    String id,
    int destination,
  ) => _mutate(scope, () async {
    if (_trackSort != TrackSort.original || _trackDescending) return;
    final current = _latest(playlist.id);
    if (current == null) return;
    // Do not apply positional intent to a concurrently modified order.
    if (current.revision != playlist.revision ||
        current.entries.map((e) => e.id).join('\n') !=
            playlist.entries.map((e) => e.id).join('\n')) {
      return;
    }
    final entries = [...current.entries];
    final index = entries.indexWhere((entry) => entry.id == id);
    if (index < 0 || destination < 0 || destination >= entries.length) return;
    entries.insert(destination, entries.removeAt(index));
    await widget.app.savePlaylist(current, entries: entries);
  });

  Widget _detail(BuildContext context, Playlist playlist) {
    final scope = _scope;
    final app = widget.app;
    _selectedEntries.retainAll(playlist.entries.map((entry) => entry.id));
    final entries = _displayEntries(playlist);
    final queue = [
      for (final entry in entries)
        if (app.trackById(entry.trackId) case final Track track) track,
    ];
    final selectedQueue = [
      for (final entry in entries)
        if (_selectedEntries.contains(entry.id))
          if (app.trackById(entry.trackId) case final Track track) track,
    ];
    final reorder = _trackSort == TrackSort.original && !_trackDescending;
    return _CollectionLayout(
      header: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 24, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _saving ? null : () => _open(scope, null),
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('Playlists'),
            ),
          ),
        ),
        SectionHeading(
          playlist.name,
          subtitle:
              '${playlist.entries.length} entries · ${reorder ? 'Drag to reorder' : 'Sorted view; order unchanged'}',
          actions: [
            FilledButton.tonalIcon(
              onPressed: _saving || queue.isEmpty
                  ? null
                  : () => _guard(
                      scope,
                      () => runUiAction(
                        context,
                        () => app.playback.playQueue(queue),
                      ),
                    ),
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text('Play'),
            ),
            OutlinedButton.icon(
              onPressed: _saving ? null : () => _addTracks(scope, playlist),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add tracks'),
            ),
            PopupMenuButton<String>(
              tooltip: 'Playlist options',
              enabled: !_saving,
              onSelected: (value) => _playlistAction(scope, playlist, value),
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
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TrackSortControl(
            value: _trackSort,
            descending: _trackDescending,
            allowOriginal: true,
            enabled: !_saving,
            onChanged: (value) => _guard(
              scope,
              () => setState(() {
                _trackSort = value;
                if (value == TrackSort.original) _trackDescending = false;
              }),
            ),
            onToggleDirection: () => _guard(
              scope,
              () => setState(() => _trackDescending = !_trackDescending),
            ),
          ),
        ),
        _selection(
          _selectedEntries,
          entries.map((entry) => entry.id),
          actions: [
            if (_selectedEntries.isNotEmpty) ...[
              TextButton.icon(
                onPressed: _saving || selectedQueue.isEmpty
                    ? null
                    : () => _guard(
                        scope,
                        () => runUiAction(
                          context,
                          () => app.playback.playQueue(selectedQueue),
                        ),
                      ),
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Play selected'),
              ),
              TextButton.icon(
                onPressed: _saving
                    ? null
                    : () => _removeEntries(scope, playlist, {
                        ..._selectedEntries,
                      }),
                icon: const Icon(Icons.remove_circle_outline),
                label: const Text('Remove selected'),
              ),
            ],
          ],
        ),
        if (_saving && ModalRoute.isCurrentOf(context) == true)
          const QuietProgress(label: 'Saving playlist'),
      ],
      body: entries.isEmpty
          ? const EmptyState(
              icon: Icons.playlist_add_rounded,
              title: 'Room for your favorites',
              message: 'Add tracks from your library.',
            )
          : reorder
          ? ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
              buildDefaultDragHandles: false,
              itemCount: entries.length,
              onReorderItem: (oldIndex, newIndex) {
                if (!_saving) {
                  _move(scope, playlist, entries[oldIndex].id, newIndex);
                }
              },
              itemBuilder: (context, index) => _entryTile(
                scope,
                playlist,
                entries,
                queue,
                index,
                reorder: true,
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
              itemCount: entries.length,
              itemBuilder: (context, index) => _entryTile(
                scope,
                playlist,
                entries,
                queue,
                index,
                reorder: false,
              ),
            ),
    );
  }

  Widget _entryTile(
    _PlaylistScope scope,
    Playlist playlist,
    List<PlaylistEntry> entries,
    List<Track> queue,
    int index, {
    required bool reorder,
  }) {
    final entry = entries[index];
    final track = widget.app.trackById(entry.trackId);
    return ListTile(
      key: ValueKey(entry.id),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            semanticLabel: 'Select entry ${index + 1}',
            value: _selectedEntries.contains(entry.id),
            onChanged: _saving
                ? null
                : (_) => _toggle(scope, _selectedEntries, entry.id),
          ),
          if (reorder)
            ReorderableDragStartListener(
              index: index,
              enabled: !_saving,
              child: const Tooltip(
                message: 'Drag to reorder',
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.drag_handle_rounded),
                ),
              ),
            ),
        ],
      ),
      title: Text(
        '${index + 1}. ${track?.title ?? 'Unavailable track'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        track?.artist ?? 'Removed from library',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: _saving || track == null
          ? null
          : () => _guard(
              scope,
              () => runUiAction(
                context,
                () => widget.app.playback.playQueue(
                  queue,
                  index: entries
                      .take(index)
                      .where(
                        (item) => widget.app.trackById(item.trackId) != null,
                      )
                      .length,
                ),
              ),
            ),
      trailing: PopupMenuButton<String>(
        enabled: !_saving,
        tooltip: 'Entry ${index + 1} options',
        onSelected: (value) {
          if (value == 'remove') {
            _removeEntries(scope, playlist, {entry.id});
          } else if (reorder) {
            _move(scope, playlist, entry.id, index + (value == 'up' ? -1 : 1));
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            value: 'up',
            enabled: reorder && index > 0,
            child: const Text('Move up'),
          ),
          PopupMenuItem(
            value: 'down',
            enabled: reorder && index < entries.length - 1,
            child: const Text('Move down'),
          ),
          const PopupMenuItem(value: 'remove', child: Text('Remove entry')),
        ],
      ),
    );
  }
}

/// Keep a usable list viewport when controls wrap in narrow/short windows.
class _CollectionLayout extends StatelessWidget {
  const _CollectionLayout({required this.header, required this.body});
  final List<Widget> header;
  final Widget body;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: constraints.maxHeight * .65),
          child: SingleChildScrollView(
            primary: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: header,
            ),
          ),
        ),
        Expanded(child: body),
      ],
    ),
  );
}

class _AddTracksDialog extends StatefulWidget {
  const _AddTracksDialog({
    required this.app,
    required this.playlistId,
    required this.isCurrent,
  });
  final AppController app;
  final String playlistId;
  final bool Function() isCurrent;
  @override
  State<_AddTracksDialog> createState() => _AddTracksDialogState();
}

class _AddTracksDialogState extends State<_AddTracksDialog> {
  String _query = '';
  final _selected = <String>{};
  TrackSort _sort = TrackSort.title;
  bool _descending = false;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.app,
    builder: (context, _) {
      final current = widget.isCurrent();
      final playlist = !current
          ? null
          : widget.app.playlists
                .where((item) => item.id == widget.playlistId)
                .firstOrNull;
      final existing =
          playlist?.entries.map((entry) => entry.trackId).toSet() ?? <String>{};
      final eligible = playlist == null
          ? <Track>[]
          : widget.app.tracks
                .where((track) => !existing.contains(track.id))
                .toList();
      _selected.retainAll(eligible.map((track) => track.id));
      final tracks = sortTracks(
        eligible.where(
          (track) => '${track.title} ${track.artist} ${track.album}'
              .toLowerCase()
              .contains(_query),
        ),
        _sort,
        descending: _descending,
      );
      final visible = tracks.map((track) => track.id).toSet();
      final all = visible.isNotEmpty && visible.every(_selected.contains);
      return AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        title: const Text('Add tracks'),
        content: SizedBox(
          width: 480,
          height: 460,
          child: _CollectionLayout(
            header: [
              TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Search your library',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
              ),
              const SizedBox(height: 8),
              TrackSortControl(
                value: _sort,
                descending: _descending,
                onChanged: (value) => setState(() => _sort = value),
                onToggleDirection: () =>
                    setState(() => _descending = !_descending),
              ),
              SelectionControls(
                selectedCount: _selected.length,
                allSelected: all,
                onSelectAll: visible.isEmpty
                    ? null
                    : () => setState(() {
                        if (all) {
                          _selected.removeAll(visible);
                        } else {
                          _selected.addAll(visible);
                        }
                      }),
                onClear: _selected.isEmpty
                    ? null
                    : () => setState(_selected.clear),
              ),
            ],
            body: tracks.isEmpty
                ? Center(
                    child: Text(
                      !current
                          ? 'Account changed; reopen this playlist'
                          : playlist == null
                          ? 'Playlist no longer exists'
                          : 'No matching tracks to add',
                    ),
                  )
                : ListView.builder(
                    itemCount: tracks.length,
                    itemBuilder: (context, index) {
                      final track = tracks[index];
                      return CheckboxListTile(
                        key: ValueKey('picker-${track.id}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          track.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          track.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        value: _selected.contains(track.id),
                        onChanged: (_) => setState(() {
                          if (!_selected.add(track.id)) {
                            _selected.remove(track.id);
                          }
                        }),
                      );
                    },
                  ),
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
                : () => Navigator.pop(
                    context,
                    widget.isCurrent() ? {..._selected} : null,
                  ),
            child: Text('Add ${_selected.length}'),
          ),
        ],
      );
    },
  );
}
