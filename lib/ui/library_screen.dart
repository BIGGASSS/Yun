import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/collection_settings_controller.dart';
import 'collection_controls.dart';
import 'track_widgets.dart';
import 'widgets.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.app,
    required this.searchFocus,
    required this.onUpload,
    required this.onSignIn,
    this.collectionSettings,
  });
  final AppController app;
  final FocusNode searchFocus;
  final VoidCallback onUpload;
  final VoidCallback onSignIn;
  final CollectionSettingsController? collectionSettings;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _search = TextEditingController();
  String _view = 'Tracks';
  String? _group;
  bool _selecting = false, _acting = false;
  final _localSettings = CollectionSettingsController();
  CollectionSettingsController get _settings =>
      widget.collectionSettings ?? _localSettings;
  TrackSortSurface get _sortSurface => switch (_view) {
    'Albums' => TrackSortSurface.album,
    'Artists' => TrackSortSurface.artist,
    _ => TrackSortSurface.library,
  };
  final _selected = <String>{};
  Object? _accountScope;
  Object? _viewKey;
  List<Track> _filtered = const [], _visible = const [];
  Map<String, List<Track>> _grouped = const {};

  Object get _scope =>
      (widget.app, widget.app.account?.server, widget.app.account?.userId);

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_appChanged);
  }

  @override
  void didUpdateWidget(covariant LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app) {
      oldWidget.app.removeListener(_appChanged);
      widget.app.addListener(_appChanged);
    }
  }

  void _appChanged() {
    if (mounted) setState(() {});
  }

  void _openGroup(String? group) => setState(() {
    _group = group;
    _selected.clear();
    _selecting = false;
  });

  void _setSort(TrackSort sort, bool descending) {
    setState(() {
      runUiAction(
        context,
        () =>
            _settings.setTrackSort(_sortSurface, sort, descending: descending),
      );
    });
  }

  Future<void> _bulk(List<Track> tracks, String action) async {
    final app = widget.app;
    final scope = _scope;
    bool stillSelected(Track track) =>
        mounted &&
        _scope == scope &&
        app.isAuthenticated &&
        _selected.contains(track.id);
    setState(() => _acting = true);
    try {
      await runUiAction(context, () async {
        if (action == 'delete' &&
            !await confirmAction(
              context,
              title: 'Delete ${tracks.length} selected tracks?',
              message: 'The selected tracks will be removed from your library and playlists on all devices.',
            )) {
          return;
        }
        final current = tracks.where(stillSelected).toList();
        if (!mounted || current.isEmpty) return;
        switch (action) {
          case 'play':
            await app.playback.playQueue(current);
          case 'playlist':
            await addTracksToPlaylist(context, app, current);
          case 'offline':
            await app.pinTracks(current.map((track) => track.id));
          case 'delete':
            for (final track in current) {
              if (!stillSelected(track)) continue;
              await app.deleteTrack(track.id);
              _selected.remove(track.id);
            }
        }
      });
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  void dispose() {
    widget.app.removeListener(_appChanged);
    _search.dispose();
    super.dispose();
  }

  String _groupKey(Track track) => _view == 'Albums'
      ? '${track.album}\u0000${track.albumArtist.isEmpty ? track.artist : track.albumArtist}'
      : track.artist;
  String _groupTitle(String key) {
    final name = key.split('\u0000').first;
    return name.isEmpty
        ? 'Unknown ${_view == 'Albums' ? 'album' : 'artist'}'
        : name;
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    if (_accountScope != _scope || !app.isAuthenticated) {
      _accountScope = _scope;
      _selected.clear();
      _selecting = false;
    }
    final query = _search.text.trim().toLowerCase();
    final albumDetail = _view == 'Albums' && _group != null;
    final trackView = _view == 'Tracks' || _group != null;
    final selection = trackView
        ? _settings.settings.trackSort(_sortSurface)
        : const TrackSortSelection(TrackSort.title);
    final sort = selection.sort;
    final descending = selection.descending;
    final viewKey = (app.tracks, query, _view, _group, sort, descending);
    if (_viewKey != viewKey) {
      _viewKey = viewKey;
      final filtered = app.tracks
          .where(
            (track) =>
                query.isEmpty ||
                '${track.title} ${track.artist} ${track.album} ${track.albumArtist}'
                    .toLowerCase()
                    .contains(query),
          )
          .toList();
      final groups = <String, List<Track>>{};
      if (_view != 'Tracks') {
        for (final track in filtered) {
          groups.putIfAbsent(_groupKey(track), () => []).add(track);
        }
      }
      var visible = _group == null ? filtered : groups[_group] ?? <Track>[];
      if (albumDetail) {
        visible.sort((a, b) {
          final disc = (a.discNumber ?? 0).compareTo(b.discNumber ?? 0);
          return disc != 0
              ? disc
              : (a.trackNumber ?? 0).compareTo(b.trackNumber ?? 0);
        });
      }
      _visible = sortTracks(visible, sort, descending: descending);
      _filtered = filtered;
      _grouped = groups;
    }
    final visible = _visible;
    final filtered = _filtered;
    final groups = _grouped;
    // IDs survive reordering, but hidden/stale/account-scoped selections do not.
    final visibleIds = trackView && app.isAuthenticated
        ? visible.map((track) => track.id).toSet()
        : <String>{};
    _selected.retainAll(visibleIds);
    final selectedTracks = visible
        .where((track) => _selected.contains(track.id))
        .toList();
    final canAct = selectedTracks.isNotEmpty && !_acting && !app.busy;
    return LayoutBuilder(
      builder: (context, constraints) => CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeading(
                  'Library',
                  subtitle: '${app.tracks.length} tracks',
                  actions: [
                    FilledButton.tonalIcon(
                      onPressed: app.isAuthenticated && visible.isNotEmpty
                          ? () => runUiAction(
                              context,
                              () => app.playback.playQueue(visible),
                            )
                          : null,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Play'),
                    ),
                    IconButton(
                      tooltip: 'Sync library',
                      onPressed: app.isAuthenticated && !app.busy
                          ? () => runUiAction(context, app.refresh)
                          : null,
                      icon: const Icon(Icons.sync_rounded),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: app.isAuthenticated ? widget.onUpload : null,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Upload'),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: TextField(
                    controller: _search,
                    focusNode: widget.searchFocus,
                    textInputAction: TextInputAction.search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Search tracks, albums, artists',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () => setState(_search.clear),
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final view in ['Tracks', 'Albums', 'Artists'])
                        ChoiceChip(
                          label: Text(view),
                          selected: _view == view,
                          onSelected: (_) {
                            _view = view;
                            _openGroup(null);
                          },
                        ),
                    ],
                  ),
                ),
                if (_group != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: 'Back to ${_view.toLowerCase()}',
                          onPressed: () => _openGroup(null),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        Expanded(
                          child: Text(
                            _groupTitle(_group!),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        if (albumDetail && visible.isNotEmpty)
                          IconButton(
                            tooltip: 'Keep album offline',
                            onPressed: () => runUiAction(
                              context,
                              () => app.pinAlbum(
                                visible.first.album,
                                visible.first.albumArtist.isEmpty
                                    ? visible.first.artist
                                    : visible.first.albumArtist,
                              ),
                            ),
                            icon: const Icon(Icons.download_outlined),
                          ),
                        IconButton(
                          tooltip: 'Play all',
                          onPressed: visible.isEmpty
                              ? null
                              : () => runUiAction(
                                  context,
                                  () => app.playback.playQueue(visible),
                                ),
                          icon: const Icon(Icons.play_arrow_rounded),
                        ),
                      ],
                    ),
                  ),
                if (app.isAuthenticated && trackView)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            TrackSortControl(
                              value: sort,
                              descending: descending,
                              allowOriginal: albumDetail,
                              originalLabel: 'Album order',
                              onChanged: (value) => _setSort(value, descending),
                              onToggleDirection: () =>
                                  _setSort(sort, !descending),
                            ),
                            TextButton.icon(
                              onPressed: _acting
                                  ? null
                                  : () => setState(() {
                                      _selecting = !_selecting;
                                      _selected.clear();
                                    }),
                              icon: Icon(
                                _selecting
                                    ? Icons.close_rounded
                                    : Icons.checklist_rounded,
                              ),
                              label: Text(
                                _selecting ? 'Done selecting' : 'Select tracks',
                              ),
                            ),
                          ],
                        ),
                        if (_selecting)
                          SelectionControls(
                            selectedCount: _selected.length,
                            allSelected:
                                visibleIds.isNotEmpty &&
                                _selected.length == visibleIds.length,
                            onSelectAll: visibleIds.isEmpty || _acting
                                ? null
                                : () => setState(() {
                                    if (_selected.containsAll(visibleIds)) {
                                      _selected.removeAll(visibleIds);
                                    } else {
                                      _selected.addAll(visibleIds);
                                    }
                                  }),
                            onClear: _selected.isEmpty || _acting
                                ? null
                                : () => setState(_selected.clear),
                            actions: [
                              TextButton.icon(
                                onPressed: canAct
                                    ? () => _bulk(selectedTracks, 'play')
                                    : null,
                                icon: const Icon(Icons.play_arrow_rounded),
                                label: const Text('Play selected'),
                              ),
                              TextButton.icon(
                                onPressed: canAct && !app.isOffline
                                    ? () => _bulk(selectedTracks, 'playlist')
                                    : null,
                                icon: const Icon(Icons.playlist_add_rounded),
                                label: const Text('Add selected to playlist'),
                              ),
                              TextButton.icon(
                                onPressed: canAct
                                    ? () => _bulk(selectedTracks, 'offline')
                                    : null,
                                icon: const Icon(Icons.download_outlined),
                                label: const Text('Keep selected offline'),
                              ),
                              TextButton.icon(
                                onPressed: canAct && !app.isOffline
                                    ? () => _bulk(selectedTracks, 'delete')
                                    : null,
                                icon: const Icon(Icons.delete_outline_rounded),
                                label: const Text('Delete selected'),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (!app.isAuthenticated)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.library_music_outlined,
                title: 'A home for your music',
                message: 'Connect to your 韵 server to listen, organize, and keep favorites offline.',
                action: FilledButton(
                  onPressed: widget.onSignIn,
                  child: const Text('Connect to server'),
                ),
              ),
            )
          else if (app.tracks.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.audio_file_outlined,
                title: 'Start with a song',
                message: 'Upload audio files from this device. On desktop, you can also drop files anywhere in 韵.',
                action: FilledButton.tonalIcon(
                  onPressed: widget.onUpload,
                  icon: const Icon(Icons.upload_file_rounded),
                  label: const Text('Choose audio files'),
                ),
              ),
            )
          else if (visible.isEmpty && trackView || filtered.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.search_off_rounded,
                title: 'No matches',
                message: 'Try another title, album, or artist.',
              ),
            )
          else if (trackView)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
              sliver: SliverList.builder(
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final track = visible[index];
                  return TrackTile(
                    key: ValueKey(track.id),
                    app: app,
                    track: track,
                    queue: visible,
                    selected: _selecting ? _selected.contains(track.id) : null,
                    onSelectionChanged: !_selecting
                        ? null
                        : (value) {
                            if (_acting) return;
                            setState(() {
                              if (value == true) {
                                _selected.add(track.id);
                              } else {
                                _selected.remove(track.id);
                              }
                            });
                          },
                  );
                },
              ),
            )
          else
            _groups(context, groups, constraints.maxWidth),
        ],
      ),
    );
  }

  Widget _groups(
    BuildContext context,
    Map<String, List<Track>> groups,
    double width,
  ) {
    final keys = groups.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    if (width < 480 || MediaQuery.textScalerOf(context).scale(1) > 1.3) {
      return SliverList.builder(
        itemCount: keys.length,
        itemBuilder: (context, index) {
          final tracks = groups[keys[index]]!;
          return ListTile(
            leading: TrackArtwork(app: widget.app, track: tracks.first),
            title: Text(_groupTitle(keys[index])),
            subtitle: Text('${tracks.length} tracks'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => _openGroup(keys[index]),
          );
        },
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 240,
          mainAxisExtent: 268,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
        ),
        itemCount: keys.length,
        itemBuilder: (context, index) {
          final tracks = groups[keys[index]]!;
          return Card(
            margin: EdgeInsets.zero,
            elevation: 0,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _openGroup(keys[index]),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Center(
                        child: TrackArtwork(
                          app: widget.app,
                          track: tracks.first,
                          size: 168,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _groupTitle(keys[index]),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      '${tracks.length} tracks',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
