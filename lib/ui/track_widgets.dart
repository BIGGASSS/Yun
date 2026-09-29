import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import 'widgets.dart';
import 'selected_builder.dart';

class TrackArtwork extends StatefulWidget {
  const TrackArtwork({
    super.key,
    required this.app,
    required this.track,
    this.size = 48,
  });
  final AppController app;
  final Track? track;
  final double size;

  @override
  State<TrackArtwork> createState() => _TrackArtworkState();
}

class _TrackArtworkState extends State<TrackArtwork> {
  Future<String?>? _request;
  Object? _requestKey;

  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          size: widget.size * .4,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
    final track = widget.track;
    return AnimatedBuilder(
      animation: Listenable.merge([widget.app, widget.app.artworkChanges]),
      builder: (context, _) {
        final app = widget.app;
        // A future's old snapshot must never paint another account/revision.
        final key = (
          app,
          app.account,
          track?.id,
          track?.revision,
          app.isOffline,
          app.busy,
          track?.hasArtwork,
        );
        if (_requestKey != key) {
          _requestKey = key;
          final cached = track == null ? null : app.artworkPath(track);
          _request = track == null
              ? null
              : cached != null
              ? Future.value(cached)
              : app.getArtwork(track);
        }
        return ExcludeSemantics(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(widget.size > 100 ? 24 : 8),
            child: SizedBox.square(
              dimension: widget.size,
              child: FutureBuilder<String?>(
                future: _request,
                builder: (context, snapshot) {
                  final path = track == null ? null : app.artworkPath(track);
                  if (path == null) return placeholder;
                  return Image.file(
                    File(path),
                    key: ValueKey(path),
                    fit: BoxFit.cover,
                    cacheWidth:
                        (widget.size * MediaQuery.devicePixelRatioOf(context))
                            .round(),
                    errorBuilder: (_, error, stack) => placeholder,
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

String downloadLabel(DownloadProgress progress) => switch (progress.status) {
  DownloadStatus.availableOnline => 'Available online',
  DownloadStatus.queued =>
    'Queued · ${formatBytes(progress.receivedBytes)} / ${formatBytes(progress.totalBytes)}',
  DownloadStatus.downloading =>
    'Downloading · ${formatBytes(progress.receivedBytes)} / ${formatBytes(progress.totalBytes)}',
  DownloadStatus.verifying => 'Verifying download',
  DownloadStatus.failed =>
    'Download failed · ${formatBytes(progress.receivedBytes)} / ${formatBytes(progress.totalBytes)}',
  DownloadStatus.downloaded => 'Downloaded · Offline',
};

class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.app,
    required this.track,
    this.queue,
    this.onTap,
    this.trailing,
    this.number,
    this.selected,
    this.onSelectionChanged,
  });
  final AppController app;
  final Track track;
  final List<Track>? queue;
  final VoidCallback? onTap;
  final Widget? trailing;
  final int? number;
  final bool? selected;
  final ValueChanged<bool?>? onSelectionChanged;

  @override
  Widget build(BuildContext context) => SelectedBuilder(
    listenable: app.playback,
    select: () => selected == null && app.playback.currentTrack?.id == track.id,
    builder: (context, current, _) => ListTile(
      selected: selected ?? current,
      leading: selected == null
          ? TrackArtwork(app: app, track: track)
          : Checkbox(
              value: selected,
              onChanged: onSelectionChanged,
              semanticLabel: 'Select ${track.title}',
            ),
      title: Text(
        '${number == null ? '' : '$number. '}${track.title}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: DownloadProgressBuilder(
        app: app,
        track: track,
        builder: (context, progress) => Text(
          '${track.artist.isEmpty ? 'Unknown artist' : track.artist} · ${downloadLabel(progress)}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      onTap: selected == null
          ? onTap ??
                () => runUiAction(context, () => app.play(track, queue: queue))
          : onSelectionChanged == null
          ? null
          : () => onSelectionChanged!(!selected!),
      trailing: trailing ?? TrackMenu(app: app, track: track),
    ),
  );
}

/// Byte ticks rebuild only the indicator belonging to the changed track.
class DownloadProgressBuilder extends StatelessWidget {
  const DownloadProgressBuilder({
    super.key,
    required this.app,
    required this.track,
    required this.builder,
  });
  final AppController app;
  final Track track;
  final Widget Function(BuildContext, DownloadProgress) builder;

  @override
  Widget build(BuildContext context) => SelectedBuilder(
    listenable: Listenable.merge([app, app.downloadChanges]),
    select: () {
      final progress = app.downloadProgress(track);
      return (
        progress.status,
        progress.receivedBytes,
        progress.totalBytes,
        progress.error,
      );
    },
    builder: (context, _, child) =>
        builder(context, app.downloadProgress(track)),
  );
}

class TrackMenu extends StatelessWidget {
  const TrackMenu({super.key, required this.app, required this.track});
  final AppController app;
  final Track track;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    tooltip: 'Options for ${track.title}',
    onSelected: (value) => runUiAction(context, () async {
      switch (value) {
        case 'playlist':
          await addTrackToPlaylist(context, app, track);
        case 'download':
          await app.pinTrack(
            track.id,
            pinned: !app.isPinned('track', track.id),
          );
        case 'edit':
          await showDialog<void>(
            context: context,
            builder: (_) => MetadataDialog(app: app, track: track),
          );
        case 'delete':
          if (await confirmAction(
            context,
            title: 'Delete track?',
            message:
                '“${track.title}” will be removed from your library and playlists on all devices.',
          )) {
            await app.deleteTrack(track.id);
          }
      }
    }),
    itemBuilder: (_) => [
      const PopupMenuItem(value: 'playlist', child: Text('Add to playlist')),
      PopupMenuItem(
        value: 'download',
        child: Text(
          app.isPinned('track', track.id) ? 'Unpin download' : 'Keep offline',
        ),
      ),
      const PopupMenuItem(
        value: 'edit',
        child: Text('Edit metadata & artwork'),
      ),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'delete', child: Text('Delete from library')),
    ],
  );
}

Future<void> addTrackToPlaylist(
  BuildContext context,
  AppController app,
  Track track,
) => addTracksToPlaylist(context, app, [track]);

Future<void> addTracksToPlaylist(
  BuildContext context,
  AppController app,
  List<Track> tracks,
) async {
  if (tracks.isEmpty) return;
  final account = (app.account?.server, app.account?.userId);
  bool sameAccount() =>
      context.mounted &&
      app.isAuthenticated &&
      account == (app.account?.server, app.account?.userId);
  final id = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Add to playlist'),
      children: [
        for (final playlist in app.playlists)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, playlist.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(playlist.name),
            ),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(context, '__new'),
          child: const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('＋ New playlist'),
          ),
        ),
      ],
    ),
  );
  if (id == null || !context.mounted || !sameAccount()) return;
  Playlist? playlist;
  if (id == '__new') {
    final name = await askForName(context, title: 'New playlist');
    if (name == null || !sameAccount()) return;
    playlist = await app.createPlaylist(name);
  } else {
    playlist = app.playlists.where((item) => item.id == id).firstOrNull;
  }
  if (playlist == null || !sameAccount()) return;
  final existing = playlist.entries.map((entry) => entry.trackId).toSet();
  final available = app.tracks.map((track) => track.id).toSet();
  final additions = [
    for (final track in tracks)
      if (available.contains(track.id) && existing.add(track.id))
        PlaylistEntry(id: app.newId(), trackId: track.id),
  ];
  if (additions.isNotEmpty) {
    await app.savePlaylist(
      playlist,
      entries: [...playlist.entries, ...additions],
    );
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          additions.isEmpty
              ? 'No new tracks to add to ${playlist.name}'
              : 'Added ${additions.length} to ${playlist.name}',
        ),
      ),
    );
  }
}

