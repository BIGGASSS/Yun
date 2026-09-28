import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/api_client.dart';

import 'fakes.dart';

void main() {
  const account = Account(
    server: 'https://yun.test',
    userId: 'user',
    username: 'listener',
  );
  test('normalization requires HTTPS except explicit loopback', () {
    expect(normalizeServer('https://yun.test/'), 'https://yun.test');
    expect(normalizeServer('http://localhost:8080/'), 'http://localhost:8080');
    expect(normalizeServer('http://[::1]:8080/'), 'http://[::1]:8080');
    for (final url in [
      'http://yun.test',
      'https://user:pass@yun.test',
      'file:///etc/passwd',
      'https://yun.test/?token=x',
    ]) {
      expect(() => normalizeServer(url), throwsArgumentError);
    }
  });
  test(
    'parallel expired requests serialize refresh and persist rotated token',
    () async {
      final storage = MemoryCredentials();
      final dio = Dio();
      var rotations = 0;
      dio.httpClientAdapter = FakeAdapter((options, bytes) async {
        if (options.path.endsWith('/auth/refresh')) {
          rotations++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return jsonResponse({
            'access_token': 'next-access',
            'refresh_token': 'next-refresh',
            'expires_at': DateTime.now().millisecondsSinceEpoch + 3600000,
          });
        }
        expect(options.headers['Authorization'], 'Bearer next-access');
        return jsonResponse({'cursor': 1});
      });
      final api = ApiClient(dio: dio, credentials: storage)
        ..session = const SessionCredentials(
          account: account,
          accessToken: 'old',
          refreshToken: 'refresh',
          expiresAt: 0,
        );
      await Future.wait(List.generate(8, (_) => api.json('/library')));
      expect(rotations, 1);
      final saved = jsonDecode(storage.values[ApiClient.sessionKey]!) as Map;
      expect(saved['refresh_token'], 'next-refresh');
      expect(api.session!.accessToken, 'next-access');
    },
  );
  test('401 requests replay once using the same shared rotation', () async {
    var rotations = 0;
    final dio = Dio();
    dio.httpClientAdapter = FakeAdapter((options, bytes) async {
      if (options.path.endsWith('/auth/refresh')) {
        rotations++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return jsonResponse({
          'access_token': 'new',
          'refresh_token': 'rotated',
          'expires_at': DateTime.now().millisecondsSinceEpoch + 3600000,
        });
      }
      if (options.headers['Authorization'] == 'Bearer old') {
        return jsonResponse({'error': 'expired'}, status: 401);
      }
      return jsonResponse({'ok': true});
    });
    final api = ApiClient(dio: dio, credentials: MemoryCredentials())
      ..session = SessionCredentials(
        account: account,
        accessToken: 'old',
        refreshToken: 'refresh',
        expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
      );
    await Future.wait(List.generate(5, (_) => api.json('/library')));
    expect(rotations, 1);
  });
  test(
    'offline logout removes active credentials even when revoke fails',
    () async {
      final storage = MemoryCredentials();
      final session = SessionCredentials(
        account: account,
        accessToken: 'expired',
        refreshToken: 'refresh',
        expiresAt: 0,
      );
      await storage.write(ApiClient.sessionKey, jsonEncode(session.toJson()));
      final dio = Dio()
        ..httpClientAdapter = FakeAdapter(
          (options, _) => throw DioException(
            requestOptions: options,
            type: DioExceptionType.connectionError,
          ),
        );
      final api = ApiClient(dio: dio, credentials: storage);
      await api.restore();
      expect(api.session!.account.userId, 'user');
      await api.logout();
      expect(api.session, isNull);
      expect(await storage.read(ApiClient.sessionKey), isNull);
    },
  );
}
