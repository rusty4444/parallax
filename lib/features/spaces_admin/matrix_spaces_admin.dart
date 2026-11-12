// Live Space administration over the Matrix SDK. Reads use `sdkClient`;
// state writes go through RoomEventFeatures.setRoomState. Every mutation
// re-reads power levels from the server first, and every await is followed
// by a session check. The homeserver makes the final authorisation decision.
import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../room_creation_request.dart';
import '../../room_details.dart';
import '../../room_events.dart';
import '../rooms_admin/leave_room.dart';
import '../rooms_admin/rooms_admin_models.dart';
import 'spaces_admin_features.dart';
import 'spaces_admin_models.dart';

class MatrixSpacesAdmin implements SpacesAdminFeatures {
  MatrixSpacesAdmin(this.backend)
    : assert(backend is MatrixSdkAccess && backend is RoomEventFeatures);

  final ChatBackend backend;
  MatrixSdkAccess get _sdk => backend as MatrixSdkAccess;
  RoomEventFeatures get _events => backend as RoomEventFeatures;

  matrix.Client _client() {
    final client = _sdk.sdkClient;
    if (client == null || !client.isLogged() || client.userID == null) {
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

  matrix.Room? _joined(matrix.Client client, String roomId) {
    final room = client.getRoomById(roomId);
    return room != null && room.membership == matrix.Membership.join
        ? room
        : null;
  }

  /// Fresh `/state` permissions of a joined room.
  Future<RoomDetails> _fresh(matrix.Client client, String roomId) =>
      _owned(client, () => backend.getRoomDetails(roomId));

  Future<RoomDetails> _freshSpace(matrix.Client client, String spaceId) async {
    final details = await _fresh(client, spaceId);
    if (!details.isSpace) throw StateError('Not a Space');
    if (!details.canSendState(spaceChildType)) {
      throw StateError('Not permitted to manage this Space');
    }
    return details;
  }

  /// Whether the user may send [type] in a joined room, from the cached
  /// (immutable) create event and fresh power levels. Avoids downloading a
  /// large room's full member list just to check one permission.
  Future<bool> _canSendStateFresh(
    matrix.Client client,
    matrix.Room room,
    String type,
  ) async {
    final levels = await _owned(
      client,
      () => _events.roomState(room.id, matrix.EventTypes.RoomPowerLevels),
    );
    final create = room.getState(matrix.EventTypes.RoomCreate);
    final userId = client.userID!;
    final details = RoomDetails.fromState(
      roomId: room.id,
      userId: userId,
      state: [
        if (create != null)
          RoomStateEntry(
            create.type,
            '',
            Map<String, Object?>.of(create.content),
            create.senderId,
          ),
        if (levels != null)
          RoomStateEntry(matrix.EventTypes.RoomPowerLevels, '', levels, ''),
        RoomStateEntry(matrix.EventTypes.RoomMember, userId, const {
          'membership': 'join',
        }, userId),
      ],
    );
    return details.canSendState(type);
  }

  List<String> _via(matrix.Client client, String roomId) {
    final own = serverNameOf(client.userID);
    final roomServer = serverNameOf(roomId);
    return [?own, if (roomServer != null && roomServer != own) roomServer];
  }

  @override
  String? get homeserverName => serverNameOf(_sdk.sdkClient?.userID);

  // --- Synced lookups -------------------------------------------------------

  @override
  bool isJoinedSpace(String roomId) {
    final client = _sdk.sdkClient;
    if (client == null) return false;
    try {
      return _joined(client, roomId)?.isSpace ?? false;
    } catch (_) {
      return false;
    }
  }

  SpaceRef _ref(matrix.Room room) => SpaceRef(
    id: room.id,
    name: room.getLocalizedDisplayname(),
    avatarUrl: room.avatar,
  );

  @override
  List<SpaceRef> get joinedSpaceRefs {
    final client = _sdk.sdkClient;
    if (client == null || !_sdk.isSessionCurrent(client)) return const [];
    final spaces = <SpaceRef>[];
    for (final room in client.rooms) {
      try {
        if (room.membership == matrix.Membership.join && room.isSpace) {
          spaces.add(_ref(room));
        }
      } catch (_) {
        // One malformed Space must not hide the others.
      }
    }
    spaces.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return spaces;
  }

  Set<String> _childIds(matrix.Room space) {
    try {
      return {
        for (final child in space.spaceChildren)
          if (child.roomId != null) child.roomId!,
      };
    } catch (_) {
      return const {};
    }
  }

  RoomDetails? _cachedDetails(matrix.Client client, matrix.Room room) {
    try {
      return RoomDetails.fromState(
        roomId: room.id,
        userId: client.userID!,
        state: [
          for (final type in const [
            matrix.EventTypes.RoomCreate,
            matrix.EventTypes.RoomPowerLevels,
          ])
            if (room.getState(type) case final event?)
              RoomStateEntry(
                type,
                '',
                Map<String, Object?>.of(event.content),
                event.senderId,
              ),
          RoomStateEntry(matrix.EventTypes.RoomMember, client.userID!, const {
            'membership': 'join',
          }, client.userID!),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  @override
  List<SpaceRef> spacesAcceptingChild(String roomId) {
    final client = _sdk.sdkClient;
    if (client == null || !_sdk.isSessionCurrent(client)) return const [];
    final spaces = <SpaceRef>[];
    for (final room in client.rooms) {
      try {
        if (room.id == roomId ||
            room.membership != matrix.Membership.join ||
            !room.isSpace ||
            _childIds(room).contains(roomId)) {
          continue;
        }
        if (_cachedDetails(client, room)?.canSendState(spaceChildType) ??
            false) {
          spaces.add(_ref(room));
        }
      } catch (_) {}
    }
    spaces.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return spaces;
  }

  @override
  List<SpaceRoomCandidate> addableRooms(String spaceId) {
    final client = _sdk.sdkClient;
    if (client == null || !_sdk.isSessionCurrent(client)) return const [];
    final space = _joined(client, spaceId);
    final existing = space == null ? const <String>{} : _childIds(space);
    final rooms = <SpaceRoomCandidate>[];
    for (final room in client.rooms) {
      try {
        if (room.id == spaceId ||
            room.membership != matrix.Membership.join ||
            room.isSpace ||
            room.isDirectChat ||
            existing.contains(room.id)) {
          continue;
        }
        final alias = room.canonicalAlias;
        rooms.add(
          SpaceRoomCandidate(
            id: room.id,
            name: room.getLocalizedDisplayname(),
            avatarUrl: room.avatar,
            alias: alias.isEmpty ? null : alias,
            members: room.summary.mJoinedMemberCount ?? 0,
          ),
        );
      } catch (_) {}
    }
    rooms.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return rooms;
  }

  // --- Creation ----------------------------------------------------------

  Future<({matrix.Client client, Uri? avatar})> _prepareCreate(
    SpaceCreationOptions options, {
    required bool encrypted,
  }) async {
    final name = options.name.trim();
    if (name.isEmpty || name.length > 255) {
      throw const RoomCreationFailure.notSubmitted(
        'The name must be between 1 and 255 characters. Try again.',
      );
    }
    final alias = options.aliasLocalpart?.trim();
    if (options.access.needsAddress &&
        (alias == null || !isValidAliasLocalpart(alias))) {
      throw const RoomCreationFailure.notSubmitted(
        'Public and ask-to-join access need a valid address. Check it and '
        'try again.',
      );
    }
    final client = _sdk.sdkClient;
    if (client == null ||
        backend.connection == SessionStatus.offline ||
        !client.isLogged()) {
      throw const RoomCreationFailure.notSubmitted(
        'Sign in and connect, then try again.',
      );
    }
    if (encrypted && !client.encryptionEnabled) {
      throw const RoomCreationFailure.notSubmitted(
        'Encryption is unavailable. Set up encryption before creating a '
        'private room, then try again.',
      );
    }
    Uri? avatar;
    if (options.avatar case final image?) {
      if (image.bytes.length > maxAvatarBytes) {
        throw const RoomCreationFailure.notSubmitted(
          'That image is too large for an avatar. Choose a smaller one.',
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
          'Couldn’t upload the avatar. Try again or remove it.',
        );
      }
      if (!_sdk.isSessionCurrent(client)) {
        throw const RoomCreationFailure.notSubmitted(
          'Your session changed. Try again.',
        );
      }
    }
    return (client: client, avatar: avatar);
  }

  Future<String> _submitCreate(
    matrix.Client client,
    Future<String> Function() create,
  ) async {
    final userId = client.userID;
    final deviceId = client.deviceID;
    late final String roomId;
    try {
      roomId = await create();
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

  @override
  Future<String> createSpace(SpaceCreationOptions options) async {
    const allowed = {
      SpaceCreationAccess.private,
      SpaceCreationAccess.askToJoin,
      SpaceCreationAccess.public,
    };
    if (!allowed.contains(options.access)) {
      throw const RoomCreationFailure.notSubmitted(
        'Choose who can join the Space, then try again.',
      );
    }
    final (:client, :avatar) = await _prepareCreate(options, encrypted: false);
    final access = options.access;
    final published = access.needsAddress;
    final topic = options.topic.trim();
    return _submitCreate(
      client,
      () => client.createRoom(
        name: options.name.trim(),
        topic: topic.isEmpty ? null : topic,
        creationContent: {'type': matrix.RoomCreationTypes.mSpace},
        preset: published
            ? matrix.CreateRoomPreset.publicChat
            : matrix.CreateRoomPreset.privateChat,
        visibility: published
            ? matrix.Visibility.public
            : matrix.Visibility.private,
        roomAliasName: published ? options.aliasLocalpart!.trim() : null,
        // Element: only admins post in a Space; anyone may invite to a
        // public Space, moderators otherwise.
        powerLevelContentOverride: {
          'events_default': 100,
          'invite': access == SpaceCreationAccess.public ? 0 : 50,
        },
        initialState: [
          if (!published)
            matrix.StateEvent(
              type: matrix.EventTypes.HistoryVisibility,
              stateKey: '',
              content: {'history_visibility': 'invited'},
            ),
          if (access.joinRule case final rule?)
            matrix.StateEvent(
              type: matrix.EventTypes.RoomJoinRules,
              stateKey: '',
              content: {'join_rule': rule},
            ),
          if (avatar != null)
            matrix.StateEvent(
              type: matrix.EventTypes.RoomAvatar,
              stateKey: '',
              content: {'url': avatar.toString()},
            ),
        ],
      ),
    );
  }

  @override
  Future<String> createRoomInSpace(
    String spaceId,
    SpaceCreationOptions options,
  ) async {
    final access = options.access;
    final client = _sdk.sdkClient;
    if (client == null || _joined(client, spaceId) == null) {
      throw const RoomCreationFailure.notSubmitted(
        'Join the Space before creating rooms in it.',
      );
    }
    // Permission and room-version checks happen before the create POST, so
    // their failures are definite.
    try {
      await _freshSpace(client, spaceId);
    } catch (_) {
      throw const RoomCreationFailure.notSubmitted(
        'You don’t have permission to add rooms to this Space.',
      );
    }
    String? roomVersion;
    if (access.minimumRoomVersion > 1) {
      try {
        final capabilities = await _owned(client, client.getCapabilities);
        final versions = capabilities.mRoomVersions;
        roomVersion =
            roomVersionFor(access.minimumRoomVersion, versions?.default$, {
              if (versions != null)
                for (final entry in versions.available.entries)
                  entry.key: entry.value.name,
            });
      } on StateError catch (error) {
        if (!_sdk.isSessionCurrent(client)) {
          throw const RoomCreationFailure.notSubmitted(
            'Your session changed. Try again.',
          );
        }
        if (error.message.contains('join rule')) {
          throw const RoomCreationFailure.notSubmitted(
            'Your server doesn’t support this kind of access. Choose another.',
          );
        }
      } catch (_) {
        // Capabilities are optional; current servers default to v10+.
      }
    }
    final (client: ready, :avatar) = await _prepareCreate(
      options,
      encrypted: access.encryptedRoom,
    );
    final via = _via(ready, spaceId);
    final published = access.needsAddress;
    final topic = options.topic.trim();
    final joinRule = access.joinRule;
    return _submitCreate(
      ready,
      () => ready.createRoom(
        name: options.name.trim(),
        topic: topic.isEmpty ? null : topic,
        roomVersion: roomVersion,
        preset: published
            ? matrix.CreateRoomPreset.publicChat
            : matrix.CreateRoomPreset.privateChat,
        visibility: published
            ? matrix.Visibility.public
            : matrix.Visibility.private,
        roomAliasName: published ? options.aliasLocalpart!.trim() : null,
        initialState: [
          if (access.encryptedRoom)
            matrix.StateEvent(
              type: matrix.EventTypes.Encryption,
              stateKey: '',
              content: {'algorithm': matrix.AlgorithmTypes.megolmV1AesSha2},
            ),
          if (!published)
            matrix.StateEvent(
              type: matrix.EventTypes.HistoryVisibility,
              stateKey: '',
              content: {'history_visibility': 'invited'},
            ),
          if (joinRule != null)
            matrix.StateEvent(
              type: matrix.EventTypes.RoomJoinRules,
              stateKey: '',
              content: joinRule == 'knock'
                  ? {'join_rule': 'knock'}
                  : spaceMemberJoinRules([
                      spaceId,
                    ], askToJoin: joinRule == 'knock_restricted'),
            ),
          matrix.StateEvent(
            type: spaceParentType,
            stateKey: spaceId,
            content: {'via': via, 'canonical': true},
          ),
          if (avatar != null)
            matrix.StateEvent(
              type: matrix.EventTypes.RoomAvatar,
              stateKey: '',
              content: {'url': avatar.toString()},
            ),
        ],
      ),
    );
  }

  // --- Children ------------------------------------------------------------

  @override
  Future<SpaceGraph> loadSpaceGraph(String spaceId) async {
    final client = _client();
    if (_joined(client, spaceId) == null) {
      throw StateError('Space is not joined');
    }
    final userId = client.userID!;
    final state = await _owned(client, () => client.getRoomState(spaceId));
    final details = RoomDetails.fromState(
      roomId: spaceId,
      userId: userId,
      state: [
        for (final event in state)
          RoomStateEntry(
            event.type,
            event.stateKey ?? '',
            event.content,
            event.senderId,
          ),
      ],
    );
    if (!details.isSpace) throw StateError('Not a Space');
    var children = spaceChildrenFromState([
      for (final event in state)
        if (event.type == spaceChildType && event.stateKey != null)
          SpaceStateEvent(
            stateKey: event.stateKey!,
            content: event.content,
            timestamp: event.originServerTs.millisecondsSinceEpoch,
          ),
    ]);
    // Names of rooms we have not joined come from one hierarchy page.
    final remote = <String, matrix.SpaceRoomsChunk$2>{};
    if (children.any((child) => _joined(client, child.roomId) == null)) {
      try {
        final page = await _owned(
          client,
          () => client.getSpaceHierarchy(spaceId, maxDepth: 1, limit: 100),
        );
        for (final room in page.rooms) {
          remote[room.roomId] = room;
        }
      } on StateError {
        rethrow;
      } catch (_) {
        // Previews are optional; the room ID is shown instead.
      }
    }
    children = [for (final child in children) _display(client, child, remote)];
    return SpaceGraph(details: details, children: children);
  }

  SpaceChildEntry _display(
    matrix.Client client,
    SpaceChildEntry child,
    Map<String, matrix.SpaceRoomsChunk$2> remote,
  ) {
    try {
      final local = client.getRoomById(child.roomId);
      if (local != null && local.membership == matrix.Membership.join) {
        return child.withDisplay(
          name: local.getLocalizedDisplayname(),
          avatarUrl: local.avatar,
          members: local.summary.mJoinedMemberCount,
          joined: true,
          isSpace: local.isSpace,
          isDirect: local.isDirectChat,
        );
      }
      final preview = remote[child.roomId];
      if (preview != null) {
        return child.withDisplay(
          name: preview.name ?? preview.canonicalAlias,
          topic: preview.topic,
          avatarUrl: preview.avatarUrl?.scheme == 'mxc'
              ? preview.avatarUrl
              : null,
          members: preview.numJoinedMembers,
          isSpace: preview.roomType == matrix.RoomCreationTypes.mSpace,
        );
      }
    } catch (_) {}
    return child;
  }

  /// Current child content from the server, or null when not a child.
  Future<Map<String, Object?>?> _childContent(
    matrix.Client client,
    String spaceId,
    String roomId,
  ) async {
    final content = await _owned(
      client,
      () => _events.roomState(spaceId, spaceChildType, stateKey: roomId),
    );
    return content == null || sanitisedVia(content['via']).isEmpty
        ? null
        : content;
  }

  @override
  Future<List<String>> addChildren(
    String spaceId,
    List<String> roomIds, {
    bool suggested = false,
  }) async {
    final ids = {...roomIds}.toList();
    if (ids.isEmpty) return const [];
    if (ids.length > maxSpaceChildrenPerWrite) {
      throw ArgumentError('Too many rooms');
    }
    final client = _client();
    await _freshSpace(client, spaceId);
    final failed = <String>[];
    for (final id in ids) {
      if (!id.startsWith('!') || id == spaceId) {
        failed.add(id);
        continue;
      }
      final via = _via(client, id);
      try {
        final existing = await _childContent(client, spaceId, id);
        await _events.setRoomState(spaceId, spaceChildType, {
          ...?existing,
          'via': existing == null ? via : sanitisedVia(existing['via']),
          if (suggested) 'suggested': true,
        }, stateKey: id);
        _check(client);
      } catch (_) {
        _check(client);
        failed.add(id);
        continue;
      }
      try {
        await _linkParent(client, spaceId, id, via);
      } catch (_) {
        // The child link is what Spaces use; the parent link is a hint.
        _check(client);
      }
    }
    return failed;
  }

  /// Best effort `m.space.parent` on a joined child. Canonical unless the
  /// room already names another canonical parent.
  Future<void> _linkParent(
    matrix.Client client,
    String spaceId,
    String childId,
    List<String> via,
  ) async {
    final child = _joined(client, childId);
    if (child == null) return;
    if (!await _canSendStateFresh(client, child, spaceParentType)) return;
    final existing = await _owned(
      client,
      () => _events.roomState(childId, spaceParentType, stateKey: spaceId),
    );
    if (existing != null && sanitisedVia(existing['via']).isNotEmpty) return;
    final otherCanonical =
        child.states[spaceParentType]?.entries.any(
          (entry) =>
              entry.key != spaceId &&
              entry.value.content['canonical'] == true &&
              sanitisedVia(entry.value.content['via']).isNotEmpty,
        ) ??
        false;
    await _events.setRoomState(childId, spaceParentType, {
      'via': via,
      if (!otherCanonical) 'canonical': true,
    }, stateKey: spaceId);
    _check(client);
  }

  @override
  Future<void> removeChild(String spaceId, String roomId) async {
    final client = _client();
    await _freshSpace(client, spaceId);
    await _events.setRoomState(
      spaceId,
      spaceChildType,
      const {},
      stateKey: roomId,
    );
    _check(client);
    // Best effort: also drop the child's pointer back to this Space.
    final child = _joined(client, roomId);
    if (child == null) return;
    try {
      final parent = await _owned(
        client,
        () => _events.roomState(roomId, spaceParentType, stateKey: spaceId),
      );
      if (parent == null || parent.isEmpty) return;
      if (!await _canSendStateFresh(client, child, spaceParentType)) return;
      await _events.setRoomState(
        roomId,
        spaceParentType,
        const {},
        stateKey: spaceId,
      );
      _check(client);
    } catch (_) {
      _check(client);
    }
  }

  @override
  Future<void> setChildSuggested(
    String spaceId,
    String roomId,
    bool suggested,
  ) async {
    final client = _client();
    await _freshSpace(client, spaceId);
    final content = await _childContent(client, spaceId, roomId);
    if (content == null) throw StateError('Not in this Space');
    if ((content['suggested'] == true) == suggested) return;
    final next = {...content}..remove('suggested');
    if (suggested) next['suggested'] = true;
    await _events.setRoomState(spaceId, spaceChildType, next, stateKey: roomId);
    _check(client);
  }

  @override
  Future<void> moveChild(String spaceId, String roomId, int toIndex) async {
    final client = _client();
    final graph = await loadSpaceGraph(spaceId);
    if (!graph.canEditChildren) {
      throw StateError('Not permitted to manage this Space');
    }
    final plan = planSpaceChildMove(graph.children, roomId, toIndex);
    for (final MapEntry(key: id, value: order) in plan.entries) {
      final child = graph.child(id)!;
      await _events.setRoomState(spaceId, spaceChildType, {
        ...child.content,
        'order': order,
      }, stateKey: id);
      _check(client);
    }
  }

  // --- Leaving ---------------------------------------------------------------

  @override
  Future<LeaveSpacePlan> leavePlan(String spaceId) async {
    final client = _client();
    final userId = client.userID!;
    final space = _joined(client, spaceId);
    if (space == null || !space.isSpace) throw StateError('Not a joined Space');
    final details = await _fresh(client, spaceId);
    final lastAdmin =
        leaveWarningFor(details, isDirect: false) == LeaveWarning.lastAdmin;
    // Joined rooms anywhere below the Space (bounded; graphs may be cyclic).
    final found = <matrix.Room>[];
    final seen = <String>{spaceId};
    final pending = [space];
    while (pending.isNotEmpty && seen.length < 300) {
      final current = pending.removeAt(0);
      for (final id in _childIds(current)) {
        if (!seen.add(id)) continue;
        final room = _joined(client, id);
        if (room == null) continue;
        try {
          if (room.isDirectChat) continue;
          found.add(room);
          if (room.isSpace) pending.add(room);
        } catch (_) {}
      }
    }
    final rooms = <LeaveSpaceRoom>[];
    for (final room in found.take(100)) {
      bool admin;
      try {
        admin = await _isLastAdmin(client, room, userId);
      } on StateError {
        rethrow;
      } catch (_) {
        admin = false;
      }
      rooms.add(
        LeaveSpaceRoom(
          id: room.id,
          name: room.getLocalizedDisplayname(),
          avatarUrl: room.avatar,
          members: room.summary.mJoinedMemberCount ?? 0,
          lastAdmin: admin,
          isSpace: room.isSpace,
        ),
      );
    }
    return LeaveSpacePlan(
      spaceId: spaceId,
      spaceName: details.hasName
          ? details.name
          : space.getLocalizedDisplayname(),
      details: details,
      lastAdmin: lastAdmin,
      rooms: rooms,
    );
  }

  /// Synced power levels and create event; memberships of the few other
  /// privileged users are read from the server when lazy loading hid them.
  Future<bool> _isLastAdmin(
    matrix.Client client,
    matrix.Room room,
    String userId,
  ) async {
    final details = _cachedDetails(client, room);
    if (details == null || !isPrivileged(details, userId)) return false;
    if ((room.summary.mJoinedMemberCount ?? 0) <= 1) return false;
    for (final id in otherPrivilegedCandidates(details, userId)) {
      var membership = room
          .getState(matrix.EventTypes.RoomMember, id)
          ?.content['membership'];
      if (membership == null) {
        final fresh = await _owned(
          client,
          () => _events.roomState(
            room.id,
            matrix.EventTypes.RoomMember,
            stateKey: id,
          ),
        );
        membership = fresh?['membership'];
      }
      if (membership == 'join') return false;
    }
    return true;
  }

  @override
  Future<void> leaveSpaceAndRooms(String spaceId, List<String> roomIds) async {
    final client = _client();
    final left = <String>[];
    // Element X leaves the rooms first and the Space last.
    for (final id in {...roomIds}..remove(spaceId)) {
      if (_joined(client, id) == null) continue;
      try {
        await backend.leaveRoom(id);
      } catch (_) {
        _check(client);
        throw LeaveSpaceFailure(id, List.unmodifiable(left));
      }
      _check(client);
      left.add(id);
    }
    try {
      await backend.leaveRoom(spaceId);
    } catch (_) {
      _check(client);
      throw LeaveSpaceFailure(spaceId, List.unmodifiable(left));
    }
    _check(client);
  }

  // --- Authorised spaces -----------------------------------------------------

  @override
  AuthorisedSpaces authorisedSpacesFor(String roomId, List<String> allowed) {
    final client = _sdk.sdkClient;
    if (client == null || !_sdk.isSessionCurrent(client)) {
      return AuthorisedSpaces(selectable: const [], unknown: [...allowed]);
    }
    final room = client.getRoomById(roomId);
    final parents = <String>{};
    try {
      if (room != null) {
        for (final parent in room.spaceParents) {
          if (parent.roomId case final id?) parents.add(id);
        }
      }
    } catch (_) {}
    final selectable = <SpaceRef>[];
    for (final space in joinedSpaceRefs) {
      if (space.id == roomId) continue;
      final joinedSpace = _joined(client, space.id);
      final parent =
          parents.contains(space.id) ||
          (joinedSpace != null && _childIds(joinedSpace).contains(roomId));
      if (parent || allowed.contains(space.id)) selectable.add(space);
    }
    final known = {for (final space in selectable) space.id};
    return AuthorisedSpaces(
      selectable: selectable,
      unknown: [
        for (final id in allowed)
          if (!known.contains(id)) id,
      ],
    );
  }

  @override
  Future<void> setAuthorisedSpaces(
    String roomId,
    List<String> spaceIds, {
    required bool askToJoin,
  }) async {
    final ids = [
      for (final id in {...spaceIds})
        if (id.startsWith('!') && id.length <= 255 && id != roomId) id,
    ];
    if (ids.isEmpty) throw ArgumentError('Choose at least one Space');
    if (ids.length > maxAuthorisedSpaces) throw ArgumentError('Too many');
    final client = _client();
    final details = await _fresh(client, roomId);
    if (!details.canChangeJoinRule) throw StateError('Not permitted');
    if (askToJoin
        ? !supportsKnockRestricted(details)
        : !details.supportsRestricted) {
      throw StateError('Room version does not support this access');
    }
    await _events.setRoomState(
      roomId,
      matrix.EventTypes.RoomJoinRules,
      spaceMemberJoinRules(ids, askToJoin: askToJoin),
    );
    _check(client);
  }
}
