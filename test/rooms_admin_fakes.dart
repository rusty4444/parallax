// Shared fake for the room administration widget tests (not a test file).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/rooms_admin/rooms_admin_features.dart';
import 'package:parallax/features/rooms_admin/rooms_admin_models.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/room_details.dart';
import 'package:parallax/room_events.dart';

import 'widget_test.dart' show FakeBackend;

const roomId = '!project:example.org';
const me = '@me:example.org';
const guest = '@guest:example.org';
const knocker = '@knocker:example.org';

final palette = paletteFor(VisualTheme.parallax);

RoomStateEntry memberState(
  String id,
  String membership, {
  String? name,
  String? reason,
}) => RoomStateEntry('m.room.member', id, {
  'membership': membership,
  'displayname': ?name,
  'reason': ?reason,
}, me);

RoomDetails adminDetails({
  int myPower = 100,
  String joinRule = 'invite',
  bool encrypted = false,
  bool knock = false,
  String? alias = '#project:example.org',
  Map<String, Object?>? levels,
  List<RoomStateEntry> extra = const [],
}) => RoomDetails.fromState(
  roomId: roomId,
  userId: me,
  state: [
    const RoomStateEntry('m.room.create', '', {'room_version': '11'}, me),
    const RoomStateEntry('m.room.name', '', {'name': 'Project room'}, me),
    const RoomStateEntry('m.room.topic', '', {'topic': 'Plans'}, me),
    RoomStateEntry(
      'm.room.power_levels',
      '',
      levels ??
          {
            'users': {me: myPower, guest: 0},
          },
      me,
    ),
    RoomStateEntry('m.room.join_rules', '', {'join_rule': joinRule}, me),
    if (alias != null)
      RoomStateEntry('m.room.canonical_alias', '', {'alias': alias}, me),
    if (encrypted)
      const RoomStateEntry('m.room.encryption', '', {
        'algorithm': 'm.megolm.v1.aes-sha2',
      }, me),
    memberState(me, 'join', name: 'Me'),
    memberState(guest, 'join', name: 'Guest'),
    if (knock)
      memberState(
        knocker,
        'knock',
        name: 'Knocker',
        reason: 'Please let me in',
      ),
    ...extra,
  ],
);

