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
