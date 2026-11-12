import 'dart:typed_data';

import 'package:parallax/chat_backend.dart';
import 'package:parallax/crypto_setup_policy.dart';
import 'package:parallax/features/home/home_features.dart';

import 'widget_test.dart' show FakeBackend;

/// A widget-test backend implementing the home module interfaces directly.
class HomeFakeBackend extends FakeBackend
    implements RoomListFeatures, AccountFeatures {
  HomeFakeBackend() {
    currentUserId = '@sam:example.org';
  }

  // Room list
  final calls = <String>[];
  List<HomeSpace> spaces = const [];
  Map<String, Set<String>> spaceChildren = const {};
  bool? lastPublicReceipt;

  void _replace(String roomId, ChatRoom Function(ChatRoom) change) {
    roomList = [
      for (final room in roomList)
        if (room.id == roomId) change(room) else room,
    ];
    notifyListeners();
  }

  @override
  Future<void> markAsRead(String roomId, {required bool publicReceipt}) async {
    calls.add('read:$roomId');
    lastPublicReceipt = publicReceipt;
    _replace(roomId, (r) => r.copyWith(unread: 0, highlightCount: 0));
  }

  @override
  Future<void> setFavourite(String roomId, bool favourite) async {
    calls.add('favourite:$roomId:$favourite');
    _replace(
      roomId,
      (r) => r.copyWith(
        favourite: favourite,
        lowPriority: favourite ? false : r.lowPriority,
      ),
    );
  }

  @override
  Future<void> setLowPriority(String roomId, bool lowPriority) async {
    calls.add('low:$roomId:$lowPriority');
    _replace(
      roomId,
      (r) => r.copyWith(
        lowPriority: lowPriority,
        favourite: lowPriority ? false : r.favourite,
      ),
    );
  }

  @override
  Future<void> setRoomMuted(String roomId, bool muted) async {
    calls.add('mute:$roomId:$muted');
    _replace(
      roomId,
      (r) => r.copyWith(
        notificationMode: muted
            ? RoomNotificationMode.mute
            : RoomNotificationMode.allMessages,
      ),
    );
  }

  @override
  String roomLink(String roomId) =>
      matrixToRoomLink(roomId, viaServer: 'x.org');

  @override
  List<HomeSpace> get joinedSpaces => spaces;

  @override
  Set<String> spaceDescendants(String spaceId) =>
      spaceChildren[spaceId] ?? const {};

  @override
  Future<void> leaveSpace(String spaceId) async {
    calls.add('leaveSpace:$spaceId');
    spaces = [
      for (final space in spaces)
        if (space.id != spaceId) space,
    ];
    notifyListeners();
  }

  // Account
  HomeProfile profile = const HomeProfile(
    userId: '@sam:example.org',
    displayName: 'Sam',
  );
  AccountManagement management = const AccountManagement(
    canChangePassword: true,
  );
  NotificationDefaults defaults = const NotificationDefaults(
    directChats: NotificationDefaultMode.allMessages,
    groupChats: NotificationDefaultMode.mentionsAndKeywords,
    roomMentions: true,
    invitations: true,
    calls: false,
  );
  List<HomeSession> sessionList = [
    const HomeSession(id: 'THIS', current: true, name: 'Parallax Android'),
    HomeSession(
      id: 'OTHER',
      current: false,
      name: 'Element Web',
      lastSeen: DateTime.now().subtract(const Duration(hours: 3)),
      verified: true,
    ),
  ];
  List<String> blocked = ['@spam:example.org'];
  String? requiredPassword;
  String? lastPassword;
  bool failNext = false;

  void _maybeFail() {
    if (failNext) {
      failNext = false;
      throw StateError('injected failure');
    }
  }

  @override
  Future<HomeProfile> ownProfile() async => profile;

  @override
  Future<void> setDisplayName(String name) async {
    _maybeFail();
    calls.add('name:$name');
    profile = HomeProfile(
      userId: profile.userId,
      displayName: name,
      avatarUrl: profile.avatarUrl,
    );
  }

  @override
  Future<void> setAvatar(
    Uint8List? bytes, {
    String name = 'avatar.jpg',
    String mimeType = 'image/jpeg',
  }) async {
    calls.add('avatar:${bytes?.length}:$mimeType');
  }

  @override
  Future<AccountManagement> accountManagement() async => management;

  @override
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    _maybeFail();
    calls.add('password');
  }

  @override
  Future<NotificationDefaults> notificationDefaults() async => defaults;

  @override
  Future<void> setDefaultNotificationMode({
    required bool directChats,
    required bool allMessages,
  }) async {
    _maybeFail();
    calls.add('mode:${directChats ? 'direct' : 'group'}:$allMessages');
    final mode = allMessages
        ? NotificationDefaultMode.allMessages
        : NotificationDefaultMode.mentionsAndKeywords;
    defaults = NotificationDefaults(
      directChats: directChats ? mode : defaults.directChats,
      groupChats: directChats ? defaults.groupChats : mode,
      roomMentions: defaults.roomMentions,
      invitations: defaults.invitations,
      calls: defaults.calls,
    );
  }

  @override
  Future<void> setNotificationToggle(
    NotificationToggle toggle,
    bool enabled,
  ) async {
    _maybeFail();
    calls.add('toggle:${toggle.name}:$enabled');
    defaults = NotificationDefaults(
      directChats: defaults.directChats,
      groupChats: defaults.groupChats,
      roomMentions: toggle == NotificationToggle.roomMentions
          ? enabled
          : defaults.roomMentions,
      invitations: toggle == NotificationToggle.invitations
          ? enabled
          : defaults.invitations,
      calls: toggle == NotificationToggle.calls ? enabled : defaults.calls,
    );
  }

  @override
  Future<List<HomeSession>> sessions() async => sessionList;

  @override
  Future<void> renameSession(String deviceId, String name) async {
    calls.add('rename:$deviceId:$name');
  }

  @override
  Future<void> signOutSessions(
    List<String> deviceIds, {
    String? password,
  }) async {
    if (requiredPassword != null) {
      if (password == null) throw const PasswordRequired();
      if (password != requiredPassword) throw StateError('wrong password');
    }
    lastPassword = password;
    calls.add('signOut:${deviceIds.join(',')}');
    sessionList = [
      for (final session in sessionList)
        if (!deviceIds.contains(session.id)) session,
    ];
  }

  @override
  List<String> get blockedUsers => blocked;

  @override
  Future<void> unblockUser(String userId) async {
    calls.add('unblock:$userId');
    blocked = [
      for (final user in blocked)
        if (user != userId) user,
    ];
  }

  @override
  Future<void> deactivateAccount({
    required String password,
    required bool eraseMessages,
  }) async {
    _maybeFail();
    lastPassword = password;
    calls.add('deactivate:$eraseMessages');
  }

  int logouts = 0;

  @override
  Future<void> logout() async {
    logouts++;
    calls.add('logout');
  }

  CryptoStatus? crypto = const CryptoStatus(
    initialized: true,
    connected: true,
    keyBackupEnabled: true,
    crossSigningEnabled: true,
    setupAvailability: CryptoSetupAvailability.connected,
  );

  @override
  Future<CryptoStatus> cryptoStatus() async {
    final value = crypto;
    if (value == null) throw StateError('unavailable');
    return value;
  }
}
