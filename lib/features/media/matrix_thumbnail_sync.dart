import 'dart:typed_data';

import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../media_disk_cache.dart';
import '../../media_download.dart';
import '../../room_events.dart';
import 'thumbnail_sync.dart';

/// Stored events read per chat: about what a chat shows when it opens.
const thumbnailSyncEventsPerRoom = 100;

/// [ThumbnailSyncSource] over the live SDK client. For each joined chat it
/// saves the chat picture (or the people pictured for an unnamed chat), the
/// senders' profile photos and the image, sticker and video thumbnails of
/// the history stored on this device. Invitations are skipped, so nothing
/// is fetched from people who haven't been accepted yet.
class MatrixThumbnailSyncSource implements ThumbnailSyncSource {
  MatrixThumbnailSyncSource(this.backend)
    : assert(backend is MatrixSdkAccess && backend is MediaCacheAccess);

  final ChatBackend backend;
  MatrixSdkAccess get _sdk => backend as MatrixSdkAccess;

  @override
  Future<ThumbnailStore?> thumbnailStore() =>
      (backend as MediaCacheAccess).thumbnailStore();

  @override
  Future<ThumbnailSyncPass?> beginThumbnailSync() async {
    final client = _sdk.sdkClient;
    if (client == null || !_sdk.isSessionCurrent(client)) return null;
    final store = await thumbnailStore();
    if (store == null || !_sdk.isSessionCurrent(client)) return null;
    final rooms = {
      for (final room in backend.rooms)
        if (!room.invited) room.id: room,
    };
    return _MatrixThumbnailSyncPass(backend, _sdk, client, store, rooms);
  }
}

class _MatrixThumbnailSyncPass implements ThumbnailSyncPass {
  _MatrixThumbnailSyncPass(
    this.backend,
    this.sdk,
    this.client,
    this.store,
    this.rooms,
  );

  final ChatBackend backend;
  final MatrixSdkAccess sdk;
  final matrix.Client client;
  @override
  final ThumbnailStore store;
  final Map<String, ChatRoom> rooms;

  @override
  List<String> get roomIds => rooms.keys.toList(growable: false);

  @override
  bool get isCurrent => sdk.isSessionCurrent(client);

  ThumbnailJob _avatar(Uri url) =>
      ThumbnailJob(avatarCacheKey(url), () => backend.loadAvatar(url));

  ThumbnailJob _media(Uri mxc) =>
      ThumbnailJob(mediaCacheKeyForMxc(mxc), () => _download(mxc));

  Future<Uint8List?> _download(Uri mxc) async {
    final uri = await mxc.getDownloadUri(client);
    final homeserver = client.homeserver;
    final token = client.accessToken;
    if (!isCurrent || homeserver == null || token == null) {
      throw StateError('Session changed');
    }
    return downloadMatrixMedia(
      httpClient: client.httpClient,
      homeserver: homeserver,
      uri: uri,
      accessToken: token,
      maxBytes: MediaDiskCache.defaultMaxFileBytes,
    );
  }

  @override
  Future<List<ThumbnailJob>> jobsFor(String roomId) async {
    final summary = rooms[roomId];
    if (summary == null || !isCurrent) return const [];
    final jobs = <ThumbnailJob>[
      if (summary.avatarUrl case final url? when url.scheme == 'mxc')
        _avatar(url),
      for (final hero in summary.heroes)
        if (hero.url case final url? when url.scheme == 'mxc') _avatar(url),
    ];
    final room = client.getRoomById(roomId);
    if (room == null) return jobs;
    final List<matrix.Event> events;
    try {
      events = await client.database.getEventList(
        room,
        limit: thumbnailSyncEventsPerRoom,
      );
    } catch (_) {
      return jobs;
    }
    final senders = <String>{};
    for (var event in events) {
      if (!isCurrent) break;
      if (event.type == matrix.EventTypes.Encrypted) {
        final encryption = client.encryption;
        if (encryption == null || !client.encryptionEnabled) continue;
        try {
          event = await encryption.decryptRoomEvent(event);
        } catch (_) {
          continue;
        }
      }
      if (previewMxcFor(event) case final mxc?) jobs.add(_media(mxc));
      if (senders.add(event.senderId)) {
        // Only member state already in memory: looking members up would
        // start database and server requests for every sender.
        final avatar = room
            .getState(matrix.EventTypes.RoomMember, event.senderId)
            ?.content['avatar_url'];
        final url = avatar is String ? Uri.tryParse(avatar) : null;
        if (url != null && url.scheme == 'mxc') jobs.add(_avatar(url));
      }
    }
    return jobs;
  }
}

/// The media a chat shows for [event] in the timeline: the thumbnail of an
/// image, sticker or video, or a small image's original when it has no
/// thumbnail. Null for anything else.
Uri? previewMxcFor(matrix.Event event) {
  if (event.redacted ||
      event.relationshipType == matrix.RelationshipTypes.edit) {
    return null;
  }
  final sticker = event.type == matrix.EventTypes.Sticker;
  if (!sticker && event.type != matrix.EventTypes.Message) return null;
  final msgtype = sticker ? null : event.messageType;
  final image = sticker || msgtype == matrix.MessageTypes.Image;
  final video = msgtype == matrix.MessageTypes.Video;
  if (!image && !video) return null;
  if (event.hasThumbnail) {
    final thumbnail = event.thumbnailMxcUrl;
    return thumbnail?.scheme == 'mxc' ? thumbnail : null;
  }
  if (!image || !event.hasAttachment) return null;
  final size = event.infoMap['size'];
  if (size is int && size > MediaDiskCache.defaultMaxFileBytes) return null;
  final original = event.attachmentMxcUrl;
  return original?.scheme == 'mxc' ? original : null;
}
