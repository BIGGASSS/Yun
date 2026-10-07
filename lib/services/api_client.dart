import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/models.dart';

abstract interface class CredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class SessionCredentials {
  const SessionCredentials({
    required this.account,
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });
  final Account account;
  final String accessToken, refreshToken;
  final int expiresAt;
  Map<String, dynamic> toJson() => {
    'account': account.toJson(),
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt,
  };
  factory SessionCredentials.fromJson(Map<String, dynamic> j) =>
      SessionCredentials(
        account: Account.fromJson(
          Map<String, dynamic>.from(j['account'] as Map),
        ),
        accessToken: j['access_token'] as String,
        refreshToken: j['refresh_token'] as String,
        expiresAt: (j['expires_at'] as num).toInt(),
      );
}

String normalizeServer(String value) {
  final uri = Uri.parse(value.trim());
  if (!uri.hasAuthority ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.scheme != 'https' &&
          !(uri.scheme == 'http' &&
              ['localhost', '127.0.0.1', '::1', '[::1]'].contains(uri.host)))) {
    throw ArgumentError(
      'Use an HTTPS server URL (HTTP allowed only on loopback).',
    );
  }
  return uri
      .replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''))
      .toString()
      .replaceFirst(RegExp(r'/+$'), '');
}

/// All authenticated requests share one refresh future. Rotated credentials are
/// stored as a single secure-storage value before the new token is made visible.
class ApiClient {
  ApiClient({Dio? dio, CredentialStore? credentials})
    : usesDefaultTransport = dio == null,
      dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              // Bound stalled upload writes too. Let Dio surface sendTimeout
              // so the upload worker can reconcile the durable server offset
              // on retry rather than blindly replaying an uncertain chunk.
              sendTimeout: const Duration(seconds: 60),
              receiveTimeout: const Duration(seconds: 60),
            ),
          ),
      credentials = credentials ?? SecureCredentialStore();
  final Dio dio;

  /// Injected clients may have custom adapters, interceptors or trust settings
  /// that cannot be copied to an isolate. Keep those downloads on that client;
  /// the app's default transport can safely create its own worker-side Dio.
  final bool usesDefaultTransport;
  final CredentialStore credentials;
  SessionCredentials? session;
  Future<void>? _refreshing;
  Future<void> _sessionOperations = Future.value();
  int _generation = 0;

  // Serialize auth operations, including secure-storage writes/deletes. A late
  // rotation must never restore credentials after logout or overwrite a login.
  Future<T> _serializeSession<T>(Future<T> Function() operation) {
    final result = _sessionOperations.then((_) => operation());
    _sessionOperations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  static const sessionKey = 'yun.active_session';
  Future<SessionCredentials?> restore() => _serializeSession(_restore);

  Future<SessionCredentials?> _restore() async {
    final raw = await credentials.read(sessionKey);
    if (raw != null) {
      session = SessionCredentials.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    }
    return session;
  }

  Future<Account> login(
    String server,
    String username,
    String password,
    String deviceId,
  ) => _serializeSession(() => _login(server, username, password, deviceId));

  Future<Account> _login(
    String server,
    String username,
    String password,
    String deviceId,
  ) async {
    server = normalizeServer(server);
    final response = await dio.post<dynamic>(
      '$server/api/v1/auth/login',
      data: {'username': username, 'password': password, 'device_id': deviceId},
    );
    final j = Map<String, dynamic>.from(response.data as Map);
    final user = Map<String, dynamic>.from(j['user'] as Map);
    final account = Account(
      server: server,
      userId: user['id'] as String,
      username: user['username'] as String,
    );
    final next = _fromResponse(account, j);
    await credentials.write(sessionKey, jsonEncode(next.toJson()));
    _generation++;
    session = next;
    return account;
  }

  SessionCredentials _fromResponse(Account account, Map<String, dynamic> j) =>
      SessionCredentials(
        account: account,
        accessToken: j['access_token'] as String,
        refreshToken: j['refresh_token'] as String,
        expiresAt: (j['expires_at'] as num).toInt(),
      );
  Future<void> refreshToken() {
    if (_refreshing != null) return _refreshing!;
    return _refreshing = _serializeSession(_rotate)
        .whenComplete(() => _refreshing = null);
  }

  Future<void> _rotate() async {
    final old = session;
    final generation = _generation;
    if (old == null) throw StateError('Sign in required');
    final response = await dio.post<dynamic>(
      '${old.account.server}/api/v1/auth/refresh',
      data: {'refresh_token': old.refreshToken},
    );
    if (generation != _generation || !identical(session, old)) {
      throw StateError('Session changed');
    }
    final next = _fromResponse(
      old.account,
      Map<String, dynamic>.from(response.data as Map),
    );
    await credentials.write(sessionKey, jsonEncode(next.toJson()));
    if (generation == _generation && identical(session, old)) session = next;
  }

  Future<Map<String, String>> headers() async {
    if (session == null) throw StateError('Sign in required');
    if (session!.expiresAt <= DateTime.now().millisecondsSinceEpoch + 30000) {
      await refreshToken();
    }
    return {'Authorization': 'Bearer ${session!.accessToken}'};
  }

  Future<Response<dynamic>> request(
    String path, {
    String method = 'GET',
    dynamic data,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    ResponseType? responseType,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
  }) async {
    return withAuthorization(
      (server, auth) => dio.request<dynamic>(
        '$server/api/v1$path',
        data: data,
        queryParameters: query,
        options: Options(
          method: method,
          headers: {...auth, ...?headers},
          responseType: responseType,
        ),
        cancelToken: cancelToken,
        onReceiveProgress: onReceiveProgress,
      ),
      isUnauthorized: (error) =>
          error is DioException && error.response?.statusCode == 401,
    );
  }

  /// Runs an authenticated operation without sharing this client or credential
  /// storage with its transport. Refresh stays serialized here, including the
  /// single retry for a worker-reported 401. Never retry under another login.
  Future<T> withAuthorization<T>(
    Future<T> Function(String server, Map<String, String> headers) send, {
    required bool Function(Object error) isUnauthorized,
  }) async {
    final generation = _generation;
    final account = session?.account;
    void checkSession() {
      if (_generation != generation ||
          session == null ||
          session?.account.userId != account?.userId ||
          session?.account.server != account?.server) {
        throw StateError('Session changed');
      }
    }

    final auth = await headers();
    checkSession();
    final current = session!;
    try {
      return await send(current.account.server, auth);
    } catch (error) {
      if (!isUnauthorized(error)) rethrow;
      checkSession();
      if (session?.accessToken == current.accessToken) await refreshToken();
      checkSession();
      return send(current.account.server, {
        'Authorization': 'Bearer ${session!.accessToken}',
      });
    }
  }

  Future<Map<String, dynamic>> json(
    String path, {
    String method = 'GET',
    dynamic data,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    final response = await request(
      path,
      method: method,
      data: data,
      query: query,
      headers: headers,
    );
    return response.data == null || response.data == ''
        ? {}
        : Map<String, dynamic>.from(response.data as Map);
  }

  Future<void> logout() => _serializeSession(_logout);

  Future<void> _logout() async {
    try {
      if (session == null) return;
      if (session!.expiresAt <= DateTime.now().millisecondsSinceEpoch + 30000) {
        await _rotate();
      }
      Future<void> revoke() async {
        final current = session!;
        await dio.post<dynamic>(
          '${current.account.server}/api/v1/auth/logout',
          data: {'refresh_token': current.refreshToken},
          options: Options(
            headers: {'Authorization': 'Bearer ${current.accessToken}'},
          ),
        );
      }

      try {
        await revoke();
      } on DioException catch (e) {
        if (e.response?.statusCode != 401) rethrow;
        // Server-side expiry can precede our local clock. Retry only once,
        // revoking the rotated refresh token, not the now-invalid old one.
        await _rotate();
        await revoke();
      }
    } catch (_) {
      // Local logout must also work offline or with expired refresh credentials.
    } finally {
      _generation++;
      session = null;
      await credentials.delete(sessionKey);
    }
  }
}
