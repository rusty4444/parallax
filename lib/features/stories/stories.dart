import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat_backend.dart';
import '../../room_events.dart';

/// One 24-hour story update.
@immutable
class Story {
  const Story({
    required this.eventId,
    required this.senderId,
    required this.senderName,
    required this.time,
    this.text = '',
    this.imageUrl,
    this.mine = false,
  });

  final String eventId;
  final String senderId;
  final String senderName;
  final DateTime time;
  final String text;
  final Uri? imageUrl;
  final bool mine;

  static const markerKey = 'net.samrusselltech.parallax.story';
  static const lifetime = Duration(hours: 24);

  bool isActive(DateTime now) => now.difference(time) < lifetime;
}

/// A room that carries stories (mine, or one shared with me).
@immutable
class StoryRoom {
  const StoryRoom({
    required this.roomId,
    required this.name,
    required this.mine,
    this.avatarUrl,
  });
  final String roomId;
  final String name;
  final bool mine;
  final Uri? avatarUrl;
}

/// Stories (WhatsApp Status / Instagram style): opt-in, 24-hour photo/text
/// updates posted to an encrypted room with `m.room.retention` of 24 hours.
class StoriesController extends ChangeNotifier {
  StoriesController({SharedPreferences? preferences}) : _prefs = preferences;

  static final shared = StoriesController();

  static const roomRecordType = 'net.samrusselltech.parallax.story_room';
  static const roomMarkerType = 'net.samrusselltech.parallax.story_room';
  static const _enabledKey = 'parallax.stories.v1.enabled';

  SharedPreferences? _prefs;
  ChatBackend? _backend;
  bool _enabled = false;
  bool _loaded = false;
  String? _myStoryRoomId;
  bool _busy = false;

  bool get enabled => _enabled;
  bool get loaded => _loaded;
  bool get busy => _busy;
  String? get myStoryRoomId => _myStoryRoomId;
  ChatBackend? get backend => _backend;

  matrix.Client? get _client {
    final backend = _backend;
    return backend is MatrixSdkAccess
        ? (backend as MatrixSdkAccess).sdkClient
        : null;
  }

  RoomEventFeatures? get _events {
    final backend = _backend;
    return backend is RoomEventFeatures ? backend as RoomEventFeatures : null;
  }

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  void bindBackend(ChatBackend? backend) {
    if (identical(_backend, backend)) return;
    _backend = backend;
    _myStoryRoomId = null;
    _loaded = false;
    notifyListeners();
    unawaited(load());
  }

  Future<void> load() async {
    try {
      _enabled = (await _preferences()).getBool(_enabledKey) ?? false;
    } catch (_) {
      _enabled = false;
    }
    final client = _client;
    _myStoryRoomId =
        client?.accountData[roomRecordType]?.content['room_id'] as String?;
    _loaded = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    notifyListeners();
    try {
      await (await _preferences()).setBool(_enabledKey, value);
    } catch (_) {}
  }

  bool _current(matrix.Client client) {
    final backend = _backend;
    return backend is MatrixSdkAccess &&
        (backend as MatrixSdkAccess).isSessionCurrent(client);
  }

  /// Creates (once) the encrypted 24-hour story room and records it.
  Future<String> ensureStoryRoom() async {
    final client = _client;
    if (client == null || client.userID == null) {
      throw StateError('Not signed in');
    }
    final existing = _myStoryRoomId;
    if (existing != null && client.getRoomById(existing) != null) {
      return existing;
    }
    if (!client.encryptionEnabled) {
      throw StateError('Set up encryption before posting a story.');
    }
    final roomId = await client.createRoom(
      name: 'My story',
      preset: matrix.CreateRoomPreset.privateChat,
      initialState: [
        matrix.StateEvent(
          type: matrix.EventTypes.Encryption,
          stateKey: '',
          content: {'algorithm': matrix.AlgorithmTypes.megolmV1AesSha2},
        ),
        matrix.StateEvent(
          type: 'm.room.retention',
          stateKey: '',
          content: {'max_lifetime': Story.lifetime.inMilliseconds},
        ),
        matrix.StateEvent(
          type: roomMarkerType,
          stateKey: '',
          content: {'owner': client.userID},
        ),
      ],
    );
    if (!_current(client)) throw StateError('Session changed');
    _myStoryRoomId = roomId;
    notifyListeners();
    try {
      await client.request(
        matrix.RequestType.PUT,
        '/client/v3/user/${Uri.encodeComponent(client.userID!)}'
        '/account_data/$roomRecordType',
        data: {'room_id': roomId},
      );
    } catch (_) {}
    return roomId;
  }

