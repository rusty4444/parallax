import 'dart:math' as math;

import 'package:matrix/matrix.dart';

import 'bridge_bots.dart';
import 'chat_network.dart';
import 'client_caches.dart';
import 'people_names.dart';

/// State event types whose `bridgebot` names a room's bridge bot (MSC2346
/// and the pre-standard type mautrix bridges also send).
const bridgeStateTypes = {'m.bridge', 'uk.half-shot.bridge'};

/// Room names and pictures without bridge bots.
extension ParallaxRoomNames on Room {
  /// [userId]'s member state if it is loaded, else a bare fallback.
  ///
  /// Unlike the SDK's `unsafeGetUserFromMemoryOrFallback`, never starts a
  /// lookup: that fires a detached database read and server request for
  /// each missing member, and the room list asks for every room's people at
  /// once after a cold start. The backend loads missing names a few at a
  /// time and projects the room again.
  User memberInMemory(String userId) =>
      getState(EventTypes.RoomMember, userId)?.asUser(this) ??
      User(userId, room: this);

  /// Bots named by this room's bridge state, where that state is loaded.
  Set<String> get bridgeBotIds => {
    for (final type in bridgeStateTypes)
      for (final event in states[type]?.values ?? const <StrippedStateEvent>[])
        if (event.content['bridgebot'] case final String bot
            when bot.isNotEmpty)
          bot,
  };

  /// Whether [userId] is a bridge bot in this room: named by bridge state,
  /// or recognised by its username or "… bridge bot" display name.
  bool isBridgeBot(String userId, [Set<String>? stateBots]) =>
      (stateBots ?? bridgeBotIds).contains(userId) ||
      looksLikeBridgeBot(
        userId,
        displayName: memberInMemory(userId).displayName,
      );

  /// Whether this is a multi-person room for naming and avatar purposes.
  /// Some bridged groups are incorrectly present in m.direct, so a direct-chat
  /// marker alone cannot decide between a single DM face and a group collage.
  bool get isMultiPersonRoom {
    final joined = summary.mJoinedMemberCount;
    final invited = summary.mInvitedMemberCount;
    if (joined != null || invited != null) {
      return (joined ?? 0) + (invited ?? 0) > 2;
    }
    return getParticipants(const [Membership.join]).length > 2;
  }

  /// The other people this room is named and pictured after (the server's
  /// heroes, or the DM partner), without bridge bots unless only bots remain.
  List<String> get peopleHeroes {
    final heroes = [...?summary.mHeroes];
    final direct = directChatPartner;
    // A sparse summary can name only us and the bridge bot even when m.direct
    // identifies the real contact. Always consider that partner, not just when
    // the server supplied no heroes at all.
    if (direct != null && !heroes.contains(direct)) heroes.add(direct);
    final bots = bridgeBotIds;
    bool isBot(String id) => isBridgeBot(id, bots);
    final result = withoutBridgeBots([
      for (final hero in heroes)
        if (hero.isNotEmpty && hero != client.userID) hero,
    ], isBot);
    // Always supplement heroes from joined members. A true DM naturally ends
    // with one person, while a bridged group gets a collage even when its
    // direct flag and summary member counts are missing or wrong.
    {
      // m.heroes is optional and is often empty on named/bridged groups. Fill
      // an avatar cluster from the latest sender and other joined members we
      // already know about, rather than falling straight back to a network
      // logo or room initial. The projection caps the actual faces at four.
      final groupHeroes = [...result];
      void addPerson(String? id) {
        if (groupHeroes.length >= 4 ||
            id == null ||
            id.isEmpty ||
            id == client.userID ||
            isBot(id) ||
            groupHeroes.contains(id)) {
          return;
        }
        final membership = getState(
          EventTypes.RoomMember,
          id,
        )?.content['membership'];
        if (membership == null || membership == Membership.join.name) {
          groupHeroes.add(id);
        }
      }

      addPerson(lastEvent?.senderId);
      List<String> finished() {
        // A bot-only hero list is just a fallback until a real person is
        // found; never prefix a bridge bot to the people's names or collage.
        final people = groupHeroes.where((id) => !isBot(id)).toList();
        return people.isEmpty ? groupHeroes : people;
      }

      if (groupHeroes.length >= 4) return finished();
      for (final user in getParticipants(const [Membership.join])) {
        addPerson(user.id);
        if (groupHeroes.length >= 4) break;
      }
      return finished();
    }
  }

