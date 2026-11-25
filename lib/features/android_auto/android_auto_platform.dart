// Dart end of `parallax/android_auto` (android/.../AndroidAuto.kt).
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('parallax/android_auto');

bool get _isAndroid => !kIsWeb && Platform.isAndroid;

/// Whether notifications should be laid out for Android Auto right now.
///
/// Android Auto reads only conversation (MessagingStyle) notifications. When
/// the answer is unknown (an engine without the channel, or no reply in
/// time) this says yes: the car layout is an ordinary conversation
/// notification, so it is never wrong on the phone.
Future<bool> androidAutoProjecting() async {
  if (!_isAndroid) return false;
  try {
    final projecting = await _channel
        .invokeMethod<bool>('isProjecting')
        .timeout(const Duration(seconds: 1));
    return projecting ?? true;
  } catch (_) {
    return true;
  }
}

/// Requests from the car screen: the method name and its arguments.
typedef CarRequestHandler =
    Future<Object?> Function(String method, Map<String, Object?> arguments);

/// The native car side, behind an interface for tests.
abstract interface class AndroidAutoPlatform {
  /// Receives the car screen's requests; null stops listening.
  void setHandler(CarRequestHandler? handler);

  /// Tells the car side whether a signed-in host is listening. Returns
  /// whether a car screen is showing.
  Future<bool> hostAttached(bool attached);

  /// The chats changed: a car screen that is showing asks again.
  Future<void> invalidate();
}

class MethodChannelAndroidAuto implements AndroidAutoPlatform {
  const MethodChannelAndroidAuto();

  @override
  void setHandler(CarRequestHandler? handler) {
    _channel.setMethodCallHandler(
      handler == null
          ? null
          : (call) {
              final arguments = call.arguments;
              return handler(
                call.method,
                arguments is Map
                    ? Map<String, Object?>.from(arguments)
                    : const <String, Object?>{},
              );
            },
    );
  }

  @override
  Future<bool> hostAttached(bool attached) async {
    try {
      final answer = await _channel.invokeMethod<Object?>('hostAttached', {
        'attached': attached,
      });
      return answer is Map && answer['carScreenActive'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> invalidate() async {
    try {
      await _channel.invokeMethod<void>('invalidate');
    } catch (_) {
      // No car screen or no Android side (tests, other platforms).
    }
  }
}
