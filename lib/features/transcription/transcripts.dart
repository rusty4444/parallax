import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../media_player_owner.dart';
import '../media/inline_audio.dart';
import '../media/media_actions.dart';
import 'transcription.dart';

class _SessionChanged implements Exception {
  const _SessionChanged();
}

/// Where a voice or audio message's transcript is up to.
enum TranscriptStatus { none, working, done, failed }

@immutable
class TranscriptState {
  const TranscriptState._(this.status, {this.text, this.error});

  static const none = TranscriptState._(TranscriptStatus.none);
  static const working = TranscriptState._(TranscriptStatus.working);
  const TranscriptState.done(String text)
    : this._(TranscriptStatus.done, text: text);
  const TranscriptState.failed(String error)
    : this._(TranscriptStatus.failed, error: error);

  final TranscriptStatus status;
  final String? text;
  final String? error;
}

/// Turns one audio file into text. The default runs the platform's
/// on-device recogniser ([SpeechTools]); tests swap in a fake.
abstract interface class TranscriptionEngine {
  Future<bool> isAvailable();
  Future<String> transcribe(DownloadedAttachment audio);
}

class OnDeviceTranscriptionEngine implements TranscriptionEngine {
  const OnDeviceTranscriptionEngine();

  @override
  Future<bool> isAvailable() => SpeechTools.isAvailable();

  /// The decrypted audio lives in a private temporary folder only while the
  /// recogniser reads it.
  @override
  Future<String> transcribe(DownloadedAttachment audio) async {
    final file = await createMediaTempFile(audio);
    try {
      return await SpeechTools.transcribe(
        file.path,
        requestMicrophone: _requestMicrophone,
      );
    } finally {
      await file.delete();
    }
  }

  static Future<bool> _requestMicrophone() async {
    final recorder = AudioRecorder();
    try {
      return await recorder.hasPermission();
    } catch (_) {
      return false;
    } finally {
      await recorder.dispose();
    }
  }
}

/// Saved transcripts per account. [read] returns null when none is saved.
abstract interface class TranscriptStore {
  Future<String?> read(String accountKey, String eventId);
  Future<void> write(String accountKey, String eventId, String text);
}

class _PreferencesTranscriptStore implements TranscriptStore {
  const _PreferencesTranscriptStore();
  @override
  Future<String?> read(String accountKey, String eventId) =>
      TranscriptCache.get(accountKey, eventId);
  @override
  Future<void> write(String accountKey, String eventId, String text) =>
      TranscriptCache.put(accountKey, eventId, text);
}

/// Transcripts of voice and audio messages, shown inside the message's own
/// bubble under the player. Finished transcripts are saved on this device
/// (per account and message), so they are there again next time the chat
/// opens. The bubble's Transcribe button and the long-press "Transcribe"
/// action both go through [transcribe], so one message is only transcribed
/// once at a time.
class Transcripts extends ChangeNotifier {
  Transcripts({TranscriptionEngine? engine, TranscriptStore? store})
    : engine = engine ?? const OnDeviceTranscriptionEngine(),
      store = store ?? const _PreferencesTranscriptStore();

  static Transcripts instance = Transcripts();

  final TranscriptionEngine engine;
  final TranscriptStore store;

  final _states = <String, TranscriptState>{};
  final _restoring = <String>{};
  Future<bool>? _available;
  bool? _availableValue;

  static String _key(String account, String eventId) => '$account\n$eventId';

  /// Whether this device can transcribe at all (known after the first
  /// check; false until then, so the button never flashes in and out).
  bool get available {
    _available ??= engine.isAvailable().catchError((Object _) => false).then((
      value,
    ) {
      _availableValue = value;
      if (value) notifyListeners();
      return value;
    });
    return _availableValue ?? false;
  }

  /// The transcript state for [eventId] in [backend]'s account. The first
  /// look loads a saved transcript in the background.
  TranscriptState stateFor(ChatBackend backend, String eventId) {
    final account = BackendSessionOwner.keyFor(backend);
    if (account == null || account.isEmpty) return TranscriptState.none;
    final key = _key(account, eventId);
    final state = _states[key];
    if (state != null) return state;
    if (_restoring.add(key)) unawaited(_restore(account, eventId, key));
    return TranscriptState.none;
  }

  Future<void> _restore(String account, String eventId, String key) async {
    String? saved;
    try {
      saved = await store.read(account, eventId);
    } catch (_) {
      saved = null;
    }
    if (saved == null || saved.trim().isEmpty) return;
    // A transcription that finished meanwhile wins.
    if (_states[key]?.status == TranscriptStatus.done) return;
    _states[key] = TranscriptState.done(saved);
    notifyListeners();
  }

  /// Downloads [eventId]'s audio, transcribes it on this device, shows the
  /// text under the player and saves it. Does nothing while it is already
  /// running or done.
  Future<void> transcribe({
    required ChatBackend backend,
    required String roomId,
    required String eventId,
  }) async {
    final owner = BackendSessionOwner(backend);
    final account = owner.accountKey;
    if (account == null || account.isEmpty) {
      owner.release();
      return;
    }
    final key = _key(account, eventId);
    final status = _states[key]?.status;
    if (status == TranscriptStatus.working || status == TranscriptStatus.done) {
      owner.release();
      return;
    }
    _states[key] = TranscriptState.working;
    notifyListeners();
    TranscriptState result;
    try {
      final saved = await store.read(account, eventId);
      if (saved != null && saved.trim().isNotEmpty) {
        result = TranscriptState.done(saved);
      } else {
        final audio = coerceAudioAttachment(
          await mediaLoaderFor(backend, roomId, eventId)(),
        );
        if (!owner.isCurrent) throw const _SessionChanged();
        final text = (await engine.transcribe(audio)).trim();
        if (!owner.isCurrent) throw const _SessionChanged();
        if (text.isEmpty) {
          result = const TranscriptState.failed('No speech was recognised.');
        } else {
          await store.write(account, eventId, text);
          result = TranscriptState.done(text);
        }
      }
    } on _SessionChanged {
      result = TranscriptState.none;
    } on TranscriptionUnavailable catch (error) {
      result = TranscriptState.failed(error.message);
    } catch (_) {
      result = const TranscriptState.failed(
        'Couldn’t transcribe this message.',
      );
    }
    // Signed out or switched account meanwhile: forget the attempt.
    if (!owner.isCurrent) result = TranscriptState.none;
    owner.release();
    if (result.status == TranscriptStatus.none) {
      _states.remove(key);
    } else {
      _states[key] = result;
    }
    notifyListeners();
  }

  /// Forgets every in-memory transcript (saved ones stay saved).
  @visibleForTesting
  void reset() {
    _states.clear();
    _restoring.clear();
    _available = null;
    _availableValue = null;
  }
}
