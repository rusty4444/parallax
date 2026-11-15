import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/bridged_messages/bridged_message_models.dart';

void main() {
  group('BridgedMessageConfig', () {
    test('is disabled and unavailable by default', () {
      final config = BridgedMessageConfig.fromValues();
      expect(config.enabled, isFalse);
      expect(config.available, isFalse);
      expect(config.endpoints, isEmpty);
    });

    test('accepts trusted HTTPS Mautrix provisioning bases per service', () {
      final config = BridgedMessageConfig.fromValues(
        enabled: true,
        googleMessagesUrl: 'https://messages.example.org/_matrix/provision/',
        messengerUrl: 'https://messenger.example.org/bridge/_matrix/provision/',
        instagramUrl: 'https://instagram.example.org/_matrix/provision',
        defaultPhoneRegion: 'au',
      );
      expect(config.available, isTrue);
      expect(
        config.endpoints[BridgedService.googleMessages].toString(),
        'https://messages.example.org/_matrix/provision',
      );
      expect(
        config.endpoints[BridgedService.messenger].toString(),
        'https://messenger.example.org/bridge/_matrix/provision',
      );
      expect(
        config.endpoints[BridgedService.instagram].toString(),
        'https://instagram.example.org/_matrix/provision',
      );
      expect(config.defaultPhoneRegion, 'AU');
    });

    test('can enable Meta services without Google Messages', () {
      final config = BridgedMessageConfig.fromValues(
        enabled: true,
        instagramUrl: 'https://instagram.example.org/_matrix/provision',
      );
      expect(config.available, isTrue);
      expect(config.endpoints.keys, [BridgedService.instagram]);
    });

    for (final url in [
      'http://messages.example.org/_matrix/provision',
      'https://user:password@messages.example.org/_matrix/provision',
      'https://messages.example.org/_matrix/provision?token=secret',
      'https://messages.example.org/_matrix/provision#fragment',
      'https://messages.example.org/other',
      'not a URL',
    ]) {
      test('rejects untrusted base $url', () {
        expect(trustedProvisioningUri(url), isNull);
        expect(
          BridgedMessageConfig.fromValues(
            enabled: true,
            googleMessagesUrl: url,
            messengerUrl: url,
            instagramUrl: url,
          ).available,
          isFalse,
        );
      });
    }
  });

  group('phone numbers', () {
    test('normalises an Australian national number with configured region', () {
      expect(
        normalizePhoneNumber('0412 345 678', defaultRegion: 'AU'),
        '+61412345678',
      );
    });

    test('accepts explicit international numbers and ordinary punctuation', () {
      expect(normalizePhoneNumber('+1 (202) 555-0100'), '+12025550100');
    });

    test('does not guess a region for a national number', () {
      expect(
        () => normalizePhoneNumber('0412 345 678'),
        throwsA(
          isA<BridgedMessageException>().having(
            (error) => error.kind,
            'kind',
            BridgedMessageErrorKind.invalidIdentifier,
          ),
        ),
      );
    });

    test('rejects invalid syntax and overlong input', () {
      for (final input in ['', 'not a phone', '+61412', '1' * 65]) {
        expect(
          () => normalizePhoneNumber(input, defaultRegion: 'AU'),
          throwsA(isA<BridgedMessageException>()),
          reason: input,
        );
      }
    });
  });

  test(
    'maps deployed Google Messages capabilities without inventing search',
    () {
      final capabilities = BridgeCapabilities.fromProvisioningJson({
        'resolve_identifier': {
          'create_dm': true,
          'lookup_phone': false,
          'lookup_email': false,
          'lookup_username': false,
          'any_phone': true,
          'contact_list': false,
          'search': false,
        },
      });
      expect(capabilities.canCreateDirectConversation, isTrue);
      expect(capabilities.canUseAnyPhoneNumber, isTrue);
      expect(capabilities.canResolvePhoneNumber, isFalse);
      expect(capabilities.canSearchRecipients, isFalse);
      expect(capabilities.canListContacts, isFalse);
      expect(capabilities.supportedIdentifierTypes, {
        BridgeIdentifierType.phoneNumber,
      });
    },
  );

  test('maps deployed Meta capabilities to search and remoteId', () {
    final capabilities = BridgeCapabilities.fromProvisioningJson({
      'resolve_identifier': {
        'create_dm': true,
        'lookup_phone': false,
        'lookup_email': false,
        'lookup_username': false,
        'any_phone': false,
        'contact_list': false,
        'search': true,
      },
    });
    expect(capabilities.canCreateDirectConversation, isTrue);
    expect(capabilities.canSearchRecipients, isTrue);
    expect(capabilities.canUseAnyPhoneNumber, isFalse);
    expect(capabilities.supportedIdentifierTypes, {
      BridgeIdentifierType.remoteId,
    });
    final account = BridgeAccount(
      service: BridgedService.instagram,
      accountId: 'ig-1',
      displayName: '@me',
      capabilities: capabilities,
      availability: BridgeAccountAvailability.connected,
    );
    expect(account.supportsSearch, isTrue);
    expect(account.supportsPhone, isFalse);
  });

  group('Meta search queries, user IDs, identifiers and avatars', () {
    test('normalises search queries and strips leading @ on handles', () {
      expect(normalizeSearchQuery('  @alice_123  '), 'alice_123');
      expect(normalizeSearchQuery('  Alice Smith  '), 'Alice Smith');
      expect(normalizeSearchQuery('@Alice Smith'), '@Alice Smith');
    });

    test('rejects empty, overlong or control-character search queries', () {
      for (final query in ['', '   ', '@', 'a' * 65, 'alice\n', 'bob\x00']) {
        expect(
          () => normalizeSearchQuery(query),
          throwsA(
            isA<BridgedMessageException>().having(
              (error) => error.kind,
              'kind',
              BridgedMessageErrorKind.invalidIdentifier,
            ),
          ),
          reason: query,
        );
      }
    });

    test('accepts only positive signed-64-bit Meta user IDs', () {
      for (final valid in ['1', '17841400000000001', '9223372036854775807']) {
        expect(isPositiveMetaUserId(valid), isTrue, reason: valid);
        expect(normalizeMetaUserId(' $valid '), valid);
      }
      for (final invalid in [
        '',
        '0',
        '0123',
        '+123',
        '-123',
        '9223372036854775808',
        '99999999999999999999',
        'alice',
      ]) {
        expect(isPositiveMetaUserId(invalid), isFalse, reason: invalid);
        expect(
          () => normalizeMetaUserId(invalid),
          throwsA(isA<BridgedMessageException>()),
          reason: invalid,
        );
      }
    });

    test('formats public handles while hiding internal numeric IDs', () {
      expect(
        formatBridgeIdentifier('instagram:alice.example'),
        '@alice.example',
      );
      expect(formatBridgeIdentifier('instagram:@alice'), '@alice');
      expect(formatBridgeIdentifier('facebook:100001234567890'), isNull);
      expect(formatBridgeIdentifier('facebook:alice.smith'), 'alice.smith');
      expect(formatBridgeIdentifier('bad\nvalue'), isNull);

      const recipient = BridgeRecipient(
        service: BridgedService.instagram,
        accountId: 'ig-login',
        identifierType: BridgeIdentifierType.remoteId,
        canonicalIdentifier: '17841400000000001',
        displayName: 'Alice Example',
        identifiers: [
          'instagram:alice.example',
          'instagram:@alice.example',
          'facebook:17841400000000001',
        ],
      );
      expect(recipient.displayLabel, 'Alice Example');
      expect(recipient.formattedIdentifiers, '@alice.example');
    });

    test('accepts only strict mxc avatar URIs', () {
      expect(
        parseMxcAvatarUri('mxc://example.org/AbCdEf123')?.toString(),
        'mxc://example.org/AbCdEf123',
      );
      for (final raw in [
        null,
        123,
        '',
        'https://example.org/avatar.png',
        'mxc:///missing-host',
        'mxc://example.org/',
        'mxc://example.org/two/segments',
        'mxc://user@example.org/media',
        'mxc://example.org/media?width=64',
        'mxc://example.org/media#frag',
      ]) {
        expect(parseMxcAvatarUri(raw), isNull, reason: '$raw');
      }
    });
  });

  test('disconnected accounts cannot submit creation', () {
    const capabilities = BridgeCapabilities(
      canListContacts: false,
      canSearchRecipients: false,
      canResolvePhoneNumber: false,
      canResolveUsername: false,
      canUseAnyPhoneNumber: true,
      canCreateDirectConversation: true,
      supportedIdentifierTypes: {BridgeIdentifierType.phoneNumber},
    );
    const account = BridgeAccount(
      service: BridgedService.googleMessages,
      accountId: 'login',
      displayName: 'Personal',
      capabilities: capabilities,
      availability: BridgeAccountAvailability.disconnected,
    );
    expect(account.canCreate, isFalse);
  });

  test(
    'room IDs require a nonempty localpart and valid Matrix server name',
    () {
      expect(isUsableRoomId('!room:example.org'), isTrue);
      expect(isUsableRoomId('!a:b'), isTrue);
      expect(isUsableRoomId('!room:example.org:8448'), isTrue);
      expect(isUsableRoomId('!room:[::1]:8448'), isTrue);
      for (final value in [
        '!room',
        '!:example.org',
        '!room:',
        '!room:bad host',
        '!room:example.org:port',
        'room:example.org',
        '!ro om:example.org',
      ]) {
        expect(isUsableRoomId(value), isFalse, reason: value);
      }
    },
  );
}
