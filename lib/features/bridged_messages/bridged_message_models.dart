import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' show MatrixIdExtension;
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

enum BridgedService { googleMessages, messenger, instagram }

extension BridgedServiceLabel on BridgedService {
  String get label => switch (this) {
    BridgedService.googleMessages => 'Google Messages',
    BridgedService.messenger => 'Messenger',
    BridgedService.instagram => 'Instagram',
  };

  bool get isMeta =>
      this == BridgedService.messenger || this == BridgedService.instagram;
}

enum BridgeIdentifierType { phoneNumber, username, remoteId }

enum BridgeAccountAvailability { connected, disconnected, unknown }

enum ConversationCreationState { created, existing, unknown }

enum BridgedMessageErrorKind {
  invalidIdentifier,
  unsupportedIdentifier,
  recipientNotFound,
  unsupportedOperation,
  disconnected,
  permissionDenied,
  rateLimited,
  bridgeUnavailable,
  uncertainOutcome,
  malformedResponse,
}

/// Safe to display and log. Raw bridge errors and recipient input are never
/// retained by this exception.
@immutable
class BridgedMessageException implements Exception {
  const BridgedMessageException(
    this.kind,
    this.message, {
    this.definiteNonCreation = true,
  });

  final BridgedMessageErrorKind kind;
  final String message;
  final bool definiteNonCreation;

  @override
  String toString() => message;
}

@immutable
class BridgeCapabilities {
  const BridgeCapabilities({
    required this.canListContacts,
    required this.canSearchRecipients,
    required this.canResolvePhoneNumber,
    required this.canResolveUsername,
    required this.canUseAnyPhoneNumber,
    required this.canCreateDirectConversation,
    required this.supportedIdentifierTypes,
  });

  factory BridgeCapabilities.fromProvisioningJson(Map<String, Object?> json) {
    final resolve = switch (json['resolve_identifier']) {
      final Map value => Map<String, Object?>.from(value),
      _ => <String, Object?>{},
    };
    bool flag(String name) => resolve[name] == true;
    final canSearch = flag('search');
    final identifiers = <BridgeIdentifierType>{
      if (flag('lookup_phone') || flag('any_phone'))
        BridgeIdentifierType.phoneNumber,
      if (flag('lookup_username')) BridgeIdentifierType.username,
      if (canSearch) BridgeIdentifierType.remoteId,
    };
    return BridgeCapabilities(
      canListContacts: flag('contact_list'),
      canSearchRecipients: canSearch,
      canResolvePhoneNumber: flag('lookup_phone'),
      canResolveUsername: flag('lookup_username'),
      canUseAnyPhoneNumber: flag('any_phone'),
      canCreateDirectConversation: flag('create_dm'),
      supportedIdentifierTypes: Set.unmodifiable(identifiers),
    );
  }

  final bool canListContacts;
  final bool canSearchRecipients;
  final bool canResolvePhoneNumber;
  final bool canResolveUsername;
  final bool canUseAnyPhoneNumber;
  final bool canCreateDirectConversation;
  final Set<BridgeIdentifierType> supportedIdentifierTypes;
}

@immutable
class BridgeAccount {
  const BridgeAccount({
    required this.service,
    required this.accountId,
    required this.displayName,
    required this.capabilities,
    this.availability = BridgeAccountAvailability.unknown,
  });

  final BridgedService service;
  final String accountId;
  final String displayName;
  final BridgeCapabilities capabilities;
  final BridgeAccountAvailability availability;

  String get key => '${service.name}:$accountId';
  bool get canCreate =>
      capabilities.canCreateDirectConversation &&
      availability != BridgeAccountAvailability.disconnected;
  bool get supportsPhone => capabilities.supportedIdentifierTypes.contains(
    BridgeIdentifierType.phoneNumber,
  );
  bool get supportsSearch =>
      capabilities.canSearchRecipients &&
      capabilities.supportedIdentifierTypes.contains(
        BridgeIdentifierType.remoteId,
      );
}

@immutable
class BridgeRecipient {
  const BridgeRecipient({
    required this.service,
    required this.accountId,
    required this.identifierType,
    required this.canonicalIdentifier,
    this.remoteUserId,
    this.displayName,
    this.avatar,
    this.identifiers = const [],
    this.ghostMxid,
    this.verifiedRemoteIdentity = false,
  });

