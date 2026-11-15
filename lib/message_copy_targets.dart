/// The useful part of a message that can be copied without its surrounding text.
enum MessageCopyKind { oneTimeCode, phoneNumber, ipAddress }

class MessageCopyTarget {
  const MessageCopyTarget(this.kind, this.value);

  final MessageCopyKind kind;
  final String value;

  String get label => switch (kind) {
    MessageCopyKind.oneTimeCode => 'Copy code',
    MessageCopyKind.phoneNumber => 'Copy phone number',
    MessageCopyKind.ipAddress => 'Copy IP address',
  };

  String get confirmation => switch (kind) {
    MessageCopyKind.oneTimeCode => 'Code copied',
    MessageCopyKind.phoneNumber => 'Phone number copied',
    MessageCopyKind.ipAddress => 'IP address copied',
  };

  @override
  bool operator ==(Object other) =>
      other is MessageCopyTarget && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

/// One tappable value inside a message, with its range in that text.
class MessageCopyMatch {
  const MessageCopyMatch(this.kind, this.value, this.start, this.end);

  final MessageCopyKind kind;
  final String value;
  final int start;
  final int end;

  MessageCopyTarget get target => MessageCopyTarget(kind, value);

  @override
  bool operator ==(Object other) =>
      other is MessageCopyMatch &&
      other.kind == kind &&
      other.value == value &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(kind, value, start, end);
}

final _codeContext = RegExp(
  r'\b(?:otp|one[- ]time(?:\s+(?:code|pin|password))?|passcode|verification(?:\s+code)?|security\s+code|log[ -]?in\s+code|auth(?:entication)?\s+code|pin|code)\b',
  caseSensitive: false,
);
final _phoneContext = RegExp(
  r'\b(?:phone(?:\s+number)?|mobile|cell(?:phone)?|call|sms|text(?:\s+message)?|whatsapp|telegram|tel(?:ephone)?)\b',
  caseSensitive: false,
);
final _numericCandidate = RegExp(
  r'(?<![A-Za-z0-9])\+?[0-9](?:[0-9\s()./-]*[0-9])?(?![A-Za-z0-9])',
);
final _alphaNumericCandidate = RegExp(
  r'(?<![A-Za-z0-9])[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*(?![A-Za-z0-9])',
);
final _ipAddressToken = RegExp(
  r'(?<![0-9.])(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(?![0-9.])',
);
final _letters = RegExp(r'[A-Za-z]');
final _digits = RegExp(r'[0-9]');
final _nonDigits = RegExp(r'[^0-9]');
final _date = RegExp(
  r'^(?:[0-9]{4}[-/.][0-9]{1,2}[-/.][0-9]{1,2}|[0-9]{1,2}[-/.][0-9]{1,2}[-/.][0-9]{2,4})$',
);
final _ipAddress = RegExp(r'^[0-9]{1,3}(?:\.[0-9]{1,3}){3}$');

String _standAlone(String text) {
  final trimmed = text.trim();
  return trimmed.replaceFirst(RegExp(r'[.!]$'), '').trim();
}

String _nearby(String text, int start, int end) {
  final from = start > 40 ? start - 40 : 0;
  final to = end + 48 < text.length ? end + 48 : text.length;
  return text.substring(from, to);
}

bool _notNetworkOrDate(String value) =>
    !_date.hasMatch(value) && !_ipAddress.hasMatch(value);

/// Validates a value carried by a notification copy action. This deliberately
/// checks the target's shape rather than reclassifying it: a grouped eight-digit
/// phone number, for example, must remain a phone number outside its sentence.
bool validMessageCopyValue(MessageCopyKind kind, String value) {
  if (value != value.trim() || value.length > 32) return false;
  return switch (kind) {
    MessageCopyKind.oneTimeCode =>
      value.length >= 4 &&
          RegExp(r'^[A-Za-z0-9]+(?:[ -][A-Za-z0-9]+)*$').hasMatch(value) &&
          _digits.hasMatch(value),
    MessageCopyKind.phoneNumber =>
      RegExp(r'^\+?[0-9][0-9\s()./-]*[0-9]$').hasMatch(value) &&
          _notNetworkOrDate(value) &&
          value.replaceAll(_nonDigits, '').length >= 7 &&
          value.replaceAll(_nonDigits, '').length <= 15,
    MessageCopyKind.ipAddress => _ipAddressToken.hasMatch(value),
  };
}

/// Every code, phone number and IP address in [text].
///
/// [context] is the whole message when [text] is only one piece of it, such as
/// an HTML text node. [contextOffset] is where [text] begins in [context].
/// Pass `-1` when the piece is not a contiguous slice and each value should be
/// found in [context] on its own.
List<MessageCopyMatch> messageCopyMatches(
  String text, {
  String? context,
  int contextOffset = 0,
}) {
  if (text.isEmpty) return const [];
  final source = context == null || context == text ? text : context;
  final anchored = source != text && contextOffset >= 0;
  String around(int start, int end) {
    if (source == text) return _nearby(text, start, end);
    if (anchored) {
      return _nearby(source, contextOffset + start, contextOffset + end);
    }
    final value = text.substring(start, end);
    final found = source.indexOf(value);
    if (found < 0) return _nearby(text, start, end);
    return _nearby(source, found, found + value.length);
  }

  final taken = <(int, int)>[];
  bool free(int start, int end) =>
      taken.every((range) => end <= range.$1 || start >= range.$2);

  final matches = <MessageCopyMatch>[];
  void add(MessageCopyKind kind, String value, int start, int end) {
    matches.add(MessageCopyMatch(kind, value, start, end));
    taken.add((start, end));
  }

  for (final match in _ipAddressToken.allMatches(text)) {
    add(MessageCopyKind.ipAddress, match.group(0)!, match.start, match.end);
  }

  final standAlone = _standAlone(source);
  for (final match in _alphaNumericCandidate.allMatches(text)) {
    if (!free(match.start, match.end)) continue;
    final value = match.group(0)!;
    if (value.length < 4 ||
        value.length > 12 ||
        !_letters.hasMatch(value) ||
        !_digits.hasMatch(value)) {
      continue;
    }
    if (_codeContext.hasMatch(around(match.start, match.end)) ||
        (source == text && value == standAlone)) {
      add(MessageCopyKind.oneTimeCode, value, match.start, match.end);
    }
  }

  for (final match in _numericCandidate.allMatches(text)) {
    if (!free(match.start, match.end)) continue;
    final value = match.group(0)!;
    if (!_notNetworkOrDate(value)) continue;
    final digits = value.replaceAll(_nonDigits, '');
    if (digits.length < 4 || digits.length > 15) continue;
    final nearby = around(match.start, match.end);
    final codeContext = _codeContext.hasMatch(nearby);
    final phoneContext = _phoneContext.hasMatch(nearby);

    if (codeContext && digits.length <= 10) {
      add(MessageCopyKind.oneTimeCode, value, match.start, match.end);
      continue;
    }
    if (phoneContext && digits.length >= 7) {
      add(MessageCopyKind.phoneNumber, value, match.start, match.end);
      continue;
    }
    if (source == text && value == standAlone) {
      add(
        digits.length <= 8
            ? MessageCopyKind.oneTimeCode
            : MessageCopyKind.phoneNumber,
        value,
        match.start,
        match.end,
      );
      continue;
    }
    final phoneShaped =
        value.startsWith('+') ||
        value.contains(RegExp(r'[\s().-]')) ||
        digits.length >= 9;
    if (phoneShaped && digits.length >= 7) {
      add(MessageCopyKind.phoneNumber, value, match.start, match.end);
    }
  }

  matches.sort((a, b) => a.start.compareTo(b.start));
  return matches;
}

/// The single value a notification should offer. A code wins over a phone
/// number. IP addresses stay tappable in the message and are not notification
/// actions.
MessageCopyTarget? messageCopyTarget(String text) {
  MessageCopyTarget? phone;
  for (final match in messageCopyMatches(text)) {
    switch (match.kind) {
      case MessageCopyKind.oneTimeCode:
        return match.target;
      case MessageCopyKind.phoneNumber:
        phone ??= match.target;
      case MessageCopyKind.ipAddress:
        break;
    }
  }
  return phone;
}