  /// [getLocalizedDisplayname] without bridge bots and without "Group
  /// with": a room with no name or address is named after its people the
  /// way Element X does ("Alex", "Alex and Sam", "Alex, Sam and 3 others").
  /// Names and addresses set on the room are used unchanged.
  String get parallaxName {
    if (name.isNotEmpty) return name;
    final alias = canonicalAlias.localpart;
    if (alias != null && alias.isNotEmpty) return alias;
    final heroes = peopleHeroes;
    if (heroes.isEmpty) return getLocalizedDisplayname();
    const i18n = MatrixDefaultLocalizations();
    final names = [
      for (final hero in heroes)
        memberInMemory(hero).calcDisplayname(i18n: i18n),
    ];
    final members =
        (summary.mJoinedMemberCount ?? 0) + (summary.mInvitedMemberCount ?? 0);
    // Everyone except me and the people already named. Bots the server
    // listed as heroes don't count as "others".
    final listed = {...?summary.mHeroes, ...heroes}..remove(client.userID);
    final others = members > 0
        ? math.max<int>(0, members - 1 - listed.length)
        : 0;
    final result = joinPeopleNames(names, others: others);
    if (isAbandonedDMRoom) return i18n.wasDirectChatDisplayName(result);
    return result;
  }

  /// Loads names and avatars for [userIds] this room holds no member state
  /// for: members are lazy-loaded, so rooms not opened since the app
  /// started often lack them. Each is looked up in the database, then the
  /// room's state on the server, then the user's profile (SDK
  /// [requestUser], which keeps what it finds). Gives up after [timeout].
  ///
  /// With [fromServer], each is then checked against the server's current
  /// member state: the database keeps a stale copy when a rename arrived
  /// while history was being filled in rather than in a live sync (bridges
  /// renaming contacts from phone numbers to names, for example).
  Future<void> loadMissingMembers(
    Iterable<String> userIds, {
    Duration timeout = const Duration(seconds: 4),
    bool fromServer = false,
  }) async {
    final missing = <String>{
      for (final id in userIds)
        if (id.isValidMatrixIdStrict() &&
            getState(EventTypes.RoomMember, id) == null)
          id,
    }.take(6);
    if (missing.isEmpty) return;
    try {
      await Future.wait([
        for (final id in missing)
          _loadMember(id).then((_) async {
            if (fromServer) await refreshMemberFromServer(id);
          }),
      ]).timeout(timeout);
    } catch (_) {
      // Slow or unreachable: the caller uses what it has.
    }
  }

