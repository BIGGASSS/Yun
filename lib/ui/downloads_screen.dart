import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import 'selected_builder.dart';
import 'track_widgets.dart';
import 'widgets.dart';

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) => SelectedBuilder(
    listenable: Listenable.merge([app, app.downloadChanges]),
    select: () => (
      app.tracks,
      app.pins,
      app.playlists,
      app.downloadedTrackIds,
      app.downloadSectionsRevision,
      app.busy,
      app.isAuthenticated,
    ),
    builder: (context, _, child) => _build(context),
  );

  Widget _build(BuildContext context) {
    final tracks = app.tracks;
    final pins = app.pins;
    final playlists = app.playlists;
    final downloadedIds = app.downloadedTrackIds;
    final downloaded = tracks
        .where((track) => downloadedIds.contains(track.id))
        .toList();
    final bytes = downloaded.fold<int>(
      0,
      (total, track) => total + track.sizeBytes,
    );
    final wanted = <String>{};
    final albumPins = <String>{};
    final playlistPins = <String>{};
    for (final pin in pins) {
      switch (pin.type) {
        case 'track':
          wanted.add(pin.id);
        case 'playlist':
          playlistPins.add(pin.id);
        case 'album':
          albumPins.add(pin.id);
      }
    }
    for (final playlist in playlists) {
      if (playlistPins.contains(playlist.id)) {
        wanted.addAll(playlist.entries.map((entry) => entry.trackId));
      }
    }
    final done = <Track>[];
    final pending = <Track>[];
    final failed = <Track>[];
    for (final track in tracks) {
      if (albumPins.contains(
        albumPinId(
          track.album,
          track.albumArtist.isEmpty ? track.artist : track.albumArtist,
        ),
      )) {
        wanted.add(track.id);
      }
      if (downloadedIds.contains(track.id)) {
        if (!app.downloadProgress(track).historyCleared) done.add(track);
      } else if (wanted.contains(track.id)) {
        if (app.downloadProgress(track).status == DownloadStatus.failed) {
          failed.add(track);
        } else {
          pending.add(track);
        }
      }
    }
    wanted.retainAll(tracks.map((track) => track.id));
    final ready = wanted.intersection(downloadedIds).length;
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeading(
            'Downloads',
            subtitle:
                '${downloaded.length} tracks · ${formatBytes(bytes)} on this device',
            actions: [
              OutlinedButton.icon(
                onPressed: app.isAuthenticated && !app.busy
                    ? () => runUiAction(context, app.refresh)
                    : null,
                icon: const Icon(Icons.sync_rounded),
                label: const Text('Sync downloads'),
              ),
            ],
          ),
          if (app.busy)
            const QuietProgress(
              label: 'Syncing library and offline selections',
            ),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Activity'),
              Tab(text: 'On this device'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                CustomScrollView(
                  key: const PageStorageKey('download-activity'),
                  slivers: [
                    if (wanted.isNotEmpty)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              QuietProgress(
                                value: ready / wanted.length,
                                label: 'Offline download completion',
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '$ready of ${wanted.length} selected tracks ready${ready < wanted.length ? ' · ${wanted.length - ready} remaining' : ''}',
                              ),
                            ],
                          ),
                        ),
                      ),
                    _section(
                      context,
                      'Done',
                      done.length,
                      action: Tooltip(
                        message: 'Clear completed entries. Downloaded music stays on this device.',
                        child: TextButton.icon(
                          onPressed: done.isNotEmpty && app.isAuthenticated
                              ? () =>
                                    runUiAction(context, app.clearDoneDownloads)
                              : null,
                          icon: const Icon(Icons.clear_all_rounded),
                          label: const Text('Clear All'),
                        ),
                      ),
                    ),
                    if (done.isEmpty)
                      _emptySection('No completed downloads')
                    else
                      SliverList.builder(
                        itemCount: done.length,
                        itemBuilder: (context, index) => TrackTile(
                          key: ValueKey('done-${done[index].id}'),
                          app: app,
                          track: done[index],
                          queue: done,
                        ),
                      ),
                    _section(context, 'Pending', pending.length),
                    if (pending.isEmpty)
                      _emptySection('No pending downloads')
                    else
                      _downloadRows(pending),
                    _section(
                      context,
                      'Failed',
                      failed.length,
                      action: failed.isEmpty
                          ? null
                          : TextButton.icon(
                              onPressed: app.isAuthenticated && !app.busy
                                  ? () =>
                                        runUiAction(context, app.retryDownloads)
                                  : null,
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text('Retry'),
                            ),
                    ),
                    if (failed.isEmpty)
                      _emptySection('No failed downloads')
                    else
                      _downloadRows(failed),
                    if (wanted.isEmpty && downloaded.isEmpty)
                      const SliverToBoxAdapter(
                        child: EmptyState(
                          icon: Icons.offline_pin_outlined,
                          title: 'Music for wherever you go',
                          message: 'Choose “Keep offline” from a track, album, or playlist menu. Downloaded audio stays available without a connection.',
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
                CustomScrollView(
                  key: const PageStorageKey('device-downloads'),
                  slivers: [
                    if (pins.isNotEmpty)
                      SliverToBoxAdapter(
                        child: ExpansionTile(
                          title: const Text('Manage offline selections'),
                          subtitle: Text('${pins.length} selections'),
                          children: pins.map(_pinTile).toList(),
                        ),
                      ),
                    if (downloaded.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyState(
                          icon: Icons.offline_pin_outlined,
                          title: 'No music on this device yet',
                          message: 'Your completed downloads appear here, including entries cleared from Activity.',
                        ),
                      )
                    else
                      SliverList.builder(
                        itemCount: downloaded.length,
                        itemBuilder: (context, index) => TrackTile(
                          key: ValueKey('device-${downloaded[index].id}'),
                          app: app,
                          track: downloaded[index],
                          queue: downloaded,
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(
    BuildContext context,
    String title,
    int count, {
    Widget? action,
  }) => SliverPadding(
    padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
    sliver: SliverToBoxAdapter(
      child: Semantics(
        header: true,
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 8),
                Text('$count'),
              ],
            ),
            ?action,
          ],
        ),
      ),
    ),
  );

  Widget _emptySection(String message) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
    sliver: SliverToBoxAdapter(child: Text(message)),
  );

  Widget _downloadRows(List<Track> tracks) => SliverList.builder(
    itemCount: tracks.length,
    itemBuilder: (context, index) {
      final track = tracks[index];
      return DownloadProgressBuilder(
        key: ValueKey('transfer-${track.id}'),
        app: app,
        track: track,
        builder: (context, progress) => ListTile(
          leading: TrackArtwork(app: app, track: track),
          title: Text(track.title),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(downloadLabel(progress)),
              if (progress.status == DownloadStatus.downloading ||
                  progress.status == DownloadStatus.verifying)
                QuietProgress(
                  value: progress.status == DownloadStatus.verifying
                      ? null
                      : progress.fraction,
                  label: 'Download progress for ${track.title}',
                ),
              if (progress.error != null)
                Text(
                  progress.error!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
          trailing: Icon(
            progress.status == DownloadStatus.failed
                ? Icons.error_outline_rounded
                : Icons.download_rounded,
          ),
        ),
      );
    },
  );

  Widget _pinTile(PinSelection pin) => Builder(
    builder: (context) => ListTile(
      leading: Icon(switch (pin.type) {
        'album' => Icons.album_outlined,
        'playlist' => Icons.queue_music_rounded,
        _ => Icons.music_note_rounded,
      }),
      title: Text(_pinName(pin)),
      subtitle: Text('${pin.type} · Offline selection'),
      trailing: IconButton(
        tooltip: 'Remove offline selection',
        onPressed: () => runUiAction(context, () async {
          if (!await confirmAction(
            context,
            title: 'Remove offline selection?',
            message: 'Files used only by this selection will be removed from this device. Your server library is unchanged.',
            confirmLabel: 'Remove',
          )) {
            return;
          }
          switch (pin.type) {
            case 'track':
              await app.pinTrack(pin.id, pinned: false);
            case 'playlist':
              await app.pinPlaylist(pin.id, pinned: false);
            case 'album':
              final parts = (jsonDecode(pin.id) as List).cast<String>();
              await app.pinAlbum(
                parts.first,
                parts.length > 1 ? parts[1] : '',
                pinned: false,
              );
          }
        }),
        icon: const Icon(Icons.close_rounded),
      ),
    ),
  );

  String _pinName(PinSelection pin) => switch (pin.type) {
    'track' => app.trackById(pin.id)?.title ?? 'Unavailable track',
    'playlist' =>
      app.playlists
              .where((playlist) => playlist.id == pin.id)
              .firstOrNull
              ?.name ??
          'Unavailable playlist',
    'album' => (jsonDecode(pin.id) as List).first as String,
    _ => pin.id,
  };
}