class MetadataDialog extends StatefulWidget {
  const MetadataDialog({super.key, required this.app, required this.track});
  final AppController app;
  final Track track;

  @override
  State<MetadataDialog> createState() => _MetadataDialogState();
}

class _MetadataDialogState extends State<MetadataDialog> {
  final _form = GlobalKey<FormState>();
  late Track _track;
  late final Map<String, TextEditingController> _fields;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _track = widget.track;
    _fields = {
      'title': TextEditingController(text: _track.title),
      'artist': TextEditingController(text: _track.artist),
      'album': TextEditingController(text: _track.album),
      'album_artist': TextEditingController(text: _track.albumArtist),
      'track_number': TextEditingController(
        text: _track.trackNumber?.toString() ?? '',
      ),
      'disc_number': TextEditingController(
        text: _track.discNumber?.toString() ?? '',
      ),
    };
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _artwork() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png'],
      withData: true,
    );
    if (result == null || !mounted) return;
    final file = result.files.single;
    if (file.bytes == null || file.size > 10 * 1024 * 1024) {
      setState(() => _error = 'Choose a JPEG or PNG no larger than 10 MB.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await widget.app.setArtwork(
        _track,
        file.bytes!,
        mimeType: file.extension?.toLowerCase() == 'png'
            ? 'image/png'
            : 'image/jpeg',
      );
      if (mounted) setState(() => _track = updated);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.app.updateTrack(_track, {
        for (final field in _fields.entries)
          field.key: field.key.endsWith('_number')
              ? int.tryParse(field.value.text.trim())
              : field.value.text.trim(),
      });
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Edit track'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  TrackArtwork(app: widget.app, track: _track, size: 64),
                  const SizedBox(width: 16),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _saving
                          ? null
                          : () => runUiAction(context, _artwork),
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('Replace artwork'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Artwork changes are saved immediately. Original audio is never modified.',
              ),
              const SizedBox(height: 20),
              for (final entry in _fields.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextFormField(
                    controller: entry.value,
                    enabled: !_saving,
                    decoration: InputDecoration(
                      labelText: const {
                        'title': 'Title',
                        'artist': 'Artist',
                        'album': 'Album',
                        'album_artist': 'Album artist',
                        'track_number': 'Track number',
                        'disc_number': 'Disc number',
                      }[entry.key],
                    ),
                    keyboardType: entry.key.endsWith('_number')
                        ? TextInputType.number
                        : TextInputType.text,
                    validator: (value) {
                      if (entry.key == 'title' &&
                          (value == null || value.trim().isEmpty)) {
                        return 'Enter a title';
                      }
                      if (entry.key.endsWith('_number')) {
                        final text = value?.trim() ?? '';
                        final number = int.tryParse(text);
                        if (text.isNotEmpty &&
                            (number == null ||
                                number < 1 ||
                                number > 1000000)) {
                          return 'Enter 1–1,000,000 or leave blank';
                        }
                      }
                      return null;
                    },
                  ),
                ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (_saving) const QuietProgress(label: 'Saving track'),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('Close'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: const Text('Save metadata'),
      ),
    ],
  );
}
