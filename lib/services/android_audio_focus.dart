import 'dart:async';

import 'package:flutter/services.dart';

/// Android's acquisition result. A denial is not a promise of a later callback.
enum AudioFocusRequestResult { granted, delayed, failed }

/// Duck requests are transient losses: Yun pauses instead of reducing volume.
enum AndroidFocusChange { gain, loss, transientLoss, noisy }

/// One owner per playback engine; Android must not also activate audio_session.
abstract interface class AndroidAudioFocus {
  factory AndroidAudioFocus({MethodChannel? channel}) =
      MethodChannelAndroidAudioFocus;

  Stream<AndroidFocusChange> get changes;
  Future<AudioFocusRequestResult> request();
  Future<bool> abandon();
  Future<void> dispose();
}

/// Native registration belongs to the Flutter engine, not an Activity. Tokens
/// also suppress messages already in transit when Dart cancels/replaces a wait.
class MethodChannelAndroidAudioFocus implements AndroidAudioFocus {
  MethodChannelAndroidAudioFocus({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('yun/android_audio_focus') {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  final MethodChannel _channel;
  final _changes = StreamController<AndroidFocusChange>.broadcast(sync: true);
  // Avoid reusing IDs if a wrapper is disposed and recreated on the same engine.
  static int _nextRequestId = 0;
  int? _activeRequestId;
  AudioFocusRequestResult? _result;
  Future<AudioFocusRequestResult>? _acquisition;
  bool _disposed = false;
  Future<void>? _disposal;

  @override
  Stream<AndroidFocusChange> get changes => _changes.stream;

  @override
  Future<AudioFocusRequestResult> request() {
    if (_disposed) return Future.value(AudioFocusRequestResult.failed);
    // A regained grant remains valid in the background. Never re-request OS
    // focus just because the engine resumes after GAIN, and never steal focus
    // while a delayed/transient registration is still waiting for its callback.
    if (_activeRequestId != null) {
      final result = _result;
      if (result != null) return Future.value(result);
      return _acquisition!;
    }
    final requestId = ++_nextRequestId;
    _activeRequestId = requestId;
    _result = null;
    return _acquisition = _request(requestId);
  }

  Future<AudioFocusRequestResult> _request(int requestId) async {
    try {
      final response = await _channel.invokeMethod<String>('request', {
        'requestId': requestId,
      });
      if (_disposed || _activeRequestId != requestId) {
        return AudioFocusRequestResult.failed;
      }
      final result = switch (response) {
        'granted' => AudioFocusRequestResult.granted,
        'delayed' => AudioFocusRequestResult.delayed,
        _ => AudioFocusRequestResult.failed,
      };
      if (result == AudioFocusRequestResult.failed) {
        _activeRequestId = null;
        _result = null;
        return result;
      }
      // A gain/loss may arrive before the method reply is delivered. Preserve
      // that newer event instead of overwriting it with the acquisition result.
      return _result ??= result;
    } catch (_) {
      if (_activeRequestId == requestId) {
        _activeRequestId = null;
        _result = null;
      }
      rethrow;
    }
  }

  Future<void> _onMethodCall(MethodCall call) async {
    if (_disposed || call.method != 'focusChanged') return;
    final args = call.arguments;
    if (args is! Map || args['requestId'] != _activeRequestId) return;
    // Null IDs must never turn an unsolicited event into an active request.
    if (_activeRequestId == null) return;
    final change = switch (args['change']) {
      'gain' => AndroidFocusChange.gain,
      'loss' => AndroidFocusChange.loss,
      'transientLoss' => AndroidFocusChange.transientLoss,
      'noisy' => AndroidFocusChange.noisy,
      _ => null,
    };
    if (change == null) return;
    switch (change) {
      case AndroidFocusChange.gain:
        _result = AudioFocusRequestResult.granted;
      case AndroidFocusChange.transientLoss:
        _result = AudioFocusRequestResult.delayed;
      case AndroidFocusChange.loss:
      case AndroidFocusChange.noisy:
        _activeRequestId = null;
        _result = null;
    }
    _changes.add(change);
  }

  @override
  Future<bool> abandon() {
    // Invalidate synchronously, before awaiting the platform channel's reply.
    _activeRequestId = null;
    _result = null;
    if (_disposed) return Future.value(true);
    return _channel
        .invokeMethod<bool>('abandon')
        .then((value) => value ?? false);
  }

  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    _activeRequestId = null;
    _result = null;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    try {
      await _channel.invokeMethod<bool>('abandon');
    } finally {
      await _changes.close();
    }
  }
}
