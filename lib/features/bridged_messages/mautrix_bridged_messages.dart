import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../room_events.dart';
import 'bridged_message_features.dart';
import 'bridged_message_models.dart';

const _maxProvisioningResponseBytes = 128 * 1024;
const _maxSearchResults = 50;

@immutable
class ProvisioningAuth {
  const ProvisioningAuth({
    required this.userId,
    required this.accessToken,
    this.deviceId,
  });

  final String userId;
  final String accessToken;
  final String? deviceId;
}

@immutable
class _ProvisioningResponse {
  const _ProvisioningResponse(this.status, this.json);
  final int status;
  final Map<String, Object?>? json;
}

enum _ProvisioningOperation {
  capabilities,
  accounts,
  search,
  resolution,
  creation,
}

class _ProvisioningRequest extends http.Request with http.Abortable {
  _ProvisioningRequest(super.method, super.url, this.abortTrigger);

  @override
  final Future<void> abortTrigger;
}

/// Small HTTP adapter for Mautrix bridgev2's `/_matrix/provision` API.
/// Matrix auth and login ownership are enforced by the bridge on every call.
class MautrixProvisioningApi {
  MautrixProvisioningApi(
    this.endpoints, {
    http.Client? httpClient,
    this.readTimeout = const Duration(seconds: 15),
    this.metaReadTimeout = const Duration(seconds: 80),
    this.createTimeout = const Duration(seconds: 85),
  }) : _http = httpClient ?? http.Client();

  final Map<BridgedService, Uri> endpoints;
  final http.Client _http;
  final Duration readTimeout;

  /// Messenger can wait up to 60s for its socket connection during reconnects
  /// before answering search or identifier calls, and `search_users` then
  /// synchronously refreshes every result's ghost profile (avatar download,
  /// Synapse upload, display name). Live searches measured 44-65s even while
  /// CONNECTED, so the deadline must cover the connection wait plus ghost
  /// sync while staying below the proxy's 90s read timeout.
  final Duration metaReadTimeout;

  /// Creation can also incur Messenger's connection wait plus portal work;
  /// keep it below the proxy's 90s read timeout.
  final Duration createTimeout;

  Future<List<BridgeAccount>> loadAccounts(
    BridgedService service,
    ProvisioningAuth auth,
  ) async {
    final capabilitiesResponse = await _request(
      'GET',
      service,
      const ['v3', 'capabilities'],
      auth,
      operation: _ProvisioningOperation.capabilities,
    );
    final capabilitiesJson = capabilitiesResponse.json;
    if (capabilitiesJson == null ||
        capabilitiesJson['resolve_identifier'] is! Map) {
      throw const BridgedMessageException(
        BridgedMessageErrorKind.malformedResponse,
        'The bridge returned an unreadable capabilities response.',
      );
    }
    final capabilities = BridgeCapabilities.fromProvisioningJson(
      capabilitiesJson,
    );
    final whoami = await _request(
      'GET',
      service,
      const ['v3', 'whoami'],
      auth,
      operation: _ProvisioningOperation.accounts,
    );
    final logins = whoami.json?['logins'];
    if (logins is! List) {
      throw const BridgedMessageException(
        BridgedMessageErrorKind.malformedResponse,
        'The bridge returned an unreadable account list.',
      );
    }
    return [
      for (final login in logins)
        if (login is Map)
          _account(service, Map<String, Object?>.from(login), capabilities)
        else
          throw const BridgedMessageException(
            BridgedMessageErrorKind.malformedResponse,
            'The bridge returned an unreadable account list.',
          ),
    ];
  }

