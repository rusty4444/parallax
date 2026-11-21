// Backend surface of the room administration module.
//
// Screens resolve it with [roomsAdminFeaturesOf]. Test fakes implement
// [RoomsAdminFeatures] directly; the live implementation wraps
// [MatrixSdkAccess] + [RoomEventFeatures] (see docs/parity/architecture.md).
import 'dart:async';

import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../room_creation_request.dart';
import '../../room_details.dart';
import '../../room_events.dart';
import 'rooms_admin_models.dart';
import '../../matrix_room_names.dart';

abstract interface class RoomsAdminFeatures {
  /// Server name of the signed-in account (for new room addresses).
  String? get homeserverName;

  // --- Start chat / join ----------------------------------------------------

  /// A joined DM with [userId], if one already exists locally.
  String? existingDirectChat(String userId);

  /// Opens (or creates) the DM with [userId] and returns its room ID.
  Future<String> startDirectChat(String userId);

  /// Resolves an alias or room ID and previews the room where possible.
  Future<RoomPreview> previewRoom(RoomAddress address);

  /// Asks to join a knockable room.
  Future<void> knockRoom(
    String roomId, {
    List<String> via = const [],
    String? reason,
  });

  /// Withdraws a pending request to join.
  Future<void> cancelKnock(String roomId);

  /// Creates a configured room (one non-idempotent POST). Throws
  /// [RoomCreationFailure] only for definite non-creation.
  Future<String> createConfiguredRoom(RoomCreationOptions options);

  // --- Room settings -------------------------------------------------------

  Future<void> setRoomAvatar(String roomId, PickedImage? image);
  Future<void> setJoinRule(String roomId, String joinRule);
  Future<void> setHistoryVisibility(String roomId, String visibility);
  Future<void> enableEncryption(String roomId);

  /// Publishes `#localpart:homeserver` and makes it the canonical address,
  /// or clears the canonical address when [localpart] is null.
  Future<void> setRoomAddress(String roomId, String? localpart);

  /// Null when the server does not say.
  Future<bool?> isPublishedInDirectory(String roomId);
  Future<void> setPublishedInDirectory(String roomId, bool published);

  // --- Roles & permissions ----------------------------------------------------

  Future<void> setMemberPowerLevels(String roomId, Map<String, int> levels);
  Future<void> setPermissionLevel(
    String roomId,
    PermissionItem item,
    int level,
  );
  Future<void> resetPermissions(String roomId);

  // --- Members ----------------------------------------------------------------

  Future<void> moderateMember(
    String roomId,
    String userId,
    RoomAction action, {
    String? reason,
  });
  Future<void> acceptKnock(String roomId, String userId);
  Future<void> declineKnock(
    String roomId,
    String userId, {
    bool ban = false,
    String? reason,
  });

  /// Pending requests to join from the synced (local) state. Actions always
  /// re-check against fresh server state.
  List<RoomMemberDetails> cachedKnockRequests(String roomId);

  /// Permission projection from synced state, for synchronous hooks.
  RoomDetails? cachedRoomDetails(String roomId);

  /// Whether the current user may post messages in [roomId] (live power
  /// levels). True when unknown, so a loading room never blocks its admin.
  bool canSendMessages(String roomId);

  // --- Notifications ----------------------------------------------------------

  Future<RoomNotificationSettings> notificationSettings(String roomId);

  /// Null restores the account default.
  Future<void> setNotificationMode(String roomId, RoomNotificationMode? mode);

  // --- Safety --------------------------------------------------------------

  /// Throws [ReportRoomUnsupported] when the server lacks the endpoint.
  Future<void> reportRoom(String roomId, String reason);
  Future<UserProfileDetails> userProfile(String userId, {String? roomId});
  UserVerification verificationOf(String userId);
  bool isIgnored(String userId);
  Future<void> setIgnored(String userId, bool ignored);

  /// Who invited the current user to [roomId], if known.
  String? inviterOf(String roomId);
}

final _features = Expando<RoomsAdminFeatures>();

RoomsAdminFeatures? roomsAdminFeaturesOf(ChatBackend backend) {
  if (backend is RoomsAdminFeatures) return backend as RoomsAdminFeatures;
  if (backend is MatrixSdkAccess && backend is RoomEventFeatures) {
    return _features[backend] ??= MatrixRoomsAdmin(backend);
  }
  return null;
}

