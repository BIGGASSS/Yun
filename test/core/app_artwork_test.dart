import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/ui/track_widgets.dart';

import 'fakes.dart';

void main() {
  late Directory root;
  late ApiClient api;
  late AppController app;
  late Track track;
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

  AppController create() => AppController(
    api: api,
    storageDirectory: () async => root,
    playbackEngine: FakeEngine(),
    automaticRefresh: false,
    enableSystemControls: false,
  );

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
          'tracks': [track.toJson()],
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
