import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/core/app_controller.dart';
import 'package:yun/services/api_client.dart';

import 'fakes.dart';

void main() {
  test('mutation endpoints treat remote IDs as one path segment', () async {
    final root = await Directory.systemTemp.createTemp('yun-endpoint-test-');
    final credentials = MemoryCredentials();
    await credentials.write(
      ApiClient.sessionKey,
      jsonEncode(
        SessionCredentials(
          account: const Account(
            server: 'https://yun.test',
            userId: 'user',
            username: 'user',
          ),
          accessToken: 'access',
          refreshToken: 'refresh',
          expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
        ).toJson(),
      ),
    );
    final requests = <RequestOptions>[];
    final app = AppController(
      api: ApiClient(
        dio: Dio()
          ..httpClientAdapter = FakeAdapter((options, _) {
            requests.add(options);
            // Fail before cache/reconciliation work: only routing is under test.
            return jsonResponse({'error': 'denied'}, status: 403);
          }),
        credentials: credentials,
      ),
      storageDirectory: () async => root,
      playbackEngine: FakeEngine(),
      enableSystemControls: false,
      automaticRefresh: false,
    );
    try {
      await app.initialize();
      const id = 'folder/../other?revision=0#fragment';
      const track = Track(id: id, title: 'Track');
      const playlist = Playlist(id: id, name: 'Playlist');
      for (final action in <Future<void> Function()>[
        () async {
          await app.updateTrack(track, {'title': 'New'});
        },
        () => app.deleteTrack(id),
        () async {
          await app.setArtwork(track, Uint8List.fromList([1]));
        },
        () async {
          await app.savePlaylist(playlist);
        },
        () => app.deletePlaylist(playlist),
      ]) {
        await expectLater(action(), throwsA(isA<DioException>()));
      }
      for (final invalid in ['', '.', '..']) {
        await expectLater(app.deleteTrack(invalid), throwsArgumentError);
        await expectLater(app.audioUrl(invalid), throwsArgumentError);
      }
      expect(requests, hasLength(5));
      for (var i = 0; i < requests.length; i++) {
        final uri = requests[i].uri;
        expect(uri.pathSegments, [
          'api',
          'v1',
          i < 3 ? 'tracks' : 'playlists',
          id,
          if (i == 2) 'artwork',
        ]);
        expect(uri.fragment, isEmpty);
        expect(uri.queryParameters, i == 4 ? {'revision': '0'} : isEmpty);
      }
    } finally {
      await app.shutdown();
      app.dispose();
      await root.delete(recursive: true);
    }
  });
}