/// Live implementation over the Matrix SDK. Reads go through `sdkClient`,
/// state writes through [RoomEventFeatures.setRoomState]; every await is
/// followed by a session check.
class MatrixRoomsAdmin implements RoomsAdminFeatures {
  MatrixRoomsAdmin(this.backend)
    : assert(backend is MatrixSdkAccess && backend is RoomEventFeatures);

  final ChatBackend backend;
  MatrixSdkAccess get _sdk => backend as MatrixSdkAccess;
  RoomEventFeatures get _events => backend as RoomEventFeatures;

  /// Local overrides until sync confirms an ignore-list change.
  final _ignoreOverrides = <String, bool>{};

  matrix.Client _client() {
    final client = _sdk.sdkClient;
    if (client == null || !client.isLogged()) {
      throw StateError('Not signed in');
    }
    return client;
  }

  void _check(matrix.Client client) {
    if (!_sdk.isSessionCurrent(client)) throw StateError('Session changed');
  }

  Future<T> _owned<T>(
    matrix.Client client,
    Future<T> Function() operation,
  ) async {
    final value = await operation();
    _check(client);
    return value;
  }

  /// Fresh server permissions; the server still makes the final decision.
  Future<RoomDetails> _fresh(String roomId) async {
    final client = _client();
    final details = await backend.getRoomDetails(roomId);
    _check(client);
    return details;
  }

  @override
  String? get homeserverName => serverNameOf(_sdk.sdkClient?.userID);

  // --- Start chat / join ----------------------------------------------------

