import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';
import '../../room_events.dart';
import 'matrix_home_features.dart';

/// Room-list operations for the home screen (Element X `features/home`).
abstract interface class RoomListFeatures {
  /// Sets the fully-read marker and read receipt on the latest event and clears
  /// a manual unread flag. A private receipt is sent when [publicReceipt] is
  /// false (Settings → Privacy → Send read receipts off).
  Future<void> markAsRead(String roomId, {required bool publicReceipt});

  /// Adds or removes the `m.favourite` tag and confirms it on the server.
  Future<void> setFavourite(String roomId, bool favourite);

  /// Adds or removes the `m.lowpriority` tag and confirms it on the server.
  Future<void> setLowPriority(String roomId, bool lowPriority);

  /// Mutes (no notifications) or restores the default for one room.
  Future<void> setRoomMuted(String roomId, bool muted);

  /// A shareable `https://matrix.to` link for a joined room.
  String roomLink(String roomId);

  /// Joined Spaces, sorted by name.
  List<HomeSpace> get joinedSpaces;

  /// Room IDs reachable from [spaceId] through `m.space.child` state of joined
  /// Spaces (nested Spaces included, cycles ignored).
  Set<String> spaceDescendants(String spaceId);

  Future<void> leaveSpace(String spaceId);
}

/// Account and settings operations (Element X `features/preferences`,
/// `features/logout`, `features/deactivation`).
abstract interface class AccountFeatures {
  Future<HomeProfile> ownProfile();
  Future<void> setDisplayName(String name);

  /// Uploads [bytes] and makes it the account avatar; null removes it.
  Future<void> setAvatar(Uint8List? bytes, {String name, String mimeType});

  /// Account management (MSC2965/MSC4191) and password-change capability.
  Future<AccountManagement> accountManagement();
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  });

  Future<NotificationDefaults> notificationDefaults();
  Future<void> setDefaultNotificationMode({
    required bool directChats,
    required bool allMessages,
  });
  Future<void> setNotificationToggle(NotificationToggle toggle, bool enabled);

  Future<List<HomeSession>> sessions();
  Future<void> renameSession(String deviceId, String name);

  /// Signs out other sessions. Throws [PasswordRequired] when the server asks
  /// for a password and [password] is null, and [UnsupportedAuthentication]
  /// when only non-password flows are offered (use account management).
  Future<void> signOutSessions(List<String> deviceIds, {String? password});

  List<String> get blockedUsers;
  Future<void> unblockUser(String userId);

  /// Deactivates the account with password UIA. Irreversible.
  Future<void> deactivateAccount({
    required String password,
    required bool eraseMessages,
  });
}

@immutable
class HomeSpace {
  const HomeSpace({required this.id, required this.name, this.avatarUrl});
  final String id;
  final String name;
  final Uri? avatarUrl;
}

@immutable
class HomeProfile {
  const HomeProfile({required this.userId, this.displayName, this.avatarUrl});
  final String userId;
  final String? displayName;
  final Uri? avatarUrl;

  String get label =>
      (displayName?.trim().isNotEmpty ?? false) ? displayName!.trim() : userId;
}

@immutable
class AccountManagement {
  const AccountManagement({
    this.url,
    this.canChangePassword = false,
    this.deviceDeleteSupported = false,
    this.deactivateSupported = false,
  });

  /// The provider's account page (OIDC/MAS), when advertised.
  final Uri? url;
  final bool canChangePassword;

  /// The provider supports MSC4191 `org.matrix.device_delete` deep links.
  final bool deviceDeleteSupported;

  /// The provider supports MSC4191 `org.matrix.account_deactivate`.
  final bool deactivateSupported;

  /// Authentication is delegated to an OIDC provider: password, session and
  /// deactivation APIs are managed there instead.
  bool get delegated => url != null;

  Uri? _action(String action, [Map<String, String> extra = const {}]) {
    final base = url;
    if (base == null) return null;
    return base.replace(
      queryParameters: {...base.queryParameters, 'action': action, ...extra},
    );
  }

  /// Deep link for removing one session (MSC4191), or the account page.
  Uri? sessionEndUrl(String deviceId) => deviceDeleteSupported
      ? _action('org.matrix.device_delete', {'device_id': deviceId})
      : url;

  /// Deep link for deactivating the account, or the account page.
  Uri? deactivateUrl() =>
      deactivateSupported ? _action('org.matrix.account_deactivate') : url;
}

/// Default notification level for a category of chats.
enum NotificationDefaultMode { allMessages, mentionsAndKeywords }

enum NotificationToggle { roomMentions, invitations, calls }

@immutable
class NotificationDefaults {
  const NotificationDefaults({
    required this.directChats,
    required this.groupChats,
    required this.roomMentions,
    required this.invitations,
    required this.calls,
    this.mismatch = false,
  });
  final NotificationDefaultMode directChats;
  final NotificationDefaultMode groupChats;
  final bool roomMentions;
  final bool invitations;
  final bool calls;

  /// Encrypted and unencrypted rules disagree (Element X
  /// "Configuration mismatch"); saving a mode rewrites both.
  final bool mismatch;
}

@immutable
class HomeSession {
  const HomeSession({
    required this.id,
    required this.current,
    this.name,
    this.lastSeen,
    this.lastSeenIp,
    this.verified,
  });
  final String id;
  final String? name;
  final DateTime? lastSeen;
  final String? lastSeenIp;
  final bool current;

  /// Cross-signing state when known.
  final bool? verified;

  String get label => (name?.trim().isNotEmpty ?? false) ? name!.trim() : id;
}

/// The server asked for the account password (user-interactive auth).
class PasswordRequired implements Exception {
  const PasswordRequired();
}

/// The server offered no password flow; use the account management page.
class UnsupportedAuthentication implements Exception {
  const UnsupportedAuthentication();
}

final _roomListCache = Expando<MatrixHomeFeatures>();

MatrixHomeFeatures? _matrixFor(ChatBackend backend) =>
    backend is MatrixSdkAccess && backend is RoomEventFeatures
    ? _roomListCache[backend] ??= MatrixHomeFeatures(backend as MatrixSdkAccess)
    : null;

/// Resolves room-list features for [backend]; test fakes implement
/// [RoomListFeatures] directly.
RoomListFeatures? roomListFeaturesOf(ChatBackend backend) =>
    backend is RoomListFeatures
    ? backend as RoomListFeatures
    : _matrixFor(backend);

/// Resolves account features for [backend]; test fakes implement
/// [AccountFeatures] directly.
AccountFeatures? accountFeaturesOf(ChatBackend backend) =>
    backend is AccountFeatures
    ? backend as AccountFeatures
    : _matrixFor(backend);

/// `https://matrix.to` permalink for a room alias or ID.
String matrixToRoomLink(String aliasOrId, {String? viaServer}) {
  final encoded = Uri.encodeComponent(aliasOrId);
  final via =
      aliasOrId.startsWith('!') && viaServer != null && viaServer.isNotEmpty
      ? '?via=${Uri.encodeQueryComponent(viaServer)}'
      : '';
  return 'https://matrix.to/#/$encoded$via';
}
