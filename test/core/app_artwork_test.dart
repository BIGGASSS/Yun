import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/artwork_cache.dart';
import 'package:yun/services/system_media_controls.dart';
import 'package:yun/ui/track_widgets.dart';

import 'fakes.dart';

void main() {
  late Directory root;
  late ApiClient api;
  late AppController app;
  late Track track;
  late List<Track> libraryTracks;
  var artworkRequests = 0;
  final audio = [1, 2, 3, 4];
  final image = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=',
  );
  const account = Account(
    server: 'https://yun.test',
    userId: 'a',
    username: 'a',
  );

  AppController create({
    int artworkCacheMaxBytes = ArtworkCache.defaultMaxBytes,
  }) => AppController(
    api: api,
    storageDirectory: () async => root,
    playbackEngine: FakeEngine(),
    automaticRefresh: false,
    enableSystemControls: false,
    artworkCacheMaxBytes: artworkCacheMaxBytes,
  );

  Future<void> reopenWithBudget(int maxBytes) async {
    await app.shutdown();
    app.dispose();
    app = create(artworkCacheMaxBytes: maxBytes);
    await app.initialize();
    await app.refresh();
  }

  Track sibling(String id, {int revision = 1}) => Track.fromJson({
    ...track.toJson(),
    'id': id,
    'title': id,
    'revision': revision,
  });

  Widget artworkRow(List<Widget> children) => MaterialApp(
    home: Scaffold(body: Row(children: children)),
  );

  Future<void> settleArtwork(
    WidgetTester tester,
    Iterable<Track> tracks, {
    List<Widget>? children,
  }) async {
    // Start widget requests in the real async zone too: joining a file request
    // first started in fake time can otherwise strand its I/O continuation.
    await tester.runAsync(() async {
      if (children == null) {
        await tester.pump();
      } else {
        await tester.pumpWidget(artworkRow(children));
      }
      await Future.wait([for (final value in tracks) app.getArtwork(value)])
          .timeout(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
  }

  Future<int> artworkDiskBytes() async {
    final directory = Directory('${root.path}/artwork');
    if (!await directory.exists()) return 0;
    var bytes = 0;
    await for (final entity in directory.list(recursive: true)) {
      if (entity is File) bytes += await entity.length();
    }
    return bytes;
  }

  void expectFileArtwork(Key key, String path) {
    final finder = find.descendant(
      of: find.byKey(key),
      matching: find.byType(Image),
    );
    expect(finder, findsOneWidget);
    final imageWidget = finder.evaluate().single.widget as Image;
    final provider = (imageWidget.image as ResizeImage).imageProvider;
    expect(provider, isA<FileImage>());
    expect((provider as FileImage).file.path, path);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yun-app-artwork-');
    artworkRequests = 0;
    track = Track(
      id: 't',
      title: 'T',
      sizeBytes: 4,
      sha256: sha256.convert(audio).toString(),
      hasArtwork: true,
      revision: 1,
    );
    libraryTracks = [track];
    api = ApiClient(dio: Dio(), credentials: MemoryCredentials())
      ..session = SessionCredentials(
        account: account,
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
      );
    api.dio.httpClientAdapter = FakeAdapter((options, _) {
      if (options.path.endsWith('/library')) {
        return jsonResponse({
          'cursor': 1,
          'reset': true,
          'tracks': [for (final value in libraryTracks) value.toJson()],
        });
      }
      if (options.path.endsWith('/audio')) {
        return ResponseBody.fromBytes(audio, 200);
      }
      if (options.path.endsWith('/artwork')) {
        if (options.method == 'PUT') {
          return jsonResponse({...track.toJson(), 'revision': 2});
        }
        artworkRequests++;
        return ResponseBody.fromBytes(image, 200);
      }
      if (options.path.endsWith('/auth/logout')) return jsonResponse({});
      throw StateError('Unexpected request ${options.path}');
    });
    app = create();
    await app.initialize();
    await app.refresh();
  });
  tearDown(() async {
    await app.shutdown();
    app.dispose();
    await root.delete(recursive: true);
  });

  Future<void> publishArtwork(NativeSystemMediaControls controls) =>
      controls.update(
        track: track,
        queue: [track],
        index: 0,
        playing: true,
        buffering: false,
        position: Duration.zero,
        shuffle: false,
        repeat: 0,
      );

  test('system media cover loads without a mounted artwork widget', () async {
    final handler = BaseAudioHandler();
    final controls = NativeSystemMediaControls(handler: handler, artwork: app);
    try {
      await publishArtwork(controls);
      final path = await app.getArtwork(track);
      expect(path, isNotNull);
      expect(handler.mediaItem.value!.artUri, Uri.file(path!));
      expect(handler.mediaItem.value!.artHeaders, isNull);
      expect(artworkRequests, 1);
      // Library changes invalidate the cover even while the queue is unchanged.
      libraryTracks = [];
      await app.refresh();
      expect(handler.mediaItem.value!.artUri, isNull);
      expect(artworkRequests, 1);
    } finally {
      await controls.dispose();
    }
  });

  test(
    'system media restores cached artwork offline and clears it on logout',
    () async {
      final path = await app.getArtwork(track);
      expect(path, isNotNull);
      await app.shutdown();
      app.dispose();
      app = create();
      await app.initialize();
      app.isOffline = true;
      api.dio.httpClientAdapter = FakeAdapter((options, _) {
        if (options.path.endsWith('/auth/logout')) return jsonResponse({});
        throw StateError('Offline media must not fetch ${options.path}');
      });
      final handler = BaseAudioHandler();
      final controls = NativeSystemMediaControls(
        handler: handler,
        artwork: app,
      );
      try {
        await publishArtwork(controls);
        await app.getArtwork(track);
        expect(handler.mediaItem.value!.artUri, Uri.file(path!));
        expect(artworkRequests, 1);
        await app.logout();
        expect(handler.mediaItem.value!.artUri, isNull);
        expect(app.mediaArtworkTrack(track), isNull);
      } finally {
        await controls.dispose();
      }
    },
  );

  test(
    'current system cover stays resident until controls release it',
    () async {
      await reopenWithBudget(image.length);
      final other = sibling('other');
      libraryTracks = [track, other];
      await app.refresh();
      final handler = BaseAudioHandler();
      final controls = NativeSystemMediaControls(
        handler: handler,
        artwork: app,
      );
      try {
        await publishArtwork(controls);
        final path = await app.getArtwork(track);
        expect(path, isNotNull);
        expect(await app.getArtwork(other), isNull);
        expect(app.artworkPath(track), path);
        expect(handler.mediaItem.value!.artUri, Uri.file(path!));
        expect(artworkRequests, 1);
        await controls.dispose();
        final release = app.retainArtwork(other);
        try {
          expect(await app.getArtwork(other), isNotNull);
          expect(app.artworkPath(track), isNull);
          expect(artworkRequests, 2);
        } finally {
          release?.call();
        }
      } finally {
        await controls.dispose();
      }
    },
  );

  test(
    'pinning proactively caches art, then restart uses it with no network',
    () async {
      // Audio reconciliation intentionally does not wait for artwork I/O.
      final cached = Completer<void>();
      void artworkChanged() {
        if (app.artworkPath(track) != null && !cached.isCompleted) {
          cached.complete();
        }
      }

      app.artworkChanges.addListener(artworkChanged);
      try {
        await app.pinTrack(track.id);
        await app.retryDownloads();
        await cached.future.timeout(const Duration(seconds: 5));
      } finally {
        app.artworkChanges.removeListener(artworkChanged);
      }
      expect(artworkRequests, 1);
      final path = app.artworkPath(track);
      expect(path, isNotNull);
      expect(await File(path!).readAsBytes(), image);
      expect(app.downloadProgress(track).status, DownloadStatus.downloaded);
      await app.shutdown();
      app.dispose();
      api.dio.httpClientAdapter = FakeAdapter(
        (_, _) => throw StateError('offline'),
      );
      app = create();
      await app.initialize();
      app.isOffline = true;
      expect(await app.getArtwork(app.tracks.single), path);
      expect(app.artworkPath(app.tracks.single), path);
    },
  );

  testWidgets('offline artwork paints a file image and logout removes it', (
    tester,
  ) async {
    await tester.runAsync(() => app.getArtwork(track));
    app.isOffline = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrackArtwork(app: app, track: track),
        ),
      ),
    );
    // Settle the FutureBuilder first: a pending completion would otherwise
    // accidentally repaint after logout even without an account subscription.
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    final imageWidget = tester.widget<Image>(find.byType(Image));
    expect((imageWidget.image as ResizeImage).imageProvider, isA<FileImage>());
    await tester.runAsync(app.logout);
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'tiny artwork budget stabilizes across notifications and duplicate demand',
    (tester) async {
      final budget = image.length + 1;
      libraryTracks = [track, for (var i = 0; i < 3; i++) sibling('other-$i')];
      await tester.runAsync(() => reopenWithBudget(budget));
      final widgets = [
        for (final value in libraryTracks)
          TrackArtwork(app: app, track: value, key: ValueKey(value.id)),
      ];
      await settleArtwork(tester, libraryTracks, children: widgets);
      // Concurrent admissions need not choose a particular winner.
      final residents = libraryTracks.where(
        (value) => app.artworkPath(value) != null,
      );
      expect(residents, hasLength(1));
      final resident = residents.single;
      final residentPath = app.artworkPath(resident)!;
      final denied = libraryTracks.firstWhere(
        (value) => app.artworkPath(value) == null,
      );
      final plateau = artworkRequests;
      expect(plateau, inInclusiveRange(1, libraryTracks.length));
      expect(
        await tester.runAsync(artworkDiskBytes),
        lessThanOrEqualTo(budget),
      );
      expectFileArtwork(ValueKey(resident.id), residentPath);

      // Adding another consumer of a denied revision is not a new demand epoch.
      const duplicateKey = ValueKey('duplicate-denied');
      await settleArtwork(
        tester,
        libraryTracks,
        children: [
          ...widgets,
          TrackArtwork(app: app, track: denied, key: duplicateKey),
        ],
      );
      expect(artworkRequests, plateau);
      for (var round = 0; round < 3; round++) {
        app.artworkChanges.notifyListeners();
        app.clearError();
        await settleArtwork(tester, libraryTracks);
        expect(artworkRequests, plateau);
        for (final state in [
          (busy: true, offline: false),
          (busy: true, offline: true),
          (busy: false, offline: true),
          (busy: false, offline: false),
        ]) {
          app.busy = state.busy;
          app.isOffline = state.offline;
          app.clearError();
          await settleArtwork(tester, libraryTracks);
          expect(artworkRequests, plateau);
          expect(app.artworkPath(resident), residentPath);
          expectFileArtwork(ValueKey(resident.id), residentPath);
          expect(find.byType(Image), findsOneWidget);
          expect(
            find.descendant(
              of: find.byKey(duplicateKey),
              matching: find.byType(Image),
            ),
            findsNothing,
          );
          expect(
            await tester.runAsync(artworkDiskBytes),
            lessThanOrEqualTo(budget),
          );
        }
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'only the first retain after all consumers dispose retries denial',
    (tester) async {
      final denied = sibling('denied');
      libraryTracks = [track, denied];
      final budget = image.length + 1;
      await tester.runAsync(() async {
        await reopenWithBudget(budget);
        await app.getArtwork(track);
      });
      const firstKey = ValueKey('first');
      const secondKey = ValueKey('second');
      const thirdKey = ValueKey('third');
      final residentWidget = TrackArtwork(
        app: app,
        track: track,
        key: const ValueKey('resident'),
      );
      final first = TrackArtwork(app: app, track: denied, key: firstKey);
      final second = TrackArtwork(app: app, track: denied, key: secondKey);
      final third = TrackArtwork(app: app, track: denied, key: thirdKey);
      await settleArtwork(
        tester,
        libraryTracks,
        children: [residentWidget, first],
      );
      expect(app.artworkPath(denied), isNull);
      final plateau = artworkRequests;
      expect(plateau, 2); // One resident, one capacity rejection.
      await settleArtwork(
        tester,
        libraryTracks,
        children: [residentWidget, first, second],
      );
      expect(artworkRequests, plateau);

      // Free capacity and dispose one duplicate, but keep continuous demand.
      await settleArtwork(tester, [denied], children: [second]);
      await settleArtwork(tester, [denied], children: [second, third]);
      expect(artworkRequests, plateau);
      expect(find.byType(Image), findsNothing);
      await settleArtwork(tester, [denied], children: [third]);
      expect(artworkRequests, plateau);

      // Release itself, ordinary reads, and app notifications cannot refill.
      await tester.pumpWidget(const SizedBox());
      app.clearError();
      app.artworkChanges.notifyListeners();
      expect(await tester.runAsync(() => app.getArtwork(denied)), isNull);
      expect(artworkRequests, plateau);
      // Audio pinning really invokes background artwork prefetch, but without
      // new foreground demand it must still respect the admission denial.
      await tester.runAsync(() async {
        await app.pinTrack(denied.id);
        await app.retryDownloads();
        expect(await app.getArtwork(denied), isNull);
      });
      expect(app.downloadProgress(denied).status, DownloadStatus.downloaded);
      expect(artworkRequests, plateau);
      await settleArtwork(tester, [denied], children: [first]);
      final path = app.artworkPath(denied);
      expect(path, isNotNull);
      expect(artworkRequests, plateau + 1);
      expect(app.artworkPath(track), isNull);
      expectFileArtwork(firstKey, path!);
      expect(
        await tester.runAsync(artworkDiskBytes),
        lessThanOrEqualTo(budget),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('explicit retry recovers a denied widget without remounting', (
    tester,
  ) async {
    final denied = sibling('denied');
    libraryTracks = [track, denied];
    final budget = image.length + 1;
    await tester.runAsync(() async {
      await reopenWithBudget(budget);
      await app.getArtwork(track);
    });
    const deniedKey = ValueKey('denied');
    final deniedWidget = TrackArtwork(app: app, track: denied, key: deniedKey);
    await settleArtwork(
      tester,
      libraryTracks,
      children: [
        TrackArtwork(app: app, track: track, key: const ValueKey('resident')),
        deniedWidget,
      ],
    );
    final mountedState = tester.state(find.byKey(deniedKey));
    final plateau = artworkRequests;
    expect(app.artworkPath(denied), isNull);
    await settleArtwork(tester, [denied], children: [deniedWidget]);
    // These request-key changes must not accidentally create a fresh lease,
    // even now that the former resident is no longer protected.
    for (final offline in [true, false]) {
      app.isOffline = offline;
      app.busy = offline;
      app.clearError();
      app.artworkChanges.notifyListeners();
      await settleArtwork(tester, [denied]);
      expect(artworkRequests, plateau);
      expect(find.byType(Image), findsNothing);
    }
    final path = await tester.runAsync(() => app.retryArtwork(denied));
    expect(path, isNotNull);
    await tester.pumpAndSettle();
    expect(tester.state(find.byKey(deniedKey)), same(mountedState));
    expectFileArtwork(deniedKey, path!);
    expect(artworkRequests, plateau + 1);
    expect(app.artworkPath(track), isNull);
    await settleArtwork(tester, libraryTracks);
    expect(artworkRequests, plateau + 1);
    expect(await tester.runAsync(artworkDiskBytes), lessThanOrEqualTo(budget));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('oversize denial survives widget disposal until explicit retry', (
    tester,
  ) async {
    final budget = image.length + 1;
    await tester.runAsync(() => reopenWithBudget(budget));
    var responseBytes = [...image, 0, 0];
    api.dio.httpClientAdapter = FakeAdapter((options, _) {
      expect(options.path, endsWith('/artwork'));
      artworkRequests++;
      return ResponseBody.fromBytes(
        responseBytes,
        200,
        headers: {
          Headers.contentLengthHeader: ['${responseBytes.length}'],
        },
      );
    });
    const artworkKey = ValueKey('oversize');
    final widget = TrackArtwork(app: app, track: track, key: artworkKey);
    await settleArtwork(tester, [track], children: [widget]);
    expect(artworkRequests, 1);
    expect(app.artworkPath(track), isNull);
    expect(await tester.runAsync(artworkDiskBytes), 0);
    responseBytes = image;
    for (var epoch = 0; epoch < 3; epoch++) {
      await tester.pumpWidget(const SizedBox());
      await settleArtwork(tester, [track], children: [widget]);
      app.clearError();
      app.artworkChanges.notifyListeners();
      await settleArtwork(tester, [track]);
      expect(artworkRequests, 1);
      expect(find.byType(Image), findsNothing);
      expect(await tester.runAsync(artworkDiskBytes), 0);
    }
    final path = await tester.runAsync(() => app.retryArtwork(track));
    expect(path, isNotNull);
    await tester.pumpAndSettle();
    expectFileArtwork(artworkKey, path!);
    expect(artworkRequests, 2);
    expect(await tester.runAsync(artworkDiskBytes), lessThanOrEqualTo(budget));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('changing track identity in place releases resident demand', (
    tester,
  ) async {
    final other = sibling('other');
    libraryTracks = [track, other];
    final budget = image.length + 1;
    await tester.runAsync(() => reopenWithBudget(budget));
    const slotKey = ValueKey('slot');
    await settleArtwork(
      tester,
      [track],
      children: [TrackArtwork(app: app, track: track, key: slotKey)],
    );
    final mountedState = tester.state(find.byKey(slotKey));
    final firstPath = app.artworkPath(track);
    expect(firstPath, isNotNull);
    final plateau = artworkRequests;
    await settleArtwork(
      tester,
      [other],
      children: [TrackArtwork(app: app, track: other, key: slotKey)],
    );
    final otherPath = app.artworkPath(other);
    expect(otherPath, isNotNull);
    expect(tester.state(find.byKey(slotKey)), same(mountedState));
    expectFileArtwork(slotKey, otherPath!);
    expect(app.artworkPath(track), isNull);
    expect(artworkRequests, plateau + 1);
    // Eviction notifications/ordinary reads do not reacquire the old identity.
    app.artworkChanges.notifyListeners();
    app.clearError();
    await settleArtwork(tester, libraryTracks);
    expect(artworkRequests, plateau + 1);
    await settleArtwork(
      tester,
      [track],
      children: [TrackArtwork(app: app, track: track, key: slotKey)],
    );
    expectFileArtwork(slotKey, firstPath!);
    expect(app.artworkPath(other), isNull);
    expect(artworkRequests, plateau + 2);
    expect(await tester.runAsync(artworkDiskBytes), lessThanOrEqualTo(budget));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a revised track acquires fresh demand in the same widget state',
    (tester) async {
      final denied = sibling('denied');
      libraryTracks = [track, denied];
      final budget = image.length + 1;
      await tester.runAsync(() async {
        await reopenWithBudget(budget);
        await app.getArtwork(track);
      });
      const slotKey = ValueKey('slot');
      await settleArtwork(
        tester,
        libraryTracks,
        children: [
          TrackArtwork(app: app, track: track, key: const ValueKey('resident')),
          TrackArtwork(app: app, track: denied, key: slotKey),
        ],
      );
      final mountedState = tester.state(find.byKey(slotKey));
      final plateau = artworkRequests;
      expect(app.artworkPath(denied), isNull);
      final revised = sibling(denied.id, revision: 2);
      libraryTracks = [track, revised];
      await tester.runAsync(app.refresh);
      await settleArtwork(
        tester,
        [revised],
        children: [TrackArtwork(app: app, track: revised, key: slotKey)],
      );
      final path = app.artworkPath(revised);
      expect(path, isNotNull);
      expect(tester.state(find.byKey(slotKey)), same(mountedState));
      expectFileArtwork(slotKey, path!);
      expect(app.artworkPath(denied), isNull);
      expect(await tester.runAsync(() => app.getArtwork(denied)), isNull);
      expect(artworkRequests, plateau + 1);
      // Fresh revision demand protects the rendered image from deliberate retry
      // of the now-idle old resident as well.
      expect(await tester.runAsync(() => app.retryArtwork(track)), isNull);
      expect(app.artworkPath(revised), path);
      expectFileArtwork(slotKey, path);
      expect(artworkRequests, lessThanOrEqualTo(plateau + 2));
      final revisedPlateau = artworkRequests;
      app.clearError();
      app.artworkChanges.notifyListeners();
      await settleArtwork(tester, libraryTracks);
      expect(artworkRequests, revisedPlateau);
      expect(
        await tester.runAsync(artworkDiskBytes),
        lessThanOrEqualTo(budget),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'manual replacement caches new revision immediately, logout locks both',
    () async {
      final old = await app.getArtwork(track);
      final updated = await app.setArtwork(track, Uint8List.fromList(image));
      expect(updated.revision, 2);
      expect(app.artworkPath(track), isNull);
      app.isOffline = true;
      final fresh = await app.getArtwork(updated);
      expect(fresh, isNotNull);
      expect(fresh, isNot(old));
      expect(await File(fresh!).readAsBytes(), image);
      expect(artworkRequests, 1); // replacement uses PUT bytes, not another GET
      final closing = app.logout();
      expect(app.artworkPath(updated), isNull);
      expect(await app.getArtwork(updated), isNull);
      await closing;
      expect(app.artworkPath(updated), isNull);
    },
  );
}
