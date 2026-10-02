import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/system_media_controls.dart';

class _Artwork extends ChangeNotifier implements SystemMediaArtwork {
  final tracks = <String, Track>{};
  final paths = <(String, int), String>{};
  final requests = <(String, int)>[];
  final retained = <(String, int), int>{};
  Future<String?> Function(Track)? load;
  bool available = true;
  bool get listening => hasListeners;

  @override
  Listenable get mediaArtworkChanges => this;
  @override
  Track? mediaArtworkTrack(Track track) => available ? tracks[track.id] : null;
  @override
  String? artworkPath(Track track) =>
      available && track.hasArtwork ? paths[(track.id, track.revision)] : null;
  @override
  Future<String?> getArtwork(Track track) {
    requests.add((track.id, track.revision));
    return load?.call(track) ?? Future.value(artworkPath(track));
  }

  @override
  VoidCallback retainArtwork(Track track) {
    final key = (track.id, track.revision);
    retained.update(key, (count) => count + 1, ifAbsent: () => 1);
    return () {
      if (retained[key] == 1) {
        retained.remove(key);
      } else {
        retained[key] = retained[key]! - 1;
      }
    };
  }
}

Future<void> _update(
  NativeSystemMediaControls controls,
  List<Track> queue, {
  int position = 0,
  bool playing = true,
  bool waiting = false,
}) => controls.update(
  track: queue.firstOrNull,
  queue: queue,
  index: queue.isEmpty ? -1 : 0,
  playing: playing && queue.isNotEmpty,
  buffering: false,
  waitingForAudio: waiting,
  position: Duration(milliseconds: position),
  shuffle: false,
  repeat: 0,
);

