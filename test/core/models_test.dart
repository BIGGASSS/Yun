import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';

void main() {
  test(
    'track/disc metadata preserve null, absent, and numbered JSON values',
    () {
      for (final numbers in [
        <String, dynamic>{},
        {'track_number': null, 'disc_number': null},
        {'track_number': 1, 'disc_number': 1000000},
      ]) {
        final track = Track.fromJson({
          'id': 'track',
          'title': 'Song',
          ...numbers,
        });
        final roundTrip = Track.fromJson(
          jsonDecode(jsonEncode(track.toJson())) as Map<String, dynamic>,
        );
        expect(roundTrip.trackNumber, numbers['track_number']);
        expect(roundTrip.discNumber, numbers['disc_number']);
        expect(roundTrip.durationMs, 0);
        expect(roundTrip.sizeBytes, 0);
      }
      const track = Track(id: 'untagged', title: 'No tags');
      expect(track.trackNumber, isNull);
      expect(track.discNumber, isNull);
    },
  );

  test('bitrate JSON preserves absent, null, and known values', () {
    for (final fields in [
      <String, dynamic>{},
      {'bitrate_kbps': null},
      {'bitrate_kbps': 128},
      {'bitrate_kbps': 320},
    ]) {
      final track = Track.fromJson({'id': 'track', 'title': 'Song', ...fields});
      expect(track.bitrateKbps, fields['bitrate_kbps']);
      expect(track.toJson()['bitrate_kbps'], fields['bitrate_kbps']);
      final roundTrip = Track.fromJson(
        jsonDecode(jsonEncode(track.toJson())) as Map<String, dynamic>,
      );
      expect(roundTrip.bitrateKbps, track.bitrateKbps);
    }
    expect(const Track(id: 'legacy', title: 'Legacy').bitrateKbps, isNull);
  });

  test('legacy bitrate converts bytes/milliseconds to rounded kbps', () {
    for (final (size, duration, expected) in [
      (12000000, 300000, 320),
      (4800000, 300000, 128),
      (80037, 2000, 320),
      (80125, 2000, 321),
      (1, 16, 1),
    ]) {
      final track = Track(
        id: 'legacy',
        title: 'Legacy',
        sizeBytes: size,
        durationMs: duration,
      );
      expect(track.bitrateKbps, isNull);
      expect(track.estimatedBitrateKbps, expected, reason: '$size / $duration');
    }
  });

  test(
    'legacy bitrate is unknown for missing or nonpositive inputs/results',
    () {
      for (final fields in [
        <String, dynamic>{},
        {'size_bytes': 40000},
        {'duration_ms': 1000},
        {'size_bytes': null, 'duration_ms': null},
        {'size_bytes': 0, 'duration_ms': 1000},
        {'size_bytes': -1, 'duration_ms': 1000},
        {'size_bytes': 40000, 'duration_ms': 0},
        {'size_bytes': 40000, 'duration_ms': -1},
        {'size_bytes': 1, 'duration_ms': 1000},
      ]) {
        final track = Track.fromJson({'id': 'legacy', ...fields});
        expect(track.estimatedBitrateKbps, isNull, reason: '$fields');
      }
    },
  );

  test('upload ID clearing is explicit and survives durable serialization', () {
    const job = UploadJob(
      id: 'job',
      localPath: '/music/file.wav',
      filename: 'file.wav',
      sizeBytes: 123,
      offset: 42,
      remoteId: 'expired',
      modifiedAtMs: 1234,
    );
    expect(job.copyWith(status: 'queued').remoteId, 'expired');
    final reset = UploadJob.fromJson(
      job.copyWith(clearRemoteId: true, offset: 0).toJson(),
    );
    expect(reset.remoteId, isNull);
    expect(reset.offset, 0);
    expect(reset.localPath, job.localPath);
    expect(reset.sizeBytes, job.sizeBytes);
    expect(reset.modifiedAtMs, job.modifiedAtMs);
  });
}
