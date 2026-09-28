import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import 'widgets.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, required this.app});
  final AppController app;
  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  String _range = 'All time';
  String _view = 'History';
  DateTimeRange? _custom;
  bool _loading = false;
  String? _error;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.app.isAuthenticated) _load();
    });
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    final now = DateTime.now();
    final from = switch (_range) {
      '7 days' => DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(days: 6)),
      '30 days' => DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(days: 29)),
      'Custom' => _custom?.start,
      _ => null,
    };
    try {
      await widget.app.loadStats(
        from: from,
        to: _range == 'Custom' && _custom != null
            ? DateTime(
                _custom!.end.year,
                _custom!.end.month,
                _custom!.end.day + 1,
              )
            : null,
      );
    } catch (error) {
      if (mounted && request == _request) setState(() => _error = '$error');
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _changeRange(String value) async {
    if (value == 'Custom') {
      final now = DateTime.now();
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: now,
        initialDateRange: _custom,
      );
      if (range == null || !mounted) return;
      _custom = range;
    }
    setState(() => _range = value);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final stats = widget.app.stats;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(
          'Listening',
          subtitle: 'A personal record, not a competition',
          actions: [
            IconButton(
              tooltip: 'Refresh listening stats',
              onPressed: _loading || !widget.app.isAuthenticated ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        Expanded(
          child: !widget.app.isAuthenticated
              ? const EmptyState(
                  icon: Icons.bar_chart_rounded,
                  title: 'Your listening story',
                  message: 'Connect to your server to see history and listening totals across your devices.',
                )
              : CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final range in [
                                  'All time',
                                  '7 days',
                                  '30 days',
                                  'Custom',
                                ])
                                  ChoiceChip(
                                    label: Text(range),
                                    selected: _range == range,
                                    onSelected: _loading
                                        ? null
                                        : (_) => _changeRange(range),
                                  ),
                              ],
                            ),
                            if (_range == 'Custom' && _custom != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  '${formatDate(_custom!.start)} – ${formatDate(_custom!.end)}',
                                ),
                              ),
                            const SizedBox(height: 20),
                            if (_loading)
                              const QuietProgress(
                                label: 'Loading listening statistics',
                              ),
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                child: Text(
                                  _error!,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ),
                            if (widget.app.pendingEventCount > 0)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Text(
                                  '${widget.app.pendingEventCount} listening segments waiting to sync. Totals include server-confirmed listening.',
                                ),
                              ),
                            if (stats != null &&
                                !_loading &&
                                _error == null) ...[
                              Wrap(
                                spacing: 16,
                                runSpacing: 16,
                                children: [
                                  _Metric(
                                    label: 'Time listened',
                                    value: _listeningTime(stats.listenedMs),
                                  ),
                                  _Metric(
                                    label: 'Plays',
                                    value: '${stats.playCount}',
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  for (final view in [
                                    'History',
                                    'Tracks',
                                    'Artists',
                                    'Albums',
                                  ])
                                    ChoiceChip(
                                      label: Text(view),
                                      selected: _view == view,
                                      onSelected: (_) =>
                                          setState(() => _view = view),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (stats != null && !_loading && _error == null)
                      ..._results(stats),
                    if (stats == null && !_loading && _error == null)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: EmptyState(
                          icon: Icons.headphones_outlined,
                          title: 'Press play to begin',
                          message: 'Listening history appears here after your first synced session.',
                        ),
                      ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
        ),
      ],
    );
  }

  List<Widget> _results(ServerStats stats) {
    final count = switch (_view) {
      'History' => stats.history.length,
      'Tracks' => stats.topTracks.length,
      'Artists' => stats.topArtists.length,
      _ => stats.topAlbums.length,
    };
    if (count == 0) {
      return [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.headphones_outlined,
            title: 'Nothing in this period',
            message: 'Choose a wider date range or listen to some music.',
          ),
        ),
      ];
    }
    return [
      SliverList.builder(
        itemCount: count,
        itemBuilder: (context, index) {
          if (_view == 'History') {
            final entry = stats.history[index];
            final track = widget.app.trackById(entry.trackId);
            return ListTile(
              leading: const Icon(Icons.history_rounded),
              title: Text(entry.title),
              subtitle: Text(
                '${entry.artist} · ${formatDate(DateTime.fromMillisecondsSinceEpoch(entry.startedAt))}\n${_listeningTime(entry.listenedMs)}${entry.countedPlay ? ' · Counted play' : ' · Partial listen'}',
              ),
              isThreeLine: true,
              trailing: track == null
                  ? null
                  : IconButton(
                      tooltip: 'Play ${entry.title}',
                      onPressed: () =>
                          runUiAction(context, () => widget.app.play(track)),
                      icon: const Icon(Icons.play_arrow_rounded),
                    ),
            );
          }
          if (_view == 'Tracks') {
            final entry = stats.topTracks[index];
            final track = widget.app.trackById(entry.id);
            return _ranking(
              index,
              entry.title,
              '${entry.artist} · ${entry.playCount} plays · ${_listeningTime(entry.listenedMs)}',
              onTap: track == null
                  ? null
                  : () => runUiAction(context, () => widget.app.play(track)),
            );
          }
          if (_view == 'Artists') {
            final entry = stats.topArtists[index];
            return _ranking(
              index,
              entry.name.isEmpty ? 'Unknown artist' : entry.name,
              '${entry.playCount} plays · ${_listeningTime(entry.listenedMs)}',
            );
          }
          final entry = stats.topAlbums[index];
          return _ranking(
            index,
            entry.name.isEmpty ? 'Unknown album' : entry.name,
            '${entry.artist} · ${entry.playCount} plays · ${_listeningTime(entry.listenedMs)}',
          );
        },
      ),
    ];
  }

  Widget _ranking(
    int index,
    String title,
    String subtitle, {
    VoidCallback? onTap,
  }) => ListTile(
    leading: SizedBox(
      width: 32,
      child: Text(
        '${index + 1}',
        style: Theme.of(context).textTheme.titleMedium,
      ),
    ),
    title: Text(title),
    subtitle: Text(subtitle),
    onTap: onTap,
  );
}

String _listeningTime(int ms) {
  final seconds = ms ~/ 1000;
  if (seconds < 60) return '$seconds sec';
  final minutes = seconds ~/ 60;
  return minutes < 60
      ? '$minutes min'
      : '${minutes ~/ 60} hr ${minutes % 60} min';
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 180),
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Text(value, style: Theme.of(context).textTheme.headlineMedium),
      ],
    ),
  );
}
