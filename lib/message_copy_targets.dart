/// The useful part of a message that can be copied without its surrounding text.
enum MessageCopyKind { oneTimeCode, phoneNumber }

class MessageCopyTarget {
  const MessageCopyTarget(this.kind, this.value);

  final MessageCopyKind kind;
  final String value;

  String get label => switch (kind) {
    MessageCopyKind.oneTimeCode => 'Copy code',
    MessageCopyKind.phoneNumber => 'Copy phone number',
  };

  String get confirmation => switch (kind) {
    MessageCopyKind.oneTimeCode => 'Code copied',
    MessageCopyKind.phoneNumber => 'Phone number copied',
  };

  @override
  bool operator ==(Object other) =>
      other is MessageCopyTarget && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

final _codeContext = RegExp(
  r'\b(?:otp|one[- ]time(?:\s+(?:code|pin|password))?|passcode|verification(?:\s+code)?|security\s+code|log[ -]?in\s+code|auth(?:entication)?\s+code|pin)\b',
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
  };
}

/// Finds the most useful exact value to copy from [text].
///
/// Numeric codes need code-related wording unless the whole message is the
/// code. Alphanumeric codes follow the same rule. Phone numbers need a phone
/// cue, international/grouped formatting, or enough digits to be unambiguous.
/// Dates, IP addresses and long card-like numbers are deliberately excluded.
MessageCopyTarget? messageCopyTarget(String text) {
  if (text.trim().isEmpty) return null;
  final standAlone = _standAlone(text);

  for (final match in _alphaNumericCandidate.allMatches(text)) {
    final value = match.group(0)!;
    if (value.length < 4 ||
        value.length > 12 ||
        !_letters.hasMatch(value) ||
        !_digits.hasMatch(value)) {
      continue;
    }
    final nearby = _nearby(text, match.start, match.end);
    if (_codeContext.hasMatch(nearby) || value == standAlone) {
      return MessageCopyTarget(MessageCopyKind.oneTimeCode, value);
    }
  }

  MessageCopyTarget? phone;
  for (final match in _numericCandidate.allMatches(text)) {
    final value = match.group(0)!;
    if (!_notNetworkOrDate(value)) continue;
    final digits = value.replaceAll(_nonDigits, '');
    if (digits.length < 4 || digits.length > 15) continue;
    final nearby = _nearby(text, match.start, match.end);
    final codeContext = _codeContext.hasMatch(nearby);
    final phoneContext = _phoneContext.hasMatch(nearby);

    if (codeContext && digits.length <= 10) {
      return MessageCopyTarget(MessageCopyKind.oneTimeCode, value);
    }
    if (phoneContext && digits.length >= 7) {
      phone ??= MessageCopyTarget(MessageCopyKind.phoneNumber, value);
      continue;
    }
    if (value == standAlone) {
      if (digits.length <= 8) {
        return MessageCopyTarget(MessageCopyKind.oneTimeCode, value);
      }
      phone ??= MessageCopyTarget(MessageCopyKind.phoneNumber, value);
      continue;
    }
    final phoneShaped =
        value.startsWith('+') ||
        value.contains(RegExp(r'[\s().-]')) ||
        digits.length >= 9;
    if (phoneShaped && digits.length >= 7) {
      phone ??= MessageCopyTarget(MessageCopyKind.phoneNumber, value);
    }
  }
  return phone;
}
