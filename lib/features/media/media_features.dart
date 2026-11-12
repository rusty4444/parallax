import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../media_download.dart';
import '../../room_events.dart';
import '../../timeline_kinds.dart';
import 'media_content.dart';

const maxPreviewBytes = 4 * 1024 * 1024;
const maxOriginalBytes = 25 * 1024 * 1024;

/// One page of a room's media history, newest first.
class MediaHistoryPage {
  const MediaHistoryPage(this.items, {this.nextBatch});
  final List<ChatEntry> items;

  /// Pagination token for older history; null when the start was reached.
  final String? nextBatch;
}

/// Media access for the media module, independent of the active timeline.
abstract interface class MediaFeatures {
  /// Decrypted preview bytes: the thumbnail, or a small original image or
  /// sticker when no thumbnail exists. Null when no bounded preview exists.
  Future<Uint8List?> loadPreview(
    String roomId,
    String eventId, {
    int maxBytes = maxPreviewBytes,
  });

  /// The decrypted original attachment, bounded to [maxBytes].
  Future<DownloadedAttachment> loadOriginal(
    String roomId,
    String eventId, {
    int maxBytes = maxOriginalBytes,
  });

  /// Older media events (images, videos, files, audio, voice, stickers),
  /// paginating server history from [from] (null = newest).
  Future<MediaHistoryPage> loadMediaHistory(String roomId, {String? from});

  /// Redacts a media event (the server enforces permission).
  Future<void> deleteMedia(String roomId, String eventId);
}

final _cache = Expando<MatrixMediaFeatures>('media features');

MediaFeatures? mediaFeaturesOf(ChatBackend backend) => backend is MediaFeatures
    ? backend as MediaFeatures
    : (backend is MatrixSdkAccess && backend is RoomEventFeatures
          ? _cache[backend] ??= MatrixMediaFeatures(backend)
          : null);

/// [MediaFeatures] over the live SDK client. Reads only; deletion goes
/// through [RoomEventFeatures.redactEvent].
class MatrixMediaFeatures implements MediaFeatures {
  MatrixMediaFeatures(this.backend);

  final ChatBackend backend;
  MatrixSdkAccess get _sdk => backend as MatrixSdkAccess;

  matrix.Client? _cacheOwner;
  final _previews = <String, Uint8List>{};
  final _inFlight = <String, Future<Uint8List?>>{};
  int _previewBytes = 0;
  int _active = 0;
  final _waiters = Queue<Completer<void>>();

  matrix.Client _client() {
    final client = _sdk.sdkClient;
    if (client == null || !_sdk.isSessionCurrent(client)) {
      throw StateError('Media is unavailable while signed out');
    }
    if (!identical(client, _cacheOwner)) {
      _previews.clear();
      _inFlight.clear();
      _previewBytes = 0;
      _originals.clear();
      _originalsInFlight.clear();
      _originalBytes = 0;
      _cacheOwner = client;
    }
    return client;
  }

  void _requireCurrent(matrix.Client client) {
    if (!_sdk.isSessionCurrent(client)) throw StateError('Session changed');
  }

