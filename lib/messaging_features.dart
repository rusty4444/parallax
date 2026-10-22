import 'dart:typed_data';

import 'chat_backend.dart';

enum DeliveryState { queued, sending, failed, sent }

class PendingSend {
  const PendingSend({
    required this.id,
    required this.roomId,
    required this.body,
    required this.state,
    required this.createdAt,
    this.fileName,
    this.error,
    this.progress,
  });
  final String id;
  final String roomId;
  final String body;
  final DeliveryState state;
  final DateTime createdAt;
  final String? fileName;
  final String? error;
  final double? progress;
}

class MediaSelection {
  const MediaSelection({
    required this.bytes,
    required this.name,
    required this.mimeType,
    this.durationMs,
  });
  final Uint8List bytes;
  final String name;
  final String mimeType;
  final int? durationMs;
}

class DirectoryUser {
  const DirectoryUser({required this.id, this.name, this.avatar});
  final String id;
  final String? name;
  final Uri? avatar;
}

class SpaceSummary {
  const SpaceSummary({
    required this.id,
    required this.name,
    this.topic,
    this.members = 0,
    this.isSpace = false,
    this.joined = false,
  });
  final String id;
  final String name;
  final String? topic;
  final int members;
  final bool isSpace;
  final bool joined;
}

class SpacePage {
  const SpacePage(this.rooms, {this.nextBatch});
  final List<SpaceSummary> rooms;
  final String? nextBatch;
}

class ThreadPage {
  const ThreadPage(this.messages, {this.nextBatch});
  final List<ChatEntry> messages;
  final String? nextBatch;
}

class MessageReader {
  const MessageReader({required this.userId, required this.name, this.time});
  final String userId;
  final String name;
  final DateTime? time;
}

class ProviderDiscovery {
  const ProviderDiscovery({
    required this.homeserver,
    required this.password,
    required this.sso,
    required this.oidc,
  });
  final Uri homeserver;
  final bool password;
  final bool sso;
  final bool oidc;
}

/// Optional feature surface: old test/demonstration backends remain usable.
abstract interface class MessagingFeatures {
  String get accountKey;
  List<PendingSend> get pendingSends;
  Future<void> queueMessage(
    String roomId,
    String text, {
    String? replyToId,
    String? editEventId,
    String? threadRootId,
  });
  Future<void> queueMedia(
    String roomId,
    MediaSelection media, {
    String? caption,
    String? replyToId,
    String? threadRootId,
  });
  Future<void> retryPending(String id);
  Future<void> discardPending(String id);
  void cancelPending(String id);
  Future<List<DirectoryUser>> searchUsers(String query);
  List<SpaceSummary> get spaces;
  Future<SpacePage> loadSpace(String spaceId, {String? nextBatch});
  Future<ThreadPage> loadThread(
    String roomId,
    String rootEventId, {
    String? nextBatch,
  });
  Future<List<MessageReader>> messageReaders(String roomId, String eventId);
  bool isFavourite(String roomId);
  Future<void> setFavourite(String roomId, bool favourite);
  Future<ProviderDiscovery> discoverProvider(String input);
  Future<void> loginWithBrowser(
    ProviderDiscovery discovery, {
    required bool oidc,
  });
}
