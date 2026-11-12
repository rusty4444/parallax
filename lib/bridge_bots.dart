/// Recognises bridge bots (mautrix and similar) so computed room names and
/// avatar clusters show the people in a bridged chat, not the bridge.
library;

/// Default bot usernames of common bridges (mautrix-whatsapp, -signal,
/// -telegram, -meta, -linkedin, -discord, -slack, -gmessages, -gvoice,
/// -googlechat, -twitter, -bluesky, -imessage, and Viber/Heisenbridge).
const bridgeBotLocalparts = {
  'whatsappbot',
  'signalbot',
  'telegrambot',
  'metabot',
  'facebookbot',
  'instagrambot',
  'messengerbot',
  'linkedinbot',
  'discordbot',
  'slackbot',
  'gmessagesbot',
  'gvoicebot',
  'googlechatbot',
  'twitterbot',
  'blueskybot',
  'imessagebot',
  'viberbot',
  'heisenbridge',
};

/// Display names bridges give their bots: "Meta bridge bot",
/// "WhatsApp Bridge Bot", "Signal bridgebot".
final _bridgeBotName = RegExp(r'\bbridge\s*bot\b', caseSensitive: false);

/// Whether [userId] (with its [displayName], if known) looks like a bridge
/// bot. Bridge state (`m.bridge`) naming the bot is checked separately.
bool looksLikeBridgeBot(String userId, {String? displayName}) {
  if (displayName != null && _bridgeBotName.hasMatch(displayName)) return true;
  if (!userId.startsWith('@')) return false;
  final colon = userId.indexOf(':');
  final localpart =
      (colon < 0 ? userId.substring(1) : userId.substring(1, colon))
          .toLowerCase();
  return bridgeBotLocalparts.contains(localpart);
}

/// [userIds] without bridge bots, unless only bots are left: a bridge's own
/// management room keeps its bot's name and picture.
List<String> withoutBridgeBots(
  Iterable<String> userIds,
  bool Function(String userId) isBot,
) {
  final all = userIds.toList();
  final people = [
    for (final id in all)
      if (!isBot(id)) id,
  ];
  return people.isEmpty ? all : people;
}
