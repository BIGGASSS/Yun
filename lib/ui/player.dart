import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide RepeatMode;

import '../core/app_controller.dart';
import 'download_repair.dart';
import 'player_icons.dart';
import 'selected_builder.dart';
import 'track_widgets.dart';
import 'widgets.dart';

/// Desktop-class platforms (Linux, macOS, Windows; never web) get the
/// redesigned [DesktopPlayerBar] and inline volume controls. Gated on the
/// actual platform, never on window width: a wide Android or iOS window keeps
/// the legacy touch bar.
bool get _desktopPlatform =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      _ => false,
    };

bool get _desktopVolume => _desktopPlatform;

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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app.playback,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final player = app.playback;
    if (player.currentTrack == null && compact) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      child: compact
          ? _CompactPlayerBar(app: app)
          : _desktopPlatform
          ? DesktopPlayerBar(app: app, onQueue: onQueue)
          : _WideTouchPlayerBar(app: app, onQueue: onQueue),
    );
  }
}

/// Narrow-window and mobile strip. Kept as-is for Android, which never shows
/// volume controls here; only the desktop-only volume button gains the local
/// vector glyphs.
class _CompactPlayerBar extends StatelessWidget {
  const _CompactPlayerBar({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final player = app.playback;
    final canPause = player.isPlaying || player.isWaitingForAudio;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (player.isBuffering)
          const QuietProgress(label: 'Buffering audio')
        else
          QuietProgress(
            value: player.duration.inMilliseconds > 0
                ? (player.position.inMilliseconds /
                          player.duration.inMilliseconds)
                      .clamp(0, 1)
                : 0,
            label: 'Playback progress',
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Expanded(child: _MetadataButton(app: app, artSize: 40)),
              IconButton.filledTonal(
                tooltip: canPause ? 'Pause' : 'Play',
                onPressed: () => runUiAction(context, player.toggle),
                icon: Icon(
                  canPause ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
              ),
              IconButton(
                tooltip: 'Next track',
                onPressed: () => runUiAction(context, player.next),
                icon: const Icon(Icons.skip_next_rounded),
              ),
              if (_desktopVolume)
                IconButton(
                  tooltip: 'Volume',
                  onPressed: () => _showVolume(context, app),
                  icon: PlayerIcon(
                    player.isMuted
                        ? PlayerGlyph.volumeMute
                        : PlayerGlyph.volumeHigh,
                  ),
                ),
            ],
          ),
        ),
        PlaybackErrorNotice(app: app, compact: true),
      ],
    );
  }
}

/// Wide-window player strip for touch platforms (Android/iOS tablets,
/// foldables, and web): the pre-redesign flex layout with Material icons.
/// Width alone never opts a touch platform into [DesktopPlayerBar]; that
/// redesign is desktop-platform only.
class _WideTouchPlayerBar extends StatelessWidget {
  const _WideTouchPlayerBar({required this.app, required this.onQueue});
  final AppController app;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) {
    final player = app.playback;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (player.isBuffering) const QuietProgress(label: 'Buffering audio'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          child: Row(
            children: [
              Expanded(flex: 3, child: _MetadataButton(app: app, artSize: 52)),
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
        PlaybackErrorNotice(app: app, compact: true),
      ],
    );
  }
}

/// Wide-window player strip: artwork plus truncated metadata on the left, a
/// bounded transport and seek column centered in the bar, and a compact
/// volume plus queue cluster on the right.
class DesktopPlayerBar extends StatelessWidget {
  const DesktopPlayerBar({super.key, required this.app, required this.onQueue});
  final AppController app;
  final VoidCallback onQueue;

  /// Upper bound for the centered seek column so the slider stays deliberate
  /// instead of sprawling across ultrawide windows.
  static const double maxSeekColumnWidth = 640;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app.playback,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final player = app.playback;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (player.isBuffering) const QuietProgress(label: 'Buffering audio'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Equal flexible side zones keep the middle column optically
              // centered no matter what the side content does.
              final centerWidth = (constraints.maxWidth * .52).clamp(
                360.0,
                maxSeekColumnWidth,
              );
              return Row(
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 300),
                        child: _MetadataButton(app: app, artSize: 44),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: centerWidth,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _DesktopTransport(app: app),
                        SizedBox(
                          height: 26,
                          child: SliderTheme(
                            data: _slimSliderTheme(scheme),
                            child: PlaybackSeek(app: app),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_desktopVolume)
                            SizedBox(
                              width: 140,
                              child: PlaybackVolume(app: app),
                            ),
                          IconButton(
                            tooltip: 'Show queue',
                            onPressed: onQueue,
                            constraints: const BoxConstraints.tightFor(
                              width: 36,
                              height: 36,
                            ),
                            iconSize: 20,
                            icon: const PlayerIcon(PlayerGlyph.queue),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        PlaybackErrorNotice(app: app, compact: true),
      ],
    );
  }
}

