import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';

/// Chat effects compatible with Element Web (`src/effects/index.ts`): the
/// same commands, message types and trigger emoji, so effects sent from
/// either client play in the other.
enum ChatEffectKind {
  confetti,
  fireworks,
  rainfall,
  snowfall,
  spaceInvaders,
  hearts,
}

@immutable
class ChatEffect {
  const ChatEffect({
    required this.kind,
    required this.command,
    required this.msgType,
    required this.emojis,
    required this.description,
    required this.fallbackMessage,
  });
  final ChatEffectKind kind;

  /// Slash command without the slash, e.g. `confetti`.
  final String command;

  /// The `msgtype` sent by `/command message`.
  final String msgType;

  /// Any of these in a message body also triggers the effect.
  final List<String> emojis;
  final String description;

  /// Emote body sent by `/command` without a message.
  final String fallbackMessage;
}

/// Element Web's `CHAT_EFFECTS`, in order.
const chatEffects = <ChatEffect>[
  ChatEffect(
    kind: ChatEffectKind.confetti,
    command: 'confetti',
    msgType: 'nic.custom.confetti',
    emojis: ['🎊', '🎉'],
    description: 'Sends the given message with confetti',
    fallbackMessage: 'sends confetti 🎉',
  ),
  ChatEffect(
    kind: ChatEffectKind.fireworks,
    command: 'fireworks',
    msgType: 'nic.custom.fireworks',
    emojis: ['🎆'],
    description: 'Sends the given message with fireworks',
    fallbackMessage: 'sends fireworks 🎆',
  ),
  ChatEffect(
    kind: ChatEffectKind.rainfall,
    command: 'rainfall',
    msgType: 'io.element.effect.rainfall',
    emojis: ['🌧️', '⛈️', '🌦️'],
    description: 'Sends the given message with rainfall',
    fallbackMessage: 'sends rainfall 🌧️',
  ),
  ChatEffect(
    kind: ChatEffectKind.snowfall,
    command: 'snowfall',
    msgType: 'io.element.effect.snowfall',
    emojis: ['❄', '🌨'],
    description: 'Sends the given message with snowfall',
    fallbackMessage: 'sends snowfall ❄',
  ),
  ChatEffect(
    kind: ChatEffectKind.spaceInvaders,
    command: 'spaceinvaders',
    msgType: 'io.element.effects.space_invaders',
    emojis: ['👾', '🌌'],
    description: 'Sends the given message with a space themed effect',
    fallbackMessage: 'sends space invaders 👾',
  ),
  ChatEffect(
    kind: ChatEffectKind.hearts,
    command: 'hearts',
    msgType: 'io.element.effect.hearts',
    emojis: ['💝'],
    description: 'Sends the given message with hearts',
    fallbackMessage: 'sends hearts 💝',
  ),
];

ChatEffect? chatEffectForCommand(String command) {
  for (final effect in chatEffects) {
    if (effect.command == command) return effect;
  }
  return null;
}

/// Effects triggered by a message, as Element Web decides: a matching
/// `msgtype`, or a trigger emoji anywhere in the body (substring match, so
/// `❄️` matches `❄`).
List<ChatEffect> chatEffectsFor({String? msgtype, required String body}) => [
  for (final effect in chatEffects)
    if (effect.msgType == msgtype || effect.emojis.any(body.contains)) effect,
];

/// Effects for a timeline entry. Only visible, non-redacted room messages
/// count; thread replies never play (as in Element Web). The body has the
/// reply fallback stripped, so quoting an effect does not replay it.
List<ChatEffect> chatEffectsForEntry(ChatEntry entry) {
  if (entry.redacted || entry.eventType != 'm.room.message') return const [];
  final relation = entry.content['m.relates_to'];
  if (relation is Map && relation['rel_type'] == 'm.thread') return const [];
  final msgtype = entry.msgtype ?? entry.content['msgtype'];
  return chatEffectsFor(
    msgtype: msgtype is String ? msgtype : null,
    body: entry.body,
  );
}

/// Decides which timeline entries are *new* (arrived after the room was
/// opened, including your own) so that effects never replay for history.
///
/// * The first observation of the room only plays entries newer than the
///   moment the room opened; everything else is history.
/// * Later, only unseen entries appended after the newest previously seen
///   entry (not back-paginated history) whose timestamp is no older than the
///   room opening minus [clockSkew] play.
/// * A local echo replaced by its server event (a new ID for the same sender
///   and body) does not play twice.
class ChatEffectTracker {
  ChatEffectTracker({
    DateTime? openedAt,
    this.clockSkew = const Duration(seconds: 10),
    this.echoWindow = const Duration(seconds: 60),
  }) : openedAt = openedAt ?? DateTime.now();

  final DateTime openedAt;
  final Duration clockSkew;
  final Duration echoWindow;

  final _seen = <String>{};
  final _fingerprints = <String, String>{};
  final _vanished = <(String, DateTime)>[];
  List<String> _previous = const [];
  bool _primed = false;

  static String _fingerprint(ChatEntry entry) =>
      '${entry.sender}\u0000${entry.msgtype}\u0000${entry.body}';

  /// Records [entries] (oldest first) and returns the effects of new ones.
  List<ChatEffect> observe(List<ChatEntry> entries, {DateTime? now}) {
    final clock = now ?? DateTime.now();
    final ids = [for (final entry in entries) entry.id];
    final current = ids.toSet();
    // Entries that disappeared since the last observation (local echoes
    // replaced by their remote echo, redactions …).
    for (final id in _previous) {
      if (!current.contains(id)) {
        final fingerprint = _fingerprints[id];
        if (fingerprint != null) _vanished.add((fingerprint, clock));
      }
    }
    _vanished.removeWhere((item) => clock.difference(item.$2) > echoWindow);

    // Index of the newest entry seen before; unseen entries before it were
    // back-paginated history.
    var lastSeenIndex = -1;
    for (var i = entries.length - 1; i >= 0; i--) {
      if (_seen.contains(entries[i].id)) {
        lastSeenIndex = i;
        break;
      }
    }
    final effects = <ChatEffect>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (!_seen.add(entry.id)) continue;
      final fingerprint = _fingerprint(entry);
      _fingerprints[entry.id] = fingerprint;
      final echo = _vanished.indexWhere((item) => item.$1 == fingerprint);
      if (echo >= 0) {
        _vanished.removeAt(echo);
        continue;
      }
      if (i <= lastSeenIndex) continue;
      final recent = _primed
          ? !entry.time.isBefore(openedAt.subtract(clockSkew))
          : entry.time.isAfter(openedAt);
      if (!recent) continue;
      for (final effect in chatEffectsForEntry(entry)) {
        if (!effects.contains(effect)) effects.add(effect);
      }
    }
    if (entries.isNotEmpty) _primed = true;
    _previous = ids;
    return effects;
  }
}
