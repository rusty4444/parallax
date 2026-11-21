import 'dart:async';
import 'dart:typed_data';

import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../room_events.dart';
import 'chat_export.dart';

/// Backend surface of the chat-export module.
abstract interface class ChatExportFeatures {
  /// Up to [limit] decrypted messages, oldest first.
  Future<List<ExportMessage>> loadMessages(String roomId, int limit);

  /// Downloads (and decrypts) a media message's original bytes.
  Future<Uint8List?> mediaBytes(String roomId, String eventId);
}

final _features = Expando<ChatExportFeatures>();

ChatExportFeatures? chatExportFeaturesOf(ChatBackend backend) {
  if (backend is ChatExportFeatures) return backend as ChatExportFeatures;
  if (backend is MatrixSdkAccess) {
    return _features[backend] ??= MatrixChatExport(backend);
  }
  return null;
}

class MatrixChatExport implements ChatExportFeatures {
  MatrixChatExport(this.backend);

  final ChatBackend backend;
  MatrixSdkAccess get _sdk => backend as MatrixSdkAccess;

  matrix.Client _client() {
    final client = _sdk.sdkClient;
    if (client == null || !client.isLogged()) throw StateError('Not signed in');
    return client;
  }

  bool _current(matrix.Client client) => _sdk.isSessionCurrent(client);

  @override
  Future<List<ExportMessage>> loadMessages(String roomId, int limit) async {
    final client = _client();
    final room = client.getRoomById(roomId);
    if (room == null) throw StateError('Room is not joined');
    final timeline = await room.getTimeline();
    try {
      // Page backwards until we have enough messages or run out of history.
      var guard = 0;
      while (timeline.events.length < limit &&
          timeline.canRequestHistory &&
          guard < 40) {
        await timeline.requestHistory(historyCount: 100);
        if (!_current(client)) return const [];
        guard++;
      }
      if (!_current(client)) return const [];
      final messages = <ExportMessage>[];
      // events are newest-first; take the newest [limit] then reverse.
      final newest = timeline.events.take(limit).toList();
      for (final event in newest.reversed) {
        if (event.type != matrix.EventTypes.Message) continue;
        if (event.redacted) continue;
        final display = event.getDisplayEvent(timeline);
        final msgtype = display.messageType;
        String? mediaKind;
        String? mediaName;
        switch (msgtype) {
          case matrix.MessageTypes.Image:
            mediaKind = 'image';
          case matrix.MessageTypes.Video:
            mediaKind = 'video';
          case matrix.MessageTypes.Audio:
            mediaKind = 'audio';
          case matrix.MessageTypes.File:
            mediaKind = 'file';
        }
        if (mediaKind != null) {
          mediaName = display.content['filename'] as String? ?? display.text;
        }
        messages.add(
          ExportMessage(
            eventId: event.eventId,
            time: event.originServerTs,
            sender: event.senderFromMemoryOrFallback.calcDisplayname(),
            body: display.text,
            mediaKind: mediaKind,
            mediaName: mediaName,
          ),
        );
      }
      return messages;
    } finally {
      timeline.cancelSubscriptions();
    }
  }

  @override
  Future<Uint8List?> mediaBytes(String roomId, String eventId) async {
    final client = _client();
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
        final file = await event.downloadAndDecryptAttachment();
        return file.bytes;
      } finally {
        timeline.cancelSubscriptions();
      }
    } catch (_) {
      return null;
    }
  }
}
