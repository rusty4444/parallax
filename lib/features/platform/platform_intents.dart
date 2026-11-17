// Android share, VIEW and chat-shortcut intents forwarded by MainActivity
// over the `parallax/platform_intents` MethodChannel.
//
// Kotlin copies shared content:// streams into the app cache (capped at
// [maxSharedFileBytes] each, [maxSharedFiles] items) and queues one payload per
// intent. Dart pulls the queue on start and whenever Kotlin signals `pending`,
// so cold-start intents are never lost to a missing handler.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'matrix_links.dart';

/// Same cap as the composer and outbox.
const maxSharedFileBytes = 20 * 1024 * 1024;
const maxSharedFiles = 10;

/// Matrix events are capped at 64 KiB; leave room for the envelope.
const maxSharedTextLength = 32 * 1024;

/// Kotlin writes shared copies under `<cache>/shared_intents/<id>/`.
const sharedCacheSegment = '/shared_intents/';

@immutable
class SharedFile {
  const SharedFile({
    required this.path,
    required this.name,
    required this.mimeType,
    required this.size,
  });
  final String path;
  final String name;
  final String mimeType;
  final int size;

  bool get isImage => mimeType.startsWith('image/');
  bool get isVideo => mimeType.startsWith('video/');
  bool get isAudio => mimeType.startsWith('audio/');
}

@immutable
sealed class PlatformIntent {
  const PlatformIntent();
}

/// ACTION_SEND / ACTION_SEND_MULTIPLE.
@immutable
final class ShareIntent extends PlatformIntent {
  const ShareIntent({
    this.text,
    this.files = const [],
    this.skipped = 0,
    this.tooLarge = 0,
    this.targetRoomId,
  });

  /// Shared text (EXTRA_TEXT, or EXTRA_SUBJECT when there is no text).
  final String? text;
  final List<SharedFile> files;

  /// The chat picked from Android's share suggestions (a sharing shortcut,
  /// see share_shortcuts.dart); null when Parallax itself was picked.
  final String? targetRoomId;

  /// Items that could not be read or were refused (non-content URIs, the
  /// app's own files, unreadable streams, beyond [maxSharedFiles]).
  final int skipped;

  /// Items over [maxSharedFileBytes].
  final int tooLarge;

  bool get isEmpty => (text?.trim().isEmpty ?? true) && files.isEmpty;
}

/// ACTION_VIEW for a matrix.to or `matrix:` link.
@immutable
final class LinkIntent extends PlatformIntent {
  const LinkIntent(this.uri);
  final Uri uri;
}

/// A chat shortcut tapped under the launcher icon: open that chat.
@immutable
final class OpenRoomIntent extends PlatformIntent {
  const OpenRoomIntent(this.roomId);
  final String roomId;
}

/// Longest room ID Matrix allows.
const maxRoomIdLength = 255;

/// A room ID from the channel, or null for anything that is not one.
String? _roomId(Object? value) =>
    value is String &&
        value.length > 1 &&
        value.length <= maxRoomIdLength &&
        value.startsWith('!') &&
        !value.contains(RegExp(r'[\u0000-\u0020\u007f]'))
    ? value
    : null;

/// Validates a payload from the channel. Returns null for anything malformed.
PlatformIntent? parsePlatformIntent(Object? raw) {
  if (raw is! Map) return null;
  final kind = raw['kind'];
  if (kind == 'room') {
    final roomId = _roomId(raw['roomId']);
    return roomId == null ? null : OpenRoomIntent(roomId);
  }
  if (kind == 'link') {
    final value = raw['uri'];
    if (value is! String || value.length > maxMatrixLinkLength) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || !isMatrixLinkCandidate(uri)) return null;
    return LinkIntent(uri);
  }
  if (kind != 'share') return null;
  var skipped = _count(raw['skipped']);
  final tooLarge = _count(raw['tooLarge']);
  final files = <SharedFile>[];
  final rawFiles = raw['files'];
  if (rawFiles is List) {
    for (final item in rawFiles) {
      final file = _parseFile(item);
      if (file == null || files.length >= maxSharedFiles) {
        skipped++;
      } else {
        files.add(file);
      }
    }
  }
  final text = _text(raw['text']) ?? _text(raw['subject']);
  final intent = ShareIntent(
    text: text,
    files: List.unmodifiable(files),
    skipped: skipped,
    tooLarge: tooLarge,
    targetRoomId: _roomId(raw['roomId']),
  );
  return intent.isEmpty && skipped == 0 && tooLarge == 0 ? null : intent;
}

