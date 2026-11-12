import 'dart:typed_data';

import 'package:matrix/matrix.dart' as matrix;

import '../../room_events.dart';
import 'home_features.dart';

/// Push rule IDs behind Element X's global notification settings.
abstract final class HomePushRules {
  static const oneToOne = '.m.rule.room_one_to_one';
  static const encryptedOneToOne = '.m.rule.encrypted_room_one_to_one';
  static const message = '.m.rule.message';
  static const encrypted = '.m.rule.encrypted';
  static const isRoomMention = '.m.rule.is_room_mention';
  static const legacyRoomMention = '.m.rule.roomnotif';
  static const inviteForMe = '.m.rule.invite_for_me';
  static const call = '.m.rule.call';
}

/// Derives Element X-style defaults from a global push rule set.
NotificationDefaults notificationDefaultsFromRules(matrix.PushRuleSet rules) {
  matrix.PushRule? find(List<matrix.PushRule>? kind, String id) =>
      kind?.where((rule) => rule.ruleId == id).firstOrNull;
  bool notifies(matrix.PushRule rule) =>
      rule.enabled && rule.actions.contains('notify');

  (NotificationDefaultMode, bool) mode(List<String> ids) {
    final present = [
      for (final id in ids) ?find(rules.underride, id),
    ].map(notifies).toList();
    if (present.isEmpty) return (NotificationDefaultMode.allMessages, false);
    final all = present.any((value) => value);
    return (
      all
          ? NotificationDefaultMode.allMessages
          : NotificationDefaultMode.mentionsAndKeywords,
      present.toSet().length > 1,
    );
  }

  final direct = mode([
    HomePushRules.oneToOne,
    HomePushRules.encryptedOneToOne,
  ]);
  final group = mode([HomePushRules.message, HomePushRules.encrypted]);
  final mention =
      find(rules.override, HomePushRules.isRoomMention) ??
      find(rules.override, HomePushRules.legacyRoomMention);
  final invite = find(rules.override, HomePushRules.inviteForMe);
  final call = find(rules.underride, HomePushRules.call);
  return NotificationDefaults(
    directChats: direct.$1,
    groupChats: group.$1,
    roomMentions: mention == null || notifies(mention),
    invitations: invite == null || notifies(invite),
    calls: call == null || notifies(call),
    mismatch: direct.$2 || group.$2,
  );
}

/// Matrix implementation of the home/settings module, wrapping the live
/// backend through [MatrixSdkAccess]. No timeline events are sent here: these
/// are account data, tags, push rules, profile and device-management calls.
class MatrixHomeFeatures implements RoomListFeatures, AccountFeatures {
  MatrixHomeFeatures(this._access);

  final MatrixSdkAccess _access;

  // Tag writes for a room are ordered so a late readback cannot undo a newer
  // choice; shared per SDK client, not per helper lifetime.
  static final _tagQueues = Expando<Map<String, Future<void>>>();

  // Provider discovery is stable for a session; avoid repeating up to four
  // requests every time Settings opens. Failures are not cached.
  static final _managementCache = Expando<AccountManagement>();

  matrix.Client _client() {
    final client = _access.sdkClient;
    if (client == null || !_access.isSessionCurrent(client)) {
      throw StateError('Not signed in');
    }
    return client;
  }

  void _check(matrix.Client client) {
    if (!_access.isSessionCurrent(client)) {
      throw StateError('This account session is no longer current.');
    }
  }

