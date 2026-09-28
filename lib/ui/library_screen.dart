import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import 'track_widgets.dart';
import 'widgets.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.app,
    required this.searchFocus,
    required this.onUpload,
    required this.onSignIn,
  });
  final AppController app;
  final FocusNode searchFocus;
  final VoidCallback onUpload;
  final VoidCallback onSignIn;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _search = TextEditingController();
  String _view = 'Tracks';
  String? _group;

  @override
  void dispose() {
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
    final query = _search.text.trim().toLowerCase();
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
    final visible = _group == null ? filtered : groups[_group] ?? <Track>[];
    if (_view == 'Albums' && _group != null) {
      visible.sort((a, b) {
        final disc = (a.discNumber ?? 0).compareTo(b.discNumber ?? 0);
        return disc != 0
            ? disc
            : (a.trackNumber ?? 0).compareTo(b.trackNumber ?? 0);
      });
    }
    return LayoutBuilder(
      builder: (context, constraints) => CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SectionHeading(
                  'Library',
                  subtitle:
                      '${app.tracks.length} tracks · Your music, your space',
                  actions: [
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
                    onChanged: (_) => setState(() => _group = null),
                    decoration: InputDecoration(
                      hintText: 'Search tracks, albums, artists',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () => setState(() {
                                _search.clear();
                                _group = null;
                              }),
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
                          onSelected: (_) => setState(() {
                            _view = view;
                            _group = null;
                          }),
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
                          onPressed: () => setState(() => _group = null),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        Expanded(
                          child: Text(
                            _groupTitle(_group!),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        if (_view == 'Albums' && visible.isNotEmpty)
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
                                  () => app.play(visible.first, queue: visible),
                                ),
                          icon: const Icon(Icons.play_arrow_rounded),
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
                message: 'Connect to your Yun server to listen, organize, and keep favorites offline.',
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
                message: 'Upload audio files from this device. On desktop, you can also drop files anywhere in Yun.',
                action: FilledButton.tonalIcon(
                  onPressed: widget.onUpload,
                  icon: const Icon(Icons.upload_file_rounded),
                  label: const Text('Choose audio files'),
                ),
              ),
            )
          else if (filtered.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.search_off_rounded,
                title: 'No matches',
                message: 'Try another title, album, or artist.',
              ),
            )
          else if (_view == 'Tracks' || _group != null)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
              sliver: SliverList.builder(
                itemCount: visible.length,
                itemBuilder: (context, index) =>
                    TrackTile(app: app, track: visible[index], queue: visible),
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
            onTap: () => setState(() => _group = keys[index]),
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
              onTap: () => setState(() => _group = keys[index]),
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
