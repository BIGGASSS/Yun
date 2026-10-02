import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android's acquisition result. A denial is not a promise of a later callback.
enum AudioFocusRequestResult { granted, delayed, failed }

/// Duck requests are transient losses: Yun pauses instead of reducing volume.
enum AndroidFocusChange { gain, loss, transientLoss, noisy }

/// Allowlisted diagnostic fields only; never retain a channel error's message,
/// details, stack trace, media URL, token or account information.
class AndroidAudioFocusDiagnostic {
  const AndroidAudioFocusDiagnostic._({
    required this.category,
    required this.requestId,
    required this.result,
    this.exceptionClass,
  });

  final String category;
  final int requestId;
  final String result;
  final String? exceptionClass;

  static const _nativeCategories = {
    'bridge_prepare',
    'native_request',
    'noisy_register',
    'noisy_unregister',
    'native_abandon',
    'request',
    'abandon',
    'bridge_channel',
  };
  static const _nativeResults = {
    'granted',
    'delayed',
    'failed',
    'success',
    'error',
    'cancelled',
    'cleanup_blocked',
    'disposed',
  };
  static final _className = RegExp(r'^[A-Za-z_$][A-Za-z0-9_.$]*$');

  static String? _safeClassName(Object? value) =>
      value is String && value.length <= 200 && _className.hasMatch(value)
      ? value
      : null;

  static AndroidAudioFocusDiagnostic? _fromNative(Object? arguments) {
    if (arguments is! Map) return null;
    final category = arguments['category'];
    final requestId = arguments['requestId'];
    final result = arguments['result'];
    if (category is! String ||
        !_nativeCategories.contains(category) ||
        requestId is! int ||
        requestId < 0 ||
        result is! String ||
        !_nativeResults.contains(result)) {
      return null;
    }
    return AndroidAudioFocusDiagnostic._(
      category: category,
      requestId: requestId,
      result: result,
      exceptionClass: _safeClassName(arguments['exceptionClass']),
    );
  }

  Map<String, Object> toMap() => {
    'category': category,
    'requestId': requestId,
    'result': result,
    'exceptionClass': ?exceptionClass,
  };

  @override
  String toString() => jsonEncode(toMap());
}

typedef AudioFocusDiagnosticCallback = void Function(
  AndroidAudioFocusDiagnostic diagnostic,
);

/// One owner per playback engine; Android must not also activate audio_session.
abstract interface class AndroidAudioFocus {
  factory AndroidAudioFocus({
    MethodChannel? channel,
    AudioFocusDiagnosticCallback? onDiagnostic,
  }) = MethodChannelAndroidAudioFocus;

  Stream<AndroidFocusChange> get changes;
  Future<AudioFocusRequestResult> request();
  Future<bool> abandon();
  Future<void> dispose();
}

/// Native registration belongs to the Flutter engine, not an Activity. Tokens
/// also suppress messages already in transit when Dart cancels/replaces a wait.
class MethodChannelAndroidAudioFocus implements AndroidAudioFocus {
  MethodChannelAndroidAudioFocus({
    MethodChannel? channel,
    AudioFocusDiagnosticCallback? onDiagnostic,
  }) : _channel = channel ?? const MethodChannel('yun/android_audio_focus'),
       _onDiagnostic = onDiagnostic ?? _logDiagnostic {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  final MethodChannel _channel;
  final AudioFocusDiagnosticCallback _onDiagnostic;

  static void _logDiagnostic(AndroidAudioFocusDiagnostic diagnostic) {
    // debugPrint also writes in release builds. Only this allowlisted object is
    // logged, never a raw PlatformException or native method payload.
    debugPrint('YunAudioFocus $diagnostic');
  }

  void _report(AndroidAudioFocusDiagnostic diagnostic) {
    try {
      _onDiagnostic(diagnostic);
    } catch (_) {
      // Diagnostic consumers cannot change focus ownership or playback intent.
    }
  }

  void _record(
    String category,
    int? requestId,
    String result, [
    Object? error,
  ]) {
    _report(
      AndroidAudioFocusDiagnostic._(
        category: category,
        requestId: requestId ?? 0,
        result: result,
        exceptionClass: error == null
            ? null
            : AndroidAudioFocusDiagnostic._safeClassName(
                error.runtimeType.toString(),
              ),
      ),
    );
  }

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
      _record(
        'channel_request',
        requestId,
        const {'granted', 'delayed', 'failed'}.contains(response)
            ? response!
            : 'invalid_response',
      );
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
    } catch (error) {
      _record('channel_request', requestId, 'error', error);
      if (_activeRequestId == requestId) {
        _activeRequestId = null;
        _result = null;
      }
      rethrow;
    }
  }

  Future<void> _onMethodCall(MethodCall call) async {
    if (_disposed) return;
    if (call.method == 'diagnostic') {
      final diagnostic = AndroidAudioFocusDiagnostic._fromNative(
        call.arguments,
      );
      if (diagnostic != null) _report(diagnostic);
      return;
    }
    if (call.method != 'focusChanged') return;
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
    final requestId = _activeRequestId;
    _activeRequestId = null;
    _result = null;
    if (_disposed) return Future.value(true);
    return _abandon(requestId, 'channel_abandon');
  }

  Future<bool> _abandon(int? requestId, String category) async {
    try {
      final value = await _channel.invokeMethod<bool>('abandon');
      _record(category, requestId, value == true ? 'success' : 'failed');
      return value ?? false;
    } catch (error) {
      _record(category, requestId, 'error', error);
      rethrow;
    }
  }

  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    final requestId = _activeRequestId;
    _activeRequestId = null;
    _result = null;
    _disposed = true;
    _channel.setMethodCallHandler(null);
    try {
      await _abandon(requestId, 'channel_dispose');
    } finally {
      await _changes.close();
    }
  }
}
