// Regression coverage against the actual Rust server; never mocked HTTP.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/cache_database.dart';
import 'package:yun/services/transfer_service.dart';

import '../core/fakes.dart';
import 'real_server.dart';

void main() {
  final server = RealServer();
  group(
    'contract regressions',
    () {
      setUpAll(
        () => server.start(['metadata', 'receipt', 'expired-upload', 'logout']),
      );
      tearDownAll(server.close);

      Future<
        (ApiClient, CacheDatabase, TransferService, Directory, List<Object>)
      >
      transfers(String user) async {
        final api = await server.login(user, const Uuid().v4());
        final root = await Directory.systemTemp.createTemp('yun-contract-');
        final db = CacheDatabase.memory();
        final errors = <Object>[];
        final service = TransferService(
          api: api,
          database: db,
          directory: root,
          onChanged: () {},
          onTrack: (t) => db.put('track', t.id, t.toJson()),
          onError: errors.add,
        );
        addTearDown(() async {
          await service.close();
          await db.close();
          api.dio.close(force: true);
          await root.delete(recursive: true);
        });
        return (api, db, service, root, errors);
      }

      test(
        'nullable track numbers survive model/cache/edit and can be cleared',
        () async {
          final api = await server.login('metadata', const Uuid().v4());
          addTearDown(() => api.dio.close(force: true));
          final (_, uploaded) = await uploadWav(api);
          final db = CacheDatabase.memory();
          addTearDown(db.close);
          await db.put('track', uploaded.id, uploaded.toJson());
          final track = Track.fromJson((await db.get('track', uploaded.id))!);
          expect(track.trackNumber, isNull);
          expect(track.discNumber, isNull);
          var result = await api.json(
            '/tracks/${track.id}',
            method: 'PATCH',
            data: {
              'revision': track.revision,
              'title': 'Only title was edited',
              'track_number': track.toJson()['track_number'],
              'disc_number': track.toJson()['disc_number'],
            },
          );
          expect(result['title'], 'Only title was edited');
          expect(result['track_number'], isNull);
          expect(result['disc_number'], isNull);
          result = await api.json(
            '/tracks/${track.id}',
            method: 'PATCH',
            data: {
              'revision': result['revision'],
              'track_number': 1,
              'disc_number': 1000000,
            },
          );
          final numbered = Track.fromJson(result);
          expect(numbered.toJson()['track_number'], 1);
          expect(numbered.toJson()['disc_number'], 1000000);
          result = await api.json(
            '/tracks/${track.id}',
            method: 'PATCH',
            data: {
              'revision': numbered.revision,
              'track_number': null,
              'disc_number': null,
            },
          );
          expect(result['track_number'], isNull);
          expect(result['disc_number'], isNull);
        },
      );

      for (final sourceState in ['missing', 'changed']) {
        for (final completed in [true, false]) {
          test(
            'full remote upload recovers with $sourceState source, receipt=$completed',
            () async {
              final (api, db, service, root, errors) = await transfers(
                'receipt',
              );
              final bytes = testWav();
              final remote = await api.json(
                '/uploads',
                method: 'POST',
                data: {'filename': 'fixture.wav', 'size_bytes': bytes.length},
              );
              final remoteId = remote['id'] as String;
              await api.request(
                '/uploads/$remoteId',
                method: 'PATCH',
                data: bytes,
                headers: {
                  'Content-Type': 'application/octet-stream',
                  'Upload-Offset': '0',
                },
              );
              String? completedId;
              if (completed) {
                completedId =
                    (await api.json(
                          '/uploads/$remoteId/complete',
                          method: 'POST',
                        ))['id']
                        as String;
              }
              final source = File('${root.path}/source.wav');
              if (sourceState == 'changed') {
                await source.writeAsBytes([1, 2, 3]);
              }
              final job = UploadJob(
                id: const Uuid().v4(),
                localPath: source.path,
                filename: 'fixture.wav',
                sizeBytes: bytes.length,
                // The final chunk ACK may have been lost as well as completion ACK.
                offset: 0,
                remoteId: remoteId,
                status: 'completing',
                modifiedAtMs: 1,
              );
              await db.put('upload', job.id, job.toJson());
              await service.runUploads();
              expect(errors, isEmpty);
              final saved = (await db.get('upload', job.id))!;
              expect(saved['status'], 'done');
              expect(saved['offset'], bytes.length);
              expect(saved['remote_id'], remoteId);
              final tracks = await db.list('track');
              expect(tracks, hasLength(1));
              final receipt = await api.json(
                '/uploads/$remoteId/complete',
                method: 'POST',
              );
              expect(tracks.single['id'], receipt['id']);
              if (completed) expect(receipt['id'], completedId);
            },
          );
        }
      }

      for (final receiptExpired in [false, true]) {
        test(
          'expired reservation is recreated at zero, prior receipt=$receiptExpired',
          () async {
            final (api, db, service, root, errors) = await transfers(
              'expired-upload',
            );
            final bytes = testWav();
            final source = await File('${root.path}/fixture.wav')
                .writeAsBytes(bytes);
            final remote = await api.json(
              '/uploads',
              method: 'POST',
              data: {'filename': 'fixture.wav', 'size_bytes': bytes.length},
            );
            final oldId = remote['id'] as String;
            await api.request(
              '/uploads/$oldId',
              method: 'PATCH',
              data: receiptExpired ? bytes : bytes.sublist(0, 117),
              headers: {
                'Content-Type': 'application/octet-stream',
                'Upload-Offset': '0',
              },
            );
            String? oldTrack;
            if (receiptExpired) {
              oldTrack =
                  (await api.json(
                        '/uploads/$oldId/complete',
                        method: 'POST',
                      ))['id']
                      as String;
            }
            final job = UploadJob(
              id: const Uuid().v4(),
              localPath: source.path,
              filename: 'fixture.wav',
              sizeBytes: bytes.length,
              offset: receiptExpired ? bytes.length : 117,
              remoteId: oldId,
              modifiedAtMs:
                  (await source.stat()).modified.millisecondsSinceEpoch,
            );
            await db.put('upload', job.id, job.toJson());
            // Same externally observable state as reservation/receipt GC after 24h.
            await api.request('/uploads/$oldId', method: 'DELETE');
            final patches = <int>[];
            api.dio.interceptors.add(
              InterceptorsWrapper(
                onRequest: (request, handler) {
                  if (request.method == 'PATCH') {
                    patches.add(request.headers['Upload-Offset'] as int);
                  }
                  handler.next(request);
                },
              ),
            );
            await service.runUploads();
            expect(errors, isEmpty);
            final saved = (await db.get('upload', job.id))!;
            expect(saved['status'], 'done');
            expect(saved['remote_id'], isNot(oldId));
            expect(saved['offset'], bytes.length);
            expect(patches, [0]);
            final tracks = await db.list('track');
            expect(tracks, hasLength(1));
            if (receiptExpired) expect(tracks.single['id'], oldTrack);
            // A completed job is not reuploaded on subsequent runs/retries.
            await service.runUploads();
            expect(patches, [0]);
          },
        );
      }

      for (final expired in [false, true]) {
        for (final sourceState in ['missing', 'size', 'mtime']) {
          test(
            'incomplete upload rejects $sourceState source, reservation expired=$expired',
            () async {
              final (api, db, service, root, errors) = await transfers(
                'expired-upload',
              );
              final bytes = testWav();
              final source = File('${root.path}/source.wav');
              if (sourceState != 'missing') {
                await source.writeAsBytes(sourceState == 'size' ? [1] : bytes);
              }
              final remote = await api.json(
                '/uploads',
                method: 'POST',
                data: {'filename': 'fixture.wav', 'size_bytes': bytes.length},
              );
              final oldId = remote['id'] as String;
              final job = UploadJob(
                id: const Uuid().v4(),
                localPath: source.path,
                filename: 'fixture.wav',
                sizeBytes: bytes.length,
                // Never trust a locally complete offset over remote status.
                offset: bytes.length,
                remoteId: oldId,
                modifiedAtMs: 1,
              );
              await db.put('upload', job.id, job.toJson());
              if (expired) {
                await api.request('/uploads/$oldId', method: 'DELETE');
              }
              final methods = <String>[];
              api.dio.interceptors.add(
                InterceptorsWrapper(
                  onRequest: (request, handler) {
                    methods.add(request.method);
                    handler.next(request);
                  },
                ),
              );
              await service.runUploads();
              final saved = (await db.get('upload', job.id))!;
              expect(saved['status'], 'failed');
              expect(saved['offset'], 0);
              expect(saved['remote_id'], expired ? isNull : oldId);
              expect(errors, hasLength(1));
              expect(
                errors.single.toString(),
                contains('source is missing or has changed'),
              );
              expect(methods, ['GET']);
              expect(await db.list('track'), isEmpty);
            },
          );
        }
      }

      for (final locallyExpired in [false, true]) {
        test(
          'online logout revokes rotated refresh token, local expiry=$locallyExpired',
          () async {
            final store = MemoryCredentials();
            final api = await server.login(
              'logout',
              const Uuid().v4(),
              credentials: store,
            );
            addTearDown(() => api.dio.close(force: true));
            final old = api.session!;
            await server.expireAccessToken(old.accessToken);
            if (locallyExpired) {
              api.session = SessionCredentials(
                account: old.account,
                accessToken: old.accessToken,
                refreshToken: old.refreshToken,
                expiresAt: 0,
              );
            }
            String? rotatedRefresh;
            String? persistedBeforeRotation;
            var revocations = 0;
            // No tokens, headers, or bodies: expose swallowed logout failures
            // without leaking credentials into CI logs.
            final requests = <String>[];
            api.dio.interceptors.add(
              InterceptorsWrapper(
                onRequest: (request, handler) {
                  requests.add('send ${Uri.parse(request.path).path}');
                  handler.next(request);
                },
                onError: (error, handler) {
                  requests.add(
                    '${Uri.parse(error.requestOptions.path).path}: '
                    '${error.type.name}, status=${error.response?.statusCode}, '
                    'cause=${error.error.runtimeType}',
                  );
                  handler.next(error);
                },
                onResponse: (response, handler) {
                  requests.add(
                    '${Uri.parse(response.requestOptions.path).path}: '
                    '${response.statusCode}',
                  );
                  if (response.statusCode == 200 &&
                      response.requestOptions.path.endsWith('/auth/refresh')) {
                    rotatedRefresh =
                        (response.data as Map)['refresh_token'] as String;
                    // During response handling, the replacement has not been published.
                    persistedBeforeRotation =
                        store.values[ApiClient.sessionKey];
                  }
                  if (response.requestOptions.path.endsWith('/auth/logout')) {
                    revocations++;
                  }
                  handler.next(response);
                },
              ),
            );
            await api.logout();
            expect(api.session, isNull);
            expect(await store.read(ApiClient.sessionKey), isNull);
            expect(rotatedRefresh, isNotNull, reason: requests.join('\n'));
            expect(
              (jsonDecode(persistedBeforeRotation!) as Map)['refresh_token'],
              old.refreshToken,
            );
            expect(revocations, 1);
            // Checking just the old token would pass with rotation but no revocation!
            for (final token in [old.refreshToken, rotatedRefresh!]) {
              final response = await api.dio.post<dynamic>(
                '${server.url}/api/v1/auth/refresh',
                data: {'refresh_token': token},
                options: Options(validateStatus: (_) => true),
              );
              expect(response.statusCode, 401);
            }
          },
        );
      }
    },
    skip: !File(server.binary).existsSync()
        ? 'Build the Rust server first (see test/integration/README.md)'
        : false,
  );
}
