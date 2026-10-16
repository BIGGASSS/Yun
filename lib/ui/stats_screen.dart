import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import 'widgets.dart';

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, required this.app, this.onSignIn});
  final AppController app;

  /// Opens account sign-in. Omitted only when the screen is shown alone.
  final VoidCallback? onSignIn;

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  String _range = 'All time';
  DateTimeRange? _custom;
  _ShownRange? _shown;
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
    final range = _range;
    final custom = _custom;
    setState(() {
      _loading = true;
      _error = null;
    });
    final window = ListeningStats.window(
      range: range,
      custom: custom,
      now: DateTime.now(),
    );
    try {
      await widget.app.loadStats(from: window.from, to: window.to);
      if (mounted && request == _request) {
        setState(() {
          _loading = false;
          _shown = _ShownRange(range, custom);
        });
      }
    } catch (error) {
      if (mounted && request == _request) {
        setState(() {
          _error = '$error';
          _loading = false;
        });
      }
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
    final app = widget.app;
    final stats = _statsForSelection(app.stats);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeading(
          'Listening',
          subtitle: 'A personal record, not a competition',
          actions: [
            IconButton(
              tooltip: 'Refresh listening stats',
              onPressed: _loading || !app.isAuthenticated ? null : _load,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        if (_loading)
          const QuietProgress(label: 'Loading listening statistics'),
        Expanded(
          child: !app.isAuthenticated
              ? EmptyState(
                  icon: Icons.bar_chart_rounded,
                  title: 'Your listening story',
                  message: 'Connect to your server to see history and listening totals across your devices.',
                  action: widget.onSignIn == null
                      ? null
                      : FilledButton(
                          onPressed: widget.onSignIn,
                          child: const Text('Connect to server'),
                        ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) => DefaultTabController(
                    length: ListeningStats.views.length,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            // Keep the totals on screen. Scroll this header
                            // only when the range, summary, and sync note
                            // would otherwise cover the list.
                            maxHeight: constraints.maxHeight * 0.72,
                          ),
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _rangeControls(),
                                if (stats != null) _Summary(stats: stats),
                                if (_error != null && stats != null)
                                  _errorBanner(),
                                if (app.pendingEventCount > 0) _syncNote(),
                              ],
                            ),
                          ),
                        ),
                        if (stats == null)
                          Expanded(
                            child: _loading
                                ? const Center(
                                    child: Text('Loading listening statistics'),
                                  )
                                : _unavailable(),
                          )
                        else ...[
                          const TabBar(
                            isScrollable: true,
                            tabAlignment: TabAlignment.start,
                            tabs: [
                              Tab(text: 'History'),
                              Tab(text: 'Tracks'),
                              Tab(text: 'Artists'),
                              Tab(text: 'Albums'),
                            ],
                          ),
                          Expanded(
                            child: TabBarView(
                              children: [
                                _HistoryList(app: app, history: stats.history),
                                _Rankings(
                                  items: stats.topTracks,
                                  noun: 'track',
                                  title: (item) => item.title.isEmpty
                                      ? 'Untitled'
                                      : item.title,
                                  detail: (item) => ListeningStats.join([
                                    item.artist,
                                    ListeningStats.plays(item.playCount),
                                  ]),
                                  onOpen: (item) {
                                    final track = app.trackById(item.id);
                                    if (track == null) return null;
                                    return () => runUiAction(
                                      context,
                                      () => app.play(track),
                                    );
                                  },
                                ),
                                _Rankings(
                                  items: stats.topArtists,
                                  noun: 'artist',
                                  title: (item) => item.name.isEmpty
                                      ? 'Unknown artist'
                                      : item.name,
                                  detail: (item) =>
                                      ListeningStats.plays(item.playCount),
                                ),
                                _Rankings(
                                  items: stats.topAlbums,
                                  noun: 'album',
                                  title: (item) => item.name.isEmpty
                                      ? 'Unknown album'
                                      : item.name,
                                  detail: (item) => ListeningStats.join([
                                    item.artist,
                                    ListeningStats.plays(item.playCount),
                                  ]),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  /// [AppController.stats] is whatever last succeeded. Show it only for the
  /// range that produced it, so a failed range change cannot relabel it.
  ServerStats? _statsForSelection(ServerStats? stats) {
    final shown = _shown;
    if (stats == null || shown == null || !shown.matches(_range, _custom)) {
      return null;
    }
    return stats;
  }

  Widget _rangeControls() {
    final custom = _range == 'Custom' && _custom != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final range in ListeningStats.ranges)
                ChoiceChip(
                  label: Text(range),
                  selected: _range == range,
                  onSelected: _loading ? null : (_) => _changeRange(range),
                ),
            ],
          ),
          if (custom)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${formatDate(_custom!.start)} – ${formatDate(_custom!.end)}',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _syncNote() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.cloud_upload_outlined,
            size: 18,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${widget.app.pendingEventCount} listening segments waiting to sync. Totals include server-confirmed listening.',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Icon(
                  Icons.error_outline_rounded,
                  color: scheme.onErrorContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _error!,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                ),
              ),
              TextButton(
                onPressed: _loading ? null : _load,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _unavailable() {
    if (_error != null) {
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Stats did not load',
        message: _error!,
        action: FilledButton.tonal(
          onPressed: _loading ? null : _load,
          child: const Text('Try again'),
        ),
      );
    }
    return const EmptyState(
      icon: Icons.headphones_outlined,
      title: 'Press play to begin',
      message:
          'Listening history appears here after your first synced session.',
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.stats});
  final ServerStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final perPlay = ListeningStats.perPlay(stats.listenedMs, stats.playCount);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Wrap(
            spacing: 32,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              _Figure(
                label: 'Time listened',
                value: ListeningStats.duration(stats.listenedMs),
              ),
              _Figure(label: 'Plays', value: '${stats.playCount}'),
              if (perPlay != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    perPlay,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({required this.app, required this.history});
  final AppController app;
  final List<HistoryItem> history;

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) return const _PeriodEmpty();
    final days = ListeningStats.days(history);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (history.length == ListeningStats.historyCap)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Text(
              'Latest ${ListeningStats.historyCap} sessions in this period.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        for (final day in days) ...[
          Semantics(
            header: true,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      formatDate(day.day),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    ListeningStats.duration(day.listenedMs),
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          for (final entry in day.entries) _HistoryTile(app: app, entry: entry),
        ],
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.app, required this.entry});
  final AppController app;
  final HistoryItem entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final track = app.trackById(entry.trackId);
    final started = DateTime.fromMillisecondsSinceEpoch(entry.startedAt);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      leading: Text(
        ListeningStats.clock(started),
        style: theme.textTheme.labelLarge?.copyWith(
          color: scheme.onSurfaceVariant,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      title: Text(
        entry.title.isEmpty ? 'Untitled' : entry.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        ListeningStats.join([
          entry.artist,
          ListeningStats.duration(entry.listenedMs),
          entry.countedPlay ? 'Counted play' : 'Partial listen',
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: track == null
          ? null
          : IconButton(
              tooltip: 'Play ${entry.title}',
              onPressed: () => runUiAction(context, () => app.play(track)),
              icon: const Icon(Icons.play_arrow_rounded),
            ),
    );
  }
}

class _Rankings extends StatelessWidget {
  const _Rankings({
    required this.items,
    required this.noun,
    required this.title,
    required this.detail,
    this.onOpen,
  });

  final List<StatsItem> items;
  final String noun;
  final String Function(StatsItem item) title;
  final String Function(StatsItem item) detail;
  final VoidCallback? Function(StatsItem item)? onOpen;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const _PeriodEmpty();
    var maxMs = 0;
    for (final item in items) {
      if (item.listenedMs > maxMs) maxMs = item.listenedMs;
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount:
          items.length + (items.length == ListeningStats.rankingCap ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == 0 && items.length == ListeningStats.rankingCap) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: Text(
              'Top ${ListeningStats.rankingCap} by time listened.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          );
        }
        final itemIndex = items.length == ListeningStats.rankingCap
            ? index - 1
            : index;
        final item = items[itemIndex];
        final open = onOpen?.call(item);
        final fraction = ListeningStats.share(item.listenedMs, maxMs);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(24, 0, 16, 0),
              leading: SizedBox(
                width: 28,
                child: Text(
                  '${itemIndex + 1}',
                  textAlign: TextAlign.end,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: itemIndex < 3
                        ? scheme.onSurface
                        : scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              title: Text(
                title(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                detail(item),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                ListeningStats.duration(item.listenedMs),
                style: theme.textTheme.labelLarge,
              ),
              onTap: open,
            ),
            if (maxMs > 0)
              _ShareBar(
                fraction: fraction,
                label:
                    'Listening share ${(fraction * 100).round()} percent for this $noun',
              ),
          ],
        );
      },
    );
  }
}

class _ShareBar extends StatelessWidget {
  const _ShareBar({required this.fraction, required this.label});
  final double fraction;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: label,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(72, 0, 24, 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: SizedBox(
            height: 4,
            child: ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: fraction.clamp(0, 1).toDouble(),
                  child: ColoredBox(color: scheme.secondary),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PeriodEmpty extends StatelessWidget {
  const _PeriodEmpty();

  @override
  Widget build(BuildContext context) => const EmptyState(
    icon: Icons.headphones_outlined,
    title: 'Nothing in this period',
    message: 'Choose a wider date range or listen to some music.',
  );
}

/// Range whose successful load produced the stats currently on screen.
class _ShownRange {
  const _ShownRange(this.range, this.custom);
  final String range;
  final DateTimeRange? custom;

  bool matches(String range, DateTimeRange? custom) {
    if (this.range != range) return false;
    if (range != 'Custom') return true;
    return this.custom == custom;
  }
}

/// Local date window for `GET /stats`. [to] is exclusive, matching the server.
class StatsWindow {
  const StatsWindow({this.from, this.to});
  final DateTime? from;
  final DateTime? to;
}

/// One local calendar day of listening sessions, in server order.
class HistoryDay {
  HistoryDay(this.day);
  final DateTime day;
  final List<HistoryItem> entries = [];
  int get listenedMs => entries.fold(0, (sum, entry) => sum + entry.listenedMs);
}

/// View helpers for listening stats. Totals still come from [AppController].
abstract final class ListeningStats {
  static const ranges = ['All time', '7 days', '30 days', 'Custom'];
  static const views = ['History', 'Tracks', 'Artists', 'Albums'];
  static const historyCap = 100;
  static const rankingCap = 50;

  static StatsWindow window({
    required String range,
    DateTimeRange? custom,
    required DateTime now,
  }) {
    final today = DateTime(now.year, now.month, now.day);
    return switch (range) {
      '7 days' => StatsWindow(from: today.subtract(const Duration(days: 6))),
      '30 days' => StatsWindow(from: today.subtract(const Duration(days: 29))),
      'Custom' when custom != null => StatsWindow(
        from: custom.start,
        to: DateTime(custom.end.year, custom.end.month, custom.end.day + 1),
      ),
      _ => const StatsWindow(),
    };
  }

  static String duration(int milliseconds) =>
      formatTotalDuration(Duration(milliseconds: milliseconds));

  static String? perPlay(int listenedMs, int playCount) {
    if (playCount <= 0 || listenedMs <= 0) return null;
    return '${duration(listenedMs ~/ playCount)} per counted play';
  }

  static String plays(int count) {
    final plays = count < 0 ? 0 : count;
    return '$plays ${plays == 1 ? 'play' : 'plays'}';
  }

  static String clock(DateTime time) {
    final local = time.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  static String join(Iterable<String> parts) =>
      parts.where((part) => part.trim().isNotEmpty).join(' · ');

  static double share(int listenedMs, int maxMs) =>
      maxMs <= 0 ? 0 : (listenedMs / maxMs).clamp(0, 1);

  static List<HistoryDay> days(List<HistoryItem> history) {
    final grouped = <HistoryDay>[];
    for (final entry in history) {
      final started = DateTime.fromMillisecondsSinceEpoch(entry.startedAt);
      final day = DateTime(started.year, started.month, started.day);
      if (grouped.isNotEmpty && grouped.last.day == day) {
        grouped.last.entries.add(entry);
      } else {
        grouped.add(HistoryDay(day)..entries.add(entry));
      }
    }
    return grouped;
  }
}
