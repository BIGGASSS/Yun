import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/app_controller.dart';
import 'services/playback_settings_store.dart';
import 'ui/app.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const YunBootstrap());
}

/// Owns the account controller and checkpoints history on lifecycle transitions.
/// Backgrounding does not stop music. OS process termination can still lose the
/// last (at most roughly ten seconds) uncheckpointed listening segment.
class YunBootstrap extends StatefulWidget {
  const YunBootstrap({super.key, this.controllerFactory});

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
  SharedPreferences? _preferences;
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
          await _controller?.shutdown();
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
      await _controller?.playback.flushSettings();
    }
  }

  Future<void> _initialize() async {
    setState(() {
      _failure = null;
      _ready = false;
    });
    final old = _controller;
    _controller = null;
    try {
      if (old != null) {
        await old.shutdown();
        old.dispose();
      }
      _preferences = await SharedPreferences.getInstance();
      final store = SharedPreferencesPlaybackSettingsStore(_preferences!);
      final saved = await store.read();
      final desktop =
          !kIsWeb &&
          switch (defaultTargetPlatform) {
            TargetPlatform.linux ||
            TargetPlatform.macOS ||
            TargetPlatform.windows => true,
            _ => false,
          };
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
      await controller.initialize();
      if (mounted) setState(() => _ready = true);
    } catch (error) {
      if (mounted) setState(() => _failure = error);
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
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
