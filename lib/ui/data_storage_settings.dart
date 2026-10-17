import 'package:flutter/material.dart';

import '../core/data_directory_controller.dart';
import '../services/data_directory_picker.dart';

/// Edits the next-launch location, never the running account's storage root.
class DataStorageSettings extends StatefulWidget {
  const DataStorageSettings({super.key, required this.controller, this.picker});

  final DataDirectoryController controller;
  final DataDirectoryPicker? picker;

  @override
  State<DataStorageSettings> createState() => _DataStorageSettingsState();
}

class _DataStorageSettingsState extends State<DataStorageSettings> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String path) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Change data directory?'),
          scrollable: true,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'On the next launch, Yun will move its local data to:',
              ),
              const SizedBox(height: 12),
              SelectableText(path),
              const SizedBox(height: 12),
              const Text(
                'Downloads, artwork, pending uploads, and listening history '
                'will be copied before the old copies are removed. '
                'Keep both locations connected and allow enough free space '
                'for a full copy. Close any other Yun instances first. '
                'Your server library and original music files are unchanged.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Change on next launch'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _choose() => _run(() async {
    final controller = widget.controller;
    final path = await (widget.picker ?? DataDirectoryPicker()).pickDirectory(
      initialDirectory: controller.pendingPath ?? controller.currentPath,
    );
    if (!mounted || path == null || path == controller.currentPath) return;
    if (await _confirm(path) && mounted) await controller.changeDirectory(path);
  });

  Future<void> _reset() => _run(() async {
    final controller = widget.controller;
    if (controller.currentPath == controller.defaultPath ||
        await _confirm(controller.defaultPath)) {
      if (mounted) await controller.useDefaultDirectory();
    }
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final enabled = !_busy && !controller.isSaving;
      final error = _error ?? controller.error;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Data storage', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text('Current data directory'),
          const SizedBox(height: 4),
          SelectableText(controller.currentPath),
          const SizedBox(height: 12),
          const Text(
            'Stores downloaded audio, artwork, library caches, pending uploads, '
            'and listening history for all accounts on this device. '
            'Preferences and secure sign-in credentials stay in system storage.',
          ),
          const SizedBox(height: 12),
          const Text(
            'Choose a writable folder without existing Yun accounts or artwork. '
            'The change takes effect after you fully quit and reopen Yun, '
            'not when you minimize it to the tray.',
          ),
          if (controller.pendingPath case final path?) ...[
            const SizedBox(height: 16),
            const Text('Restart required · Next data directory'),
            const SizedBox(height: 4),
            SelectableText(path),
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                'Could not change data directory. $error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: enabled ? _choose : null,
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('Choose folder'),
              ),
              TextButton(
                onPressed:
                    enabled &&
                        (controller.currentPath != controller.defaultPath ||
                            controller.restartRequired)
                    ? _reset
                    : null,
                child: const Text('Use default location'),
              ),
              if (controller.restartRequired)
                TextButton(
                  onPressed: enabled
                      ? () => _run(controller.cancelChange)
                      : null,
                  child: const Text('Cancel pending change'),
                ),
            ],
          ),
          if (_busy || controller.isSaving) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: const Text('Choosing or saving…'),
            ),
          ],
        ],
      );
    },
  );
}