  final BridgedService service;
  final String accountId;
  final String? remoteUserId;
  final String? displayName;
  final Uri? avatar;
  final List<String> identifiers;
  final String? ghostMxid;
  final BridgeIdentifierType identifierType;
  final String canonicalIdentifier;

  /// Google Messages deliberately returns a synthetic ID for a phone-number
  /// lookup. That response is not proof of reachability or RCS availability.
  final bool verifiedRemoteIdentity;

  List<String> get formattedIdentifiersList {
    final seen = <String>{};
    final formatted = <String>[];
    for (final raw in identifiers) {
      final label = formatBridgeIdentifier(raw);
      if (label != null && seen.add(label)) formatted.add(label);
    }
    return List.unmodifiable(formatted);
  }

  String? get formattedIdentifiers {
    final list = formattedIdentifiersList;
    return list.isEmpty ? null : list.join(' · ');
  }

  String get displayLabel {
    final trimmedName = displayName?.trim();
    if (trimmedName != null && trimmedName.isNotEmpty) return trimmedName;
    if (identifierType == BridgeIdentifierType.phoneNumber) {
      return canonicalIdentifier;
    }
    final handles = formattedIdentifiersList;
    if (handles.isNotEmpty) return handles.first;
    return '${service.label} user';
  }
}

@immutable
class BridgeConversation {
  const BridgeConversation({
    required this.roomId,
    required this.accountId,
    required this.service,
    required this.createdOrExisting,
    required this.portalCreated,
  });

  final String roomId;
  final String accountId;
  final BridgedService service;

  /// Mautrix reports whether it created the Matrix portal, not whether the
  /// remote service created a new thread, so this remains unknown.
  final ConversationCreationState createdOrExisting;

  /// Distinguishes HTTP 201 (new Matrix portal) from HTTP 200 (existing one).
  final bool portalCreated;
}

@immutable
class BridgedMessageConfig {
  const BridgedMessageConfig._({
    required this.enabled,
    required this.endpoints,
    required this.defaultPhoneRegion,
  });

  factory BridgedMessageConfig.fromValues({
    bool enabled = false,
    String googleMessagesUrl = '',
    String messengerUrl = '',
    String instagramUrl = '',
    String defaultPhoneRegion = '',
  }) {
    final endpoints = <BridgedService, Uri>{};
    void addEndpoint(BridgedService service, String raw) {
      if (raw.trim().isEmpty) return;
      final uri = trustedProvisioningUri(raw);
      if (uri != null) endpoints[service] = uri;
    }

    addEndpoint(BridgedService.googleMessages, googleMessagesUrl);
    addEndpoint(BridgedService.messenger, messengerUrl);
    addEndpoint(BridgedService.instagram, instagramUrl);
    final region = defaultPhoneRegion.trim().toUpperCase();
    return BridgedMessageConfig._(
      enabled: enabled,
      endpoints: Map.unmodifiable(endpoints),
      defaultPhoneRegion: IsoCode.values.any((code) => code.name == region)
          ? region
          : null,
    );
  }

  factory BridgedMessageConfig.fromEnvironment() =>
      BridgedMessageConfig.fromValues(
        enabled: const bool.fromEnvironment('PARALLAX_NEW_BRIDGED_MESSAGES'),
        googleMessagesUrl: const String.fromEnvironment(
          'PARALLAX_GMESSAGES_PROVISIONING_URL',
        ),
        messengerUrl: const String.fromEnvironment(
          'PARALLAX_MESSENGER_PROVISIONING_URL',
        ),
        instagramUrl: const String.fromEnvironment(
          'PARALLAX_INSTAGRAM_PROVISIONING_URL',
        ),
        defaultPhoneRegion: const String.fromEnvironment(
          'PARALLAX_PHONE_DEFAULT_REGION',
        ),
      );

  final bool enabled;
  final Map<BridgedService, Uri> endpoints;
  final String? defaultPhoneRegion;

  bool get available => enabled && endpoints.isNotEmpty;
}

final _maxSignedInt64 = BigInt.parse('9223372036854775807');
final _positiveDecimalDigits = RegExp(r'^[1-9][0-9]{0,18}$');
final _controlChars = RegExp(r'[\x00-\x1F\x7F]');

/// Only an administrator-supplied HTTPS provisioning base URL is trusted.
/// Credentials, query parameters, fragments and client-selected hosts are not
/// accepted. The URL must include Mautrix's `/_matrix/provision` base path.
Uri? trustedProvisioningUri(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final path = uri.path.replaceFirst(RegExp(r'/+$'), '');
  if (!path.endsWith('/_matrix/provision')) return null;
  return uri.replace(path: path);
}