  matrix.Room _joined(matrix.Client client, String roomId) {
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != matrix.Membership.join) {
      throw StateError('Room is not joined');
    }
    return room;
  }

  // --- Room list ----------------------------------------------------------

  @override
  Future<void> markAsRead(String roomId, {required bool publicReceipt}) async {
    final client = _client();
    final room = _joined(client, roomId);
    if (room.markedUnread) {
      await room.markUnread(false);
      _check(client);
    }
    final event = room.lastEvent;
    final eventId = event?.eventId;
    if (event == null ||
        eventId == null ||
        eventId.isEmpty ||
        !event.status.isSynced) {
      return;
    }
    await room.setReadMarker(eventId, mRead: eventId, public: publicReceipt);
    _check(client);
  }

  @override
  Future<void> setFavourite(String roomId, bool favourite) =>
      _setTag(roomId, matrix.TagType.favourite, favourite);

  @override
  Future<void> setLowPriority(String roomId, bool lowPriority) =>
      _setTag(roomId, matrix.TagType.lowPriority, lowPriority);

  Future<void> _setTag(String roomId, String tag, bool enabled) {
    final client = _client();
    final queue = _tagQueues[client] ??= <String, Future<void>>{};
    final previous = queue[roomId] ?? Future<void>.value();
    final operation = previous.then((_) async {
      _check(client);
      final room = _joined(client, roomId);
      final userId = client.userID!;
      if (enabled) {
        await room.addTag(tag);
      } else {
        await room.removeTag(tag);
      }
      _check(client);
      final tags = await client.getRoomTags(userId, roomId);
      _check(client);
      if ((tags?.containsKey(tag) ?? false) != enabled) {
        throw StateError('The server did not confirm the tag change.');
      }
      // Element X lets favourite and low priority exclude each other.
      final other = tag == matrix.TagType.favourite
          ? matrix.TagType.lowPriority
          : matrix.TagType.favourite;
      final finalTags = <String, matrix.Tag>{...?tags};
      if (enabled && finalTags.containsKey(other)) {
        await room.removeTag(other);
        _check(client);
        finalTags.remove(other);
      }
      room.roomAccountData['m.tag'] = matrix.BasicEvent(
        type: 'm.tag',
        content: {
          'tags': {
            for (final entry in finalTags.entries)
              entry.key: entry.value.toJson(),
          },
        },
      );
    });
    queue[roomId] = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  @override
  Future<void> setRoomMuted(String roomId, bool muted) async {
    final client = _client();
    final room = _joined(client, roomId);
    await room.setPushRuleState(
      muted ? matrix.PushRuleState.dontNotify : matrix.PushRuleState.notify,
    );
    _check(client);
  }

  @override
  String roomLink(String roomId) {
    final client = _client();
    final room = client.getRoomById(roomId);
    final alias = room?.canonicalAlias ?? '';
    final server = client.userID?.split(':').skip(1).join(':');
    return matrixToRoomLink(
      alias.isNotEmpty ? alias : roomId,
      viaServer: server,
    );
  }

  @override
  List<HomeSpace> get joinedSpaces {
    final client = _access.sdkClient;
    if (client == null || !_access.isSessionCurrent(client)) return const [];
    final spaces = <HomeSpace>[];
    for (final room in client.rooms) {
      try {
        if (room.membership != matrix.Membership.join || !room.isSpace) {
          continue;
        }
        spaces.add(
          HomeSpace(
            id: room.id,
            name: room.getLocalizedDisplayname(),
            avatarUrl: room.avatar,
          ),
        );
      } catch (_) {
        // One malformed Space must not hide the others.
      }
    }
    spaces.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return spaces;
  }

  @override
  Set<String> spaceDescendants(String spaceId) {
    final client = _access.sdkClient;
    if (client == null || !_access.isSessionCurrent(client)) return const {};
    final result = <String>{};
    final visited = <String>{};
    final pending = [spaceId];
    // Bound the walk: Space graphs are user-controlled and may be cyclic.
    while (pending.isNotEmpty && visited.length < 200) {
      final id = pending.removeLast();
      if (!visited.add(id)) continue;
      final space = client.getRoomById(id);
      if (space == null || !space.isSpace) continue;
      for (final child in space.spaceChildren) {
        final childId = child.roomId;
        if (childId == null || childId.isEmpty) continue;
        result.add(childId);
        final childRoom = client.getRoomById(childId);
        if (childRoom != null &&
            childRoom.membership == matrix.Membership.join &&
            childRoom.isSpace) {
          pending.add(childId);
        }
      }
    }
    result.remove(spaceId);
    return result;
  }

  @override
  Future<void> leaveSpace(String spaceId) async {
    final client = _client();
    final room = _joined(client, spaceId);
    if (!room.isSpace) throw StateError('Not a Space');
    await room.leave().timeout(const Duration(seconds: 30));
    _check(client);
  }

  // --- Account ------------------------------------------------------------

  @override
  Future<HomeProfile> ownProfile() async {
    final client = _client();
    final userId = client.userID!;
    final profile = await client.getUserProfile(
      userId,
      maxCacheAge: Duration.zero,
    );
    _check(client);
    return HomeProfile(
      userId: userId,
      displayName: profile.displayname,
      avatarUrl: profile.avatarUrl,
    );
  }

  @override
  Future<void> setDisplayName(String name) async {
    final client = _client();
    final value = name.trim();
    if (value.isEmpty || value.length > 256) {
      throw ArgumentError.value(name, 'name', 'Invalid display name');
    }
    await client.setProfileField(client.userID!, 'displayname', {
      'displayname': value,
    });
    _check(client);
  }

  @override
  Future<void> setAvatar(
    Uint8List? bytes, {
    String name = 'avatar.jpg',
    String mimeType = 'image/jpeg',
  }) async {
    final client = _client();
    if (bytes != null && bytes.length > maxAvatarBytes) {
      throw ArgumentError('Avatar is too large');
    }
    await client.setAvatar(
      bytes == null
          ? null
          : matrix.MatrixImageFile(
              bytes: bytes,
              name: name,
              mimeType: mimeType,
            ),
    );
    _check(client);
  }

  @override
  Future<AccountManagement> accountManagement() async {
    final client = _client();
    final cached = _managementCache[client];
    if (cached != null) return cached;
    final (result, conclusive) = await _discoverAccountManagement(client);
    _check(client);
    if (conclusive) _managementCache[client] = result;
    return result;
  }

  /// Returns the result and whether it came from a successful server answer
  /// (only those are cached).
  Future<(AccountManagement, bool)> _discoverAccountManagement(
    matrix.Client client,
  ) async {
    Uri? url;
    var actions = const <String>{};
    for (final path in const [
      '/client/v1/auth_metadata',
      '/client/unstable/org.matrix.msc2965/auth_metadata',
    ]) {
      try {
        // Parse leniently: the SDK's typed model rejects action names it does
        // not know, which providers commonly advertise.
        final json = await client.request(matrix.RequestType.GET, path);
        _check(client);
        url = safeAccountUrl(json['account_management_uri']);
        final raw = json['account_management_actions_supported'];
        actions = raw is List ? raw.whereType<String>().toSet() : const {};
        break;
      } on StateError {
        rethrow;
      } catch (_) {
        _check(client);
      }
    }
    if (url == null) {
      try {
        final wellKnown = await client.getWellknown();
        _check(client);
        final auth =
            wellKnown.additionalProperties['org.matrix.msc2965.authentication'];
        if (auth is Map) url = safeAccountUrl(auth['account']);
      } on StateError {
        rethrow;
      } catch (_) {
        _check(client);
      }
    }
    var canChangePassword = false;
    var conclusive = url != null;
    if (url == null) {
      try {
        final capabilities = await client.getCapabilities();
        _check(client);
        canChangePassword = capabilities.mChangePassword?.enabled ?? true;
        conclusive = true;
      } on StateError {
        rethrow;
      } catch (_) {
        _check(client);
      }
    }
    return (
      AccountManagement(
        url: url,
        canChangePassword: canChangePassword,
        deviceDeleteSupported:
            actions.contains('org.matrix.device_delete') ||
            actions.contains('org.matrix.session_end'),
        deactivateSupported: actions.contains('org.matrix.account_deactivate'),
      ),
      conclusive,
    );
  }

  @override
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    final client = _client();
    await client.changePassword(
      newPassword,
      oldPassword: oldPassword,
      logoutDevices: false,
    );
    _check(client);
  }

  @override
  Future<NotificationDefaults> notificationDefaults() async {
    final client = _client();
    final rules = await client.getPushRules();
    _check(client);
    return notificationDefaultsFromRules(rules);
  }

  @override
  Future<void> setDefaultNotificationMode({
    required bool directChats,
    required bool allMessages,
  }) async {
    final client = _client();
    final ids = directChats
        ? const [HomePushRules.oneToOne, HomePushRules.encryptedOneToOne]
        : const [HomePushRules.message, HomePushRules.encrypted];
    final actions = <Object?>[
      if (allMessages) 'notify',
      if (allMessages && directChats)
        {'set_tweak': 'sound', 'value': 'default'},
    ];
    await _forRules(client, ids, (id) async {
      await client.setPushRuleActions(
        matrix.PushRuleKind.underride,
        id,
        actions,
      );
      _check(client);
      await client.setPushRuleEnabled(matrix.PushRuleKind.underride, id, true);
    });
  }

  @override
  Future<void> setNotificationToggle(
    NotificationToggle toggle,
    bool enabled,
  ) async {
    final client = _client();
    final (kind, ids) = switch (toggle) {
      NotificationToggle.roomMentions => (
        matrix.PushRuleKind.override,
        const [HomePushRules.isRoomMention, HomePushRules.legacyRoomMention],
      ),
      NotificationToggle.invitations => (
        matrix.PushRuleKind.override,
        const [HomePushRules.inviteForMe],
      ),
      NotificationToggle.calls => (
        matrix.PushRuleKind.underride,
        const [HomePushRules.call],
      ),
    };
    await _forRules(
      client,
      ids,
      (id) => client.setPushRuleEnabled(kind, id, enabled),
    );
  }

  /// Applies [write] to every rule that exists; at least one must.
  Future<void> _forRules(
    matrix.Client client,
    List<String> ids,
    Future<void> Function(String id) write,
  ) async {
    var written = 0;
    for (final id in ids) {
      try {
        await write(id);
        _check(client);
        written++;
      } on matrix.MatrixException catch (error) {
        _check(client);
        if (error.error != matrix.MatrixError.M_NOT_FOUND) rethrow;
      }
    }
    if (written == 0) throw StateError('Push rule unavailable');
  }

  @override
  Future<List<HomeSession>> sessions() async {
    final client = _client();
    final devices = await client.getDevices();
    _check(client);
    final userId = client.userID!;
    final keys = client.userDeviceKeys[userId]?.deviceKeys;
    final result = [
      for (final device in devices ?? const <matrix.Device>[])
        HomeSession(
          id: device.deviceId,
          name: device.displayName,
          lastSeen: device.lastSeenTs == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(device.lastSeenTs!),
          lastSeenIp: device.lastSeenIp,
          current: device.deviceId == client.deviceID,
          verified: keys?[device.deviceId]?.verified,
        ),
    ];
    result.sort((a, b) {
      if (a.current != b.current) return a.current ? -1 : 1;
      return (b.lastSeen ?? DateTime(1970)).compareTo(
        a.lastSeen ?? DateTime(1970),
      );
    });
    return result;
  }

  @override
  Future<void> renameSession(String deviceId, String name) async {
    final client = _client();
    final value = name.trim();
    if (value.isEmpty || value.length > 100) {
      throw ArgumentError.value(name, 'name', 'Invalid session name');
    }
    await client.updateDevice(deviceId, displayName: value);
    _check(client);
  }

  @override
  Future<void> signOutSessions(
    List<String> deviceIds, {
    String? password,
  }) async {
    final client = _client();
    final others = deviceIds.where((id) => id != client.deviceID).toList();
    if (others.isEmpty) return;
    await _withPassword(
      client,
      password,
      (auth) => client.deleteDevices(others, auth: auth),
    );
  }

  @override
  List<String> get blockedUsers {
    final client = _access.sdkClient;
    if (client == null || !_access.isSessionCurrent(client)) return const [];
    return client.ignoredUsers..sort();
  }

  @override
  Future<void> unblockUser(String userId) async {
    final client = _client();
    await client.unignoreUser(userId);
    _check(client);
  }

  @override
  Future<void> deactivateAccount({
    required String password,
    required bool eraseMessages,
  }) async {
    final client = _client();
    if (password.isEmpty) throw const PasswordRequired();
    await _withPassword(
      client,
      password,
      (auth) => client.deactivateAccount(auth: auth, erase: eraseMessages),
    );
  }

  /// Runs a user-interactive-auth request, answering a password-only flow.
  Future<void> _withPassword(
    matrix.Client client,
    String? password,
    Future<Object?> Function(matrix.AuthenticationData? auth) request,
  ) async {
    try {
      await request(null);
      _check(client);
      return;
    } on matrix.MatrixException catch (error) {
      _check(client);
      if (!error.requireAdditionalAuthentication) rethrow;
      final passwordFlow = (error.authenticationFlows ?? const []).any(
        (flow) =>
            flow.stages.length == 1 &&
            flow.stages.single == matrix.AuthenticationTypes.password,
      );
      if (!passwordFlow) throw const UnsupportedAuthentication();
      if (password == null || password.isEmpty) throw const PasswordRequired();
      await request(
        matrix.AuthenticationPassword(
          session: error.session,
          identifier: matrix.AuthenticationUserIdentifier(user: client.userID!),
          password: password,
        ),
      );
      _check(client);
    }
  }
}

/// Avatar uploads are capped before they reach the homeserver.
const maxAvatarBytes = 10 * 1024 * 1024;

/// Only HTTPS account-management pages are opened.
Uri? safeAccountUrl(Object? value) {
  if (value is! String || value.length > 2048) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}
