import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/recipient_trust.dart';

void main() {
  const original = UntrustedRecipient(
    userId: '@friend:example.org',
    masterKey: 'master-A',
  );
  const rotated = UntrustedRecipient(
    userId: '@friend:example.org',
    masterKey: 'master-B',
  );

  test(
    'approved room snapshot rejects new invitees, devices and master keys',
    () {
      const approved = <String, Map<String, String>>{
        '@me:example.org': {'__master__': 'mine', 'SELF': 'self-keys'},
        '@friend:example.org': {'__master__': 'master-A', 'D1': 'device-keys'},
      };
      expect(sameRecipientSnapshot(approved, approved), isTrue);
      expect(
        sameRecipientSnapshot(approved, {
          ...approved,
          '@invitee:example.org': {'__master__': '', 'D2': 'new-keys'},
        }),
        isFalse,
      );
      expect(
        sameRecipientSnapshot(approved, {
          ...approved,
          '@friend:example.org': {
            '__master__': 'master-A',
            'D1': 'device-keys',
            'D2': 'new-keys',
          },
        }),
        isFalse,
      );
      expect(
        sameRecipientSnapshot(approved, {
          ...approved,
          '@friend:example.org': {
            '__master__': 'master-B',
            'D1': 'device-keys',
          },
        }),
        isFalse,
      );
    },
  );

  test('a changed master key or member invalidates an earlier decision', () {
    expect(sameUntrustedRecipients([original], [rotated]), isFalse);
    expect(
      sameUntrustedRecipients(
        [original],
        [original, const UntrustedRecipient(userId: '@new:example.org')],
      ),
      isFalse,
    );
    expect(sameUntrustedRecipients([original], [original]), isTrue);
  });

  test('rejection never records trust', () async {
    final prompted = Completer<void>();
    final decision = Completer<bool>();
    final trusted = <UntrustedRecipient>[];
    final result = confirmRecipientTrust(
      readRecipients: () async => [original],
      askUser: (_) {
        prompted.complete();
        return decision.future;
      },
      trustKey: (recipient) async => trusted.add(recipient),
      isCurrentSession: () => true,
    );
    await prompted.future;
    decision.complete(false);
    await expectLater(result, throwsStateError);
    expect(trusted, isEmpty);
  });

  test(
    'rotation while awaiting approval prompts again instead of trusting',
    () async {
      final firstPrompt = Completer<void>();
      final secondPrompt = Completer<void>();
      final firstDecision = Completer<bool>();
      final secondDecision = Completer<bool>();
      final trusted = <UntrustedRecipient>[];
      var readCount = 0;
      var promptCount = 0;
      final result = confirmRecipientTrust(
        readRecipients: () async => ++readCount == 1 ? [original] : [rotated],
        askUser: (recipients) {
          promptCount++;
          if (promptCount == 1) {
            expect(recipients.single.masterKey, 'master-A');
            firstPrompt.complete();
            return firstDecision.future;
          }
          expect(recipients.single.masterKey, 'master-B');
          secondPrompt.complete();
          return secondDecision.future;
        },
        trustKey: (recipient) async => trusted.add(recipient),
        isCurrentSession: () => true,
      );
      await firstPrompt.future;
      firstDecision.complete(true);
      await secondPrompt.future;
      expect(trusted, isEmpty);
      secondDecision.complete(false);
      await expectLater(result, throwsStateError);
      expect(promptCount, 2);
      expect(trusted, isEmpty);
    },
  );

  test(
    'logout while awaiting approval blocks trust even if user taps send',
    () async {
      final prompted = Completer<void>();
      final decision = Completer<bool>();
      final trusted = <UntrustedRecipient>[];
      var current = true;
      final result = confirmRecipientTrust(
        readRecipients: () async => [original],
        askUser: (_) {
          prompted.complete();
          return decision.future;
        },
        trustKey: (recipient) async => trusted.add(recipient),
        isCurrentSession: () => current,
      );
      await prompted.future;
      current = false;
      decision.complete(true);
      await expectLater(result, throwsStateError);
      expect(trusted, isEmpty);
    },
  );

  test('unchanged approved master key is trusted once', () async {
    final trusted = <UntrustedRecipient>[];
    var reads = 0;
    await confirmRecipientTrust(
      readRecipients: () async {
        reads++;
        return [original];
      },
      askUser: (recipients) async => recipients.single.masterKey == 'master-A',
      trustKey: (recipient) async => trusted.add(recipient),
      isCurrentSession: () => true,
    );
    expect(reads, 2);
    expect(trusted, [original]);
  });
}
