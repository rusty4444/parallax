/// Which app a chat comes from: a native Matrix room, or a room bridged
/// from WhatsApp, Messenger, Google Messages and so on. Drives the app logo
/// shown for chats without a picture (Settings → Appearance).
library;

enum ChatNetwork {
  matrix('Matrix'),
  whatsapp('WhatsApp'),
  googleMessages('Google Messages'),
  messenger('Messenger'),
  instagram('Instagram'),
  discord('Discord'),
  linkedin('LinkedIn'),
  x('X'),
  xbox('Xbox'),

  /// Bridged from an app with no logo here (Signal, Telegram, Slack …).
  otherBridge('Bridged chat');

  const ChatNetwork(this.label);
  final String label;

  /// Whether a logo is drawn for this network.
  bool get hasLogo => this != otherBridge;
}

/// `protocol.id` values bridges put in their `m.bridge` state (mautrix
/// bridgev2 network IDs and the older bridges' names).
const _protocols = <String, ChatNetwork>{
  'whatsapp': ChatNetwork.whatsapp,
  'gmessages': ChatNetwork.googleMessages,
  'googlemessages': ChatNetwork.googleMessages,
  'facebook': ChatNetwork.messenger,
  'facebookgo': ChatNetwork.messenger,
  'facebook-tor': ChatNetwork.messenger,
  'messenger': ChatNetwork.messenger,
  'meta': ChatNetwork.messenger,
  'instagram': ChatNetwork.instagram,
  'instagramgo': ChatNetwork.instagram,
  'discord': ChatNetwork.discord,
  'discordgo': ChatNetwork.discord,
  'linkedin': ChatNetwork.linkedin,
  'twitter': ChatNetwork.x,
  'x': ChatNetwork.x,
  'xbox': ChatNetwork.xbox,
};

/// Default username prefixes of bridged contacts ("puppets"), from the
/// bridges' `username_template` (`whatsapp_{{.}}` and so on). mautrix-meta
/// uses `meta_` for Messenger and Instagram alike; its `m.bridge` state
/// tells them apart where it is loaded.
const _puppetPrefixes = <String, ChatNetwork>{
  'whatsapp_': ChatNetwork.whatsapp,
  'gmessages_': ChatNetwork.googleMessages,
  'meta_': ChatNetwork.messenger,
  'facebook_': ChatNetwork.messenger,
  'messenger_': ChatNetwork.messenger,
  'instagram_': ChatNetwork.instagram,
  'discord_': ChatNetwork.discord,
  'linkedin_': ChatNetwork.linkedin,
  'twitter_': ChatNetwork.x,
  'xbox_': ChatNetwork.xbox,
  'signal_': ChatNetwork.otherBridge,
  'telegram_': ChatNetwork.otherBridge,
  'slack_': ChatNetwork.otherBridge,
  'gvoice_': ChatNetwork.otherBridge,
  'googlechat_': ChatNetwork.otherBridge,
  'imessage_': ChatNetwork.otherBridge,
  'bluesky_': ChatNetwork.otherBridge,
};

/// Bridge bot usernames (see `bridgeBotLocalparts`).
const _bots = <String, ChatNetwork>{
  'whatsappbot': ChatNetwork.whatsapp,
  'gmessagesbot': ChatNetwork.googleMessages,
  'metabot': ChatNetwork.messenger,
  'facebookbot': ChatNetwork.messenger,
  'messengerbot': ChatNetwork.messenger,
  'instagrambot': ChatNetwork.instagram,
  'discordbot': ChatNetwork.discord,
  'linkedinbot': ChatNetwork.linkedin,
  'twitterbot': ChatNetwork.x,
  'xboxbot': ChatNetwork.xbox,
  'signalbot': ChatNetwork.otherBridge,
  'telegrambot': ChatNetwork.otherBridge,
  'slackbot': ChatNetwork.otherBridge,
  'gvoicebot': ChatNetwork.otherBridge,
  'googlechatbot': ChatNetwork.otherBridge,
  'imessagebot': ChatNetwork.otherBridge,
  'blueskybot': ChatNetwork.otherBridge,
  'viberbot': ChatNetwork.otherBridge,
  'heisenbridge': ChatNetwork.otherBridge,
};

/// The network a bridge's `m.bridge` `protocol.id` names, if known.
ChatNetwork? chatNetworkForProtocol(String id) =>
    _protocols[id.trim().toLowerCase()];

/// The network [userId] is a bridged contact or bridge bot of, judging by
/// its username; null for ordinary Matrix users.
ChatNetwork? chatNetworkForUser(String userId) {
  if (!userId.startsWith('@')) return null;
  final colon = userId.indexOf(':');
  final localpart =
      (colon < 0 ? userId.substring(1) : userId.substring(1, colon))
          .toLowerCase();
  final bot = _bots[localpart];
  if (bot != null) return bot;
  for (final MapEntry(key: prefix, value: network) in _puppetPrefixes.entries) {
    if (localpart.startsWith(prefix) && localpart.length > prefix.length) {
      return network;
    }
  }
  return null;
}

/// A room's network from its bridge state ([bridgeStates]: the content of
/// each `m.bridge`/`uk.half-shot.bridge` event) and the people it is named
/// after ([userIds]: heroes and the DM partner). With neither, it is a
/// native Matrix room.
ChatNetwork chatNetworkOf({
  required Iterable<Map<String, Object?>> bridgeStates,
  required Iterable<String> userIds,
}) {
  var bridged = false;
  for (final content in bridgeStates) {
    bridged = true;
    final protocol = content['protocol'];
    final id = protocol is Map ? protocol['id'] : null;
    if (id is String) {
      final network = chatNetworkForProtocol(id);
      if (network != null) return network;
    }
    final bot = content['bridgebot'];
    if (bot is String) {
      final network = chatNetworkForUser(bot);
      if (network != null) return network;
    }
  }
  ChatNetwork? other;
  for (final userId in userIds) {
    final network = chatNetworkForUser(userId);
    if (network == null) continue;
    if (network != ChatNetwork.otherBridge) return network;
    other = network;
  }
  return other ?? (bridged ? ChatNetwork.otherBridge : ChatNetwork.matrix);
}
