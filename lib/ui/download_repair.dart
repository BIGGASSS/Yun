import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import 'selected_builder.dart';
import 'widgets.dart';

/// An explicit network action, shared by playback errors and Downloads.
/// Connectivity and per-track repair state can change without playback ticks.
class RedownloadTrackButton extends StatelessWidget {
  const RedownloadTrackButton({
    super.key,
    required this.app,
    required this.track,
  });

  final AppController app;
  final Track track;

  @override
  Widget build(BuildContext context) => SelectedBuilder(
    listenable: Listenable.merge([app, app.downloadChanges]),
    select: () => (
      app.isAuthenticated,
      app.isOffline,
      app.isRedownloadingTrack(track.id),
    ),
    builder: (context, state, _) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: state.$1 && !state.$2 && !state.$3
              ? () => runUiAction(context, () async {
                  final account = app.account;
                  final currentTrack = app.playback.currentTrack;
                  await app.redownloadTrack(track);
                  if (!context.mounted ||
                      !app.isAuthenticated ||
                      !identical(app.account, account) ||
                      !identical(app.playback.currentTrack, currentTrack)) {
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Downloaded again. Press Play to retry.'),
                      showCloseIcon: true,
                    ),
                  );
                })
              : null,
          icon: const Icon(Icons.download_rounded),
          label: Text(state.$3 ? 'Redownloading…' : 'Redownload'),
        ),
        if (state.$2)
          Text(
            'Reconnect to redownload',
            style: Theme.of(context).textTheme.bodySmall,
          )
        else if (!state.$1)
          Text(
            'Sign in to redownload',
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    ),
  );
}
