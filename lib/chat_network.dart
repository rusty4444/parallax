/// Which app a chat comes from: a native Matrix room, or a room bridged
/// from WhatsApp, Messenger, Google Messages and so on. Drives the app logo
/// shown for chats without a picture (Settings → Appearance).
library;

enum ChatNetwork {
  /// No evidence either way: show the letter, don't guess.
  unknown('Unknown'),
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
  bool get hasLogo => this != otherBridge && this != unknown;
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
  'wa_': ChatNetwork.whatsapp,
  'ig_': ChatNetwork.instagram,
  'fb_': ChatNetwork.messenger,
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
  return _networkForLocalpart(
    (colon < 0 ? userId.substring(1) : userId.substring(1, colon))
        .toLowerCase(),
  );
}

/// The network a portal's alias names (`#whatsapp_…:server`), if any. Bridge
/// aliases follow the same naming as the ghosts, and alias state is loaded
/// even in rooms whose members aren't.
ChatNetwork? chatNetworkForAlias(String alias) {
  if (!alias.startsWith('#')) return null;
  final colon = alias.indexOf(':');
  return _networkForLocalpart(
    (colon < 0 ? alias.substring(1) : alias.substring(1, colon)).toLowerCase(),
  );
}

ChatNetwork? _networkForLocalpart(String localpart) {
  final bot = _bots[localpart];
  if (bot != null) return bot;
  for (final MapEntry(key: prefix, value: network) in _puppetPrefixes.entries) {
    if (localpart.startsWith(prefix) && localpart.length > prefix.length) {
      return network;
    }
  }
  return null;
}

/// A room's network, from strongest to weakest evidence:
/// 1. [bridgeStates]: the content of its `m.bridge`/`uk.half-shot.bridge`
///    events (`protocol.id`, `bridgebot`);
/// 2. [userIds]: the people it is named after and its last sender (bridged
///    contacts and bots carry their network in the username);
/// 3. [aliases]: its canonical alias (portal aliases name the network);
/// 4. [memberIds]: room members, when loaded — a portal's ghosts give it
///    away even when nothing above is available.
///
/// Returns [ChatNetwork.matrix] only when there was some evidence and none
/// of it pointed at a bridge, and [ChatNetwork.unknown] when there was
/// nothing to go on (so the UI shows a letter rather than a wrong logo).
ChatNetwork chatNetworkOf({
  required Iterable<Map<String, Object?>> bridgeStates,
  required Iterable<String> userIds,
  Iterable<String> aliases = const [],
  Iterable<String> memberIds = const [],
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
  var evidence = false;
  ChatNetwork? other;

  ChatNetwork? scan(
    Iterable<String> values,
    ChatNetwork? Function(String) lookup,
  ) {
    for (final value in values) {
      if (value.isEmpty) continue;
      evidence = true;
      final network = lookup(value);
      if (network == null) continue;
      if (network != ChatNetwork.otherBridge) return network;
      other = network;
    }
    return null;
  }

  return scan(userIds, chatNetworkForUser) ??
      scan(aliases, chatNetworkForAlias) ??
      scan(memberIds, chatNetworkForUser) ??
      other ??
      (bridged
          ? ChatNetwork.otherBridge
          : evidence
          ? ChatNetwork.matrix
          : ChatNetwork.unknown);
}