  /// Replaces [userId]'s member state with the server's current one when
  /// it differs, in memory and (where the database can be written) on
  /// disk. Returns whether anything changed; never throws.
  Future<bool> refreshMemberFromServer(String userId) async {
    if (!userId.isValidMatrixIdStrict()) return false;
    // Join any lookup already running (the SDK starts them for missing
    // members): it re-reads the database and would otherwise overwrite the
    // server's answer with the stale copy when it finishes later.
    try {
      await requestUser(userId, ignoreErrors: true);
    } catch (_) {}
    try {
      final content = await client.getRoomStateWithKey(
        id,
        EventTypes.RoomMember,
        userId,
      );
      final membership = content.tryGet<String>('membership', TryGet.silent);
      if (membership == null) return false;
      var name = content.tryGet<String>('displayname', TryGet.silent);
      var avatar = content.tryGet<String>('avatar_url', TryGet.silent);
      if (name == null || avatar == null) {
        try {
          final profile = await client.request(
            RequestType.GET,
            '/client/v3/profile/${Uri.encodeComponent(userId)}',
          );
          name ??= profile.tryGet<String>('displayname', TryGet.silent);
          avatar ??= profile.tryGet<String>('avatar_url', TryGet.silent);
        } catch (_) {}
      }
      final current = getState(EventTypes.RoomMember, userId)?.content;
      if (current != null &&
          current['displayname'] == name &&
          current['avatar_url'] == avatar &&
          current['membership'] == membership) {
        return false;
      }
      final user = User(
        userId,
        room: this,
        displayName: name,
        avatarUrl: avatar,
        membership: membership,
      );
      setState(user);
      try {
        await client.database.transaction(
          () => client.database.storeEventUpdate(
            id,
            user,
            EventUpdateType.state,
            client,
          ),
        );
      } catch (_) {
        // Read-only (notification isolate): memory is enough there.
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _loadMember(String userId) async {
    try {
      await requestUser(userId, ignoreErrors: true);
    } catch (_) {}
    if (getState(EventTypes.RoomMember, userId) != null) return;
    // The SDK stores what it fetches and gives up when that write fails
    // (the notification isolate opens the database read-only), so read the
    // member, then the profile, directly and keep them in memory only.
    String? name;
    String? avatar;
    var membership = Membership.leave.name;
    try {
      final member = await client.request(
        RequestType.GET,
        '/client/v3/rooms/${Uri.encodeComponent(id)}/state/'
        'm.room.member/${Uri.encodeComponent(userId)}',
      );
      name = member.tryGet<String>('displayname', TryGet.silent);
      avatar = member.tryGet<String>('avatar_url', TryGet.silent);
      membership =
          member.tryGet<String>('membership', TryGet.silent) ?? membership;
    } catch (_) {}
    if (name == null || avatar == null) {
      try {
        final profile = await client.request(
          RequestType.GET,
          '/client/v3/profile/${Uri.encodeComponent(userId)}',
        );
        name ??= profile.tryGet<String>('displayname', TryGet.silent);
        avatar ??= profile.tryGet<String>('avatar_url', TryGet.silent);
      } catch (_) {}
    }
    if (name == null && avatar == null) return;
    if (getState(EventTypes.RoomMember, userId) != null) return;
    setState(
      User(
        userId,
        room: this,
        displayName: name,
        avatarUrl: avatar,
        membership: membership,
      ),
    );
  }

  /// The app this room comes from: its bridge state where loaded, else
  /// the usernames of the people it is named after (bridged contacts and
  /// bots), else native Matrix.
  ChatNetwork get parallaxNetwork => chatNetworkOf(
    bridgeStates: [
      for (final type in bridgeStateTypes)
        for (final event
            in states[type]?.values ?? const <StrippedStateEvent>[])
          event.content,
    ],
    // Heroes and the DM partner first; the last sender is often the only
    // bridged ghost we know in a room whose members aren't loaded.
    userIds: [...?summary.mHeroes, ?directChatPartner, ?lastEvent?.senderId],
    aliases: [canonicalAlias],
    // Bounded: portals are full of ghosts, so a sample finds one. Big
    // native rooms shouldn't pay for a full member scan on every sync.
    memberIds: (states[EventTypes.RoomMember]?.keys ?? const <String>[]).take(
      200,
    ),
  );

  /// The room's explicit avatar, or null so `RoomAvatar` can use its people.
  /// Returning the SDK's direct-chat avatar here would pin a single person even
  /// before the joined-member list has loaded, hiding a group's collage.
  Uri? get parallaxAvatar {
    final url = getState(EventTypes.RoomAvatar)?.content.tryGet<String>('url');
    return url == null ? null : Uri.tryParse(url);
  }
}