  @override
  String? existingDirectChat(String userId) {
    final client = _sdk.sdkClient;
    if (client == null) return null;
    try {
      final id = client.getDirectChatFromUserId(userId);
      return client.getRoomById(id ?? '')?.membership == matrix.Membership.join
          ? id
          : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<String> startDirectChat(String userId) async {
    if (!isValidUserId(userId)) throw ArgumentError('Invalid Matrix ID');
    final client = _client();
    final existing = existingDirectChat(userId);
    if (existing != null) return existing;
    // The backend owns DM creation (encryption defaults, inbox refresh).
    await backend.createDirectChat(userId);
    _check(client);
    final id = backend.activeRoomId;
    if (id == null) throw StateError('Direct chat was not confirmed');
    return id;
  }

  @override
  Future<RoomPreview> previewRoom(RoomAddress address) async {
    final client = _client();
    var roomId = address.idOrAlias;
    var via = address.via;
    if (address.isAlias) {
      final resolved = await _owned(
        client,
        () => client.getRoomIdByAlias(address.idOrAlias),
      );
      final id = resolved.roomId;
      if (id == null || !id.startsWith('!')) {
        throw StateError('Room not found');
      }
      roomId = id;
      via = [...?resolved.servers?.take(10)];
    }
    final local = client.getRoomById(roomId);
    try {
      final summary = await _owned(
        client,
        () => client.getRoomSummary(roomId, via: via.isEmpty ? null : via),
      );
      return RoomPreview(
        roomId: summary.roomId,
        name: summary.name,
        topic: summary.topic,
        alias:
            summary.canonicalAlias ??
            (address.isAlias ? address.idOrAlias : null),
        avatarUrl: summary.avatarUrl,
        memberCount: summary.numJoinedMembers,
        joinRule: summary.joinRule,
        membership: summary.membership?.name ?? local?.membership.name,
        isSpace: summary.roomType == 'm.space',
        via: via,
      );
    } on StateError {
      rethrow;
    } catch (_) {
      // Older servers lack /room_summary; fall back to the hierarchy API,
      // which previews public and world-readable rooms.
    }
    try {
      final hierarchy = await _owned(
        client,
        () => client.getSpaceHierarchy(roomId, limit: 1, maxDepth: 0),
      );
      final room = hierarchy.rooms
          .where((room) => room.roomId == roomId)
          .firstOrNull;
      if (room != null) {
        return RoomPreview(
          roomId: roomId,
          name: room.name,
          topic: room.topic,
          alias:
              room.canonicalAlias ??
              (address.isAlias ? address.idOrAlias : null),
          avatarUrl: room.avatarUrl,
          memberCount: room.numJoinedMembers,
          joinRule: room.joinRule,
          membership: local?.membership.name,
          isSpace: room.roomType == 'm.space',
          via: via,
        );
      }
    } on StateError {
      rethrow;
    } catch (_) {
      // No preview available; joining may still work.
    }
    return RoomPreview(
      roomId: roomId,
      name: local?.parallaxName,
      alias: address.isAlias ? address.idOrAlias : null,
      membership: local?.membership.name,
      via: via,
    );
  }

  @override
  Future<void> knockRoom(
    String roomId, {
    List<String> via = const [],
    String? reason,
  }) async {
    final client = _client();
    final message = reason?.trim();
    await _owned(
      client,
      () => client.knockRoom(
        roomId,
        via: via.isEmpty ? null : via,
        reason: message == null || message.isEmpty ? null : message,
      ),
    );
  }

  @override
  Future<void> cancelKnock(String roomId) async {
    final client = _client();
    await _owned(client, () => client.leaveRoom(roomId));
  }

  @override
  Future<String> createConfiguredRoom(RoomCreationOptions options) async {
    final name = options.name.trim();
    if (name.isEmpty || name.length > 255) {
      throw const RoomCreationFailure.notSubmitted(
        'Room name must be between 1 and 255 characters. Try again.',
      );
    }
    final alias = options.aliasLocalpart?.trim();
    if (options.isPublic && (alias == null || !isValidAliasLocalpart(alias))) {
      throw const RoomCreationFailure.notSubmitted(
        'Public rooms need a valid address. Check it and try again.',
      );
    }
    final client = _sdk.sdkClient;
    if (client == null ||
        backend.connection == SessionStatus.offline ||
        !client.isLogged()) {
      throw const RoomCreationFailure.notSubmitted(
        'Sign in and connect before creating a room, then try again.',
      );
    }
    if (options.encrypted && !client.encryptionEnabled) {
      throw const RoomCreationFailure.notSubmitted(
        'Encryption is unavailable. Set up encryption before creating a '
        'private room, then try again.',
      );
    }
    final userId = client.userID;
    final deviceId = client.deviceID;
    Uri? avatar;
    if (options.avatar case final image?) {
      if (image.bytes.length > maxAvatarBytes) {
        throw const RoomCreationFailure.notSubmitted(
          'That image is too large for a room avatar. Choose a smaller one.',
        );
      }
      try {
        // Uploading media is not room creation: a failure here is definite.
        avatar = await client.uploadContent(
          image.bytes,
          filename: image.name,
          contentType: image.mimeType,
        );
      } catch (_) {
        throw const RoomCreationFailure.notSubmitted(
          'Couldn’t upload the room avatar. Try again or remove it.',
        );
      }
      if (!_sdk.isSessionCurrent(client)) {
        throw const RoomCreationFailure.notSubmitted(
          'Your session changed. Try again.',
        );
      }
    }
    final joinRule = options.askToJoin
        ? 'knock'
        : (options.isPublic ? 'public' : 'invite');
    late final String roomId;
    try {
      roomId = await client.createRoom(
        name: name,
        topic: options.topic.trim().isEmpty ? null : options.topic.trim(),
        preset: options.isPublic
            ? matrix.CreateRoomPreset.publicChat
            : matrix.CreateRoomPreset.privateChat,
        visibility: options.isPublic
            ? matrix.Visibility.public
            : matrix.Visibility.private,
        roomAliasName: options.isPublic ? alias : null,
        powerLevelContentOverride: options.broadcastChannel
            ? {'events_default': 50}
            : null,
        initialState: [
          if (options.encrypted)
            matrix.StateEvent(
              type: matrix.EventTypes.Encryption,
              stateKey: '',
              content: {'algorithm': matrix.AlgorithmTypes.megolmV1AesSha2},
            ),
          if (!options.isPublic)
            matrix.StateEvent(
              type: matrix.EventTypes.HistoryVisibility,
              stateKey: '',
              content: {'history_visibility': 'invited'},
            ),
          if (joinRule == 'knock')
            matrix.StateEvent(
              type: matrix.EventTypes.RoomJoinRules,
              stateKey: '',
              content: {'join_rule': 'knock'},
            ),
          if (options.voiceRoom)
            matrix.StateEvent(
              type: 'net.samrusselltech.parallax.voice_room',
              stateKey: '',
              content: {'drop_in': true},
            ),
          if (avatar != null)
            matrix.StateEvent(
              type: matrix.EventTypes.RoomAvatar,
              stateKey: '',
              content: {'url': avatar.toString()},
            ),
        ],
      );
    } catch (error) {
      if (definiteRoomCreationFailure(error) case final failure?) {
        throw failure;
      }
      rethrow;
    }
    if (!_sdk.isSessionCurrent(client) ||
        client.userID != userId ||
        client.deviceID != deviceId) {
      throw StateError('Session changed after creating the room');
    }
    return roomId;
  }

  // --- Room settings -------------------------------------------------------

  @override
  Future<void> setRoomAvatar(String roomId, PickedImage? image) async {
    final client = _client();
    final details = await _fresh(roomId);
    if (!details.canEditAvatar) throw StateError('Not permitted');
    if (image == null) {
      await _events.setRoomState(roomId, matrix.EventTypes.RoomAvatar, {});
      return;
    }
    if (image.bytes.length > maxAvatarBytes) {
      throw ArgumentError('Image too large');
    }
    final url = await _owned(
      client,
      () => client.uploadContent(
        image.bytes,
        filename: image.name,
        contentType: image.mimeType,
      ),
    );
    await _events.setRoomState(roomId, matrix.EventTypes.RoomAvatar, {
      'url': url.toString(),
      'info': {'mimetype': image.mimeType, 'size': image.bytes.length},
    });
  }

  @override
  Future<void> setJoinRule(String roomId, String joinRule) async {
    const allowed = {'invite', 'knock', 'public', 'restricted'};
    if (!allowed.contains(joinRule)) throw ArgumentError('Unknown join rule');
    final details = await _fresh(roomId);
    if (!details.canChangeJoinRule) throw StateError('Not permitted');
    final restricted = joinRule == 'restricted';
    if (restricted && details.allowedRoomIds.isEmpty) {
      throw StateError('No spaces are authorised for this room');
    }
    await _events.setRoomState(roomId, matrix.EventTypes.RoomJoinRules, {
      'join_rule': joinRule,
      if (restricted)
        'allow': [
          for (final id in details.allowedRoomIds)
            {'type': 'm.room_membership', 'room_id': id},
        ],
    });
  }

  @override
  Future<void> setHistoryVisibility(String roomId, String visibility) async {
    const allowed = {'invited', 'shared', 'joined', 'world_readable'};
    if (!allowed.contains(visibility)) {
      throw ArgumentError('Unknown history visibility');
    }
    final details = await _fresh(roomId);
    if (!details.canChangeHistory) throw StateError('Not permitted');
    await _events.setRoomState(roomId, matrix.EventTypes.HistoryVisibility, {
      'history_visibility': visibility,
    });
  }

  @override
  Future<void> enableEncryption(String roomId) async {
    final details = await _fresh(roomId);
    if (details.encrypted) return;
    if (!details.canEnableEncryption) throw StateError('Not permitted');
    await _events.setRoomState(roomId, matrix.EventTypes.Encryption, {
      'algorithm': matrix.AlgorithmTypes.megolmV1AesSha2,
    });
  }

  @override
  Future<void> setRoomAddress(String roomId, String? localpart) async {
    final client = _client();
    final details = await _fresh(roomId);
    if (!details.canChangeAddress) throw StateError('Not permitted');
    final server = homeserverName;
    final previous = details.canonicalAlias;
    String? alias;
    if (localpart != null) {
      if (!isValidAliasLocalpart(localpart) || server == null) {
        throw ArgumentError('Invalid address');
      }
      alias = '#$localpart:$server';
      if (alias == previous) return;
      // Publishing the alias is idempotent for this room; a taken alias fails
      // here before the canonical address changes.
      await _owned(client, () => client.setRoomAlias(alias!, roomId));
    }
    await _events.setRoomState(roomId, matrix.EventTypes.RoomCanonicalAlias, {
      'alias': ?alias,
      if (details.altAliases.isNotEmpty) 'alt_aliases': details.altAliases,
    });
    // Best effort: retire our server's previous alias for this room.
    if (previous != null &&
        previous != alias &&
        serverNameOf(previous) == server) {
      try {
        await _owned(client, () => client.deleteRoomAlias(previous));
      } on StateError {
        rethrow;
      } catch (_) {}
    }
  }

  @override
  Future<bool?> isPublishedInDirectory(String roomId) async {
    final client = _client();
    final visibility = await _owned(
      client,
      () => client.getRoomVisibilityOnDirectory(roomId),
    );
    return visibility == null ? null : visibility == matrix.Visibility.public;
  }

  @override
  Future<void> setPublishedInDirectory(String roomId, bool published) async {
    final client = _client();
    final details = await _fresh(roomId);
    if (!details.canChangeAddress && !details.canChangeJoinRule) {
      throw StateError('Not permitted');
    }
    await _owned(
      client,
      () => client.setRoomVisibilityOnDirectory(
        roomId,
        visibility: published
            ? matrix.Visibility.public
            : matrix.Visibility.private,
      ),
    );
  }

  // --- Roles & permissions ----------------------------------------------------

  @override
  Future<void> setMemberPowerLevels(
    String roomId,
    Map<String, int> levels,
  ) async {
    if (levels.isEmpty) return;
    final details = await _fresh(roomId);
    for (final MapEntry(key: userId, value: level) in levels.entries) {
      final target =
          details.member(userId) ??
          RoomMemberDetails(
            id: userId,
            name: userId,
            status: RoomMemberStatus.joined,
            powerLevel: details.powerOf(userId),
          );
      if (!details.canSetPowerLevel(target, level)) {
        throw StateError('Not permitted to change $userId');
      }
    }
    await _events.setRoomState(
      roomId,
      matrix.EventTypes.RoomPowerLevels,
      withMemberLevels(details.powerLevels, levels),
    );
  }

  @override
  Future<void> setPermissionLevel(
    String roomId,
    PermissionItem item,
    int level,
  ) async {
    final details = await _fresh(roomId);
    final current = permissionLevel(details.powerLevels, item);
    if (!details.canChangePowerLevels ||
        level > details.ownPowerLevel ||
        current > details.ownPowerLevel) {
      throw StateError('Not permitted');
    }
    if (current == level) return;
    await _events.setRoomState(
      roomId,
      matrix.EventTypes.RoomPowerLevels,
      withPermissionLevel(details.powerLevels, item, level),
    );
  }

  @override
  Future<void> resetPermissions(String roomId) async {
    final details = await _fresh(roomId);
    if (!details.canChangePowerLevels) throw StateError('Not permitted');
    final next = withDefaultPermissions(details.powerLevels);
    // Every changed level must be within the sender's own level.
    for (final key in const [
      'ban',
      'invite',
      'kick',
      'redact',
      'events_default',
      'state_default',
      'users_default',
    ]) {
      final before = details.powerLevels?[key];
      if (before is int && before > details.ownPowerLevel) {
        throw StateError('Not permitted');
      }
    }
    await _events.setRoomState(roomId, matrix.EventTypes.RoomPowerLevels, next);
  }

  // --- Members ----------------------------------------------------------------

  @override
  Future<void> moderateMember(
    String roomId,
    String userId,
    RoomAction action, {
    String? reason,
  }) async {
    if (action != RoomAction.kick &&
        action != RoomAction.ban &&
        action != RoomAction.unban) {
      throw ArgumentError('Not a moderation action');
    }
    final client = _client();
    final details = await _fresh(roomId);
    if (userId == client.userID) throw StateError('Cannot moderate yourself');
    if (!details.can(action, details.member(userId))) {
      throw StateError('Not permitted to ${action.name} in this room');
    }
    final text = reason?.trim();
    final why = text == null || text.isEmpty ? null : text;
    await _owned(client, () async {
      switch (action) {
        case RoomAction.kick:
          await client.kick(roomId, userId, reason: why);
        case RoomAction.ban:
          await client.ban(roomId, userId, reason: why);
        case RoomAction.unban:
          await client.unban(roomId, userId, reason: why);
        default:
          throw ArgumentError('Not a moderation action');
      }
    });
  }

  @override
  Future<void> acceptKnock(String roomId, String userId) async {
    final details = await _fresh(roomId);
    if (details.member(userId)?.status != RoomMemberStatus.knocking) {
      throw StateError('Request to join is no longer pending');
    }
    // inviteToRoom re-checks the invite permission against server state.
    await backend.inviteToRoom(roomId, userId);
  }

  @override
  Future<void> declineKnock(
    String roomId,
    String userId, {
    bool ban = false,
    String? reason,
  }) async {
    final details = await _fresh(roomId);
    if (details.member(userId)?.status != RoomMemberStatus.knocking) {
      throw StateError('Request to join is no longer pending');
    }
    await moderateMember(
      roomId,
      userId,
      ban ? RoomAction.ban : RoomAction.kick,
      reason: reason,
    );
  }

  @override
  RoomDetails? cachedRoomDetails(String roomId) {
    final client = _sdk.sdkClient;
    final userId = client?.userID;
    final room = client?.getRoomById(roomId);
    if (client == null || userId == null || room == null) return null;
    try {
      return RoomDetails.fromState(
        roomId: roomId,
        userId: userId,
        state: [
          for (final byKey in room.states.values)
            for (final event in byKey.values)
              RoomStateEntry(
                event.type,
                event.stateKey ?? '',
                event.content,
                event.senderId,
              ),
        ],
      );
    } catch (_) {
      return null; // A malformed cached event must not break the room screen.
    }
  }

  @override
  bool canSendMessages(String roomId) {
    final room = _sdk.sdkClient?.getRoomById(roomId);
    // Unknown room/state: don't block (the server is the final authority).
    return room?.canSendDefaultMessages ?? true;
  }

  @override
  List<RoomMemberDetails> cachedKnockRequests(String roomId) {
    final room = _sdk.sdkClient?.getRoomById(roomId);
    final rule = room
        ?.getState(matrix.EventTypes.RoomJoinRules)
        ?.content['join_rule'];
    if (room == null || (rule != 'knock' && rule != 'knock_restricted')) {
      return const [];
    }
    return cachedRoomDetails(roomId)?.knockRequests ?? const [];
  }

  // --- Notifications ----------------------------------------------------------

  @override
  Future<RoomNotificationSettings> notificationSettings(String roomId) async {
    final client = _client();
    final room = client.getRoomById(roomId);
    final rules = await _owned(client, client.getPushRules);
    final json = rules.toJson();
    final members =
        (room?.summary.mJoinedMemberCount ?? 0) +
        (room?.summary.mInvitedMemberCount ?? 0);
    return RoomNotificationSettings(
      defaultMode: defaultNotificationMode(
        json,
        encrypted: room?.encrypted ?? false,
        oneToOne: members == 2,
      ),
      customMode: userDefinedNotificationMode(json, roomId),
    );
  }

  @override
  Future<void> setNotificationMode(
    String roomId,
    RoomNotificationMode? mode,
  ) async {
    final client = _client();
    final json = (await _owned(client, client.getPushRules)).toJson();
    bool has(String kind) =>
        (json[kind] as List?)?.any(
          (rule) => rule is Map && rule['rule_id'] == roomId,
        ) ??
        false;
    // Insert the new rule first, then delete the other room rules, as the
    // Rust SDK does, so a failure never leaves the room unexpectedly noisy.
    switch (mode) {
      case RoomNotificationMode.allMessages:
        await _owned(
          client,
          () => client.setPushRule(matrix.PushRuleKind.room, roomId, [
            'notify',
            {'set_tweak': 'sound', 'value': 'default'},
          ]),
        );
      case RoomNotificationMode.mentionsAndKeywords:
        await _owned(
          client,
          () => client.setPushRule(matrix.PushRuleKind.room, roomId, []),
        );
      case RoomNotificationMode.mute:
        await _owned(
          client,
          () => client.setPushRule(
            matrix.PushRuleKind.override,
            roomId,
            [],
            conditions: [
              matrix.PushCondition(
                kind: 'event_match',
                key: 'room_id',
                pattern: roomId,
              ),
            ],
          ),
        );
      case null:
        break;
    }
    if (mode != RoomNotificationMode.mute && has('override')) {
      await _owned(
        client,
        () => client.deletePushRule(matrix.PushRuleKind.override, roomId),
      );
    }
    if ((mode == null || mode == RoomNotificationMode.mute) && has('room')) {
      await _owned(
        client,
        () => client.deletePushRule(matrix.PushRuleKind.room, roomId),
      );
    }
  }

  // --- Safety --------------------------------------------------------------

  @override
  Future<void> reportRoom(String roomId, String reason) async {
    final client = _client();
    try {
      await _owned(client, () => client.reportRoom(roomId, reason.trim()));
    } on matrix.MatrixException catch (error) {
      if (error.errcode == 'M_UNRECOGNIZED' ||
          error.response?.statusCode == 404 ||
          error.response?.statusCode == 405) {
        throw const ReportRoomUnsupported();
      }
      rethrow;
    }
  }

  @override
  Future<UserProfileDetails> userProfile(
    String userId, {
    String? roomId,
  }) async {
    final client = _client();
    final member = roomId == null
        ? null
        : client
              .getRoomById(roomId)
              ?.getState(matrix.EventTypes.RoomMember, userId)
              ?.content;
    String? name = member?['displayname'] is String
        ? member!['displayname'] as String
        : null;
    Uri? avatar = member?['avatar_url'] is String
        ? Uri.tryParse(member!['avatar_url'] as String)
        : null;
    if (name == null || avatar == null) {
      try {
        final profile = await _owned(
          client,
          () => client.getUserProfile(userId),
        );
        name ??= profile.displayname;
        avatar ??= profile.avatarUrl;
      } on StateError {
        rethrow;
      } catch (_) {
        // Profiles may be private; show what we know.
      }
    }
    return UserProfileDetails(
      userId: userId,
      displayName: name,
      avatarUrl: avatar?.scheme == 'mxc' ? avatar : null,
    );
  }

  @override
  UserVerification verificationOf(String userId) {
    final keys = _sdk.sdkClient?.userDeviceKeys[userId];
    if (keys == null) return UserVerification.unknown;
    if (keys.verified == matrix.UserVerifiedStatus.verified) {
      return UserVerification.verified;
    }
    return keys.masterKey == null && keys.deviceKeys.isEmpty
        ? UserVerification.unknown
        : UserVerification.unverified;
  }

  @override
  bool isIgnored(String userId) {
    final client = _sdk.sdkClient;
    if (client == null) return false;
    final synced = client.ignoredUsers.contains(userId);
    final override = _ignoreOverrides[userId];
    if (override == synced) _ignoreOverrides.remove(userId);
    return override ?? synced;
  }

  @override
  Future<void> setIgnored(String userId, bool ignored) async {
    if (!isValidUserId(userId)) throw ArgumentError('Invalid Matrix ID');
    final client = _client();
    final own = client.userID!;
    if (userId == own) throw ArgumentError('Cannot block yourself');
    // Read-modify-write the server copy so a stale sync cannot drop entries.
    // Written directly rather than via Client.ignoreUser, which also wipes
    // the local cache and restarts sync underneath the open timeline.
    Map<String, Object?> current;
    try {
      current = await _owned(
        client,
        () => client.getAccountData(own, 'm.ignored_user_list'),
      );
    } on matrix.MatrixException catch (error) {
      if (error.errcode != 'M_NOT_FOUND') rethrow;
      current = const {};
    }
    final users = <String, Object?>{
      if (current['ignored_users'] case final Map<dynamic, dynamic> map)
        for (final entry in map.entries)
          if (entry.key is String) entry.key as String: entry.value ?? {},
    };
    if (ignored) {
      users[userId] = <String, Object?>{};
    } else {
      users.remove(userId);
    }
    await _owned(
      client,
      () => client.setAccountData(own, 'm.ignored_user_list', {
        'ignored_users': users,
      }),
    );
    _ignoreOverrides[userId] = ignored;
  }

  @override
  String? inviterOf(String roomId) {
    final client = _sdk.sdkClient;
    final userId = client?.userID;
    if (client == null || userId == null) return null;
    final sender = client
        .getRoomById(roomId)
        ?.getState(matrix.EventTypes.RoomMember, userId)
        ?.senderId;
    return sender == null || sender == userId ? null : sender;
  }
}
