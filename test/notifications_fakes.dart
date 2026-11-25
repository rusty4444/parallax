// Shared fakes for the notifications module tests (not a test file itself).
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:parallax/features/notifications/notification_model.dart';
import 'package:parallax/features/notifications/notification_renderer.dart';
import 'package:parallax/features/notifications/notification_store.dart';
import 'package:parallax/features/notifications/push_handoff.dart';
import 'package:parallax/push_notifications.dart';

/// Records posted, cancelled and generic notifications.
class FakeSurface implements NotificationSurface {
  final shown = <RenderedNotification>[];
  final cancelled = <int>[];
  final generic = <PushEnvelope>[];
  bool failShow = false;

  @override
  Future<void> show(RenderedNotification notification) async {
    if (failShow) throw StateError('plugin failed');
    shown.add(notification);
  }

  @override
  Future<void> cancel(int id) async => cancelled.add(id);

  @override
  Future<void> showGeneric(PushEnvelope envelope) async =>
      generic.add(envelope);

  int cancelledAll = 0;

  @override
  Future<void> cancelAll() async => cancelledAll++;

  RenderedNotification? byId(int id) =>
      shown.lastWhere((n) => n.id == id, orElse: () => _none);
  static final _none = RenderedNotification(
    id: -1,
    title: null,
    body: null,
    details: const NotificationDetails(),
  );
}

/// In-memory store for widget tests (real file I/O can stall fake async).
class MemoryNotificationStore extends NotificationStore {
  MemoryNotificationStore() : super(Directory('unused-notification-store'));

  NotificationPreferences preferences = const NotificationPreferences();
  final rooms = <String, RoomNotificationThread>{};
  final pending = <PendingReply>[];
  int clears = 0;
  bool failWrites = false;

  @override
  Future<NotificationPreferences> readPreferences() async => preferences;

  @override
  Future<void> writePreferences(NotificationPreferences value) async {
    if (failWrites) throw const FileSystemException('read-only');
    preferences = value;
  }

  @override
  Future<RoomNotificationThread> appendEvent(
    String account,
    ResolvedPushEvent event,
  ) async {
    final existing = rooms[event.roomId];
    final thread = RoomNotificationThread(
      roomId: event.roomId,
      roomName: event.roomName,
      isDirect: event.isDirect,
      latestEventId: event.eventId,
      lines: [...?existing?.lines, event.line],
    );
    return rooms[event.roomId] = thread;
  }

  @override
  Future<RoomNotificationThread?> appendOwnLine(
    String account,
    String roomId,
    NotificationLine line,
  ) async {
    final existing = rooms[roomId];
    if (existing == null) return null;
    return rooms[roomId] = RoomNotificationThread(
      roomId: roomId,
      roomName: existing.roomName,
      isDirect: existing.isDirect,
      latestEventId: existing.latestEventId,
      lines: [...existing.lines, line],
    );
  }

  @override
  Future<List<RoomNotificationThread>> threads(String account) async =>
      rooms.values.toList();

  @override
  Future<RoomNotificationThread?> thread(String account, String roomId) async =>
      rooms[roomId];

  @override
  Future<Set<String>> removeRooms(
    String account,
    Iterable<String> roomIds,
  ) async => {
    for (final id in roomIds)
      if (rooms.remove(id) != null) id,
  };

  @override
  Future<void> addPendingReply(PendingReply reply) async => pending.add(reply);

  @override
  Future<List<PendingReply>> takePendingReplies() async {
    final taken = List.of(pending);
    pending.clear();
    return taken;
  }

  @override
  Future<void> clearHistory() async {
    clears++;
    rooms.clear();
    pending.clear();
  }
}

/// In-memory stand-in for IsolateNameServer.
class FakeDirectory implements PortDirectory {
  final ports = <String, SendPort>{};
  int removals = 0;

  @override
  SendPort? lookup(String name) => ports[name];

  @override
  bool register(SendPort port, String name) {
    if (ports.containsKey(name)) return false;
    ports[name] = port;
    return true;
  }

  @override
  bool remove(String name) {
    removals++;
    return ports.remove(name) != null;
  }
}
