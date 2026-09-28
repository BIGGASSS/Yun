import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_controller.dart';
import 'downloads_screen.dart';
import 'library_screen.dart';
import 'player.dart';
import 'playlist_screen.dart';
import 'settings_screen.dart';
import 'stats_screen.dart';
import 'theme.dart';
import 'uploads.dart';
import 'widgets.dart';

/// The application view. The caller owns initialization and disposal of [controller].
class YunApp extends StatefulWidget {
  const YunApp({
    super.key,
    required this.controller,
    this.initialThemeMode = ThemeMode.system,
    this.onThemeChanged,
  });
  final AppController controller;
  final ThemeMode initialThemeMode;
  final ValueChanged<ThemeMode>? onThemeChanged;

  @override
  State<YunApp> createState() => _YunAppState();
}

class _YunAppState extends State<YunApp> {
  late ThemeMode _themeMode = widget.initialThemeMode;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Yun',
    debugShowCheckedModeBanner: false,
    theme: YunTheme.light(),
    darkTheme: YunTheme.dark(),
    themeMode: _themeMode,
    home: _AppShell(
      app: widget.controller,
      themeMode: _themeMode,
      onThemeChanged: (mode) {
        setState(() => _themeMode = mode);
        widget.onThemeChanged?.call(mode);
      },
    ),
  );
}

class _AppShell extends StatefulWidget {
  const _AppShell({
    required this.app,
    required this.themeMode,
    required this.onThemeChanged,
  });
  final AppController app;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;

