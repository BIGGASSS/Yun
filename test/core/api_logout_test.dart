import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/api_client.dart';

import 'fakes.dart';

const account = Account(
  server: 'https://yun.test',
  userId: 'user',
  username: 'listener',
);
SessionCredentials oldSession({bool expired = false}) => SessionCredentials(
  account: account,
  accessToken: 'old',
  refreshToken: 'refresh',
  expiresAt: expired ? 0 : DateTime.now().millisecondsSinceEpoch + 3600000,
);
ResponseBody rotated() => jsonResponse({
  'access_token': 'new',
  'refresh_token': 'rotated',
  'expires_at': DateTime.now().millisecondsSinceEpoch + 3600000,
});

class _BlockedCredentials extends MemoryCredentials {
  final writing = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> write(String key, String value) async {
    writing.complete();
    await release.future;
    await super.write(key, value);
  }
}

void main() {
  for (final locallyExpired in [false, true]) {
    test(
      'logout rotates and revokes current credentials (expired=$locallyExpired)',
      () async {
        final storage = MemoryCredentials();
        final dio = Dio();
        final calls = <String>[];
        final bodies = <Map>[];
        final auth = <Object?>[];
        String? persistedAtRevoke;
        dio.httpClientAdapter = FakeAdapter((options, bytes) {
          calls.add(Uri.parse(options.path).path.split('/').last);
          bodies.add(jsonDecode(utf8.decode(bytes)) as Map);
          auth.add(options.headers['Authorization']);
          if (options.path.endsWith('/auth/refresh')) return rotated();
          if (options.headers['Authorization'] == 'Bearer old') {
            return jsonResponse({'error': 'expired'}, status: 401);
          }
          persistedAtRevoke = storage.values[ApiClient.sessionKey];
          return jsonResponse({});
        });
        final api = ApiClient(dio: dio, credentials: storage)
          ..session = oldSession(expired: locallyExpired);
        await api.logout();
        expect(
          calls,
          locallyExpired
              ? ['refresh', 'logout']
              : ['logout', 'refresh', 'logout'],
        );
        expect(bodies[calls.indexOf('refresh')]['refresh_token'], 'refresh');
        expect(bodies.last['refresh_token'], 'rotated');
        expect(auth.last, 'Bearer new');
        expect(
          (jsonDecode(persistedAtRevoke!) as Map)['refresh_token'],
          'rotated',
        );
        expect(api.session, isNull);
        expect(storage.values, isEmpty);
      },
    );
  }

  test(
    'failed revoke after rotation deletes credentials; 401 retry is bounded',
    () async {
      final storage = MemoryCredentials();
      final dio = Dio();
      var refreshes = 0;
      var revocations = 0;
      dio.httpClientAdapter = FakeAdapter((options, _) {
        if (options.path.endsWith('/auth/refresh')) {
          refreshes++;
          return rotated();
        }
        revocations++;
        return jsonResponse({'error': 'unauthorized'}, status: 401);
      });
      final api = ApiClient(dio: dio, credentials: storage)
        ..session = oldSession();
      await api.logout();
      expect(refreshes, 1);
      expect(revocations, 2);
      expect(api.session, isNull);
      expect(storage.values, isEmpty);
    },
  );

  test(
    'logout waits for pending credential write and cannot be resurrected',
    () async {
      final storage = _BlockedCredentials();
      final dio = Dio();
      final revocations = <(String, Object?, Object?)>[];
      dio.httpClientAdapter = FakeAdapter((options, body) {
        if (options.path.endsWith('/auth/refresh')) return rotated();
        revocations.add((
          Uri.parse(options.path).path,
          options.headers['Authorization'],
          (jsonDecode(utf8.decode(body)) as Map)['refresh_token'],
        ));
        return jsonResponse({});
      });
      final api = ApiClient(dio: dio, credentials: storage)
        ..session = oldSession(expired: true);
      final refresh = api.refreshToken();
      await storage.writing.future;
      expect(api.session!.accessToken, 'old');
      final logout = api.logout();
      storage.release.complete();
      await Future.wait([refresh, logout]);
      expect(revocations, [('/api/v1/auth/logout', 'Bearer new', 'rotated')]);
      expect(api.session, isNull);
      expect(storage.values, isEmpty);
      expect(await api.restore(), isNull);
    },
  );

  test(
    'login queued during logout is not removed by late revocation',
    () async {
      final storage = MemoryCredentials();
      final revoking = Completer<void>();
      final release = Completer<void>();
      final dio = Dio();
      dio.httpClientAdapter = FakeAdapter((options, _) async {
        if (options.path.endsWith('/auth/logout')) {
          revoking.complete();
          await release.future;
          return jsonResponse({});
        }
        expect(options.path, endsWith('/auth/login'));
        return jsonResponse({
          'user': {'id': 'other', 'username': 'other'},
          'access_token': 'other-access',
          'refresh_token': 'other-refresh',
          'expires_at': DateTime.now().millisecondsSinceEpoch + 3600000,
        });
      });
      final api = ApiClient(dio: dio, credentials: storage)
        ..session = oldSession();
      final logout = api.logout();
      await revoking.future;
      final login = api.login(account.server, 'other', 'password', 'device');
      release.complete();
      await logout;
      await login;
      expect(api.session!.account.userId, 'other');
      expect(
        (jsonDecode(storage.values[ApiClient.sessionKey]!)
            as Map)['refresh_token'],
        'other-refresh',
      );
    },
  );

  test(
    'failed refresh does not poison auth queue or prevent local logout',
    () async {
      final storage = MemoryCredentials();
      final dio = Dio()
        ..httpClientAdapter = FakeAdapter(
          (options, _) => throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ),
        );
      final api = ApiClient(dio: dio, credentials: storage)
        ..session = oldSession(expired: true);
      await storage.write(
        ApiClient.sessionKey,
        jsonEncode(api.session!.toJson()),
      );
      final refresh = api.refreshToken();
      final failed = expectLater(refresh, throwsA(isA<DioException>()));
      final logout = api.logout();
      await failed;
      await logout;
      expect(api.session, isNull);
      expect(storage.values, isEmpty);
    },
  );
}
