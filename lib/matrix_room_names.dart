import 'package:matrix/matrix.dart';

import 'bridge_bots.dart';

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

  /// [getLocalizedDisplayname], but a name built from members leaves out
  /// bridge bots ("Group with Alex, Sam", not "Group with Meta bridge bot…").
  /// Names and addresses set on the room are used unchanged.
  String get parallaxName {
    if (name.isNotEmpty) return name;
    final alias = canonicalAlias.localpart;
    if (alias != null && alias.isNotEmpty) return alias;
    final heroes = peopleHeroes;
    if (heroes.isEmpty) return getLocalizedDisplayname();
    const i18n = MatrixDefaultLocalizations();
    final result = heroes
        .map(
          (hero) => unsafeGetUserFromMemoryOrFallback(
            hero,
          ).calcDisplayname(i18n: i18n),
        )
        .join(', ');
    if (isAbandonedDMRoom) return i18n.wasDirectChatDisplayName(result);
    return isDirectChat ? result : i18n.groupWith(result);
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