  @override
  State<_AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<_AppShell> {
  int _destination = 0;
  bool _queueVisible = false;
  final _searchFocus = FocusNode(debugLabel: 'Library search');

  static const _labels = [
    'Library',
    'Playlists',
    'Downloads',
    'Stats',
    'Settings',
  ];
  static const _icons = [
    Icons.library_music_outlined,
    Icons.queue_music_rounded,
    Icons.download_outlined,
    Icons.bar_chart_rounded,
    Icons.settings_outlined,
  ];

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  void _search() {
    setState(() => _destination = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  void _upload() {
    if (widget.app.isAuthenticated) {
      pickUploads(context, widget.app);
    } else {
      setState(() => _destination = 4);
    }
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      for (final meta in [false, true]) ...{
        SingleActivator(LogicalKeyboardKey.keyF, control: !meta, meta: meta):
            _search,
        SingleActivator(LogicalKeyboardKey.keyU, control: !meta, meta: meta):
            _upload,
        SingleActivator(
          LogicalKeyboardKey.space,
          control: !meta,
          meta: meta,
        ): () =>
            runUiAction(context, widget.app.playback.toggle),
        SingleActivator(
          LogicalKeyboardKey.arrowRight,
          control: !meta,
          meta: meta,
        ): () =>
            runUiAction(context, widget.app.playback.next),
        SingleActivator(
          LogicalKeyboardKey.arrowLeft,
          control: !meta,
          meta: meta,
        ): () =>
            runUiAction(context, widget.app.playback.previous),
      },
    },
    child: Focus(
      autofocus: true,
      child: ListenableBuilder(
        listenable: widget.app,
        builder: (context, _) {
          final app = widget.app;
          return LayoutBuilder(
            builder: (context, constraints) {
              final scale = MediaQuery.textScalerOf(context).scale(1);
              final desktop =
                  constraints.maxWidth >= 840 &&
                  constraints.maxHeight >= 500 * scale.clamp(1, 1.6);
              final extendedRail = constraints.maxWidth >= 1320 && scale < 1.5;
              final sideQueue =
                  desktop &&
                  constraints.maxWidth >= 1180 &&
                  scale < 1.5 &&
                  _queueVisible;
              final compactPlayer = !desktop || scale > 1.5;
              return Scaffold(
                body: SafeArea(
                  bottom: false,
                  child: UploadDropRegion(
                    app: app,
                    child: Column(
                      children: [
                        if (!app.initialized || app.busy)
                          const QuietProgress(label: 'Syncing your library'),
                        Expanded(
                          child: Row(
                            children: [
                              if (desktop) ...[
                                _rail(extendedRail),
                                const VerticalDivider(width: 1),
                              ],
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _statusBar(desktop),
                                    if (app.error != null)
                                      MaterialBanner(
                                        content: Text(
                                          app.error!,
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        leading: const Icon(
                                          Icons.info_outline_rounded,
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: app.clearError,
                                            child: const Text('Dismiss'),
                                          ),
                                        ],
                                      ),
                                    Expanded(
                                      child: KeyedSubtree(
                                        // Destroy account-specific transient UI when the account changes.
                                        key: ValueKey(
                                          '${app.account?.server}/${app.account?.userId}/$_destination',
                                        ),
                                        child: switch (_destination) {
                                          0 => LibraryScreen(
                                            app: app,
                                            searchFocus: _searchFocus,
                                            onUpload: _upload,
                                            onSignIn: () => setState(
                                              () => _destination = 4,
                                            ),
                                          ),
                                          1 => PlaylistsScreen(app: app),
                                          2 => DownloadsScreen(app: app),
                                          3 => StatsScreen(app: app),
                                          _ => SettingsScreen(
                                            app: app,
                                            themeMode: widget.themeMode,
                                            onThemeChanged:
                                                widget.onThemeChanged,
                                          ),
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (sideQueue) ...[
                                const VerticalDivider(width: 1),
                                SizedBox(
                                  width: 300,
                                  child: QueuePanel(
                                    app: app,
                                    onClose: () =>
                                        setState(() => _queueVisible = false),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        PlayerBar(
                          app: app,
                          compact: compactPlayer,
                          onQueue: () {
                            if (constraints.maxWidth >= 1180 && scale < 1.5) {
                              setState(() => _queueVisible = !_queueVisible);
                            } else {
                              showQueue(context, app);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                bottomNavigationBar: desktop
                    ? null
                    : NavigationBar(
                        selectedIndex: _destination,
                        labelBehavior: constraints.maxWidth < 430 || scale > 1.2
                            ? NavigationDestinationLabelBehavior
                                  .onlyShowSelected
                            : NavigationDestinationLabelBehavior.alwaysShow,
                        onDestinationSelected: (value) =>
                            setState(() => _destination = value),
                        destinations: [
                          for (var index = 0; index < _labels.length; index++)
                            NavigationDestination(
                              icon: Icon(_icons[index]),
                              label: _labels[index],
                            ),
                        ],
                      ),
              );
            },
          );
        },
      ),
    ),
  );

  Widget _rail(bool extended) => NavigationRail(
    extended: extended,
    minExtendedWidth: 200,
    selectedIndex: _destination,
    labelType: extended
        ? NavigationRailLabelType.none
        : NavigationRailLabelType.all,
    onDestinationSelected: (value) => setState(() => _destination = value),
    leading: Padding(
      padding: const EdgeInsets.fromLTRB(12, 24, 12, 28),
      child: Text(
        'yun',
        style: Theme.of(context).textTheme.headlineMedium
            ?.copyWith(fontWeight: FontWeight.w300, letterSpacing: 4),
      ),
    ),
    destinations: [
      for (var index = 0; index < _labels.length; index++)
        NavigationRailDestination(
          icon: Icon(_icons[index]),
          label: Text(_labels[index]),
        ),
    ],
  );

  Widget _statusBar(bool desktop) {
    final app = widget.app;
    final activeUploads = app.uploads
        .where(
          (job) => [
            'queued',
            'uploading',
            'completing',
            'failed',
          ].contains(job.status),
        )
        .length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 12, 0),
      child: Row(
        children: [
          if (!desktop)
            Text(
              'yun',
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(letterSpacing: 3),
            ),
          const Spacer(),
          if (app.isOffline && app.isAuthenticated)
            Flexible(
              child: Tooltip(
                message: 'Offline. Downloaded tracks are available.',
                child: Text(
                  'Offline',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ),
          if (app.isAuthenticated)
            IconButton(
              tooltip: activeUploads > 0
                  ? 'Uploads, $activeUploads active or needing attention'
                  : 'Show uploads',
              onPressed: () => showUploads(context, app),
              icon: Badge(
                isLabelVisible: activeUploads > 0,
                label: Text('$activeUploads'),
                child: const Icon(Icons.cloud_upload_outlined),
              ),
            ),
          if (!app.isAuthenticated)
            TextButton.icon(
              onPressed: () => setState(() => _destination = 4),
              icon: const Icon(Icons.person_outline_rounded, size: 18),
              label: const Text('Connect'),
            ),
        ],
      ),
    );
  }
}