  Future<List<BridgeRecipient>> searchRecipients(
    BridgeAccount account,
    String query,
    ProvisioningAuth auth,
  ) async {
    if (account.availability == BridgeAccountAvailability.disconnected) {
      throw BridgedMessageException(
        BridgedMessageErrorKind.disconnected,
        'The ${account.service.label} account is disconnected. Reconnect it in the bridge, then try again.',
      );
    }
    if (!account.supportsSearch) {
      throw const BridgedMessageException(
        BridgedMessageErrorKind.unsupportedOperation,
        'This account does not support searching for people.',
      );
    }
    final normalizedQuery = normalizeSearchQuery(query);
    final response = await _request(
      'POST',
      account.service,
      const ['v3', 'search_users'],
      auth,
      accountId: account.accountId,
      body: {'query': normalizedQuery},
      operation: _ProvisioningOperation.search,
    );
    final rawResults = response.json?['results'];
    if (rawResults is! List) {
      throw const BridgedMessageException(
        BridgedMessageErrorKind.malformedResponse,
        'The bridge returned an unreadable search response.',
      );
    }
    final recipients = <BridgeRecipient>[];
    final seenIds = <String>{};
    for (final item in rawResults) {
      if (item is! Map) {
        throw const BridgedMessageException(
          BridgedMessageErrorKind.malformedResponse,
          'The bridge returned an unreadable search response.',
        );
      }
      final entry = Map<String, Object?>.from(item);
      final rawId = entry['id'];
      if (rawId is! String) {
        throw const BridgedMessageException(
          BridgedMessageErrorKind.malformedResponse,
          'The bridge returned an unreadable search response.',
        );
      }
      final trimmedId = rawId.trim();
      // Instagram search can include accounts without a positive interop FBID
      // (such as id "0") and does not deduplicate results itself.
      if (!isPositiveMetaUserId(trimmedId) || !seenIds.add(trimmedId)) {
        continue;
      }
      final rawIdentifiers = entry['identifiers'];
      if (rawIdentifiers != null && rawIdentifiers is! List) {
        throw const BridgedMessageException(
          BridgedMessageErrorKind.malformedResponse,
          'The bridge returned an unreadable search response.',
        );
      }
      final identifiers = <String>[
        if (rawIdentifiers is List)
          for (final value in rawIdentifiers)
            if (value is String && value.trim().isNotEmpty) value.trim(),
      ];
      final name = entry['name'];
      final mxid = entry['mxid'];
      recipients.add(
        BridgeRecipient(
          service: account.service,
          accountId: account.accountId,
          identifierType: BridgeIdentifierType.remoteId,
          canonicalIdentifier: trimmedId,
          remoteUserId: trimmedId,
          displayName: name is String && name.trim().isNotEmpty
              ? name.trim()
              : null,
          avatar: parseMxcAvatarUri(entry['avatar_url']),
          identifiers: List.unmodifiable(identifiers),
          ghostMxid: mxid is String && mxid.trim().isNotEmpty
              ? mxid.trim()
              : null,
          verifiedRemoteIdentity: true,
        ),
      );
      if (recipients.length >= _maxSearchResults) break;
    }
    return List.unmodifiable(recipients);
  }

  Future<BridgeRecipient> resolveRecipient(
    BridgeAccount account,
    String identifier,
    ProvisioningAuth auth, {
    String? defaultRegion,
  }) async {
    if (account.availability == BridgeAccountAvailability.disconnected) {
      throw BridgedMessageException(
        BridgedMessageErrorKind.disconnected,
        'The ${account.service.label} account is disconnected. Reconnect it in the bridge, then try again.',
      );
    }
    if (!account.supportsPhone) {
      throw const BridgedMessageException(
        BridgedMessageErrorKind.unsupportedIdentifier,
        'This account does not accept phone numbers.',
      );
    }
    final phone = normalizePhoneNumber(
      identifier,
      defaultRegion: defaultRegion,
    );
    final response = await _request(
      'GET',
      account.service,
      ['v3', 'resolve_identifier', phone],
      auth,
      accountId: account.accountId,
      operation: _ProvisioningOperation.resolution,
    );
    final json = response.json;
    final remoteId = json?['id'];
    if (remoteId is! String || remoteId.isEmpty) {
      throw const BridgedMessageException(
        BridgedMessageErrorKind.malformedResponse,
        'The bridge returned an unreadable recipient response.',
      );
    }
    return BridgeRecipient(
      service: account.service,
      accountId: account.accountId,
      identifierType: BridgeIdentifierType.phoneNumber,
      canonicalIdentifier: phone,
      remoteUserId: remoteId,
      displayName: json?['name'] is String ? json!['name'] as String : null,
      avatar: parseMxcAvatarUri(json?['avatar_url']),
      // A bare phone response is explicitly synthetic in the Google connector.
      verifiedRemoteIdentity: false,
    );
  }

