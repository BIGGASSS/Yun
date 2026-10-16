import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import 'selected_builder.dart';
import 'track_widgets.dart';
import 'widgets.dart';

/// Personal listening dashboard: headline totals, recent activity, ranked
/// top lists and the play-by-play history for the chosen period.
class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key, required this.app, DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final AppController app;

  /// Clock for range bucketing; injectable so golden tests can freeze time.
  final DateTime Function() _now;
  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  static const _ranges = ['All time', '7 days', '30 days', 'Custom'];
  static const _views = ['Tracks', 'Artists', 'Albums', 'History'];
  static const _weekdayShort = [
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];
  static const _weekdayLong = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  static const _monthShort = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  static const _monthLong = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  final _scroll = ScrollController();
  String _range = 'All time';
  String _view = 'Tracks';
  DateTimeRange? _custom;
  bool _loading = false;
  String? _error;
  int _request = 0;
  String? _loadedKey;

  // Representative artwork and play queues, rebuilt only when the account's
  // track list changes identity.
  List<Track>? _artSource;
  Map<String, Track> _artistArt = const {};
  Map<String, Track> _albumArt = const {};
  Map<String, List<Track>> _artistTracks = const {};
  Map<String, List<Track>> _albumTracks = const {};

  AppController get _app => widget.app;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _app.isAuthenticated) _load();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    final now = widget._now();
    // Calendar-day arithmetic: DateTime constructor overflow handles month
    // boundaries and stays on local midnights across DST transitions.
    final from = switch (_range) {
      '7 days' => DateTime(now.year, now.month, now.day - 6),
      '30 days' => DateTime(now.year, now.month, now.day - 29),
      'Custom' => _custom?.start,
      _ => null,
    };
    try {
      await _app.loadStats(
        from: from,
        to: _range == 'Custom' && _custom != null
            ? DateTime(
                _custom!.end.year,
                _custom!.end.month,
                _custom!.end.day + 1,
              )
            : null,
      );
      // Tag the snapshot with the range that produced it. Results are only
      // presented while the selection still matches; a failed range change
      // must not dress previous-range totals in new-range controls.
      _loadedKey = _selectionKey();
    } catch (error) {
      if (mounted && request == _request) setState(() => _error = '$error');
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _changeRange(String value) async {
    if (_loading) return;
    if (value == 'Custom') {
      final now = widget._now();
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: now,
        initialDateRange: _custom,
        helpText: 'Listening stats range',
      );
      // Cancelling the picker keeps the previously selected range.
      if (range == null || !mounted) return;
      _custom = range;
    } else if (value == _range) {
      return;
    }
    setState(() => _range = value);
    _jumpToTop();
    await _load();
  }

  void _changeView(String view) {
    if (view == _view) return;
    setState(() => _view = view);
    _jumpToTop();
  }

  void _jumpToTop() {
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Identifies the range selection (including custom dates) so displayed
  /// stats can be tied to the load that produced them.
  String _selectionKey() =>
      '$_range|${_custom?.start.millisecondsSinceEpoch}|'
      '${_custom?.end.millisecondsSinceEpoch}';

  /// The controller's cached snapshot outlives this screen (navigation
  /// recreates the state), so an untagged snapshot is unverified: present it
  /// only after this instance has loaded and tagged the current selection.
  bool get _stale => _app.stats != null && _loadedKey != _selectionKey();

  static String _norm(String value) => value.trim().toLowerCase();

  static String _albumKey(String album, String artist) =>
      '${_norm(album)}\u0000${_norm(artist)}';

  static int _byTrackOrder(Track a, Track b) {
    final album = a.album.compareTo(b.album);
    if (album != 0) return album;
    final disc = (a.discNumber ?? 0).compareTo(b.discNumber ?? 0);
    if (disc != 0) return disc;
    final number = (a.trackNumber ?? 0).compareTo(b.trackNumber ?? 0);
    return number != 0 ? number : a.title.compareTo(b.title);
  }

  void _indexLibrary(List<Track> tracks) {
    if (identical(_artSource, tracks)) return;
    _artSource = tracks;
    final artistArt = <String, Track>{};
    final albumArt = <String, Track>{};
    final artistTracks = <String, List<Track>>{};
    final albumTracks = <String, List<Track>>{};
    for (final track in tracks) {
      final artist = _norm(track.artist);
      if (artist.isNotEmpty) {
        (artistTracks[artist] ??= []).add(track);
        if (track.hasArtwork) artistArt.putIfAbsent(artist, () => track);
      }
      if (track.album.isNotEmpty) {
        final key = _albumKey(
          track.album,
          track.albumArtist.isEmpty ? track.artist : track.albumArtist,
        );
        (albumTracks[key] ??= []).add(track);
        if (track.hasArtwork) albumArt.putIfAbsent(key, () => track);
      }
    }
    for (final list in artistTracks.values) {
      list.sort(_byTrackOrder);
    }
    for (final list in albumTracks.values) {
      list.sort(_byTrackOrder);
    }
    _artistArt = artistArt;
    _albumArt = albumArt;
    _artistTracks = artistTracks;
    _albumTracks = albumTracks;
  }

  List<Track> get _playableTopTracks => [
    for (final item in _app.stats?.topTracks ?? const <StatsItem>[])
      ?_app.trackById(item.id),
  ];

  static DateTime _dayStart(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  /// Calendar-day distance between local dates. UTC ordinals are exact: two
  /// local midnights can be 23 or 25 hours apart across DST transitions.
  static int _dayOrdinal(DateTime local) =>
      DateTime.utc(local.year, local.month, local.day).millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;

  /// The local midnight `days` calendar days after [local]; the constructor
  /// normalizes month/year overflow instead of stepping 24-hour durations.
  static DateTime _addCalendarDays(DateTime local, int days) =>
      DateTime(local.year, local.month, local.day + days);

  /// Buckets history into days, or months for long ranges. The server caps
  /// history at the newest 100 sessions, so long-range charts are recent.
  ({List<_Bucket> buckets, bool daily}) _activity(ServerStats stats) {
    final today = _dayStart(widget._now());
    final DateTime from;
    var to = today;
    final custom = _custom;
    if (_range == '7 days') {
      from = _addCalendarDays(today, -6);
    } else if (_range == '30 days') {
      from = _addCalendarDays(today, -29);
    } else if (_range == 'Custom' && custom != null) {
      from = _dayStart(custom.start);
      to = _dayStart(custom.end);
    } else {
      if (stats.history.isEmpty) {
        return (buckets: const <_Bucket>[], daily: true);
      }
      var first = today;
      for (final entry in stats.history) {
        final day = _dayStart(
          DateTime.fromMillisecondsSinceEpoch(entry.startedAt),
        );
        if (day.isBefore(first)) first = day;
      }
      from = first;
    }
    final days = _dayOrdinal(to) - _dayOrdinal(from) + 1;
    if (days <= 0) return (buckets: const <_Bucket>[], daily: true);
    String listened(int ms) => ms == 0
        ? 'No listening'
        : formatTotalDuration(Duration(milliseconds: ms));
    if (days <= 45) {
      final sums = List<int>.filled(days, 0);
      for (final entry in stats.history) {
        final index =
            _dayOrdinal(DateTime.fromMillisecondsSinceEpoch(entry.startedAt)) -
            _dayOrdinal(from);
        if (index >= 0 && index < days) sums[index] += entry.listenedMs;
      }
      return (
        daily: true,
        buckets: [
          for (var i = 0; i < days; i++)
            () {
              final day = _addCalendarDays(from, i);
              return _Bucket(
                ms: sums[i],
                label: days <= 7
                    ? _weekdayShort[day.weekday - 1]
                    : '${day.day}',
                tooltip:
                    '${_weekdayShort[day.weekday - 1]}, ${day.day} '
                    '${_monthShort[day.month - 1]} · ${listened(sums[i])}',
              );
            }(),
        ],
      );
    }
    int monthIndex(DateTime day) => day.year * 12 + day.month - 1;
    final count = monthIndex(to) - monthIndex(from) + 1;
    final sums = List<int>.filled(count, 0);
    for (final entry in stats.history) {
      final index =
          monthIndex(DateTime.fromMillisecondsSinceEpoch(entry.startedAt)) -
          monthIndex(from);
      if (index >= 0 && index < count) sums[index] += entry.listenedMs;
    }
    return (
      daily: false,
      buckets: [
        for (var i = 0; i < count; i++)
          () {
            final month = (from.month - 1 + i) % 12 + 1;
            final year = from.year + (from.month - 1 + i) ~/ 12;
            return _Bucket(
              ms: sums[i],
              label: month == 1 && count > 12
                  ? "Jan '${year % 100}"
                  : _monthShort[month - 1],
              tooltip: '${_monthLong[month - 1]} $year · ${listened(sums[i])}',
            );
          }(),
      ],
    );
  }

  String _dayLabel(DateTime day) {
    final today = _dayStart(widget._now());
    final diff = _dayOrdinal(today) - _dayOrdinal(day);
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    if (diff < 7) return _weekdayLong[day.weekday - 1];
    final date = '${day.day} ${_monthShort[day.month - 1]}';
    return day.year == today.year ? date : '$date ${day.year}';
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    final stats = app.stats;
    if (app.isAuthenticated) _indexLibrary(app.tracks);
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
        Expanded(
          child: !app.isAuthenticated
              ? const EmptyState(
                  icon: Icons.bar_chart_rounded,
                  title: 'Your listening story',
                  message: 'Connect to your server to see history and listening totals across your devices.',
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: CustomScrollView(
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        sliver: SliverToBoxAdapter(
                          child: _controls(context, stats),
                        ),
                      ),
                      ..._body(context, stats),
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _controls(BuildContext context, ServerStats? stats) {
    final app = widget.app;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final range in _ranges)
              ChoiceChip(
                label: Text(range),
                selected: _range == range,
                onSelected: _loading ? null : (_) => _changeRange(range),
              ),
            if (_range == 'Custom' && _custom != null)
              TextButton.icon(
                onPressed: _loading ? null : () => _changeRange('Custom'),
                icon: const Icon(Icons.date_range_rounded, size: 18),
                label: Text(
                  '${formatDate(_custom!.start)} – ${formatDate(_custom!.end)}',
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        // Reserve the progress line's height so content never jumps. While a
        // new range is loading, the body shows the centered progress instead.
        SizedBox(
          height: 3,
          child: _loading && stats != null && !_stale
              ? const QuietProgress(label: 'Loading listening statistics')
              : null,
        ),
        if (app.pendingEventCount > 0) ...[
          const SizedBox(height: 12),
          _Notice(
            icon: Icons.cloud_upload_outlined,
            text:
                '${app.pendingEventCount} listening segments waiting to sync — '
                'totals include server-confirmed listening.',
          ),
        ],
        if (_error != null && stats != null && !_stale) ...[
          const SizedBox(height: 12),
          _ErrorCard(message: _error!, onRetry: _loading ? null : _load),
        ],
      ],
    );
  }

  List<Widget> _body(BuildContext context, ServerStats? stats) {
    if (stats == null || _stale) {
      // A failed range change must not present the previous range's results
      // under the new selection; only same-range refreshes keep content.
      if (!_loading && _error != null) {
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.cloud_off_rounded,
              title: 'Could not load stats',
              message: _error!,
              action: FilledButton.tonalIcon(
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ),
          ),
        ];
      }
      if (!_loading && stats == null) {
        return const [
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.headphones_outlined,
              title: 'Press play to begin',
              message: 'Listening history appears here after your first synced session.',
            ),
          ),
        ];
      }
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(
            child: SizedBox(
              width: 220,
              child: QuietProgress(label: 'Loading listening statistics'),
            ),
          ),
        ),
      ];
    }
    final activity = _activity(stats);
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              _OverviewGrid(cards: _cards(stats)),
              if (activity.buckets.isNotEmpty) ...[
                const SizedBox(height: 16),
                _ActivityChart(
                  buckets: activity.buckets,
                  daily: activity.daily,
                  capped: stats.history.length >= 100,
                ),
              ],
              const SizedBox(height: 24),
              _viewSelector(context),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
      ..._viewContent(context, stats),
    ];
  }

  List<Widget> _cards(ServerStats stats) {
    final topArtist = stats.topArtists.firstOrNull;
    final topArtistName = topArtist == null || topArtist.name.isEmpty
        ? null
        : topArtist.name;
    return [
      _StatCard(
        icon: Icons.schedule_rounded,
        label: 'Time listened',
        value: _headlineTime(stats.listenedMs),
      ),
      _StatCard(
        icon: Icons.headphones_rounded,
        label: 'Plays',
        value: _groupedCount(stats.playCount),
      ),
      _StatCard(
        icon: Icons.timelapse_rounded,
        label: 'Per play',
        value: stats.playCount == 0
            ? '—'
            : _headlineTime(stats.listenedMs ~/ stats.playCount),
        sub: 'average',
      ),
      _StatCard(
        icon: Icons.person_outline_rounded,
        label: 'Top artist',
        value: topArtistName ?? '—',
        sub: topArtist == null
            ? 'nothing played yet'
            : '${_playsLabel(topArtist.playCount)} · '
                  '${formatTotalDuration(Duration(milliseconds: topArtist.listenedMs))}',
      ),
    ];
  }

  Widget _viewSelector(BuildContext context) {
    final playable = _view == 'Tracks' ? _playableTopTracks : const <Track>[];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final view in _views)
          ChoiceChip(
            label: Text(view),
            selected: _view == view,
            onSelected: (_) => _changeView(view),
          ),
        if (playable.isNotEmpty)
          TextButton.icon(
            onPressed: () =>
                runUiAction(context, () => _app.playback.playQueue(playable)),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('Play all'),
          ),
      ],
    );
  }

  List<Widget> _viewContent(BuildContext context, ServerStats stats) {
    switch (_view) {
      case 'Tracks':
        return _rankedList(
          context,
          items: stats.topTracks,
          emptyIcon: Icons.music_note_rounded,
          emptyTitle: 'No top tracks in this period',
          row: (index, item, fraction) {
            final track = _app.trackById(item.id);
            final menu = track == null
                ? null
                : TrackMenu(app: _app, track: track);
            return SelectedBuilder<bool>(
              listenable: _app.playback,
              select: () => _app.playback.currentTrack?.id == item.id,
              builder: (context, current, _) => _RankedRow(
                rank: index + 1,
                title: item.title.isEmpty ? 'Unknown track' : item.title,
                subtitle: item.artist.isEmpty ? 'Unknown artist' : item.artist,
                playCount: item.playCount,
                listenedMs: item.listenedMs,
                fraction: fraction,
                highlighted: current,
                leading: TrackArtwork(app: _app, track: track, size: 44),
                onTap: track == null
                    ? null
                    : () => runUiAction(context, () => _app.play(track)),
                onMenuAt: menu == null
                    ? null
                    : (position) => menu.showAt(context, position),
                trailing: menu,
              ),
            );
          },
        );
      case 'Artists':
        return _rankedList(
          context,
          items: stats.topArtists,
          emptyIcon: Icons.person_outline_rounded,
          emptyTitle: 'No top artists in this period',
          row: (index, item, fraction) {
            final name = item.name.isEmpty ? 'Unknown artist' : item.name;
            final art = _artistArt[_norm(item.name)];
            final queue = _artistTracks[_norm(item.name)] ?? const <Track>[];
            return _RankedRow(
              rank: index + 1,
              title: name,
              subtitle: 'Artist',
              playCount: item.playCount,
              listenedMs: item.listenedMs,
              fraction: fraction,
              leading: art != null
                  ? TrackArtwork(app: _app, track: art, size: 44)
                  : const _IconTile(Icons.person_outline_rounded),
              onTap: queue.isEmpty
                  ? null
                  : () => runUiAction(
                      context,
                      () => _app.playback.playQueue(queue),
                    ),
            );
          },
        );
      case 'Albums':
        return _rankedList(
          context,
          items: stats.topAlbums,
          emptyIcon: Icons.album_outlined,
          emptyTitle: 'No top albums in this period',
          row: (index, item, fraction) {
            final key = _albumKey(item.name, item.artist);
            final art = _albumArt[key];
            final queue = _albumTracks[key] ?? const <Track>[];
            return _RankedRow(
              rank: index + 1,
              title: item.name.isEmpty ? 'Unknown album' : item.name,
              subtitle: item.artist.isEmpty ? 'Unknown artist' : item.artist,
              playCount: item.playCount,
              listenedMs: item.listenedMs,
              fraction: fraction,
              leading: art != null
                  ? TrackArtwork(app: _app, track: art, size: 44)
                  : const _IconTile(Icons.album_outlined),
              onTap: queue.isEmpty
                  ? null
                  : () => runUiAction(
                      context,
                      () => _app.playback.playQueue(queue),
                    ),
            );
          },
        );
      default:
        return _historyList(context, stats.history);
    }
  }

  List<Widget> _rankedList(
    BuildContext context, {
    required List<StatsItem> items,
    required IconData emptyIcon,
    required String emptyTitle,
    required Widget Function(int index, StatsItem item, double fraction) row,
  }) {
    if (items.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: emptyIcon,
            title: emptyTitle,
            message: 'Try a wider range, or press play on something you love.',
          ),
        ),
      ];
    }
    final maxMs = items.fold<int>(
      0,
      (best, item) => math.max(best, item.listenedMs),
    );
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        sliver: SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, index) => row(
            index,
            items[index],
            maxMs == 0 ? 0 : items[index].listenedMs / maxMs,
          ),
        ),
      ),
    ];
  }

  List<Widget> _historyList(BuildContext context, List<HistoryItem> history) {
    if (history.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyState(
            icon: Icons.history_rounded,
            title: 'Nothing played in this period',
            message: 'Try a wider range, or press play on something you love.',
          ),
        ),
      ];
    }
    final rows = <({String? header, HistoryItem entry})>[];
    DateTime? last;
    for (final entry in history) {
      final day = _dayStart(
        DateTime.fromMillisecondsSinceEpoch(entry.startedAt),
      );
      rows.add((header: day == last ? null : _dayLabel(day), entry: entry));
      last = day;
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        sliver: SliverList.builder(
          itemCount: rows.length,
          itemBuilder: (context, index) {
            final row = rows[index];
            final track = _app.trackById(row.entry.trackId);
            final menu = track == null
                ? null
                : TrackMenu(app: _app, track: track);
            final tile = _HistoryTile(
              app: _app,
              entry: row.entry,
              track: track,
              onTap: track == null
                  ? null
                  : () => runUiAction(context, () => _app.play(track)),
              onMenuAt: menu == null
                  ? null
                  : (position) => menu.showAt(context, position),
            );
            if (row.header == null) return tile;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
                  child: Text(
                    row.header!,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                tile,
              ],
            );
          },
        ),
      ),
    ];
  }
}

