import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import 'track_widgets.dart';
import 'selected_builder.dart';
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
    for (final track in tracks) {
      if (albumPins.isNotEmpty &&
          albumPins.contains(
            albumPinId(
              track.album,
              track.albumArtist.isEmpty ? track.artist : track.albumArtist,
            ),
          )) {
        wanted.add(track.id);
      }
    }
    wanted.retainAll(tracks.map((track) => track.id));
    final ready = wanted.intersection(downloadedIds).length;
    final pending = tracks
        .where(
          (track) =>
              wanted.contains(track.id) && !downloadedIds.contains(track.id),
        )
        .toList();
    return Column(
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
          const QuietProgress(label: 'Syncing library and offline selections'),
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Kept offline',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Pin a track, album, or playlist to keep it on this device. New playlist entries are downloaded when you sync. Shared files remain while another selection needs them.',
                      ),
                      const SizedBox(height: 12),
                      if (wanted.isNotEmpty) ...[
                        QuietProgress(
                          value: ready / wanted.length,
                          label: 'Offline download completion',
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '$ready of ${wanted.length} selected tracks ready${ready < wanted.length ? ' · ${wanted.length - ready} pending' : ''}',
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ),
                ),
              ),
              if (pins.isNotEmpty)
                SliverList.builder(
                  itemCount: pins.length,
                  itemBuilder: (context, index) {
                    final pin = pins[index];
                    return ListTile(
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
                              final parts = (jsonDecode(pin.id) as List)
                                  .cast<String>();
                              await app.pinAlbum(
                                parts.first,
                                parts.length > 1 ? parts[1] : '',
                                pinned: false,
                              );
                          }
                        }),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    );
                  },
                ),
              if (pending.isNotEmpty)
                SliverList.builder(
                  itemCount: pending.length,
                  itemBuilder: (context, index) {
                    final track = pending[index];
                    return DownloadProgressBuilder(
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
                              LinearProgressIndicator(
                                value:
                                    progress.status == DownloadStatus.verifying
                                    ? null
                                    : progress.fraction,
                                semanticsLabel:
                                    'Download progress for ${track.title}',
                              ),
                            if (progress.error != null)
                              Text(
                                progress.error!,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                        trailing: progress.status == DownloadStatus.failed
                            ? IconButton(
                                tooltip: 'Retry download',
                                onPressed: () =>
                                    runUiAction(context, app.retryDownloads),
                                icon: const Icon(Icons.refresh_rounded),
                              )
                            : const Icon(Icons.download_rounded),
                      ),
                    );
                  },
                ),
              if (downloaded.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                    child: Text(
                      'Ready to listen',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ),
                SliverList.builder(
                  itemCount: downloaded.length,
                  itemBuilder: (context, index) => TrackTile(
                    app: app,
                    track: downloaded[index],
                    queue: downloaded,
                  ),
                ),
              ] else
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: Icons.offline_pin_outlined,
                    title: app.pins.isEmpty
                        ? 'Music for wherever you go'
                        : 'Waiting for downloads',
                    message: app.pins.isEmpty
                        ? 'Choose “Keep offline” from a track, album, or playlist menu. Downloaded audio stays available without a connection.'
                        : 'Connect to your server and sync to finish downloading your selections.',
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
      ],
    );
  }

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