  Future<BridgeConversation> ensureDirectConversation(
    BridgeAccount account,
    BridgeRecipient recipient,
    ProvisioningAuth auth,
  ) async {
    if (recipient.service != account.service ||
        recipient.accountId != account.accountId) {
      throw const BridgedMessageException(
        BridgedMessageErrorKind.permissionDenied,
        'The recipient belongs to a different account. Select it again.',
      );
    }
    if (!account.canCreate) {
      throw BridgedMessageException(
        account.availability == BridgeAccountAvailability.disconnected
            ? BridgedMessageErrorKind.disconnected
            : BridgedMessageErrorKind.unsupportedOperation,
        account.availability == BridgeAccountAvailability.disconnected
            ? 'The ${account.service.label} account is disconnected. Reconnect it in the bridge, then try again.'
            : 'This account does not support starting new conversations.',
      );
    }
    final String targetIdentifier;
    switch (recipient.identifierType) {
      case BridgeIdentifierType.phoneNumber:
        if (!account.supportsPhone) {
          throw const BridgedMessageException(
            BridgedMessageErrorKind.unsupportedIdentifier,
            'This account does not accept that identifier type.',
          );
        }
        targetIdentifier = normalizePhoneNumber(recipient.canonicalIdentifier);
      case BridgeIdentifierType.remoteId:
        if (!account.capabilities.supportedIdentifierTypes.contains(
          BridgeIdentifierType.remoteId,
        )) {
          throw const BridgedMessageException(
            BridgedMessageErrorKind.unsupportedIdentifier,
            'This account does not accept that identifier type.',
          );
        }
        targetIdentifier = normalizeMetaUserId(recipient.canonicalIdentifier);
      case BridgeIdentifierType.username:
        throw const BridgedMessageException(
          BridgedMessageErrorKind.unsupportedIdentifier,
          'This account does not accept that identifier type.',
        );
    }
    final response = await _request(
      'POST',
      account.service,
      ['v3', 'create_dm', targetIdentifier],
      auth,
      accountId: account.accountId,
      operation: _ProvisioningOperation.creation,
    );
    final roomId = response.json?['dm_room_mxid'];
    if (roomId is! String || !isUsableRoomId(roomId)) {
      throw const BridgedMessageException(
        BridgedMessageErrorKind.malformedResponse,
        'The bridge returned an unreadable room response. Check your conversations before trying again.',
        definiteNonCreation: false,
      );
    }
    return BridgeConversation(
      roomId: roomId,
      accountId: account.accountId,
      service: account.service,
      createdOrExisting: ConversationCreationState.unknown,
      portalCreated: response.status == 201,
    );
  }

  Uri _base(BridgedService service) {
    final base = endpoints[service];
    if (base == null) {
      throw BridgedMessageException(
        BridgedMessageErrorKind.unsupportedOperation,
        '${service.label} is not configured for new conversations.',
      );
    }
    return base;
  }

  BridgeAccount _account(
    BridgedService service,
    Map<String, Object?> login,
    BridgeCapabilities capabilities,
  ) {
    final id = login['id'];
    if (id is! String || id.isEmpty || id.length > 512) {
      throw const BridgedMessageException(
        BridgedMessageErrorKind.malformedResponse,
        'The bridge returned an unreadable account list.',
      );
    }
    final profile = switch (login['profile']) {
      final Map value => Map<String, Object?>.from(value),
      _ => const <String, Object?>{},
    };
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value.trim() : null;
    final name =
        text(login['name']) ??
        text(profile['name']) ??
        text(profile['username']) ??
        '${service.label} account';
    final state = switch (login['state']) {
      final Map value => Map<String, Object?>.from(value),
      _ => const <String, Object?>{},
    };
    final event = text(state['state_event']) ?? text(login['state_event']);
    final availability = switch (event?.toUpperCase()) {
      'CONNECTED' ||
      'RUNNING' ||
      'BACKFILLING' => BridgeAccountAvailability.connected,
      'LOGGED_OUT' ||
      'BAD_CREDENTIALS' ||
      'TRANSIENT_DISCONNECT' ||
      'BRIDGE_UNREACHABLE' => BridgeAccountAvailability.disconnected,
      _ => BridgeAccountAvailability.unknown,
    };
    return BridgeAccount(
      service: service,
      accountId: id,
      displayName: name,
      capabilities: capabilities,
      availability: availability,
    );
  }

