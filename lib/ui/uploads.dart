import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import 'widgets.dart';

Future<void> pickUploads(
  BuildContext context,
  AppController app,
) => runUiAction(context, () async {
  final account = app.account;
  if (account == null) throw StateError('Sign in before importing music');
  final result = await FilePicker.platform.pickFiles(
    allowMultiple: true,
    type: FileType.custom,
    allowedExtensions: [
      'mp3',
      'flac',
      'm4a',
      'aac',
      'ogg',
      'opus',
      'wav',
      'aiff',
      'aif',
    ],
    withData: false,
  );
  if (result == null || !context.mounted) return;
  final paths = result.files
      .map((file) => file.path)
      .whereType<String>()
      .toList();
  if (paths.isEmpty) {
    throw StateError('The file picker did not provide a readable local file.');
  }
  // Show the queue immediately; jobs are persisted and run by AppController.
  showUploads(context, app);
  for (final path in paths) {
    _requireSameAccount(app, account);
    await app.enqueueUpload(path);
  }
});

void _requireSameAccount(AppController app, Account account) {
  if (app.account?.server != account.server ||
      app.account?.userId != account.userId) {
    throw StateError('Account changed; select your files again');
  }
}

void showUploads(BuildContext context, AppController app) {
  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Uploads'),
      content: SizedBox(
        width: 520,
        height: 380,
        child: ListenableBuilder(
          listenable: app,
          builder: (context, _) {
            if (app.uploads.isEmpty) {
              return const EmptyState(
                icon: Icons.upload_file_outlined,
                title: 'Ready when you are',
                message: 'Choose audio files or drop them into 韵. Uploads can be retried after a connection interruption.',
              );
            }
            final pending = <UploadJob>[];
            final done = <UploadJob>[];
            final failed = <UploadJob>[];
            for (final job in app.uploads) {
              switch (job.status) {
                case 'done':
                  done.add(job);
                case 'failed':
                case 'cancelled':
                  failed.add(job);
                default:
                  pending.add(job);
              }
            }
            final rows = <Object>[
              ('Pending', pending.length),
              ...pending,
              ('Done', done.length),
              ...done,
              ('Failed', failed.length),
              ...failed,
            ];
            return ListView.separated(
              itemCount: rows.length,
              separatorBuilder: (_, _) => const SizedBox(height: 16),
              itemBuilder: (context, index) {
                final row = rows[index];
                if (row is (String, int)) {
                  return Semantics(
                    header: true,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            row.$1,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        Text('${row.$2}'),
                      ],
                    ),
                  );
                }
                final job = row as UploadJob;
                final active = ![
                  'done',
                  'failed',
                  'cancelled',
                ].contains(job.status);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            job.filename,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        if (active)
                          IconButton(
                            tooltip: 'Cancel ${job.filename}',
                            onPressed: () => runUiAction(
                              context,
                              () => app.cancelUpload(job.id),
                            ),
                            icon: const Icon(Icons.close_rounded),
                          ),
                        if (job.status == 'failed')
                          IconButton(
                            tooltip: 'Retry ${job.filename}',
                            onPressed: () => runUiAction(
                              context,
                              () => app.retryUpload(job.id),
                            ),
                            icon: const Icon(Icons.refresh_rounded),
                          ),
                        if (job.status == 'done')
                          const Padding(
                            padding: EdgeInsets.all(12),
                            child: Icon(Icons.check_circle_outline_rounded),
                          ),
                      ],
                    ),
                    if (active)
                      QuietProgress(
                        value: job.status == 'completing' ? null : job.progress,
                        label: 'Uploading ${job.filename}',
                      ),
                    const SizedBox(height: 6),
                    Text(
                      '${_status(job.status)} · ${formatBytes(job.offset)} / ${formatBytes(job.sizeBytes)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (job.error != null)
                      Text(
                        job.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
      actions: [
        ListenableBuilder(
          listenable: app,
          builder: (context, _) => TextButton(
            onPressed: app.uploads.any((job) => job.status == 'done')
                ? () => runUiAction(context, app.clearDoneUploads)
                : null,
            child: const Text('Clear done'),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
        FilledButton.tonalIcon(
          onPressed: () {
            Navigator.pop(dialogContext);
            pickUploads(context, app);
          },
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add files'),
        ),
      ],
    ),
  );
}

String _status(String status) => switch (status) {
  'queued' => 'Queued',
  'uploading' => 'Uploading',
  'completing' => 'Reading audio metadata',
  'done' => 'Complete',
  'failed' => 'Needs attention',
  'cancelled' => 'Cancelled · choose the file again to upload',
  _ => status,
};

class UploadDropRegion extends StatefulWidget {
  const UploadDropRegion({super.key, required this.app, required this.child});
  final AppController app;
  final Widget child;

  @override
  State<UploadDropRegion> createState() => _UploadDropRegionState();
}

class _UploadDropRegionState extends State<UploadDropRegion> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => DropTarget(
    enable: widget.app.isAuthenticated,
    onDragEntered: (_) => setState(() => _hover = true),
    onDragExited: (_) => setState(() => _hover = false),
    onDragDone: (details) {
      setState(() => _hover = false);
      final account = widget.app.account;
      runUiAction(context, () async {
        if (account == null) throw StateError('Sign in before importing music');
        showUploads(context, widget.app);
        for (final file in details.files) {
          _requireSameAccount(widget.app, account);
          final bookmark = file.extraAppleBookmark;
          var scoped = false;
          try {
            if (Platform.isMacOS && bookmark != null && bookmark.isNotEmpty) {
              scoped = await DesktopDrop.instance
                  .startAccessingSecurityScopedResource(bookmark: bookmark);
            }
            _requireSameAccount(widget.app, account);
            // Keep sandbox access until the durable app-private copy is complete.
            await widget.app.enqueueUpload(file.path);
          } finally {
            if (scoped) {
              await DesktopDrop.instance.stopAccessingSecurityScopedResource(
                bookmark: bookmark!,
              );
            }
          }
        }
      });
    },
    child: Stack(
      children: [
        widget.child,
        if (_hover)
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surface
                    .withValues(alpha: .94),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(40),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.primary,
                        width: 2,
                      ),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.file_upload_outlined, size: 56),
                        SizedBox(height: 16),
                        Text('Drop audio files to upload'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
