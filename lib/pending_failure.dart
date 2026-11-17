// Why an outbox send failed, in words (the raw error stays available).

/// A short reason for a failed send, from the outbox's stored error.
String pendingFailureReason(String? error) {
  final text = (error ?? '').trim();
  if (text.isEmpty) return 'unknown error';
  final lower = text.toLowerCase();
  bool has(String part) => lower.contains(part);
  if (has('another secure operation') || has('a send is already in progress')) {
    return 'another message was still sending';
  }
  if (has('m_too_large') || has('413') || has('too large')) {
    return 'too large for the server';
  }
  if (has('m_limit_exceeded') || has('429')) {
    return 'the server asked to slow down';
  }
  if (has('timeoutexception') || has('timed out')) {
    return 'the server took too long';
  }
  if (has('socketexception') ||
      has('clientexception') ||
      has('failed host lookup') ||
      has('connection')) {
    return 'no connection to the server';
  }
  if (has('room is no longer joined')) return 'you’re no longer in this room';
  if (has('reply target is unavailable')) {
    return 'the message you replied to isn’t available';
  }
  if (has('can no longer be edited')) {
    return 'that message can no longer be edited';
  }
  if (has('encrypted send was cancelled')) {
    return 'new devices weren’t approved';
  }
  if (has('recipient encryption') ||
      has('encrypted-room participants') ||
      has('blocked encryption identity') ||
      has('encrypted recipients')) {
    return 'couldn’t confirm who can read it (encryption)';
  }
  if (has('still reconnecting')) return 'still reconnecting to your account';
  if (has('sign in again')) return 'you need to sign in again';
  // Stored by builds that failed a send during an access-token renewal.
  if (has('unavailable session')) return 'the account was reconnecting';
  if (has('not acknowledged')) return 'the server didn’t confirm it';
  if (has('m_forbidden')) return 'the server refused it';
  if (has('undo couldn')) return 'undo couldn’t be saved';
  final first = text
      .replaceFirst(
        RegExp(r'^(Bad state|Exception|Invalid argument\(s\)|StateError): '),
        '',
      )
      .split('\n')
      .first;
  return first.length > 90 ? '${first.substring(0, 89)}…' : first;
}