  Duration _deadlineFor(
    BridgedService service,
    _ProvisioningOperation operation,
  ) {
    if (operation == _ProvisioningOperation.creation) return createTimeout;
    if (service.isMeta) return metaReadTimeout;
    return readTimeout;
  }

  Future<_ProvisioningResponse> _request(
    String method,
    BridgedService service,
    List<String> pathSegments,
    ProvisioningAuth auth, {
    String? accountId,
    Map<String, Object?>? body,
    required _ProvisioningOperation operation,
  }) async {
    final base = _base(service);
    final creating = operation == _ProvisioningOperation.creation;
    final deadline = _deadlineFor(service, operation);
    final uri = base.replace(
      pathSegments: [...base.pathSegments, ...pathSegments],
      queryParameters: {'user_id': auth.userId, 'login_id': ?accountId},
    );
    final abort = Completer<void>();
    final request = _ProvisioningRequest(method, uri, abort.future)
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers['Accept'] = 'application/json'
      ..headers['Authorization'] = 'Bearer ${auth.accessToken}';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    // package:http's IOClient aborts both a pending request and a response
    // stream. Future.timeout remains a backstop for other Client implementations.
    final timer = Timer(deadline, () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      return await (() async {
        final streamed = await _http.send(request);
        final bytes = await _readBounded(streamed, creating: creating);
        Map<String, Object?>? json;
        if (bytes.isNotEmpty) {
          try {
            final decoded = jsonDecode(utf8.decode(bytes));
            if (decoded is Map) json = Map<String, Object?>.from(decoded);
          } on FormatException {
            // A proxy/bridge error can be plain text or HTML; its HTTP status
            // remains useful. Successful creation/read responses must be JSON.
            if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
              rethrow;
            }
          }
        }
        final response = _ProvisioningResponse(streamed.statusCode, json);
        if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
          throw _responseError(service, response, operation);
        }
        return response;
      })().timeout(deadline);
    } on TimeoutException {
      throw _transportError(service, creating);
    } on http.RequestAbortedException {
      throw _transportError(service, creating);
    } on BridgedMessageException {
      rethrow;
    } on FormatException {
      throw BridgedMessageException(
        BridgedMessageErrorKind.malformedResponse,
        creating
            ? 'The bridge returned an unreadable response. Check your conversations before trying again.'
            : 'The bridge returned an unreadable response.',
        definiteNonCreation: !creating,
      );
    } catch (_) {
      throw _transportError(service, creating);
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<Uint8List> _readBounded(
    http.StreamedResponse response, {
    required bool creating,
  }) async {
    final declared = response.contentLength;
    if (declared != null && declared > _maxProvisioningResponseBytes) {
      final subscription = response.stream.listen((_) {}, onError: (_) {});
      await subscription.cancel();
      throw _oversizedResponse(creating);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > _maxProvisioningResponseBytes) {
        throw _oversizedResponse(creating);
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  BridgedMessageException _oversizedResponse(
    bool creating,
  ) => BridgedMessageException(
    BridgedMessageErrorKind.malformedResponse,
    creating
        ? 'The bridge response was too large to read safely. Check your conversations before trying again.'
        : 'The bridge response was too large to read safely.',
    definiteNonCreation: !creating,
  );

  BridgedMessageException _transportError(
    BridgedService service,
    bool creating,
  ) => BridgedMessageException(
    creating
        ? BridgedMessageErrorKind.uncertainOutcome
        : BridgedMessageErrorKind.bridgeUnavailable,
    creating
        ? '${service.label} did not confirm the conversation. Check your conversations before trying again.'
        : 'Couldn’t reach ${service.label}. Check the connection and try again.',
    definiteNonCreation: !creating,
  );

  BridgedMessageException _responseError(
    BridgedService service,
    _ProvisioningResponse response,
    _ProvisioningOperation operation,
  ) {
    final creating = operation == _ProvisioningOperation.creation;
    final code = response.json?['errcode'];
    final status = response.status;
    if (code == 'M_LIMIT_EXCEEDED' || status == 429) {
      return BridgedMessageException(
        BridgedMessageErrorKind.rateLimited,
        '${service.label} is rate-limiting requests. Wait before trying again.',
      );
    }
    if (code == 'M_UNRECOGNIZED' || status == 405 || status == 501) {
      return BridgedMessageException(
        BridgedMessageErrorKind.unsupportedOperation,
        operation == _ProvisioningOperation.capabilities ||
                operation == _ProvisioningOperation.accounts
            ? 'This bridge does not provide the required account-discovery API.'
            : operation == _ProvisioningOperation.search
            ? 'This bridge does not support searching for people.'
            : 'This bridge does not support starting conversations this way.',
      );
    }
    if (code == 'FI.MAU.NOT_LOGGED_IN' || code == 'FI.MAU.NOT_CONNECTED') {
      return BridgedMessageException(
        BridgedMessageErrorKind.disconnected,
        'The ${service.label} account is disconnected. Reconnect it in the bridge, then try again.',
      );
    }
    if (code == 'M_UNKNOWN_TOKEN' ||
        code == 'M_MISSING_TOKEN' ||
        status == 401) {
      return BridgedMessageException(
        BridgedMessageErrorKind.disconnected,
        'Your Matrix session was not accepted by ${service.label}. Check the bridge connection or sign in again.',
      );
    }
    if ((operation == _ProvisioningOperation.search ||
            operation == _ProvisioningOperation.resolution ||
            creating) &&
        (code == 'M_INVALID_PARAM' ||
            code == 'M_NOT_JSON' ||
            code == 'M_BAD_JSON' ||
            (status == 400 && code == null))) {
      return BridgedMessageException(
        BridgedMessageErrorKind.invalidIdentifier,
        operation == _ProvisioningOperation.search
            ? '${service.label} rejected that search. Try a shorter name or username.'
            : service.isMeta
            ? '${service.label} could not use that recipient. Search again and select a person from the results.'
            : '${service.label} could not use that recipient. Check the phone number and try again.',
      );
    }
    if (code == 'M_FORBIDDEN' || status == 403) {
      return BridgedMessageException(
        BridgedMessageErrorKind.permissionDenied,
        creating
            ? 'The bridge rejected this account or recipient. The outcome is uncertain; check your conversations before trying again.'
            : 'The bridge rejected this account or request. Check the account connection and permissions.',
        // Remote credential/permission failures can come back after a remote
        // setup RPC, so a create-time 403 is not proof of no creation.
        definiteNonCreation: !creating,
      );
    }
    if (code == 'M_NOT_FOUND' || status == 404) {
      if (operation == _ProvisioningOperation.capabilities ||
          operation == _ProvisioningOperation.accounts) {
        return const BridgedMessageException(
          BridgedMessageErrorKind.unsupportedOperation,
          'This bridge does not provide the required account-discovery API.',
        );
      }
      return const BridgedMessageException(
        BridgedMessageErrorKind.recipientNotFound,
        'The selected account or recipient was not found. Refresh and try again.',
      );
    }
    if (!creating && status >= 400 && status < 500) {
      return BridgedMessageException(
        BridgedMessageErrorKind.bridgeUnavailable,
        'The ${service.label} bridge rejected the request. Check its connection and configuration, then try again.',
      );
    }
    return _transportError(service, creating);
  }
}

/// Live module implementation. It pins each operation to the current Matrix
/// client, user and device (a refreshed access token is the same session), and
/// never gives the SDK token to a URL that was not supplied in trusted build
/// configuration.
class MatrixBridgedMessages implements BridgedMessageFeatures {
  MatrixBridgedMessages(
    this.backend,
    this.config, {
    MautrixProvisioningApi? api,
  }) : _api = api ?? MautrixProvisioningApi(config.endpoints);

  final ChatBackend backend;
  final BridgedMessageConfig config;
  final MautrixProvisioningApi _api;
  List<String> _serviceWarnings = const [];

  MatrixSdkAccess get _sdk => backend as MatrixSdkAccess;

  @override
  String? get defaultPhoneRegion => config.defaultPhoneRegion;

  @override
  List<String> get serviceWarnings => _serviceWarnings;

  @override
  Future<List<BridgeAccount>> loadAccounts() async {
    final context = _context();
    final services = config.endpoints.keys.toList(growable: false);
    final results = await Future.wait(
      services.map((service) async {
        try {
          final loaded = await _api.loadAccounts(service, context.auth);
          return (accounts: loaded, error: null);
        } catch (error) {
          return (accounts: null, error: error);
        }
      }),
    );
    _check(context);
    final accounts = <BridgeAccount>[];
    final warnings = <String>[];
    Object? firstError;
    var anySucceeded = false;
    for (var i = 0; i < services.length; i++) {
      final result = results[i];
      if (result.accounts case final loaded?) {
        anySucceeded = true;
        accounts.addAll(loaded);
      } else if (result.error case final error?) {
        firstError ??= error;
        warnings.add(
          error is BridgedMessageException
              ? error.message
              : 'Couldn’t load ${services[i].label} accounts.',
        );
      }
    }
    if (!anySucceeded && firstError != null) {
      _serviceWarnings = const [];
      Error.throwWithStackTrace(firstError, StackTrace.current);
    }
    _serviceWarnings = List.unmodifiable(warnings);
    return List.unmodifiable(accounts);
  }

  @override
  Future<List<BridgeRecipient>> searchRecipients(
    BridgeAccount account,
    String query,
  ) async {
    final context = _context();
    final recipients = await _api.searchRecipients(
      account,
      query,
      context.auth,
    );
    _check(context);
    return recipients;
  }

  @override
  Future<BridgeRecipient> resolveRecipient(
    BridgeAccount account,
    String identifier,
  ) async {
    final context = _context();
    final recipient = await _api.resolveRecipient(
      account,
      identifier,
      context.auth,
      defaultRegion: defaultPhoneRegion,
    );
    _check(context);
    return recipient;
  }

  @override
  Future<BridgeConversation> ensureDirectConversation(
    BridgeAccount account,
    BridgeRecipient recipient,
  ) async {
    final context = _context();
    final conversation = await _api.ensureDirectConversation(
      account,
      recipient,
      context.auth,
    );
    _check(context);
    return conversation;
  }

  _MatrixContext _context() {
    final client = _sdk.sdkClient;
    final userId = client?.userID;
    final token = client?.accessToken;
    if (client == null ||
        userId == null ||
        token == null ||
        token.isEmpty ||
        !client.isLogged()) {
      throw const BridgedMessageException(
        BridgedMessageErrorKind.disconnected,
        'Your Matrix session is unavailable. Reconnect before starting a conversation.',
      );
    }
    return _MatrixContext(
      client,
      ProvisioningAuth(
        userId: userId,
        accessToken: token,
        deviceId: client.deviceID,
      ),
    );
  }

  void _check(_MatrixContext context) {
    final auth = context.auth;
    // Pin the session identity (client, user, device), not the access-token
    // string. The SDK routinely refreshes the token during long bridge calls
    // (create_dm can wait ~40-60s for the phone); a refresh keeps the same
    // client/user/device and signed-in state. Treating it as a session change
    // threw StateError AFTER the bridge created the room, discarding the
    // confirmed room ID and locking creation into a permanent uncertain state.
    if (!_sdk.isSessionCurrent(context.client) ||
        context.client.userID != auth.userId ||
        context.client.deviceID != auth.deviceId) {
      throw StateError('Session changed during bridge operation');
    }
  }
}

class _MatrixContext {
  const _MatrixContext(this.client, this.auth);
  final matrix.Client client;
  final ProvisioningAuth auth;
}
