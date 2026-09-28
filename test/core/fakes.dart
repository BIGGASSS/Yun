import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:yun/services/api_client.dart';
import 'package:yun/services/playback_engine.dart';

class MemoryCredentials implements CredentialStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);
  final FutureOr<ResponseBody> Function(RequestOptions, List<int>) handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    return handler(options, bytes);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonResponse(Object value, {int status = 200}) =>
    ResponseBody.fromString(
      jsonEncode(value),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

class FakeEngine implements PlaybackEngine {
  final controller = StreamController<EngineState>.broadcast(sync: true);
  EngineState state = const EngineState();
  String? opened;
  int opens = 0, initializations = 0;
  double volume = 100;
  final volumeCalls = <double>[];
  final calls = <String>[];
  Future<void> Function(double)? onSetVolume;
  void emit(EngineState value) {
    state = value;
    controller.add(value);
  }

  @override
  Stream<EngineState> get states => controller.stream;
  @override
  Future<void> initialize() async {
    initializations++;
    calls.add('initialize');
  }

  @override
  Future<void> open(String uri, {Map<String, String>? headers}) async {
    calls.add('open');
    opened = uri;
    opens++;
    emit(const EngineState(playing: true, duration: Duration(seconds: 120)));
  }

  @override
  Future<void> play() async {
    emit(
      EngineState(
        playing: true,
        position: state.position,
        duration: state.duration,
      ),
    );
  }

  @override
  Future<void> pause() async {
    emit(EngineState(position: state.position, duration: state.duration));
  }

  @override
  Future<void> seek(Duration position) async {
    emit(
      EngineState(
        playing: state.playing,
        position: position,
        duration: state.duration,
      ),
    );
  }

  @override
  Future<void> setVolume(double value) async {
    calls.add('volume');
    volumeCalls.add(value);
    await onSetVolume?.call(value);
    volume = value;
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    emit(const EngineState());
  }

  @override
  Future<void> dispose() async {
    await controller.close();
  }
}