void main() {
  const a = Track(id: 'a', title: 'A', hasArtwork: true, revision: 1);
  const b = Track(id: 'b', title: 'B', hasArtwork: true, revision: 1);
  late _Artwork artwork;
  late BaseAudioHandler handler;
  late NativeSystemMediaControls controls;

  setUp(() {
    artwork = _Artwork()..tracks.addAll({'a': a, 'b': b});
    handler = BaseAudioHandler();
    controls = NativeSystemMediaControls(handler: handler, artwork: artwork);
  });
  tearDown(() async {
    await controls.dispose();
    expect(artwork.retained, isEmpty);
    expect(artwork.listening, isFalse);
    artwork.dispose();
  });

  test(
    'cached cover is a local URI and survives pause and audio waiting',
    () async {
      const path = '/private/album cover #1.png';
      artwork.paths[('a', 1)] = path;
      await _update(controls, const [a, b]);
      expect(handler.mediaItem.value!.artUri, Uri.file(path));
      expect(handler.mediaItem.value!.artUri!.toFilePath(), path);
      expect(handler.mediaItem.value!.artHeaders, isNull);
      expect(artwork.requests, [('a', 1)]);
      expect(artwork.retained, {('a', 1): 1});
      final item = handler.mediaItem.value;
      final queue = handler.queue.value;
      await _update(controls, const [a, b], playing: false, position: 123);
      expect(identical(handler.mediaItem.value, item), isTrue);
      expect(identical(handler.queue.value, queue), isTrue);
      expect(handler.playbackState.value.controls, contains(MediaControl.play));
      await _update(controls, const [a, b], playing: false, waiting: true);
      expect(identical(handler.mediaItem.value, item), isTrue);
      expect(
        handler.playbackState.value.controls,
        contains(MediaControl.pause),
      );
      expect(artwork.retained, {('a', 1): 1});
      await _update(controls, const []);
      expect(handler.mediaItem.value, isNull);
      expect(artwork.retained, isEmpty);
    },
  );

  test(
    'slow cover does not block transport and ticks do not refetch',
    () async {
      final gate = Completer<String?>();
      artwork.load = (_) => gate.future;
      await _update(controls, const [a]).timeout(const Duration(seconds: 1));
      expect(handler.mediaItem.value!.artUri, isNull);
      expect(handler.playbackState.value.playing, isTrue);
      for (var i = 0; i < 30; i++) {
        await _update(controls, const [a], position: i * 100);
        artwork.notifyListeners();
      }
      final state = handler.playbackState.value;
      artwork.paths[('a', 1)] = '/private/a.png';
      gate.complete('/private/a.png');
      await Future<void>.delayed(Duration.zero);
      expect(handler.mediaItem.value!.artUri, Uri.file('/private/a.png'));
      expect(identical(handler.playbackState.value, state), isTrue);
      expect(artwork.requests, [('a', 1)]);
    },
  );

  test('failed or missing covers keep controls available without retry loops', () async {
    artwork.load = (_) async => throw StateError('cover unavailable');
    final statuses = <SystemMediaControlsStatus>[];
    final subscription = controls.statusChanges.listen(statuses.add);
    await _update(controls, const [a]);
    await Future<void>.delayed(Duration.zero);
    expect(handler.mediaItem.value!.artUri, isNull);
    expect(statuses.last.available, isTrue);
    for (var i = 0; i < 10; i++) {
      artwork.notifyListeners();
      await _update(controls, const [a], position: i);
    }
    expect(artwork.requests, [('a', 1)]);
    // Another cache consumer can fill the cover without starting another load.
    artwork.paths[('a', 1)] = '/private/a.png';
    artwork.notifyListeners();
    expect(handler.mediaItem.value!.artUri, Uri.file('/private/a.png'));
    const noArt = Track(id: 'c', title: 'C');
    artwork.tracks['c'] = noArt;
    await _update(controls, const [noArt]);
    expect(handler.mediaItem.value!.artUri, isNull);
    expect(artwork.requests, [('a', 1)]);
    await subscription.cancel();
  });

  test('late results cannot replace a new track or a revised cover', () async {
    final old = Completer<String?>();
    final revised = Completer<String?>();
    artwork.load = (track) => track.id == 'a'
        ? (track.revision == 1 ? old.future : revised.future)
        : Future.value(artwork.artworkPath(track));
    await _update(controls, const [a]);
    artwork.paths[('b', 1)] = '/private/b.png';
    await _update(controls, const [b]);
    expect(artwork.retained, {('b', 1): 1});
    artwork.paths[('a', 1)] = '/private/old-a.png';
    old.complete('/private/old-a.png');
    await Future<void>.delayed(Duration.zero);
    expect(handler.mediaItem.value!.id, 'b');
    expect(handler.mediaItem.value!.artUri, Uri.file('/private/b.png'));
    await _update(controls, const [a]);
    expect(handler.mediaItem.value!.artUri, Uri.file('/private/old-a.png'));
    // The library revision can change while the playback queue keeps its track.
    artwork.tracks['a'] = Track.fromJson({...a.toJson(), 'revision': 2});
    artwork.notifyListeners();
    expect(handler.mediaItem.value!.artUri, isNull);
    expect(artwork.retained, {('a', 2): 1});
    await _update(controls, const [a], position: 456);
    expect(handler.mediaItem.value!.artUri, isNull);
    artwork.paths[('a', 2)] = '/private/new-a.png';
    revised.complete('/private/new-a.png');
    await Future<void>.delayed(Duration.zero);
    expect(handler.mediaItem.value!.artUri, Uri.file('/private/new-a.png'));
    artwork.tracks.remove('a');
    artwork.notifyListeners();
    expect(handler.mediaItem.value!.artUri, isNull);
    expect(artwork.retained, isEmpty);
  });

  test(
    'logout invalidates pending artwork even with the same track ID',
    () async {
      final gate = Completer<String?>();
      artwork.load = (_) => gate.future;
      await _update(controls, const [a]);
      artwork.available = false;
      artwork.notifyListeners();
      expect(artwork.retained, isEmpty);
      artwork.paths[('a', 1)] = '/private/old-account.png';
      gate.complete('/private/old-account.png');
      await Future<void>.delayed(Duration.zero);
      expect(handler.mediaItem.value!.artUri, isNull);
      artwork.paths[('a', 1)] = '/private/new-account.png';
      artwork.available = true;
      artwork.notifyListeners();
      expect(
        handler.mediaItem.value!.artUri,
        Uri.file('/private/new-account.png'),
      );
      expect(artwork.requests, [('a', 1), ('a', 1)]);
    },
  );

  test('late revision and disposed requests cannot restore artwork', () async {
    final old = Completer<String?>();
    final revised = Completer<String?>();
    artwork.load = (track) => track.revision == 1 ? old.future : revised.future;
    await _update(controls, const [a]);
    artwork.tracks['a'] = Track.fromJson({...a.toJson(), 'revision': 2});
    artwork.notifyListeners();
    artwork.paths[('a', 1)] = '/private/old-a.png';
    old.complete('/private/old-a.png');
    await Future<void>.delayed(Duration.zero);
    expect(handler.mediaItem.value!.artUri, isNull);
    expect(artwork.retained, {('a', 2): 1});
    await controls.dispose();
    artwork.paths[('a', 2)] = '/private/new-a.png';
    revised.complete('/private/new-a.png');
    await Future<void>.delayed(Duration.zero);
    artwork.notifyListeners();
    expect(handler.mediaItem.value, isNull);
    expect(artwork.retained, isEmpty);
  });

  test(
    'retired handler owner cannot overwrite its successor with a late cover',
    () async {
      final gate = Completer<String?>();
      artwork.load = (_) => gate.future;
      await _update(controls, const [a]);
      final successor = NativeSystemMediaControls(handler: handler);
      await _update(successor, const [b]);
      artwork.paths[('a', 1)] = '/private/a.png';
      gate.complete('/private/a.png');
      await Future<void>.delayed(Duration.zero);
      artwork.notifyListeners();
      expect(handler.mediaItem.value!.id, 'b');
      expect(handler.mediaItem.value!.artUri, isNull);
      await controls.dispose();
      expect(handler.mediaItem.value!.id, 'b');
      await successor.dispose();
      expect(handler.mediaItem.value, isNull);
    },
  );
}
