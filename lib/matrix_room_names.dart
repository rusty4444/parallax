import 'dart:math' as math;

import 'package:matrix/matrix.dart';

import 'bridge_bots.dart';
import 'people_names.dart';

/// State event types whose `bridgebot` names a room's bridge bot (MSC2346
/// and the pre-standard type mautrix bridges also send).
const bridgeStateTypes = {'m.bridge', 'uk.half-shot.bridge'};

/// Room names and pictures without bridge bots.
extension ParallaxRoomNames on Room {
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
        displayName: unsafeGetUserFromMemoryOrFallback(userId).displayName,
      );

  /// The other people this room is named and pictured after (the server's
  /// heroes, or the DM partner), without bridge bots unless only bots remain.
  List<String> get peopleHeroes {
    final heroes = [...?summary.mHeroes];
    final direct = directChatMatrixID;
    if (heroes.isEmpty && direct != null) heroes.add(direct);
    final bots = bridgeBotIds;
    return withoutBridgeBots([
      for (final hero in heroes)
        if (hero.isNotEmpty && hero != client.userID) hero,
    ], (id) => isBridgeBot(id, bots));
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
        unsafeGetUserFromMemoryOrFallback(hero).calcDisplayname(i18n: i18n),
    ];
    final members =
        (summary.mJoinedMemberCount ?? 0) + (summary.mInvitedMemberCount ?? 0);
    // Everyone except me and the people already named. Bots the server
    // listed as heroes don't count as "others".
    final listed = {...?summary.mHeroes}..remove(client.userID);
    final others = members > 0
        ? math.max<int>(
            0,
            members - 1 - math.max<int>(listed.length, heroes.length),
          )
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
      final name = content.tryGet<String>('displayname', TryGet.silent);
      final avatar = content.tryGet<String>('avatar_url', TryGet.silent);
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
    if (name == null) {
      try {
        final profile = await client.request(
          RequestType.GET,
          '/client/v3/profile/${Uri.encodeComponent(userId)}',
        );
        name = profile.tryGet<String>('displayname', TryGet.silent);
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

  /// [avatar], except a DM whose partner is a bridge bot shows its people
  /// (the avatar cluster) instead of the bot's logo.
  Uri? get parallaxAvatar {
    final url = getState(EventTypes.RoomAvatar)?.content.tryGet<String>('url');
    if (url != null) return Uri.tryParse(url);
    final direct = directChatMatrixID;
    if (direct != null &&
        isBridgeBot(direct) &&
        peopleHeroes.any((hero) => hero != direct)) {
      return null;
    }
    return avatar;
  }
}
