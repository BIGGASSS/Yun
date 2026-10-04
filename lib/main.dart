import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/app_controller.dart';
import 'core/collection_settings_controller.dart';
import 'core/desktop_controller.dart';
import 'services/desktop_host.dart';
import 'services/collection_settings_store.dart';
import 'services/desktop_settings_store.dart';
import 'services/native_desktop_host.dart';
import 'services/playback_settings_store.dart';
import 'ui/app.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const YunBootstrap());
}

/// Owns the account controller and checkpoints history on lifecycle transitions.
/// Backgrounding does not stop music. OS process termination can still lose
/// unpersisted listening (normally roughly ten seconds; delayed callbacks or
/// failed storage writes can leave more in memory).
class YunBootstrap extends StatefulWidget {
  const YunBootstrap({
    super.key,
    this.controllerFactory,
    this.desktopHostFactory,
  });

  /// Native boundary injected by bootstrap tests; never called on touch/web.
  final DesktopHost Function()? desktopHostFactory;

  final AppController Function({
    required PlaybackSettings playbackSettings,
    required Future<void> Function(PlaybackSettings) savePlaybackSettings,
  })?
  controllerFactory;

  @override
  State<YunBootstrap> createState() => _YunBootstrapState();
}

class _YunBootstrapState extends State<YunBootstrap> {
  AppController? _controller;
  DesktopController? _desktop;
  Future<void>? _opening;
  SharedPreferences? _preferences;
  CollectionSettingsController? _collectionSettings;
  Object? _failure;
  bool _ready = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () => _bestEffort(() => _controller?.refresh()),
      onInactive: () => _bestEffort(_checkpoint),
      onPause: () => _bestEffort(_checkpoint),
      onExitRequested: () async {
        try {
          final desktop = _desktop;
          if (desktop != null) {
            return await desktop.requestApplicationExit()
                ? AppExitResponse.exit
                : AppExitResponse.cancel;
          }
          await _shutdownController();
          return AppExitResponse.exit;
        } catch (error) {
          if (mounted) setState(() => _failure = error);
          return AppExitResponse.cancel;
        }
      },
    );
    unawaited(_initialize());
  }

  void _bestEffort(Future<void>? Function() action) {
    if (!_ready) return;
    unawaited(() async {
      try {
        await action();
      } catch (_) {
        // The core exposes network/storage failures in its observable error state.
      }
    }());
  }

  Future<void> _checkpoint() async {
    try {
      await _controller?.playback.checkpoint();
    } finally {
      try {
        await _controller?.playback.flushSettings();
      } finally {
        try {
          await _collectionSettings?.flushSettings();
        } finally {
          await _desktop?.flushSettings();
        }
      }
    }
  }

  Future<void> _shutdownController() async {
    await _collectionSettings?.flushSettings();
    await _controller?.shutdown();
  }

  Future<void> _initialize() =>
      _opening ??= _open().whenComplete(() => _opening = null);

  Future<void> _open() async {
    setState(() {
      _failure = null;
      _ready = false;
    });
    final old = _controller;
    final oldDesktop = _desktop;
    try {
      // Keep references and close interception until pending durable work is
      // finished. A native close or OS quit during Retry must await it too.
      if (old != null) await _shutdownController();
      if (!mounted || (oldDesktop?.isQuitting ?? false)) return;
      if (oldDesktop != null) {
        // A close-to-tray event may have hidden the failed startup meanwhile.
        // Do not remove its recovery icon while replacing desktop resources.
        await oldDesktop.showWindow();
        await oldDesktop.detach();
        oldDesktop.dispose();
      }
      old?.dispose();
      _controller = null;
      _desktop = null;
      _preferences = await SharedPreferences.getInstance();
      final collectionStore = SharedPreferencesCollectionSettingsStore(
        _preferences!,
      );
      _collectionSettings = CollectionSettingsController(
        initialSettings: await collectionStore.read(),
        saveSettings: collectionStore.write,
      );
      final store = SharedPreferencesPlaybackSettingsStore(_preferences!);
      final saved = await store.read();
      if (!mounted) return;
      final desktop = isDesktopPlatform;
      // Touch devices retain their OS-managed volume. Shuffle and repeat are
      // shared preferences on every platform; never start playback on restore.
      final settings = PlaybackSettings(
        volume: desktop ? saved.volume : null,
        lastPositiveVolume: desktop ? saved.lastPositiveVolume : 100,
        shuffle: saved.shuffle,
        repeatMode: saved.repeatMode,
      );
      final factory = widget.controllerFactory ?? AppController.new;
      final controller = factory(
        playbackSettings: settings,
        savePlaybackSettings: store.write,
      );
      _controller = controller;
      if (desktop) {
        final integration = DesktopController(
          host: (widget.desktopHostFactory ?? NativeDesktopHost.new)(),
          settings: SharedPreferencesDesktopSettingsStore(_preferences!),
          prepareExit: () async => await _collectionSettings?.flushSettings(),
          shutdown: controller.shutdown,
          checkpoint: () async {
            try {
              await controller.playback.checkpoint();
            } finally {
              try {
                await controller.playback.flushSettings();
              } finally {
                await _collectionSettings?.flushSettings();
              }
            }
          },
        );
        _desktop = integration;
        await integration.initialize();
      }
      if (!mounted || (_desktop?.isQuitting ?? false)) return;
      await controller.initialize();
      if (mounted && !(_desktop?.isQuitting ?? false)) {
        setState(() => _ready = true);
      }
    } catch (error) {
      if (mounted) setState(() => _failure = error);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _desktop?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) {
      final savedTheme = _preferences?.getString('appearance.theme');
      final theme = ThemeMode.values.firstWhere(
        (mode) => mode.name == savedTheme,
        orElse: () => ThemeMode.system,
      );
      return YunApp(
        controller: _controller!,
        collectionSettings: _collectionSettings,
        desktop: _desktop,
        initialThemeMode: theme,
        onThemeChanged: (mode) async {
          await _preferences?.setString('appearance.theme', mode.name);
        },
      );
    }
    return MaterialApp(
      title: '韵',
      debugShowCheckedModeBanner: false,
      theme: YunTheme.light(),
      darkTheme: YunTheme.dark(),
      home: Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('韵', style: TextStyle(fontSize: 40)),
                  const SizedBox(height: 24),
                  if (_failure == null)
                    const Text('Opening your library…')
                  else ...[
                    const Text('Your library could not be opened.'),
                    const SizedBox(height: 12),
                    const Text(
                      'Check that your secure credential store is available '
                      'and your application storage is writable. '
                      'Your music and pending history have not been deleted.',
                    ),
                    const SizedBox(height: 12),
                    SelectableText(_failure.toString()),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _initialize,
                      child: const Text('Retry'),
                    ),
                    if (_desktop != null)
                      TextButton(
                        onPressed: _desktop!.quit,
                        child: const Text('Quit Yun'),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