class _Bucket {
  const _Bucket({required this.ms, required this.label, required this.tooltip});
  final int ms;
  final String label, tooltip;
}

/// Responsive grid of headline metrics: four across on wide layouts, two
/// across on narrow ones.
class _OverviewGrid extends StatelessWidget {
  const _OverviewGrid({required this.cards});
  final List<Widget> cards;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      const spacing = 12.0;
      final columns = constraints.maxWidth >= 760 ? 4 : 2;
      final width = (constraints.maxWidth - spacing * (columns - 1)) / columns;
      return Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [
          for (final card in cards) SizedBox(width: width, child: card),
        ],
      );
    },
  );
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    this.sub,
  });
  final IconData icon;
  final String label, value;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (sub != null) ...[
            const SizedBox(height: 4),
            Text(
              sub!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(24),
    ),
    child: child,
  );
}

/// Bar chart of listening time. Deliberately static: values are readable at a
/// glance and honor reduced-motion settings.
class _ActivityChart extends StatelessWidget {
  const _ActivityChart({
    required this.buckets,
    required this.daily,
    required this.capped,
  });
  final List<_Bucket> buckets;
  final bool daily;

  /// The server returns at most 100 history sessions; long-range charts then
  /// cover only recent activity and say so.
  final bool capped;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final maxMs = buckets.fold<int>(0, (a, b) => math.max(a, b.ms));
    final total = buckets.fold<int>(0, (a, b) => a + b.ms);
    var peak = 0;
    for (var i = 1; i < buckets.length; i++) {
      if (buckets[i].ms > buckets[peak].ms) peak = i;
    }
    final summary = StringBuffer(
      'Listening activity over ${buckets.length} ${daily ? 'days' : 'months'}',
    );
    if (total > 0) {
      summary.write(
        ', ${formatTotalDuration(Duration(milliseconds: total))} in total',
      );
    }
    if (maxMs > 0) summary.write('. Peak: ${buckets[peak].tooltip}');
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Activity', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            daily ? 'Listening time per day' : 'Listening time per month',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          Semantics(
            container: true,
            label: '$summary',
            child: ExcludeSemantics(
              child: SizedBox(
                height: 148,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final slot = constraints.maxWidth / buckets.length;
                    // Keep at most ~8 labels, never packed tighter than
                    // ~28 px; the OverflowBox lets a label extend past its
                    // narrow bar slot instead of clipping.
                    final labelEvery = math.max(
                      1,
                      math.max((buckets.length / 8).ceil(), (28 / slot).ceil()),
                    );
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        for (final (index, bucket) in buckets.indexed)
                          Expanded(
                            child: Tooltip(
                              message: bucket.tooltip,
                              triggerMode: TooltipTriggerMode.tap,
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Container(
                                    height: bucket.ms == 0 || maxMs == 0
                                        ? 3
                                        : 4 + 112 * bucket.ms / maxMs,
                                    margin: EdgeInsets.symmetric(
                                      horizontal: buckets.length > 14 ? 1 : 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: bucket.ms == 0 || maxMs == 0
                                          ? scheme.surfaceContainerHighest
                                          : scheme.primary.withValues(
                                              alpha: bucket.ms == maxMs
                                                  ? .95
                                                  : .55,
                                            ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    height: 14,
                                    child: OverflowBox(
                                      maxWidth: 80,
                                      child: Text(
                                        index % labelEvery == 0
                                            ? bucket.label
                                            : '',
                                        maxLines: 1,
                                        softWrap: false,
                                        textAlign: TextAlign.center,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ),
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
            ),
          ),
          if (capped) ...[
            const SizedBox(height: 12),
            Text(
              'Based on your 100 most recent sessions.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RankedRow extends StatelessWidget {
  const _RankedRow({
    required this.rank,
    required this.title,
    required this.subtitle,
    required this.playCount,
    required this.listenedMs,
    required this.fraction,
    this.leading,
    this.onTap,
    this.onMenuAt,
    this.trailing,
    this.highlighted = false,
  });
  final int rank, playCount, listenedMs;
  final String title, subtitle;

  /// Share of the top entry's listening time, 0–1.
  final double fraction;
  final Widget? leading, trailing;
  final VoidCallback? onTap;
  final ValueChanged<Offset>? onMenuAt;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final top = rank <= 3;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: onMenuAt == null
            ? null
            : (details) => onMenuAt!(details.globalPosition),
        onLongPressStart: onMenuAt == null
            ? null
            : (details) => onMenuAt!(details.globalPosition),
        child: Material(
          color: highlighted
              ? scheme.secondaryContainer.withValues(alpha: .55)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 32,
                    child: Center(
                      child: top
                          ? Container(
                              width: 26,
                              height: 26,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: scheme.primaryContainer,
                                shape: BoxShape.circle,
                              ),
                              child: Text(
                                '$rank',
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: scheme.onPrimaryContainer,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            )
                          : Text(
                              '$rank',
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ?leading,
                  if (leading != null) const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                            color: highlighted ? scheme.primary : null,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Cap the width so a full bar reads as a bar, not a
                        // divider, on wide layouts.
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 320),
                          child: _ProportionBar(fraction: fraction),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _playsLabel(playCount),
                        maxLines: 1,
                        style: theme.textTheme.labelLarge,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        formatTotalDuration(Duration(milliseconds: listenedMs)),
                        maxLines: 1,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.app,
    required this.entry,
    required this.track,
    this.onTap,
    this.onMenuAt,
  });
  final AppController app;
  final HistoryItem entry;
  final Track? track;
  final VoidCallback? onTap;
  final ValueChanged<Offset>? onMenuAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final started = DateTime.fromMillisecondsSinceEpoch(entry.startedAt);
    final time = MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay.fromDateTime(started));
    final listened = formatDuration(Duration(milliseconds: entry.listenedMs));
    final durationMs = track?.durationMs ?? 0;
    final trackDuration = durationMs <= 0
        ? null
        : formatDuration(Duration(milliseconds: durationMs));
    final completion = entry.countedPlay
        ? 'Counted as a play'
        : 'Partial listen, not counted as a play';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapUp: onMenuAt == null
            ? null
            : (details) => onMenuAt!(details.globalPosition),
        onLongPressStart: onMenuAt == null
            ? null
            : (details) => onMenuAt!(details.globalPosition),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 46,
                    child: Text(
                      time,
                      maxLines: 1,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TrackArtwork(app: app, track: track, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.title.isEmpty ? 'Unknown track' : entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          entry.artist.isEmpty
                              ? 'Unknown artist'
                              : entry.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        trackDuration == null
                            ? listened
                            : '$listened of $trackDuration',
                        maxLines: 1,
                        style: theme.textTheme.labelLarge,
                      ),
                      const SizedBox(height: 2),
                      Tooltip(
                        message: completion,
                        excludeFromSemantics: true,
                        child: Icon(
                          entry.countedPlay
                              ? Icons.check_circle_outline_rounded
                              : Icons.timelapse_rounded,
                          size: 16,
                          color: entry.countedPlay
                              ? scheme.primary
                              : scheme.onSurfaceVariant,
                          semanticLabel: completion,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProportionBar extends StatelessWidget {
  const _ProportionBar({required this.fraction});
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '${(fraction * 100).round()}% of the top entry',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(
          height: 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: scheme.surfaceContainerHighest),
              FractionallySizedBox(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: fraction.clamp(0.0, 1.0),
                child: ColoredBox(color: scheme.primary.withValues(alpha: .75)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile(this.icon);
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 20, color: scheme.onSurfaceVariant),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: scheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

String _groupedCount(int value) {
  final digits = '$value';
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return '$buffer';
}

String _playsLabel(int count) =>
    '${_groupedCount(count)} ${count == 1 ? 'play' : 'plays'}';

/// Compact card-scale duration: `<1 min`, `42 min`, `9 hr 30 min`, `27 hr`,
/// `12 d 3 hr`.
String _headlineTime(int ms) {
  final minutes = ms ~/ 60000;
  if (minutes <= 0) return '<1 min';
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  if (hours < 10) {
    final rest = minutes % 60;
    return rest == 0 ? '$hours hr' : '$hours hr $rest min';
  }
  if (hours < 48) return '$hours hr';
  final days = hours ~/ 24;
  final restHours = hours % 24;
  return restHours == 0 ? '$days d' : '$days d $restHours hr';
}
