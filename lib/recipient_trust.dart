import 'chat_backend.dart';

typedef RoomRecipientSnapshot = Map<String, Map<String, String>>;

bool sameRecipientSnapshot(
  RoomRecipientSnapshot approved,
  RoomRecipientSnapshot current,
) {
  if (approved.length != current.length) return false;
  for (final user in approved.entries) {
    final devices = current[user.key];
    if (devices == null || devices.length != user.value.length) return false;
    for (final device in user.value.entries) {
      if (devices[device.key] != device.value) return false;
    }
  }
  return true;
}

/// A send is allowed only for the exact membership and master keys the user saw.
bool sameUntrustedRecipients(
  List<UntrustedRecipient> first,
  List<UntrustedRecipient> second,
) {
  if (first.length != second.length) return false;
  for (var i = 0; i < first.length; i++) {
    if (first[i].userId != second[i].userId ||
        first[i].masterKey != second[i].masterKey) {
      return false;
    }
  }
  return true;
}

Future<void> confirmRecipientTrust({
  required Future<List<UntrustedRecipient>> Function() readRecipients,
  required Future<bool> Function(List<UntrustedRecipient>) askUser,
  required Future<void> Function(UntrustedRecipient) trustKey,
  required bool Function() isCurrentSession,
}) async {
  void checkSession() {
    if (!isCurrentSession()) throw StateError('Encrypted send was cancelled');
  }

  // A changing member list must never turn an old approval into a new one.
  for (var attempt = 0; attempt < 3; attempt++) {
    final recipients = await readRecipients();
    checkSession();
    if (recipients.isEmpty) return;
    final approved = await askUser(recipients);
    checkSession();
    if (!approved) throw StateError('Encrypted send was cancelled');
    final current = await readRecipients();
    checkSession();
    if (!sameUntrustedRecipients(recipients, current)) continue;
    for (final recipient in current) {
      checkSession();
      await trustKey(recipient);
    }
    checkSession();
    return;
  }
  throw StateError('Recipient encryption keys changed; try again');
}