/// Waiting, local playback failures and unavailable background controls remain
/// visible without opening a sheet. Waiting is a neutral status, cancelled with
/// Pause. A separate service warning survives playback success and other errors;
/// it never offers file repair. Compact strips cap text, while tooltips and the
/// scrollable now-playing sheet retain each full message. Repair actions wrap at
/// narrow widths or larger accessibility text sizes.
class PlaybackErrorNotice extends StatelessWidget {
  const PlaybackErrorNotice({
    super.key,
    required this.app,
    this.compact = false,
  });

  final AppController app;
  final bool compact;

  @override
  Widget build(BuildContext context) => SelectedBuilder(
    listenable: app.playback,
    select: () => (
      app.playback.currentTrack,
      app.playback.localPlaybackError,
      app.playback.error,
      app.playback.audioFocusError,
      app.playback.isWaitingForAudio,
      app.playback.systemMediaControlsError,
    ),
    builder: (context, state, _) {
      final waiting = state.$5;
      final serviceWarning = state.$6;
      // The general error falls back to the service warning. Render it only in
      // its own notice so the full sheet does not show the same warning twice.
      final otherError = state.$3 == serviceWarning ? null : state.$3;
      final message = waiting
          ? 'Waiting for audio'
          : state.$2 ?? state.$4 ?? (compact ? null : otherError);
      if (message == null && serviceWarning == null) {
        return const SizedBox.shrink();
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (message != null)
            _notice(
              context,
              message,
              waiting: waiting,
              repairTrack: !waiting && state.$2 != null ? state.$1 : null,
            ),
          if (serviceWarning != null) _notice(context, serviceWarning),
        ],
      );
    },
  );

  Widget _notice(
    BuildContext context,
    String message, {
    bool waiting = false,
    Track? repairTrack,
  }) {
    // Keep the decoder's cause visible at narrow widths and large text,
    // rather than spending every available line on the explanatory prefix.
    const localPrefix = 'Could not play the downloaded audio: ';
    final displayMessage =
        compact && repairTrack != null && message.startsWith(localPrefix)
        ? message.substring(localPrefix.length)
        : message;
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 12 : 0, 4, compact ? 12 : 0, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final detail = Semantics(
            liveRegion: true,
            child: Tooltip(
              message: message,
              child: Text(
                displayMessage,
                semanticsLabel: message,
                maxLines: compact ? 3 : null,
                overflow: compact ? TextOverflow.ellipsis : null,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: waiting
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          );
          if (repairTrack == null) return detail;
          final action = RedownloadTrackButton(app: app, track: repairTrack);
          if (constraints.maxWidth >= 700 &&
              MediaQuery.textScalerOf(context).scale(14) <= 18) {
            return Row(
              children: [
                Expanded(child: detail),
                const SizedBox(width: 16),
                Flexible(child: action),
              ],
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [detail, const SizedBox(height: 4), action],
          );
        },
      ),
    );
  }
}

/// Artwork plus truncated title/artist that opens the now playing sheet.
class _MetadataButton extends StatelessWidget {
  const _MetadataButton({required this.app, required this.artSize});
  final AppController app;
  final double artSize;