int _count(Object? value) =>
    value is int && value > 0 && value < 1000 ? value : 0;

String? _text(Object? value) {
  if (value is! String) return null;
  final text = value.trim();
  if (text.isEmpty) return null;
  return text.length > maxSharedTextLength
      ? text.substring(0, maxSharedTextLength)
      : text;
}

SharedFile? _parseFile(Object? raw) {
  if (raw is! Map) return null;
  final path = raw['path'];
  final size = raw['size'];
  if (path is! String ||
      !path.startsWith('/') ||
      !path.contains(sharedCacheSegment) ||
      path.contains('/../') ||
      path.endsWith('/..') ||
      size is! int ||
      size <= 0 ||
      size > maxSharedFileBytes) {
    return null;
  }
  return SharedFile(
    path: path,
    name: sanitiseSharedName(raw['name']),
    mimeType: sanitiseMimeType(raw['mimeType']),
    size: size,
  );
}

/// A display/file name without path separators or control characters.
String sanitiseSharedName(Object? value) {
  var name = value is String ? value : '';
  name = name.split(RegExp(r'[/\\]')).last;
  name = name.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), '').trim();
  if (name.isEmpty || name == '.' || name == '..') return 'shared-file';
  return name.length > 128 ? name.substring(name.length - 128) : name;
}

/// `type/subtype`, lower-cased, or `application/octet-stream`.
String sanitiseMimeType(Object? value) {
  if (value is! String) return 'application/octet-stream';
  final mime = value.split(';').first.trim().toLowerCase();
  return RegExp(
            r'^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$',
          ).hasMatch(mime) &&
          mime.length <= 127
      ? mime
      : 'application/octet-stream';
}

/// Source of incoming share/VIEW intents.
abstract interface class PlatformIntentSource {
  /// Pending and future intents. Single subscriber.
  Stream<PlatformIntent> get intents;

  /// Deletes cached copies of shared files (after sending or cancelling).
  Future<void> discard(Iterable<SharedFile> files);
}

/// Production source backed by MainActivity's channel.
class MethodChannelPlatformIntents implements PlatformIntentSource {
  MethodChannelPlatformIntents._();
  static final instance = MethodChannelPlatformIntents._();

  static const channel = MethodChannel('parallax/platform_intents');

  StreamController<PlatformIntent>? _controller;
  bool _pulling = false;
  bool _pullAgain = false;

  @override
  Stream<PlatformIntent> get intents {
    final existing = _controller;
    if (existing != null && !existing.isClosed && existing.hasListener) {
      // A replacement host (account change) takes over the queue.
      unawaited(existing.close());
    }
    late final StreamController<PlatformIntent> controller;
    controller = StreamController<PlatformIntent>(
      onListen: () {
        channel.setMethodCallHandler((call) async {
          if (call.method == 'pending') unawaited(_pull());
          return null;
        });
        unawaited(_pull());
      },
      onCancel: () {
        if (identical(_controller, controller)) {
          channel.setMethodCallHandler(null);
          _controller = null;
        }
      },
    );
    _controller = controller;
    return controller.stream;
  }

  Future<void> _pull() async {
    if (_pulling) {
      _pullAgain = true;
      return;
    }
    _pulling = true;
    try {
      do {
        _pullAgain = false;
        final controller = _controller;
        if (controller == null || controller.isClosed) return;
        final List<Object?>? pending;
        try {
          pending = await channel.invokeListMethod<Object?>('takePending');
        } on MissingPluginException {
          return;
        } on PlatformException {
          return;
        }
        for (final raw in pending ?? const <Object?>[]) {
          final intent = parsePlatformIntent(raw);
          final current = _controller;
          if (intent == null) continue;
          if (current == null || current.isClosed) {
            if (intent is ShareIntent) await discard(intent.files);
            continue;
          }
          current.add(intent);
        }
      } while (_pullAgain);
    } finally {
      _pulling = false;
    }
  }

  @override
  Future<void> discard(Iterable<SharedFile> files) async {
    final paths = [for (final file in files) file.path];
    if (paths.isEmpty) return;
    try {
      await channel.invokeMethod<void>('discard', {'paths': paths});
    } on MissingPluginException {
      // Not on Android (tests/desktop): nothing was copied.
    } on PlatformException {
      // Kotlin also prunes stale share copies on the next start.
    }
  }
}
