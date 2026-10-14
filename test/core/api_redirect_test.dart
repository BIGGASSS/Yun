import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/api_client.dart';

import 'fakes.dart';

void main() {
  for (final injected in [false, true]) {
    for (final operation in ['login', 'refresh', 'request', 'logout']) {
      test('$operation rejects redirects (injected=$injected)', () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        addTearDown(() => target.close(force: true));
        var redirectedRequests = 0;
        target.listen((request) async {
          redirectedRequests++;
          await request.drain<void>();
          request.response.write('{}');
          await request.response.close();
        });
        server.listen((request) async {
          await request.drain<void>();
          // Dart follows POST 303 redirects as GET; same-host redirects may
          // also retain Authorization even when the destination port changes.
          request.response.statusCode = HttpStatus.seeOther;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${target.port}/redirected',
          );
          await request.response.close();
        });
        final base = 'http://127.0.0.1:${server.port}';
        final api =
            ApiClient(
                dio: injected ? Dio(BaseOptions(followRedirects: true)) : null,
                credentials: MemoryCredentials(),
              )
              ..session = SessionCredentials(
                account: Account(
                  server: base,
                  userId: 'user',
                  username: 'listener',
                ),
                accessToken: 'private-access',
                refreshToken: 'private-refresh',
                expiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
              );
        addTearDown(() => api.dio.close(force: true));
        final Future<dynamic> result = switch (operation) {
          'login' => api.login(base, 'listener', 'private-password', 'device'),
          'refresh' => api.refreshToken(),
          'logout' => api.logout(),
          _ => api.request('/library'),
        };
        if (operation == 'logout') {
          // Local logout deliberately succeeds even when revocation fails.
          await result;
          expect(api.session, isNull);
        } else {
          await expectLater(
            result,
            throwsA(
              isA<DioException>().having(
                (error) => error.response?.statusCode,
                'status',
                HttpStatus.seeOther,
              ),
            ),
          );
        }
        expect(redirectedRequests, 0);
      });
    }
  }
}
