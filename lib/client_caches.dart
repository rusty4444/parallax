/// Account data the Matrix SDK (14.1) parses again on every read, cached per
/// client until the account data event changes.
///
/// `Client.directChats` rebuilds the whole `m.direct` map (one new list per
/// contact) on every access, and `Client.globalPushRules` parses every push
/// rule. `Room.isDirectChat`, `directChatMatrixID`, `getLocalizedDisplayname`
/// and `pushRuleState` read them for each room; for a room that isn't a DM,
/// `directChatMatrixID` also scans all of `m.direct`. Projecting a large
/// account (1,500 rooms, a bridged contact list in `m.direct`) rebuilt the map
/// thousands of times and stalled the UI.
///
/// Sync replaces an account data event rather than editing it, so each cache
/// is keyed to the identity of the event it was built from.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

/// A [Client] whose [directChats] and [globalPushRules] are parsed once per
/// account data event instead of on every read (SDK internals included),
/// and whose image resizing runs off the UI isolate.
class ParallaxClient extends Client {
  ParallaxClient(
    super.clientName, {
    required super.database,
    super.httpClient,
    super.supportedLoginTypes,
    super.onSoftLogout,
    super.verificationMethods,
    super.defaultNetworkRequestTimeout,
    super.importantStateEvents,
    super.nativeImplementations = const ParallaxNativeImplementations(),
  });

  @override
  Map<String, List<String>> get directChats => cachedDirectChats(this);

  @override
  PushRuleSet? get globalPushRules => cachedGlobalPushRules(this);
}

/// The SDK's default implementations run everything on the calling isolate;
/// its own docs warn the UI will likely freeze. Image shrinking and metadata
/// (pure Dart decode, resize, encode and blurhash: about 1–3 s for a 12 MP
/// photo on a phone, per photo of a gallery send) run in [compute] here.
/// Crypto work stays inline: vodozemac's bindings need initialising in each
/// isolate, and those calls are short.
class ParallaxNativeImplementations extends NativeImplementations {
  const ParallaxNativeImplementations();

  static const _inline = NativeImplementations.dummy;

  @override
  Future<MatrixImageFileResizedResponse?> shrinkImage(
    MatrixImageFileResizeArguments args, {
    bool retryInDummy = false,
  }) => compute(MatrixImageFile.resizeImplementation, args);

  @override
  Future<MatrixImageFileResizedResponse?> calcImageMetadata(
    Uint8List bytes, {
    bool retryInDummy = false,
  }) => compute(MatrixImageFile.calcMetadataImplementation, bytes);

  @override
  Future<Uint8List?> decryptFile(
    EncryptedFile file, {
    bool retryInDummy = true,
  }) => _inline.decryptFile(file);

  @override
  Future<RoomKeys> generateUploadKeys(
    GenerateUploadKeysArgs args, {
    bool retryInDummy = true,
  }) => _inline.generateUploadKeys(args);

  @override
  Future<Uint8List> keyFromPassphrase(
    KeyFromPassphraseArgs args, {
    bool retryInDummy = true,
  }) => _inline.keyFromPassphrase(args);

  @override
  FutureOr<bool> checkSecretStorageKey(CheckSecretStorageKeyArgs args) =>
      _inline.checkSecretStorageKey(args);
}

class _DirectChats {
  _DirectChats(this.source, this.chats, this.byRoom);
  final BasicEvent? source;
  final Map<String, List<String>> chats;

  /// The first user whose `m.direct` entry lists each room, as the SDK's
  /// `directChatMatrixID` scan finds it.
  final Map<String, String> byRoom;
}

final _directChats = Expando<_DirectChats>('m.direct');

