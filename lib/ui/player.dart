import 'dart:math' as math;

import 'package:flutter/material.dart' hide RepeatMode;

import '../core/app_controller.dart';
import 'track_widgets.dart';
import 'widgets.dart';

class PlayerBar extends StatelessWidget {
  const PlayerBar({
    super.key,
    required this.app,
    required this.compact,
    required this.onQueue,
  });
  final AppController app;
  final bool compact;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    final player = app.playback;
    final track = player.currentTrack;
    if (track == null && compact) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (player.isBuffering)
            const QuietProgress(label: 'Buffering audio')
          else if (compact)
            QuietProgress(
              value: player.duration.inMilliseconds > 0
                  ? (player.position.inMilliseconds /
                            player.duration.inMilliseconds)
                        .clamp(0, 1)
                  : 0,
              label: 'Playback progress',
            ),
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 8 : 20,
              vertical: 8,
            ),
            child: Row(
              children: [
                Expanded(
                  flex: compact ? 1 : 3,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => showNowPlaying(context, app),
                    child: Semantics(
                      button: true,
                      label: 'Open now playing',
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Row(
                          children: [
                            TrackArtwork(
                              app: app,
                              track: track,
                              size: compact ? 40 : 52,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    track?.title ?? 'Nothing playing',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall,
                                  ),
                                  Text(
                                    track?.artist ??
                                        'Choose a track from your library',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (!compact)
                  Expanded(
                    flex: 5,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PlaybackButtons(app: app, small: true),
                        PlaybackSeek(app: app),
                      ],
                    ),
                  ),
                if (compact)
                  IconButton.filledTonal(
                    tooltip: player.isPlaying ? 'Pause' : 'Play',
                    onPressed: () => runUiAction(context, player.toggle),
                    icon: Icon(
                      player.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                if (compact)
                  IconButton(
                    tooltip: 'Next track',
                    onPressed: () => runUiAction(context, player.next),
                    icon: const Icon(Icons.skip_next_rounded),
                  ),
                if (!compact)
                  Expanded(
                    flex: 2,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        tooltip: 'Show queue',
                        onPressed: onQueue,
                        icon: const Icon(Icons.queue_music_rounded),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PlaybackButtons extends StatelessWidget {
  const PlaybackButtons({super.key, required this.app, this.small = false});
  final AppController app;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final player = app.playback;
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: small ? 0 : 8,
      children: [
        IconButton(
          tooltip: player.shuffle ? 'Turn shuffle off' : 'Turn shuffle on',
          isSelected: player.shuffle,
          onPressed: () => player.setShuffle(!player.shuffle),
          icon: const Icon(Icons.shuffle_rounded),
        ),
        IconButton(
          tooltip: 'Previous track',
          onPressed: () => runUiAction(context, player.previous),
          icon: const Icon(Icons.skip_previous_rounded),
          iconSize: small ? 24 : 32,
        ),
        IconButton.filled(
          tooltip: player.isPlaying ? 'Pause' : 'Play',
          onPressed: player.currentTrack == null
              ? null
              : () => runUiAction(context, player.toggle),
          icon: Icon(
            player.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          ),
          iconSize: small ? 24 : 36,
        ),
        IconButton(
          tooltip: 'Next track',
          onPressed: () => runUiAction(context, player.next),
          icon: const Icon(Icons.skip_next_rounded),
          iconSize: small ? 24 : 32,
        ),
        IconButton(
          tooltip: 'Repeat: ${player.repeatMode.name}. Change repeat mode',
          isSelected: player.repeatMode != RepeatMode.off,
          onPressed: () => player.setRepeat(switch (player.repeatMode) {
            RepeatMode.off => RepeatMode.all,
            RepeatMode.all => RepeatMode.one,
            RepeatMode.one => RepeatMode.off,
          }),
          icon: Icon(
            player.repeatMode == RepeatMode.one
                ? Icons.repeat_one_rounded
                : Icons.repeat_rounded,
          ),
        ),
      ],
    );
  }
}

class PlaybackSeek extends StatefulWidget {
  const PlaybackSeek({super.key, required this.app});
  final AppController app;
  @override
  State<PlaybackSeek> createState() => _PlaybackSeekState();
}

class _PlaybackSeekState extends State<PlaybackSeek> {
  double? _drag;
  @override
  Widget build(BuildContext context) {
    final player = widget.app.playback;
    final max = math.max(1, player.duration.inMilliseconds).toDouble();
    return Row(
      children: [
        Text(
          formatDuration(
            Duration(
              milliseconds: (_drag ?? player.position.inMilliseconds).round(),
            ),
          ),
          style: Theme.of(context).textTheme.labelSmall,
        ),
        Expanded(
          child: Slider(
            label: formatDuration(
              Duration(
                milliseconds: (_drag ?? player.position.inMilliseconds).round(),
              ),
            ),
            min: 0,
            max: max,
            value: (_drag ?? player.position.inMilliseconds.toDouble()).clamp(
              0,
              max,
            ),
            semanticFormatterCallback: (value) =>
                '${formatDuration(Duration(milliseconds: value.round()))} of ${formatDuration(player.duration)}',
            onChanged: player.duration > Duration.zero
                ? (value) => setState(() => _drag = value)
                : null,
            onChangeEnd: (value) {
              setState(() => _drag = null);
              runUiAction(
                context,
                () => player.seek(Duration(milliseconds: value.round())),
              );
            },
          ),
        ),
        Text(
          formatDuration(player.duration),
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }
}

void showNowPlaying(BuildContext context, AppController app) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: .94,
      child: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final track = app.playback.currentTrack;
          return LayoutBuilder(
            builder: (context, constraints) {
              final artSize = math
                  .min(
                    360.0,
                    math.min(
                      constraints.maxWidth - 64,
                      constraints.maxHeight * .42,
                    ),
                  )
                  .clamp(80.0, 360.0);
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            IconButton(
                              tooltip: 'Close now playing',
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(
                                Icons.keyboard_arrow_down_rounded,
                              ),
                            ),
                            const Expanded(
                              child: Text(
                                'Now playing',
                                textAlign: TextAlign.center,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Show queue',
                              onPressed: () => showQueue(context, app),
                              icon: const Icon(Icons.queue_music_rounded),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        TrackArtwork(app: app, track: track, size: artSize),
                        const SizedBox(height: 28),
                        Text(
                          track?.title ?? 'Nothing playing',
                          style: Theme.of(context).textTheme.headlineSmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          track?.artist ?? 'Choose a track from your library',
                          style: Theme.of(context).textTheme.titleMedium,
                          textAlign: TextAlign.center,
                        ),
                        if (track?.album.isNotEmpty == true)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              track!.album,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        const SizedBox(height: 24),
                        if (app.playback.isBuffering)
                          const QuietProgress(label: 'Buffering audio'),
                        if (app.playback.error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                app.playback.error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          ),
                        PlaybackSeek(app: app),
                        const SizedBox(height: 8),
                        PlaybackButtons(app: app),
                        if (track != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 12,
                              children: [
                                OutlinedButton.icon(
                                  onPressed: () => runUiAction(
                                    context,
                                    () => app.pinTrack(
                                      track.id,
                                      pinned: !app.isPinned('track', track.id),
                                    ),
                                  ),
                                  icon: Icon(
                                    app.isPinned('track', track.id)
                                        ? Icons.offline_pin_rounded
                                        : Icons.download_outlined,
                                  ),
                                  label: Text(
                                    app.isPinned('track', track.id)
                                        ? 'Kept offline'
                                        : 'Keep offline',
                                  ),
                                ),
                                TrackMenu(app: app, track: track),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    ),
  );
}

void showQueue(BuildContext context, AppController app) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: .8,
      child: ListenableBuilder(
        listenable: app,
        builder: (context, _) => QueuePanel(app: app),
      ),
    ),
  );
}

class QueuePanel extends StatelessWidget {
  const QueuePanel({super.key, required this.app, this.onClose});
  final AppController app;
  final VoidCallback? onClose;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Play queue',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (onClose != null)
              IconButton(
                tooltip: 'Hide queue',
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded),
              ),
          ],
        ),
      ),
      Expanded(
        child: app.playback.queue.isEmpty
            ? const EmptyState(
                icon: Icons.queue_music_rounded,
                title: 'A quiet queue',
                message: 'Play a track or playlist to get started.',
              )
            : ListView.builder(
                itemCount: app.playback.queue.length,
                itemBuilder: (context, index) {
                  final track = app.playback.queue[index];
                  return ListTile(
                    selected: index == app.playback.index,
                    leading: index == app.playback.index
                        ? const Icon(Icons.graphic_eq_rounded)
                        : Text('${index + 1}'),
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
                    onTap: () => runUiAction(
                      context,
                      () => app.playback.playQueue(
                        app.playback.queue,
                        index: index,
                      ),
                    ),
                  );
                },
              ),
      ),
    ],
  );
}