class AdminBackend extends FakeBackend
    implements RoomsAdminFeatures, MessagingFeatures, RoomEventFeatures {
  AdminBackend() {
    currentUserId = me;
    roomList = [
      const ChatRoom(
        id: roomId,
        name: 'Project room',
        preview: '',
        lastActivity: null,
      ),
    ];
  }

  RoomDetails details = adminDetails();
  final calls = <String>[];
  RoomNotificationSettings notifications = const RoomNotificationSettings(
    defaultMode: RoomNotificationMode.allMessages,
  );
  bool? published = false;
  final ignored = <String>{};
  final favourites = <String>{};
  final dms = <String, String>{};
  final previews = <String, RoomPreview>{};
  List<DirectoryUser> directory = const [];
  bool reportSupported = true;
  Object? createFailure;
  RoomCreationOptions? created;
  UserVerification userVerification = UserVerification.unverified;
  String? inviter = '@spammer:example.org';

  @override
  // Fakes only implement what the screens use.
  // ignore: unnecessary_overrides
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  // --- ChatBackend --------------------------------------------------------
  @override
  Future<RoomDetails> getRoomDetails(String roomId) async => details;
  @override
  Future<void> inviteToRoom(String roomId, String userId) async =>
      calls.add('invite:$userId');
  @override
  Future<void> editRoomName(String roomId, String name) async =>
      calls.add('name:$name');
  @override
  Future<void> editRoomTopic(String roomId, String topic) async =>
      calls.add('topic:$topic');
  @override
  Future<void> leaveRoom(String roomId) async {
    calls.add('leave:$roomId');
    await super.leaveRoom(roomId);
  }

  @override
  Future<void> declineInvite(String roomId) async {
    calls.add('decline:$roomId');
    await super.declineInvite(roomId);
  }

  @override
  Future<void> startVerification(String userId, {String? deviceId}) async =>
      calls.add('verify:$userId');

  // --- MessagingFeatures ---------------------------------------------------
  @override
  String get accountKey => 'account';
  @override
  List<PendingSend> get pendingSends => const [];
  @override
  Future<List<DirectoryUser>> searchUsers(String query) async => directory;
  @override
  bool isFavourite(String roomId) => favourites.contains(roomId);
  @override
  Future<void> setFavourite(String roomId, bool favourite) async {
    calls.add('favourite:$favourite');
    favourite ? favourites.add(roomId) : favourites.remove(roomId);
  }

  // --- RoomEventFeatures ---------------------------------------------------
  @override
  Future<void> redactEvent(
    String roomId,
    String eventId, {
    String? reason,
  }) async => calls.add('redact:$eventId:${reason ?? ''}');

  // --- RoomsAdminFeatures --------------------------------------------------
  @override
  String? get homeserverName => 'example.org';
  @override
  String? existingDirectChat(String userId) => dms[userId];
  @override
  Future<String> startDirectChat(String userId) async {
    calls.add('dm:$userId');
    return dms[userId] ??= '!dm-$userId';
  }

  @override
  Future<RoomPreview> previewRoom(RoomAddress address) async {
    calls.add('preview:${address.idOrAlias}');
    final preview = previews[address.idOrAlias];
    if (preview == null) throw StateError('Room not found');
    return preview;
  }

  @override
  Future<void> knockRoom(
    String roomId, {
    List<String> via = const [],
    String? reason,
  }) async => calls.add('knock:$roomId:${reason ?? ''}');
  @override
  Future<void> cancelKnock(String roomId) async =>
      calls.add('cancelKnock:$roomId');

  @override
  Future<String> createConfiguredRoom(RoomCreationOptions options) async {
    calls.add('create:${options.name}');
    created = options;
    if (createFailure case final failure?) throw failure;
    const id = '!created:example.org';
    roomList = [
      ...roomList,
      ChatRoom(id: id, name: options.name, preview: '', lastActivity: null),
    ];
    // Sync arrives after the acknowledgement.
    scheduleMicrotask(notifyListeners);
    return id;
  }

  @override
  Future<void> setRoomAvatar(String roomId, PickedImage? image) async =>
      calls.add('avatar:${image?.name}');
  @override
  Future<void> setJoinRule(String roomId, String joinRule) async =>
      calls.add('joinRule:$joinRule');
  @override
  Future<void> setHistoryVisibility(String roomId, String visibility) async =>
      calls.add('history:$visibility');
  @override
  Future<void> enableEncryption(String roomId) async => calls.add('encryption');
  @override
  Future<void> setRoomAddress(String roomId, String? localpart) async =>
      calls.add('address:$localpart');
  @override
  Future<bool?> isPublishedInDirectory(String roomId) async => published;
  @override
  Future<void> setPublishedInDirectory(String roomId, bool published) async {
    calls.add('published:$published');
    this.published = published;
  }

  @override
  Future<void> setMemberPowerLevels(
    String roomId,
    Map<String, int> levels,
  ) async => calls.add('levels:$levels');
  @override
  Future<void> setPermissionLevel(
    String roomId,
    PermissionItem item,
    int level,
  ) async => calls.add('permission:${item.key ?? item.state}:$level');
  @override
  Future<void> resetPermissions(String roomId) async =>
      calls.add('resetPermissions');

  @override
  Future<void> moderateMember(
    String roomId,
    String userId,
    RoomAction action, {
    String? reason,
  }) async => calls.add('${action.name}:$userId:${reason ?? ''}');
  @override
  Future<void> acceptKnock(String roomId, String userId) async =>
      calls.add('accept:$userId');
  @override
  Future<void> declineKnock(
    String roomId,
    String userId, {
    bool ban = false,
    String? reason,
  }) async => calls.add('declineKnock:$userId:$ban:${reason ?? ''}');
  @override
  List<RoomMemberDetails> cachedKnockRequests(String roomId) =>
      details.isKnockable ? details.knockRequests : const [];
  @override
  RoomDetails? cachedRoomDetails(String roomId) => details;

  @override
  bool canSendMessages(String roomId) =>
      details.ownPowerLevel >= details.requiredForEvent('m.room.message');

  @override
  Future<RoomNotificationSettings> notificationSettings(String roomId) async =>
      notifications;
  @override
  Future<void> setNotificationMode(
    String roomId,
    RoomNotificationMode? mode,
  ) async {
    calls.add('notify:${mode?.name}');
    notifications = RoomNotificationSettings(
      defaultMode: notifications.defaultMode,
      customMode: mode,
    );
  }

  @override
  Future<void> reportRoom(String roomId, String reason) async {
    if (!reportSupported) throw const ReportRoomUnsupported();
    calls.add('report:$reason');
  }

  @override
  Future<UserProfileDetails> userProfile(
    String userId, {
    String? roomId,
  }) async => UserProfileDetails(
    userId: userId,
    displayName: details.member(userId)?.name,
  );
  @override
  UserVerification verificationOf(String userId) => userVerification;
  @override
  bool isIgnored(String userId) => ignored.contains(userId);
  @override
  Future<void> setIgnored(String userId, bool ignore) async {
    calls.add('ignore:$userId:$ignore');
    ignore ? ignored.add(userId) : ignored.remove(userId);
  }

  @override
  String? inviterOf(String roomId) => inviter;
}

Widget app(Widget home) =>
    MaterialApp(theme: themeFor(VisualTheme.parallax), home: home);

/// Taps a button that opens [open] and keeps its eventual result.
class Launcher<T> {
  T? result;
  bool done = false;

  Widget build(Future<T> Function(BuildContext context) open) => app(
    Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async {
              result = await open(context);
              done = true;
            },
            child: const Text('Launch'),
          ),
        ),
      ),
    ),
  );

  Future<void> launch(WidgetTester tester) async {
    await tester.tap(find.text('Launch'));
    await tester.pumpAndSettle();
  }
}

/// A tall test surface so long admin pages fit without scrolling.
void tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Brings [finder] fully on screen.
Future<void> scrollTo(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}