_DirectChats _directFor(Client client) {
  final source = client.accountData['m.direct'];
  final cached = _directChats[client];
  if (cached != null && identical(cached.source, source)) return cached;
  final chats = <String, List<String>>{};
  final byRoom = <String, String>{};
  for (final MapEntry(key: user, value: list)
      in (source?.content ?? const <String, Object?>{}).entries) {
    // Same shape as the SDK's getter: non-lists become empty lists.
    final rooms = list is List
        ? List<String>.unmodifiable(list.whereType<String>())
        : const <String>[];
    chats[user] = rooms;
    for (final room in rooms) {
      byRoom.putIfAbsent(room, () => user);
    }
  }
  return _directChats[client] = _DirectChats(
    source,
    Map<String, List<String>>.unmodifiable(chats),
    byRoom,
  );
}

/// [Client.directChats] (read-only), rebuilt only when `m.direct` changes.
Map<String, List<String>> cachedDirectChats(Client client) =>
    _directFor(client).chats;

class _PushRules {
  _PushRules(this.source, this.rules, this.roomStates);
  final BasicEvent? source;
  final PushRuleSet? rules;

  /// Per-room [PushRuleState] where a rule decides it, null when no rules.
  final Map<String, PushRuleState>? roomStates;
}

final _pushRules = Expando<_PushRules>('m.push_rules');

_PushRules _pushRulesFor(Client client) {
  final source = client.accountData[EventTypes.PushRules];
  final cached = _pushRules[client];
  if (cached != null && identical(cached.source, source)) return cached;
  final global = source?.content.tryGetMap<String, Object?>('global');
  PushRuleSet? rules;
  Map<String, PushRuleState>? states;
  if (global != null) {
    try {
      rules = PushRuleSet.fromJson(global);
    } catch (_) {
      // As the SDK: a malformed set counts as an empty one.
      rules = PushRuleSet.fromJson(const {});
    }
    states = _roomStates(rules);
  }
  return _pushRules[client] = _PushRules(source, rules, states);
}

bool _silent(PushRule rule) => !rule.actions.any(
  // "dont_notify" and "coalesce" are ignored in actions since spec v1.7.
  (action) => action != 'dont_notify' && action != 'coalesce',
);

/// Room ID → state, decided the way `Room.pushRuleState` does: the first
/// override rule with the room's ID mutes it when it has no actions; else
/// the first room rule with no actions makes it mentions-only.
Map<String, PushRuleState> _roomStates(PushRuleSet rules) {
  final states = <String, PushRuleState>{};
  final decided = <String>{};
  for (final rule in rules.override ?? const <PushRule>[]) {
    if (!decided.add(rule.ruleId)) continue;
    if (_silent(rule)) states[rule.ruleId] = PushRuleState.dontNotify;
  }
  final roomDecided = <String>{};
  for (final rule in rules.room ?? const <PushRule>[]) {
    if (!roomDecided.add(rule.ruleId)) continue;
    if (states.containsKey(rule.ruleId)) continue;
    if (_silent(rule)) states[rule.ruleId] = PushRuleState.mentionsOnly;
  }
  return states;
}

/// [Client.globalPushRules], parsed only when `m.push_rules` changes.
PushRuleSet? cachedGlobalPushRules(Client client) =>
    _pushRulesFor(client).rules;

extension CachedRoomAccountData on Room {
  /// [directChatMatrixID] without scanning `m.direct` for every room: an
  /// invite marked direct is a DM with its sender, otherwise the first user
  /// whose `m.direct` entry lists this room.
  String? get directChatPartner {
    if (membership == Membership.invite) {
      final userID = client.userID;
      if (userID == null) return null;
      final invitation = getState(EventTypes.RoomMember, userID);
      if (invitation != null && invitation.content['is_direct'] == true) {
        return invitation.senderId;
      }
    }
    final user = _directFor(client).byRoom[id];
    return user != null && user.isValidMatrixIdStrict() ? user : null;
  }

  /// [isDirectChat] from the cached `m.direct` index.
  bool get isDirectChatCached => directChatPartner != null;

  /// [pushRuleState] from the cached push rules.
  PushRuleState get pushRuleStateCached {
    final states = _pushRulesFor(client).roomStates;
    if (states == null) return PushRuleState.notify;
    return states[id] ?? PushRuleState.notify;
  }
}