  @override
  Widget build(BuildContext context) {
    final track = app.playback.currentTrack;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => showNowPlaying(context, app),
      child: Semantics(
        button: true,
        label: 'Open now playing',
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            children: [
              TrackArtwork(app: app, track: track, size: artSize),
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
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      track?.artist ?? 'Choose a track from your library',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact transport cluster for the desktop strip: a filled play/pause
/// anchor with evenly spaced skip, shuffle, and repeat buttons using local
/// vector glyphs with a consistent stroke.
class _DesktopTransport extends StatelessWidget {
  const _DesktopTransport({required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final player = app.playback;
    final canPause = player.isPlaying || player.isWaitingForAudio;
    final scheme = Theme.of(context).colorScheme;
    // A filled secondary container plus primary glyph makes the persistent
    // shuffle/repeat selection unmistakable in a low-chroma theme.
    final toggleStyle = ButtonStyle(
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.onSurfaceVariant,
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.secondaryContainer
            : Colors.transparent,
      ),
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: player.shuffle ? 'Turn shuffle off' : 'Turn shuffle on',
          isSelected: player.shuffle,
          style: toggleStyle,
          onPressed: () => player.setShuffle(!player.shuffle),
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          iconSize: 19,
          icon: const PlayerIcon(PlayerGlyph.shuffle),
        ),
        const SizedBox(width: 6),
        IconButton(
          tooltip: 'Previous track',
          onPressed: () => runUiAction(context, player.previous),
          constraints: const BoxConstraints.tightFor(width: 38, height: 38),
          iconSize: 22,
          icon: const PlayerIcon(PlayerGlyph.previous),
        ),
        const SizedBox(width: 6),
        IconButton.filled(
          tooltip: canPause ? 'Pause' : 'Play',
          onPressed: player.currentTrack == null
              ? null
              : () => runUiAction(context, player.toggle),
          constraints: const BoxConstraints.tightFor(width: 40, height: 40),
          iconSize: 24,
          icon: PlayerIcon(canPause ? PlayerGlyph.pause : PlayerGlyph.play),
        ),
        const SizedBox(width: 6),
        IconButton(
          tooltip: 'Next track',
          onPressed: () => runUiAction(context, player.next),
          constraints: const BoxConstraints.tightFor(width: 38, height: 38),
          iconSize: 22,
          icon: const PlayerIcon(PlayerGlyph.next),
        ),
        const SizedBox(width: 6),
        IconButton(
          tooltip: 'Repeat: ${player.repeatMode.name}. Change repeat mode',
          isSelected: player.repeatMode != RepeatMode.off,
          style: toggleStyle,
          onPressed: () => player.setRepeat(switch (player.repeatMode) {
            RepeatMode.off => RepeatMode.all,
            RepeatMode.all => RepeatMode.one,
            RepeatMode.one => RepeatMode.off,
          }),
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          iconSize: 19,
          icon: PlayerIcon(
            player.repeatMode == RepeatMode.one
                ? PlayerGlyph.repeatOne
                : PlayerGlyph.repeat,
          ),
        ),
      ],
    );
  }
}

/// Slim slider geometry for the desktop strip: a 3px track with a small thumb
/// and zero padding inflation instead of the oversized Material defaults.
SliderThemeData _slimSliderTheme(ColorScheme scheme) => SliderThemeData(
  trackHeight: 3,
  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
  thumbShape: const RoundSliderThumbShape(
    enabledThumbRadius: 6,
    elevation: 0,
    pressedElevation: 0,
  ),
  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
  activeTrackColor: scheme.primary,
  inactiveTrackColor: scheme.surfaceContainerHighest,
  thumbColor: scheme.primary,
);

/// App-local gain, not the operating system's master volume.
class PlaybackVolume extends StatelessWidget {
  const PlaybackVolume({super.key, required this.app});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final player = app.playback;
    return Row(
      children: [
        IconButton(
          tooltip: player.isMuted ? 'Unmute' : 'Mute',
          onPressed: () => runUiAction(context, player.toggleMute),
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          iconSize: 20,
          icon: PlayerIcon(
            player.isMuted
                ? PlayerGlyph.volumeMute
                : player.volume < 50
                ? PlayerGlyph.volumeLow
                : PlayerGlyph.volumeHigh,
          ),
        ),
        Expanded(
          child: Semantics(
            label: 'Volume',
            child: SliderTheme(
              data: _slimSliderTheme(Theme.of(context).colorScheme),
              child: Slider(
                key: const ValueKey('playback-volume-slider'),
                value: player.volume,
                max: 100,
                divisions: 100,
                label: '${player.volume.round()}%',
                semanticFormatterCallback: (value) => '${value.round()}%',
                onChanged: (value) =>
                    runUiAction(context, () => player.setVolume(value)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

void _showVolume(BuildContext context, AppController app) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Volume'),
      content: SizedBox(
        width: 280,
        child: ListenableBuilder(
          listenable: app.playback,
          builder: (context, _) => PlaybackVolume(app: app),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class PlaybackButtons extends StatelessWidget {
  const PlaybackButtons({super.key, required this.app, this.small = false});
  final AppController app;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final player = app.playback;
    final canPause = player.isPlaying || player.isWaitingForAudio;
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
          tooltip: canPause ? 'Pause' : 'Play',
          onPressed: player.currentTrack == null
              ? null
              : () => runUiAction(context, player.toggle),
          icon: Icon(canPause ? Icons.pause_rounded : Icons.play_arrow_rounded),
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
        listenable: Listenable.merge([app, app.playback, app.downloadChanges]),
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
                        PlaybackErrorNotice(app: app),
                        PlaybackSeek(app: app),
                        const SizedBox(height: 8),
                        PlaybackButtons(app: app),
                        if (_desktopVolume)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: PlaybackVolume(app: app),
                          ),
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
    builder: (context) =>
        FractionallySizedBox(heightFactor: .8, child: QueuePanel(app: app)),
  );
}

class QueuePanel extends StatelessWidget {
  const QueuePanel({super.key, required this.app, this.onClose});
  final AppController app;
  final VoidCallback? onClose;
  @override
  Widget build(BuildContext context) => SelectedBuilder(
    listenable: app.playback,
    select: () => (
      app.playback.effectiveQueue,
      app.playback.effectiveIndex,
      app.playback.shuffle,
    ),
    builder: (context, snapshot, _) =>
        _build(context, snapshot.$1, snapshot.$2, snapshot.$3),
  );

  Widget _build(
    BuildContext context,
    List<PlaybackQueueEntry> queue,
    int currentIndex,
    bool shuffle,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Play queue',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (queue.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Playing ${currentIndex + 1} of ${queue.length}'
                      '${shuffle ? ' · Shuffled' : ''}',
                      key: const ValueKey('queue-position'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
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
        child: queue.isEmpty
            ? const EmptyState(
                icon: Icons.queue_music_rounded,
                title: 'A quiet queue',
                message: 'Play a track or playlist to get started.',
              )
            : _QueueList(app: app, queue: queue, currentIndex: currentIndex),
      ),
    ],
  );
}

class _QueueList extends StatefulWidget {
  const _QueueList({
    required this.app,
    required this.queue,
    required this.currentIndex,
  });

  final AppController app;
  final List<PlaybackQueueEntry> queue;
  final int currentIndex;

  @override
  State<_QueueList> createState() => _QueueListState();
}

class _QueueListState extends State<_QueueList> {
  final _scroll = ScrollController();
  double _rowHeight = 80, _viewportHeight = 0;
  bool _revealScheduled = false;

  @override
  void initState() {
    super.initState();
    _revealCurrent();
  }

  @override
  void didUpdateWidget(covariant _QueueList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex ||
        !identical(oldWidget.queue, widget.queue)) {
      _revealCurrent();
    }
  }

  // Fixed-height rows make the current occurrence reachable without building
  // every track in large queues. Position ticks leave this scroll state alone.
  void _revealCurrent() {
    if (_revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted || !_scroll.hasClients || widget.currentIndex < 0) return;
      final offset = widget.currentIndex * _rowHeight - _viewportHeight / 4;
      _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final textScale = math.max(
        1.0,
        MediaQuery.textScalerOf(context).scale(14) / 14,
      );
      final rowHeight = 80 * textScale;
      final numberWidth =
          math.max(32.0, widget.queue.length.toString().length * 9.0) *
          textScale;
      if (_rowHeight != rowHeight || _viewportHeight != constraints.maxHeight) {
        _rowHeight = rowHeight;
        _viewportHeight = constraints.maxHeight;
        _revealCurrent();
      }
      return ListView.builder(
        key: const ValueKey('play-queue-list'),
        controller: _scroll,
        itemExtent: _rowHeight,
        itemCount: widget.queue.length,
        itemBuilder: (context, index) {
          final entry = widget.queue[index];
          final current = index == widget.currentIndex;
          final status = current
              ? 'Now playing'
              : entry.isManuallyQueued
              ? index > widget.currentIndex
                    ? 'Queued next'
                    : 'Queued'
              : null;
          return ListTile(
            key: ObjectKey(entry),
            selected: current,
            leading: SizedBox(
              width: numberWidth,
              child: Center(child: Text('${index + 1}')),
            ),
            // Keep the icon beside the text: leading has a fixed height cap,
            // even when accessibility text scaling increases the row height.
            trailing: current
                ? const Icon(Icons.graphic_eq_rounded, size: 18)
                : null,
            title: Text(
              entry.track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Row(
              children: [
                Expanded(
                  child: Text(
                    entry.track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (status != null) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Tooltip(
                      message: status,
                      child: Text(
                        status,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            onTap: () => runUiAction(
              context,
              () => widget.app.playback.selectQueueEntry(entry),
            ),
          );
        },
      );
    },
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }
}
