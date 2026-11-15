import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/message_copy_targets.dart';

void main() {
  group('one-time codes', () {
    final cases = <String, String>{
      'Your one-time code is 123456. Do not share it.': '123456',
      'Your verification code: 123-456': '123-456',
      'G-123456 is your Google verification code': 'G-123456',
      'ABC123 is your login code': 'ABC123',
      '123456': '123456',
      '123456.': '123456',
      'Your eight digit security code is 12345678': '12345678',
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(
          messageCopyTarget(entry.key),
          MessageCopyTarget(MessageCopyKind.oneTimeCode, entry.value),
        );
      });
    }
  });

  group('phone numbers', () {
    final cases = <String, String>{
      'Call me on +61 400 123 456': '+61 400 123 456',
      'Mobile: 0412 345 678': '0412 345 678',
      'My number is 0412345678': '0412345678',
      'Call 8123 4567': '8123 4567',
      '+1 (555) 123-4567': '+1 (555) 123-4567',
    };
    for (final entry in cases.entries) {
      test(entry.key, () {
        expect(
          messageCopyTarget(entry.key),
          MessageCopyTarget(MessageCopyKind.phoneNumber, entry.value),
        );
      });
    }
  });

  test('a code takes priority over a phone number in the same message', () {
    expect(
      messageCopyTarget('Call +61 400 123 456 and enter login code 123456'),
      const MessageCopyTarget(MessageCopyKind.oneTimeCode, '123456'),
    );
  });

  test('ordinary numbers, dates and addresses do not become copy actions', () {
    for (final text in [
      'Room 2026',
      'Order 123456',
      'Version 2026.11.15',
      'Server 192.168.1.1',
      'Card 1234 5678 9012 3456',
      'See you at 6',
      '',
    ]) {
      expect(messageCopyTarget(text), isNull, reason: text);
    }
  });

  test('notification values keep their original kind outside the sentence', () {
    expect(
      validMessageCopyValue(MessageCopyKind.phoneNumber, '8123 4567'),
      isTrue,
    );
    expect(
      validMessageCopyValue(MessageCopyKind.oneTimeCode, '123-456'),
      isTrue,
    );
    expect(
      validMessageCopyValue(MessageCopyKind.oneTimeCode, '+61 400 123 456'),
      isFalse,
    );
    expect(validMessageCopyValue(MessageCopyKind.phoneNumber, '1234'), isFalse);
  });
}