  /// Posts a text and/or photo story. Returns the event ID.
  Future<String> postStory(
    String text, {
    Uint8List? imageBytes,
    String? imageName,
    String? imageMime,
  }) async {
    final client = _client;
    final events = _events;
    if (client == null || events == null) throw StateError('Not signed in');
    final roomId = await ensureStoryRoom();
    if (!_current(client)) throw StateError('Session changed');
    _busy = true;
    notifyListeners();
    try {
      final Map<String, Object?> content;
      if (imageBytes != null) {
        final mxc = await client.uploadContent(
          imageBytes,
          filename: imageName ?? 'story.jpg',
          contentType: imageMime ?? 'image/jpeg',
        );
        if (!_current(client)) throw StateError('Session changed');
        content = {
          'msgtype': matrix.MessageTypes.Image,
          'body': text.trim().isEmpty ? (imageName ?? 'Story') : text.trim(),
          'url': mxc.toString(),
          Story.markerKey: true,
          if (text.trim().isNotEmpty) 'filename': imageName,
        };
      } else {
        if (text.trim().isEmpty) throw StateError('Write a story first.');
        content = {
          'msgtype': matrix.MessageTypes.Text,
          'body': text.trim(),
          Story.markerKey: true,
        };
      }
      final eventId = await events.sendRoomEvent(
        roomId,
        matrix.EventTypes.Message,
        content,
      );
      if (!_current(client)) throw StateError('Session changed');
      return eventId;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Story rooms visible to me: my own plus joined rooms carrying the marker.
  List<StoryRoom> storyRooms() {
    final client = _client;
    if (client == null) return const [];
    final rooms = <StoryRoom>[];
    final mine = _myStoryRoomId;
    for (final room in client.rooms) {
      if (room.membership != matrix.Membership.join) continue;
      final marker = room.getState(roomMarkerType);
      final isMine =
          room.id == mine || marker?.content['owner'] == client.userID;
      if (marker == null && !isMine) continue;
      rooms.add(
        StoryRoom(
          roomId: room.id,
          name: isMine ? 'Your story' : room.name,
          mine: isMine,
          avatarUrl: room.avatar,
        ),
      );
    }
    // My story first.
    rooms.sort((a, b) => (b.mine ? 1 : 0) - (a.mine ? 1 : 0));
    return rooms;
  }

  /// Active (last 24h) stories in a room, oldest first.
  Future<List<Story>> activeStories(String roomId) async {
    final client = _client;
    if (client == null) return const [];
    final room = client.getRoomById(roomId);
    if (room == null) return const [];
    final timeline = await room.getTimeline();
    try {
      if (!_current(client)) return const [];
      final now = DateTime.now();
      final stories = <Story>[];
      for (final event in timeline.events) {
        if (event.type != matrix.EventTypes.Message) continue;
        if (event.redacted) continue;
        if (event.content[Story.markerKey] != true) continue;
        final time = event.originServerTs;
        if (now.difference(time) >= Story.lifetime) continue;
        final msgtype = event.messageType;
        final url = event.content['url'];
        stories.add(
          Story(
            eventId: event.eventId,
            senderId: event.senderId,
            senderName: event.senderFromMemoryOrFallback.calcDisplayname(),
            time: time,
            text: msgtype == matrix.MessageTypes.Image
                ? (event.content['filename'] as String? ?? '')
                : event.text,
            imageUrl: msgtype == matrix.MessageTypes.Image && url is String
                ? Uri.tryParse(url)
                : null,
            mine: event.senderId == client.userID,
          ),
        );
      }
      stories.sort((a, b) => a.time.compareTo(b.time));
      return stories;
    } finally {
      timeline.cancelSubscriptions();
    }
  }

  /// Downloads (and decrypts) a story image's bytes for display.
  Future<Uint8List?> storyImageBytes(String roomId, String eventId) async {
    final client = _client;
    if (client == null) return null;
    final room = client.getRoomById(roomId);
    if (room == null) return null;
    try {
      final timeline = await room.getTimeline(eventContextId: eventId);
      try {
        if (!_current(client)) return null;
        matrix.Event? event;
        for (final candidate in timeline.events) {
          if (candidate.eventId == eventId) {
            event = candidate;
            break;
          }
        }
        if (event == null || event.redacted) return null;
        final file = await event.downloadAndDecryptAttachment(
          getThumbnail: true,
        );
        return file.bytes;
      } finally {
        timeline.cancelSubscriptions();
      }
    } catch (_) {
      return null;
    }
  }
}

class StoriesScope extends InheritedNotifier<StoriesController> {
  const StoriesScope({
    super.key,
    required StoriesController controller,
    required super.child,
  }) : super(notifier: controller);

  StoriesController get controller => notifier!;

  static StoriesController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StoriesScope>()?.controller;
}