  Future<T> _limited<T>(Future<T> Function() work) async {
    if (_active >= 4) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    } else {
      _active++;
    }
    try {
      return await work();
    } finally {
      if (_waiters.isNotEmpty) {
        _waiters.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }

  Future<matrix.Event?> _event(
    matrix.Client client,
    String roomId,
    String eventId,
  ) async {
    final room = client.getRoomById(roomId);
    if (room == null) return null;
    final event = await room.getEventById(eventId);
    _requireCurrent(client);
    if (event == null ||
        event.redacted ||
        !{
          matrix.EventTypes.Message,
          matrix.EventTypes.Sticker,
        }.contains(event.type)) {
      return null;
    }
    return event;
  }

  Future<Uint8List> Function(Uri) _downloader(
    matrix.Client client,
    int maxBytes,
  ) => (uri) {
    final homeserver = client.homeserver;
    final token = client.accessToken;
    if (homeserver == null || token == null) {
      throw StateError('Media homeserver is unavailable');
    }
    return downloadMatrixMedia(
      httpClient: client.httpClient,
      homeserver: homeserver,
      uri: uri,
      accessToken: token,
      maxBytes: maxBytes,
    );
  };

  @override
  Future<Uint8List?> loadPreview(
    String roomId,
    String eventId, {
    int maxBytes = maxPreviewBytes,
  }) {
    final matrix.Client client;
    try {
      client = _client();
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    final key = '$roomId/$eventId/$maxBytes';
    final cached = _previews.remove(key);
    if (cached != null) {
      _previews[key] = cached;
      return Future.value(cached);
    }
    return _inFlight[key] ??= _fetchPreview(client, roomId, eventId, maxBytes)
        .whenComplete(() {
          if (identical(client, _cacheOwner)) _inFlight.remove(key);
        });
  }

  Future<Uint8List?> _fetchPreview(
    matrix.Client client,
    String roomId,
    String eventId,
    int maxBytes,
  ) => _limited(() async {
    _requireCurrent(client);
    final event = await _event(client, roomId, eventId);
    if (event == null) return null;
    final imageLike =
        event.type == matrix.EventTypes.Sticker ||
        event.messageType == matrix.MessageTypes.Image;
    if (!event.hasThumbnail) {
      // Only images and stickers can fall back to their original as preview.
      final declared = event.infoMap['size'];
      if (!imageLike || (declared is int && declared > maxBytes)) return null;
    }
    final file = await event.downloadAndDecryptAttachment(
      getThumbnail: true,
      downloadCallback: _downloader(client, maxBytes),
    );
    _requireCurrent(client);
    final bytes = file.bytes;
    if (bytes.isEmpty || bytes.lengthInBytes > maxBytes) return null;
    if (!identical(client, _cacheOwner)) return bytes;
    final key = '$roomId/$eventId/$maxBytes';
    if (bytes.lengthInBytes <= 2 * 1024 * 1024) {
      _previews[key] = bytes;
      _previewBytes += bytes.lengthInBytes;
      while (_previewBytes > 24 * 1024 * 1024 && _previews.isNotEmpty) {
        final oldest = _previews.keys.first;
        _previewBytes -= _previews.remove(oldest)!.lengthInBytes;
      }
    }
    return bytes;
  });

  /// Small originals (the animated GIF/WebP the timeline plays, at most
  /// 4 MB) are kept like previews: a bubble built again (scrolling back to
  /// it) would otherwise download, decrypt and decode the same file again.
  static const _maxCachedOriginal = 4 * 1024 * 1024;
  final _originals = <String, DownloadedAttachment>{};
  final _originalsInFlight = <String, Future<DownloadedAttachment>>{};
  int _originalBytes = 0;

  @override
  Future<DownloadedAttachment> loadOriginal(
    String roomId,
    String eventId, {
    int maxBytes = maxOriginalBytes,
  }) {
    final matrix.Client client;
    try {
      client = _client();
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    if (maxBytes > _maxCachedOriginal) {
      return _fetchOriginal(client, roomId, eventId, maxBytes);
    }
    final key = '$roomId/$eventId/$maxBytes';
    final cached = _originals.remove(key);
    if (cached != null) {
      _originals[key] = cached;
      return Future.value(cached);
    }
    return _originalsInFlight[key] ??=
        _fetchOriginal(client, roomId, eventId, maxBytes)
            .then((file) {
              if (identical(client, _cacheOwner)) {
                _originals[key] = file;
                _originalBytes += file.bytes.lengthInBytes;
                while (_originalBytes > 16 * 1024 * 1024 &&
                    _originals.isNotEmpty) {
                  final oldest = _originals.keys.first;
                  _originalBytes -= _originals
                      .remove(oldest)!
                      .bytes
                      .lengthInBytes;
                }
              }
              return file;
            })
            .whenComplete(() {
              if (identical(client, _cacheOwner)) {
                _originalsInFlight.remove(key);
              }
            });
  }

  Future<DownloadedAttachment> _fetchOriginal(
    matrix.Client client,
    String roomId,
    String eventId,
    int maxBytes,
  ) async {
    final event = await _event(client, roomId, eventId);
    if (event == null || !event.hasAttachment) {
      throw StateError('Attachment unavailable');
    }
    final declared = event.infoMap['size'];
    if (declared is int && declared > maxBytes) {
      throw StateError('Attachment is too large');
    }
    final file = await event.downloadAndDecryptAttachment(
      downloadCallback: _downloader(client, maxBytes),
    );
    _requireCurrent(client);
    if (file.bytes.isEmpty || file.bytes.lengthInBytes > maxBytes) {
      throw StateError('Attachment unavailable');
    }
    return DownloadedAttachment(
      name: file.name,
      mimeType: file.mimeType,
      bytes: file.bytes,
    );
  }

  @override
  Future<MediaHistoryPage> loadMediaHistory(
    String roomId, {
    String? from,
  }) async {
    final client = _client();
    final room = client.getRoomById(roomId);
    if (room == null) throw StateError('Room unavailable');
    final filter = jsonEncode({
      'types': [
        matrix.EventTypes.Message,
        matrix.EventTypes.Encrypted,
        matrix.EventTypes.Sticker,
      ],
      'lazy_load_members': true,
      // Encrypted content hides URLs from the server; filter locally instead.
      if (!room.encrypted) 'contains_url': true,
    });
    final items = <ChatEntry>[];
    var token = from;
    // Bound requests per call so a text-heavy encrypted room cannot spin.
    for (var request = 0; request < 4 && items.length < 24; request++) {
      final response = await client.getRoomEvents(
        roomId,
        matrix.Direction.b,
        from: token,
        limit: 80,
        filter: filter,
      );
      _requireCurrent(client);
      for (final raw in response.chunk) {
        var event = matrix.Event.fromMatrixEvent(raw, room);
        if (event.type == matrix.EventTypes.Encrypted) {
          final encryption = client.encryption;
          if (encryption == null || !client.encryptionEnabled) continue;
          try {
            event = await encryption.decryptRoomEvent(event);
          } catch (_) {
            continue;
          }
          _requireCurrent(client);
        }
        final entry = projectMediaEvent(event, client.userID);
        if (entry != null) items.add(entry);
      }
      final end = response.end;
      if (end == null || end == token || response.chunk.isEmpty) {
        token = null;
        break;
      }
      token = end;
    }
    return MediaHistoryPage(List.unmodifiable(items), nextBatch: token);
  }

  @override
  Future<void> deleteMedia(String roomId, String eventId) =>
      (backend as RoomEventFeatures).redactEvent(roomId, eventId);
}

/// Projects an SDK event into a media [ChatEntry], or null when it is not a
/// visible media message (redacted, edits, undecryptable, text …).
ChatEntry? projectMediaEvent(matrix.Event event, String? ownUserId) {
  if (event.redacted ||
      event.relationshipType == matrix.RelationshipTypes.edit) {
    return null;
  }
  final content = Map<String, Object?>.unmodifiable(event.content);
  final kind = entryKindFor(
    type: event.type,
    msgtype: event.type == matrix.EventTypes.Message ? event.messageType : null,
    content: content,
    redacted: false,
  );
  if (!isMediaKind(kind) || !event.hasAttachment) return null;
  final member = event.room.getState(
    matrix.EventTypes.RoomMember,
    event.senderId,
  );
  final name = member?.content['displayname'];
  return ChatEntry(
    id: event.eventId,
    sender: event.senderId,
    body: content['body'] is String ? content['body'] as String : '',
    time: event.originServerTs,
    mine: event.senderId == ownUserId,
    isImage: kind == EntryKind.image || kind == EntryKind.sticker,
    isAttachment: isFileMediaKind(kind) || kind == EntryKind.video,
    kind: kind,
    eventType: event.type,
    msgtype: event.type == matrix.EventTypes.Message ? event.messageType : null,
    content: content,
    senderName: name is String ? name : null,
  );
}
