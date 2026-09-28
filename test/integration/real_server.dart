// Disposable real Rust server for Flutter/Dart TCP integration tests.
// Prerequisite: cargo build --locked --manifest-path server/Cargo.toml
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:yun/models/models.dart';
import 'package:yun/services/api_client.dart';

import '../core/fakes.dart';

class RealServer {
  static const password = 'integration-test-password';
  final binary =
      Platform.environment['YUN_SERVER_BINARY'] ??
      File('server/target/debug/yun-server').absolute.path;
  late Directory directory;
  late String url;
  Process? _process;
  final StringBuffer logs = StringBuffer();

  Future<void> start(List<String> users) async {
    if (!await File(binary).exists()) {
      throw StateError(
        'Build the server first: cargo build --locked --manifest-path server/Cargo.toml',
      );
    }
    directory = await Directory.systemTemp.createTemp('yun-client-tcp-');
    for (final user in users) {
      final process = await Process.start(binary, [
        '--data-dir',
        directory.path,
        'create-user',
        user,
        '--password-stdin',
      ]);
      process.stdin.writeln(password);
      await process.stdin.close();
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode;
      if (code != 0) throw StateError('${await stdout}\n${await stderr}');
      await stdout;
      await stderr;
    }
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    url = 'http://127.0.0.1:$port';
    _process = await Process.start(binary, [
      '--data-dir',
      directory.path,
      'serve',
      '--bind',
      '127.0.0.1:$port',
      '--insecure-loopback',
    ]);
    _process!.stdout.transform(utf8.decoder).listen(logs.write);
    _process!.stderr.transform(utf8.decoder).listen(logs.write);
    final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 1)));
    try {
      for (var i = 0; i < 100; i++) {
        try {
          if ((await dio.get<dynamic>('$url/health')).statusCode == 200) return;
        } on DioException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      throw StateError('Server failed health check: $logs');
    } finally {
      dio.close(force: true);
    }
  }

  Future<ApiClient> login(
    String user,
    String device, {
    MemoryCredentials? credentials,
  }) async {
    final api = ApiClient(credentials: credentials ?? MemoryCredentials());
    await api.login(url, user, password, device);
    return api;
  }

  Future<void> expireAccessToken(String accessToken) async {
    // Accelerates the real server's 15-minute expiry without changing server code.
    final result = await Process.run('python3', [
      '-c',
      'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("UPDATE sessions SET access_expires=0 WHERE access_hash=?", (sys.argv[2],)); c.commit()',
      '${directory.path}/yun.sqlite3',
      sha256.convert(utf8.encode(accessToken)).toString(),
    ]);
    if (result.exitCode != 0) throw StateError('${result.stderr}');
  }

  Future<void> close() async {
    final process = _process;
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    }
    await directory.delete(recursive: true);
  }
}

Uint8List testWav() {
  const samples = 8000 * 4;
  final bytes = Uint8List(44 + samples * 2);
  final view = ByteData.sublistView(bytes);
  void ascii(int offset, String value) =>
      bytes.setRange(offset, offset + value.length, asciiEncode(value));
  ascii(0, 'RIFF');
  view.setUint32(4, bytes.length - 8, Endian.little);
  ascii(8, 'WAVEfmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little);
  view.setUint16(22, 1, Endian.little);
  view.setUint32(24, 8000, Endian.little);
  view.setUint32(28, 16000, Endian.little);
  view.setUint16(32, 2, Endian.little);
  view.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  view.setUint32(40, samples * 2, Endian.little);
  return bytes;
}

List<int> asciiEncode(String value) => ascii.encode(value);

Future<(String, Track)> uploadWav(ApiClient api) async {
  final bytes = testWav();
  final upload = await api.json(
    '/uploads',
    method: 'POST',
    data: {'filename': 'fixture.wav', 'size_bytes': bytes.length},
  );
  final id = upload['id'] as String;
  await api.request(
    '/uploads/$id',
    method: 'PATCH',
    data: bytes,
    headers: {'Content-Type': 'application/octet-stream', 'Upload-Offset': '0'},
  );
  final track = Track.fromJson(
    await api.json('/uploads/$id/complete', method: 'POST'),
  );
  return (id, track);
}

Future<void> eventually(bool Function() predicate) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('Condition did not become true within five seconds');
}
