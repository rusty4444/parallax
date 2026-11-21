import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// One audio output device reported by the platform.
@immutable
class AudioOutput {
  const AudioOutput({required this.id, required this.name, required this.type});
  final int id;
  final String name;
  final String type;
}

/// Dart bridge to the native call integration (Android): picture-in-picture,
/// in-call audio routing and the full-screen incoming-call notification. On
/// other platforms the calls are inert no-ops.
class CallIntegration {
  static const _channel = MethodChannel('parallax/call_integration');

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<bool> enterPip() async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>('enterPip') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<bool> setAutoPip(bool enabled) async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>('setAutoPip', {
            'enabled': enabled,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<List<AudioOutput>> audioOutputs() async {
    if (!_android) return const [];
    try {
      final list = await _channel.invokeMethod<List<dynamic>>('audioOutputs');
      return [
        for (final item in list ?? const [])
          if (item is Map)
            AudioOutput(
              id: (item['id'] as num?)?.toInt() ?? 0,
              name: item['name'] as String? ?? 'Audio device',
              type: item['type'] as String? ?? '',
            ),
      ];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  static Future<bool> setAudioOutput(int id) async {
    if (!_android) return false;
    try {
      return await _channel.invokeMethod<bool>('setAudioOutput', {'id': id}) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static Future<void> showIncomingCall(
    String name, {
    bool audioOnly = false,
  }) async {
    if (!_android) return;
    try {
      await _channel.invokeMethod('showIncomingCall', {
        'name': name,
        'audioOnly': audioOnly,
      });
    } on PlatformException {
      // Best effort.
    } on MissingPluginException {
      // Other platforms.
    }
  }

  static Future<void> dismissIncomingCall() async {
    if (!_android) return;
    try {
      await _channel.invokeMethod('dismissIncomingCall');
    } on PlatformException {
      // Best effort.
    } on MissingPluginException {
      // Other platforms.
    }
  }
}
