import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TranscriptionUnavailable implements Exception {
  const TranscriptionUnavailable([
    this.message = 'On-device transcription is unavailable here.',
  ]);
  final String message;
  @override
  String toString() => message;
}

/// Dart bridge to the native on-device speech recogniser (Android 13+,
/// android/.../SpeechTools.kt). The audio file is decoded and streamed into
/// the recogniser: nothing plays aloud and the microphone is not used.
class SpeechTools {
  static const _channel = MethodChannel('parallax/speech');

  static Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Text spoken in the audio file at [path]. Some recognisers insist on
  /// the microphone permission even for a file; then [requestMicrophone]
  /// asks once and the transcription is tried again.
  static Future<String> transcribe(
    String path, {
    String? language,
    Future<bool> Function()? requestMicrophone,
  }) async {
    try {
      return await _transcribe(path, language);
    } on PlatformException catch (error) {
      if (error.code == 'NO_PERMISSION' && requestMicrophone != null) {
        if (await requestMicrophone()) {
          try {
            return await _transcribe(path, language);
          } on PlatformException catch (retry) {
            throw _unavailable(retry);
          }
        }
        throw const TranscriptionUnavailable(
          'Android’s speech recogniser needs microphone access, even though '
          'nothing is recorded.',
        );
      }
      throw _unavailable(error);
    } on MissingPluginException {
      throw const TranscriptionUnavailable();
    }
  }

  static Future<String> _transcribe(String path, String? language) async {
    final result = await _channel.invokeMethod<String>('transcribe', {
      'path': path,
      'language': ?language,
    });
    return result ?? '';
  }

  static TranscriptionUnavailable _unavailable(
    PlatformException error,
  ) => switch (error.code) {
    'UNSUPPORTED' => const TranscriptionUnavailable(
      'This device has no on-device speech recogniser.',
    ),
    'NO_SPEECH' => const TranscriptionUnavailable('No speech was recognised.'),
    'NO_PERMISSION' => const TranscriptionUnavailable(
      'Android’s speech recogniser needs microphone access, even though '
      'nothing is recorded.',
    ),
    'LANGUAGE' => TranscriptionUnavailable(
      '${error.message ?? 'This language isn’t available'}. '
      'Try again in a little while.',
    ),
    _ => const TranscriptionUnavailable('Couldn’t transcribe this message.'),
  };
}

/// Cached transcripts, per account and event (deleted with the account key).
class TranscriptCache {
  static String _key(String accountKey, String eventId) =>
      'parallax.transcript.v1.${sha256.convert(utf8.encode('$accountKey|$eventId'))}';

  static Future<String?> get(String accountKey, String eventId) async {
    try {
      return (await SharedPreferences.getInstance()).getString(
        _key(accountKey, eventId),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> put(
    String accountKey,
    String eventId,
    String text,
  ) async {
    try {
      await (await SharedPreferences.getInstance()).setString(
        _key(accountKey, eventId),
        text,
      );
    } catch (_) {}
  }
}