String normalizePhoneNumber(String input, {String? defaultRegion}) {
  final value = input.trim();
  if (value.isEmpty || value.length > 64) {
    throw const BridgedMessageException(
      BridgedMessageErrorKind.invalidIdentifier,
      'Enter a phone number using up to 64 characters.',
    );
  }
  try {
    if (!value.startsWith('+') && defaultRegion == null) {
      throw const BridgedMessageException(
        BridgedMessageErrorKind.invalidIdentifier,
        'Enter an international number with + and the country code, or choose a default region.',
      );
    }
    final region = defaultRegion == null
        ? null
        : IsoCode.values.byName(defaultRegion.trim().toUpperCase());
    final parsed = PhoneNumber.parse(value, callerCountry: region);
    if (!parsed.isValid()) {
      throw const BridgedMessageException(
        BridgedMessageErrorKind.invalidIdentifier,
        'Enter a valid phone number. Include + and the country code for an international number.',
      );
    }
    return parsed.international;
  } on BridgedMessageException {
    rethrow;
  } catch (_) {
    throw const BridgedMessageException(
      BridgedMessageErrorKind.invalidIdentifier,
      'Enter a valid phone number. Include + and the country code for an international number.',
    );
  }
}

String normalizeSearchQuery(String input) {
  if (_controlChars.hasMatch(input)) {
    throw const BridgedMessageException(
      BridgedMessageErrorKind.invalidIdentifier,
      'Enter a name or username using up to 64 characters.',
    );
  }
  final trimmed = input.trim();
  if (trimmed.isEmpty || trimmed.length > 64) {
    throw const BridgedMessageException(
      BridgedMessageErrorKind.invalidIdentifier,
      'Enter a name or username using up to 64 characters.',
    );
  }
  final normalized = trimmed.startsWith('@') && !trimmed.contains(RegExp(r'\s'))
      ? trimmed.substring(1)
      : trimmed;
  if (normalized.isEmpty) {
    throw const BridgedMessageException(
      BridgedMessageErrorKind.invalidIdentifier,
      'Enter a name or username using up to 64 characters.',
    );
  }
  return normalized;
}

bool isPositiveMetaUserId(String value) {
  if (!_positiveDecimalDigits.hasMatch(value)) return false;
  final parsed = BigInt.tryParse(value);
  return parsed != null && parsed > BigInt.zero && parsed <= _maxSignedInt64;
}

String normalizeMetaUserId(String input) {
  final value = input.trim();
  if (!isPositiveMetaUserId(value)) {
    throw const BridgedMessageException(
      BridgedMessageErrorKind.invalidIdentifier,
      'Select a valid person from the search results.',
    );
  }
  return value;
}

String? formatBridgeIdentifier(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty ||
      trimmed.length > 128 ||
      _controlChars.hasMatch(trimmed)) {
    return null;
  }
  if (trimmed.startsWith('instagram:')) {
    final handle = trimmed.substring('instagram:'.length).trim();
    if (handle.isEmpty) return null;
    return handle.startsWith('@') ? handle : '@$handle';
  }
  if (trimmed.startsWith('facebook:') || trimmed.startsWith('fb:')) {
    final value = trimmed.substring(trimmed.indexOf(':') + 1).trim();
    if (value.isEmpty || isPositiveMetaUserId(value)) return null;
    return value;
  }
  final colon = trimmed.indexOf(':');
  if (colon > 0) {
    final value = trimmed.substring(colon + 1).trim();
    return value.isEmpty ? null : value;
  }
  return trimmed;
}

Uri? parseMxcAvatarUri(Object? raw) {
  if (raw is! String ||
      !raw.startsWith('mxc://') ||
      raw.length > 512 ||
      _controlChars.hasMatch(raw)) {
    return null;
  }
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.scheme != 'mxc' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final segments = uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList();
  return segments.length == 1 ? uri : null;
}

bool isUsableRoomId(String value) {
  if (value.length < 4 ||
      value.length > 255 ||
      !value.startsWith('!') ||
      value.contains(RegExp(r'\s'))) {
    return false;
  }
  final separator = value.indexOf(':');
  return separator > 1 &&
      separator < value.length - 1 &&
      value.isValidMatrixIdStrict(strictDomainCheck: true);
}
