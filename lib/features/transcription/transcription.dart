import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat_backend.dart';
import '../../room_events.dart';

class TranscriptionUnavailable implements Exception {
  const TranscriptionUnavailable([
    this.message = 'On-device transcription is unavailable here.',
  ]);
  final String message;
  @override
  String toString() => message;
}

/// Dart bridge to the native on-device speech recognizer (Android).
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

  static Future<String> transcribe(String path) async {
    try {
      final result = await _channel.invokeMethod<String>('transcribe', {
        'path': path,
      });
      return result ?? '';
    } on MissingPluginException {
      throw const TranscriptionUnavailable();
    } on PlatformException catch (error) {
      if (error.code == 'UNSUPPORTED') {
        throw const TranscriptionUnavailable(
          'This device has no on-device speech recognizer.',
        );
      }
      throw TranscriptionUnavailable(error.message ?? 'Transcription failed.');
    }
  }
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

/// Downloads a voice/audio message to a temporary file for the recognizer.
Future<String?> downloadAudioToFile(
  ChatBackend backend,
  String roomId,
  String eventId,
) async {
  final sdk = backend is MatrixSdkAccess
      ? (backend as MatrixSdkAccess).sdkClient
      : null;
  if (sdk == null) return null;
  final room = sdk.getRoomById(roomId);
  if (room == null) return null;
  try {
    final timeline = await room.getTimeline(eventContextId: eventId);
    try {
      matrix.Event? event;
      for (final candidate in timeline.events) {
        if (candidate.eventId == eventId) {
          event = candidate;
          break;
        }
      }
      if (event == null || event.redacted) return null;
      final file = await event.downloadAndDecryptAttachment();
      final dir = await getTemporaryDirectory();
      final name = file.name.isEmpty ? 'voice.m4a' : file.name;
      final out = File('${dir.path}/transcribe_${eventId.hashCode}_$name');
      await out.writeAsBytes(file.bytes, flush: true);
      return out.path;
    } finally {
      timeline.cancelSubscriptions();
    }
  } catch (_) {
    return null;
  }
}
