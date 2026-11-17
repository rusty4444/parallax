import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;

import 'homeserver_security.dart';
import 'messaging_features.dart';
import 'secure_store.dart';

/// Deliberately NOT a MatrixException/OidcException: SDK 14.1 clears local
/// encryption/session data when those escape its onSoftLogout callback.
class MatrixAuthException implements Exception {
  const MatrixAuthException(
    this.message, {
    this.statusCode,
    this.retryable = true,
  });
  final String message;
  final int? statusCode;
  final bool retryable;
  @override
  String toString() => message;
}

/// The session/device must be retained while the user signs in again.
class ReauthenticationRequired extends MatrixAuthException {
  const ReauthenticationRequired()
    : super('Sign in again to continue on this device.', retryable: false);
}

// --- OAuth 2.0 device authorization grant (QR code sign-in, MSC4108) -----

enum DeviceAuthorizationFailure {
  /// The authorization server has no device authorization grant.
  unsupported,

  /// The user declined on the other device (`access_denied`).
  declined,

  /// The device code expired (`expired_token`) before approval.
  expired,

  /// This side gave up while waiting.
  cancelled,
}

class DeviceAuthorizationException extends MatrixAuthException {
  const DeviceAuthorizationException(this.failure)
    : super('The device authorization did not complete.', retryable: false);
  final DeviceAuthorizationFailure failure;
}

/// RFC 8628 device authorization response, as forwarded to the device that
/// approves the sign-in (never contains the device code).
class DeviceAuthorizationGrant {
  const DeviceAuthorizationGrant({
    required this.deviceId,
    required this.userCode,
    required this.verificationUri,
    this.verificationUriComplete,
  });
  final String deviceId;
  final String userCode;
  final Uri verificationUri;
  final Uri? verificationUriComplete;
}

/// Authentication boundary for Matrix SDK 14.1.
///
/// HTTP/browser/storage work is owner- and account-pinned. The backend must
/// serialize logout/account replacement while [applyingSession] is true: SDK
/// Client.init and DatabaseApi.storeClient have internal, uncancellable awaits.
/// Logout may invalidate the owner freely before this short commit phase.
class MatrixAuthService {
  MatrixAuthService(
    this.client, {
    required this.ownerCurrent,
    Future<String> Function(String url, String callbackScheme)? authenticate,
    SecureValueStore? storage,
  }) : _authenticate = authenticate ?? _openBrowser,
       _storage = storage ?? const PlatformSecureValueStore();

  static final callbackUri = Uri.parse('net.samrusselltech.parallax:/auth');
  static const callbackScheme = 'net.samrusselltech.parallax';
  static final _leases = Expando<_AuthLease>();

  /// Also available statically when the backend makes an owner-scoped service
  /// for each operation instead of retaining one instance.
  static bool isApplyingSession(matrix.Client client) =>
      _leases[client]?.applyingSession ?? false;

  final matrix.Client client;
  final bool Function() ownerCurrent;
  final Future<String> Function(String, String) _authenticate;
  final SecureValueStore _storage;
  bool _disposed = false;
  _AuthLease get _lease => _leases[client] ??= _AuthLease();
  bool get _busy => _lease.busy;
  set _busy(bool value) => _lease.busy = value;
  bool get _applyingSession => _lease.applyingSession;
  set _applyingSession(bool value) => _lease.applyingSession = value;
  Future<void>? get _refreshing => _lease.refreshing;
  set _refreshing(Future<void>? value) => _lease.refreshing = value;

  bool get applyingSession => _applyingSession;
  bool get busy => _busy;
  void dispose() => _disposed = true;

  static Future<String> _openBrowser(String url, String scheme) =>
      FlutterWebAuth2.authenticate(url: url, callbackUrlScheme: scheme);

  /// Accept a full MXID, server name (including IPv6/port), or HTTPS base URL.
  /// Reject ambiguous email addresses, malformed MXIDs and implicit URL paths.
  static Uri providerUri(String input) {
    var value = input.trim();
    if (value.isEmpty || RegExp(r'[\s\\\x00-\x1f\x7f]').hasMatch(value)) {
      throw const FormatException('Enter a Matrix ID or HTTPS homeserver.');
    }
    if (value.startsWith('@')) {
      final colon = value.indexOf(':');
      if (colon <= 1 || !value.isValidMatrixIdStrict(strictDomainCheck: true)) {
        throw const FormatException('Enter a complete Matrix ID.');
      }
      value = value.substring(colon + 1);
    }
    final explicitUrl = value.contains('://');
    if (!explicitUrl && RegExp(r'[/@?#%]').hasMatch(value)) {
      throw const FormatException('Enter a server name or HTTPS URL.');
    }
    final uri = _parseHttps(explicitUrl ? value : 'https://$value');
    if (!explicitUrl && uri.path.isNotEmpty) {
      throw const FormatException('Enter a server name or HTTPS URL.');
    }
    return uri;
  }

  static void _validateHttps(Uri uri) {
    if (!isSecureHomeserver(uri) ||
        uri.authority.contains('@') ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.host.contains('%') ||
        RegExp(r'[\s\\\x00-\x1f\x7f]').hasMatch(uri.toString())) {
      throw const FormatException(
        'An HTTPS URL without credentials is required.',
      );
    }
  }

  static Uri _endpoint(Uri server, String path) {
    _validateHttps(server);
    final base = server.path.endsWith('/')
        ? server
        : server.replace(path: '${server.path}/');
    return base.resolve(path);
  }

  static Uri _parseHttps(String value) {
    // Dart canonicalizes an empty userinfo ('https://@host') away. Check the
    // source authority before parsing instead of trusting canonicalization.
    final authority = RegExp(r'^[^:]+://([^/?#]*)').firstMatch(value)?.group(1);
    if (authority == null || authority.contains('@')) {
      throw const FormatException(
        'An HTTPS URL without credentials is required.',
      );
    }
    final uri = Uri.parse(value);
    _validateHttps(uri);
    return uri;
  }

  Future<T> _exclusive<T>(Future<T> Function(_AccountPin) action) async {
    if (_busy) throw StateError('Another authentication operation is running.');
    final pin = _AccountPin(client);
    _check(pin);
    _busy = true;
    try {
      return await action(pin);
    } finally {
      _busy = false;
    }
  }

  void _check(_AccountPin pin) {
    if (_disposed || !ownerCurrent() || !pin.matches(client)) {
      throw StateError('The Matrix authentication owner changed.');
    }
  }

  Future<T> _wait<T>(Future<T> future, _AccountPin pin) async {
    try {
      final value = await future;
      _check(pin);
      return value;
    } catch (_) {
      _check(pin);
      rethrow;
    }
  }

  Future<ProviderDiscovery> discover(String input) => _exclusive((pin) async {
    var server = providerUri(input);
    try {
      final wellKnown = await _jsonRequest(
        'GET',
        _endpoint(server, '.well-known/matrix/client'),
        pin,
      );
      final hs = wellKnown['m.homeserver'];
      if (hs is Map && hs['base_url'] is String) {
        // Validate BEFORE making even an unauthenticated request to delegation.
        server = _parseHttps(hs['base_url'] as String);
      } else {
        throw const FormatException('Invalid Matrix homeserver discovery.');
      }
    } on MatrixAuthException catch (e) {
      if (e.statusCode != 404) rethrow;
    }
    final versions = await _jsonRequest(
      'GET',
      _endpoint(server, '_matrix/client/versions'),
      pin,
    );
    if (versions['versions'] is! List) {
      throw const FormatException('Invalid Matrix version response.');
    }
    Map<String, dynamic> flows;
    try {
      flows = await _jsonRequest(
        'GET',
        _endpoint(server, '_matrix/client/v3/login'),
        pin,
      );
    } on MatrixAuthException catch (e) {
      // Native-OIDC-only homeservers may not expose the legacy login endpoint.
      if (e.statusCode != 404 && e.statusCode != 405) rethrow;
      flows = {'flows': <Object>[]};
    }
    final types = (flows['flows'] as List? ?? const [])
        .whereType<Map>()
        .map((f) => f['type'])
        .toSet();
    var oidc = false;
    try {
      await _metadata(server, pin);
      _check(pin);
      oidc = true;
    } on MatrixAuthException catch (e) {
      if (e.statusCode != 404 && e.statusCode != 405) rethrow;
    }
    return ProviderDiscovery(
      homeserver: server,
      password: types.contains(matrix.AuthenticationTypes.password),
      sso: types.contains(matrix.AuthenticationTypes.sso),
      oidc: oidc,
    );
  });

  Future<void> browserLogin(
    ProviderDiscovery discovery, {
    required bool oidc,
  }) => _exclusive((pin) async {
    final server = discovery.homeserver;
    _validateHttps(server);
    if (!(oidc ? discovery.oidc : discovery.sso)) {
      throw StateError('This provider does not advertise that sign-in method.');
    }
    final existing = await _existingSession(pin);
    _check(pin);
    if (existing != null && pin.homeserver != server) {
      throw StateError('Reauthentication must use the existing homeserver.');
    }
    if (oidc) {
      await _oidcLogin(server, pin, existing);
    } else {
      final state = _random();
      final redirect = callbackUri.replace(queryParameters: {'state': state});
      final url = _endpoint(
        server,
        '_matrix/client/v3/login/sso/redirect',
      ).replace(queryParameters: {'redirectUrl': redirect.toString()});
      final callback = await _wait(
        _authenticate(url.toString(), callbackScheme),
        pin,
      );
      final parameters = _callback(callback, state);
      final token = _required(parameters, 'loginToken');
      final json = await _jsonRequest(
        'POST',
        _endpoint(server, '_matrix/client/v3/login'),
        pin,
        body: {
          'type': matrix.LoginType.mLoginToken,
          'token': token,
          // No 'refresh_token': see [passwordLogin].
          if (existing != null) 'device_id': pin.device,
          'initial_device_display_name': 'Parallax',
        },
      );
      final response = matrix.LoginResponse.fromJson(json);
      _verifyIdentity(response.userId, response.deviceId, pin, existing);
      await _apply(
        pin,
        server,
        response.accessToken,
        response.userId,
        response.deviceId,
        refresh: response.refreshToken,
        expires: response.expiresInMs == null
            ? null
            : Duration(milliseconds: response.expiresInMs!),
        existing: existing,
      );
    }
  });

  Future<matrix.GetAuthMetadataResponse> _metadata(
    Uri server,
    _AccountPin pin,
  ) async {
    final json = await _jsonRequest(
      'GET',
      _endpoint(server, '_matrix/client/v1/auth_metadata'),
      pin,
    );
    for (final field in [
      'issuer',
      'authorization_endpoint',
      'token_endpoint',
      'registration_endpoint',
      'revocation_endpoint',
    ]) {
      _parseHttps(_required(json, field));
    }
    final metadata = matrix.GetAuthMetadataResponse.fromJson(json);
    for (final url in [
      metadata.issuer,
      metadata.authorizationEndpoint,
      metadata.tokenEndpoint,
      metadata.registrationEndpoint,
      metadata.revocationEndpoint,
    ]) {
      _validateHttps(url);
    }
    if (!metadata.codeChallengeMethodsSupported.contains('S256') ||
        !metadata.responseTypesSupported.contains('code') ||
        !metadata.responseModesSupported.contains('query') ||
        !metadata.grantTypesSupported.contains('authorization_code') ||
        !metadata.grantTypesSupported.contains('refresh_token')) {
      throw const FormatException(
        'This provider does not support secure native OIDC.',
      );
    }
    return metadata;
  }

  Future<void> _oidcLogin(
    Uri server,
    _AccountPin pin,
    Map<String, dynamic>? existing,
  ) async {
    final metadata = await _metadata(server, pin);
    _check(pin);
    // Registration is scoped to the exact issuer and callback; no bearer tokens
    // or client secrets are written to this registration cache.
    final cacheKey =
        'parallax.oidc.${sha256.convert(utf8.encode('${metadata.issuer}\n$callbackUri'))}';
    var clientId = await _wait(_storage.read(cacheKey), pin);
    if (existing?['oidc_client_id'] case final String registered) {
      clientId = registered;
    }
    if (clientId == null || clientId.isEmpty) {
      final information = matrix.OidcClientInformation(
        clientName: 'Parallax',
        clientUri: Uri.parse('https://samrusselltech.net/'),
        logoUri: null,
        tosUri: null,
        policyUri: null,
      );
      final registration = await _jsonRequest(
        'POST',
        metadata.registrationEndpoint,
        pin,
        body: {
          ...information.toJson(),
          'redirect_uris': [callbackUri.toString()],
          'application_type': matrix.OidcApplicationType.native.name,
          'token_endpoint_auth_method': 'none',
          'response_types': ['code'],
          'grant_types': ['authorization_code', 'refresh_token'],
        },
      );
      clientId = _required(registration, 'client_id');
      await _wait(_storage.write(cacheKey, clientId), pin);
    }
    final state = _random();
    final verifier = _random();
    final challenge = base64UrlEncode(
      sha256.convert(ascii.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final device = pin.device ?? matrix.generateRandomDeviceId();
    final session = matrix.OidcLoginSession(
      oidcClientData: matrix.OidcClientData(
        clientId: clientId,
        clientIdIssuedAt: null,
        clientInformation: matrix.OidcClientInformation(
          clientName: 'Parallax',
          clientUri: Uri.parse('https://samrusselltech.net/'),
          logoUri: null,
          tosUri: null,
          policyUri: null,
        ),
        additionalProperties: const {},
      ),
      authenticationUri: metadata.authorizationEndpoint.replace(
        queryParameters: {
          'client_id': clientId,
          'response_type': 'code',
          'redirect_uri': callbackUri.toString(),
          'response_mode': 'query',
          'scope':
              'openid urn:matrix:org.matrix.msc2967.client:api:* '
              'urn:matrix:org.matrix.msc2967.client:device:$device',
          'state': state,
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
        },
      ),
      redirectUri: callbackUri,
      codeVerifier: verifier,
      state: state,
    );
    final callback = await _wait(
      _authenticate(session.authenticationUri.toString(), callbackScheme),
      pin,
    );
    final parameters = _callback(callback, session.state);
    if (parameters['iss'] != null &&
        parameters['iss'] != metadata.issuer.toString()) {
      throw StateError(
        'The authentication issuer did not match this provider.',
      );
    }
    final code = _required(parameters, 'code');
    final json = await _jsonRequest(
      'POST',
      metadata.tokenEndpoint,
      pin,
      form: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': callbackUri.toString(),
        'client_id': clientId,
        'code_verifier': verifier,
      },
    );
    final response = matrix.OidcAuthResponse.fromJson(json);
    if (response.tokenType.toLowerCase() != 'bearer') {
      throw const FormatException('Unsupported OIDC token type.');
    }
    // Resolve ownership using an isolated bearer request, not mutable Client.
    final identity = await _jsonRequest(
      'GET',
      _endpoint(server, '_matrix/client/v3/account/whoami'),
      pin,
      bearer: response.accessToken,
    );
    final user = _required(identity, 'user_id');
    final returnedDevice = _required(identity, 'device_id');
    _verifyIdentity(user, returnedDevice, pin, existing);
    if (returnedDevice != device) {
      throw StateError('OIDC returned a different Matrix device.');
    }
    await _apply(
      pin,
      server,
      response.accessToken,
      user,
      returnedDevice,
      refresh: response.refreshToken,
      expires: response.expiresIn,
      oidcId: clientId,
      existing: existing,
    );
  }

  /// Safe as Client.onSoftLogout: transient metadata/token failures cannot be
  /// caught by the SDK's destructive MatrixException/OidcException branches.
  Future<void> refresh() => _refreshing ??= _refresh().whenComplete(() {
    _refreshing = null;
  });

  Future<void> _refresh() => _exclusive((pin) async {
    final existing = await _existingSession(pin, required: true);
    _check(pin);
    final refresh = existing!['refresh_token'];
    if (refresh is! String || refresh.isEmpty) {
      throw const ReauthenticationRequired();
    }
    final server = pin.homeserver!;
    _validateHttps(server);
    final oidcId = existing['oidc_client_id'] as String?;
    late Map<String, dynamic> json;
    if (oidcId != null) {
      final metadata = await _metadata(server, pin);
      _check(pin);
      json = await _jsonRequest(
        'POST',
        metadata.tokenEndpoint,
        pin,
        form: {
          'grant_type': 'refresh_token',
          'refresh_token': refresh,
          'client_id': oidcId,
        },
        reauthOnRejection: true,
      );
    } else {
      json = await _jsonRequest(
        'POST',
        _endpoint(server, '_matrix/client/v3/refresh'),
        pin,
        body: {'refresh_token': refresh},
        reauthOnRejection: true,
      );
    }
    final token = _required(json, 'access_token');
    final rotated = json['refresh_token'];
    if (rotated != null && (rotated is! String || rotated.isEmpty)) {
      throw const FormatException('Invalid rotated refresh token.');
    }
    final lifetime = json[oidcId == null ? 'expires_in_ms' : 'expires_in'];
    if (lifetime != null && (lifetime is! int || lifetime <= 0)) {
      throw const FormatException('Invalid access-token lifetime.');
    }
    await _apply(
      pin,
      server,
      token,
      pin.user!,
      pin.device!,
      refresh: rotated as String? ?? refresh,
      expires: lifetime == null
          ? null
          : oidcId == null
          ? Duration(milliseconds: lifetime as int)
          : Duration(seconds: lifetime as int),
      oidcId: oidcId,
      existing: existing,
    );
  });

  /// Fresh password login uses the already validated discovery result. Never
  /// re-enter SDK discovery, which can contact an HTTP delegated homeserver.
  Future<void> passwordLogin(
    ProviderDiscovery discovery,
    String username,
    String password,
  ) => _exclusive((pin) async {
    _validateHttps(discovery.homeserver);
    if (!discovery.password) {
      throw StateError('Password login is not advertised');
    }
    if (await _existingSession(pin) != null) {
      throw StateError('Use reauthentication for the existing Matrix device');
    }
    _check(pin);
    final json = await _jsonRequest(
      'POST',
      _endpoint(discovery.homeserver, '_matrix/client/v3/login'),
      pin,
      body: {
        'type': matrix.LoginType.mLoginPassword,
        'identifier': matrix.AuthenticationUserIdentifier(
          user: username,
        ).toJson(),
        'password': password,
        // Deliberately no 'refresh_token': true. Asking for refresh tokens
        // makes Synapse issue access tokens that last five minutes, so the
        // session has to be renewed every few minutes for as long as it
        // lives (and every renewal is a moment when requests can't be
        // sent). Without it the token lasts until sign-out, as it does for
        // Element. OIDC sign-ins always use refresh tokens; those are
        // handled by [refresh].
        'initial_device_display_name': 'Parallax',
      },
    );
    final response = matrix.LoginResponse.fromJson(json);
    _verifyIdentity(response.userId, response.deviceId, pin, null);
    await _apply(
      pin,
      discovery.homeserver,
      response.accessToken,
      response.userId,
      response.deviceId,
      refresh: response.refreshToken,
      expires: response.expiresInMs == null
          ? null
          : Duration(milliseconds: response.expiresInMs!),
    );
  });

  Future<void> reauthenticatePassword(
    String username,
    String password,
  ) => _exclusive((pin) async {
    final existing = await _existingSession(pin, required: true);
    _check(pin);
    // A username alias must not select another account during reauthentication.
    if (username != pin.user && username != pin.user!.localpart) {
      throw StateError(
        'Reauthentication must use the existing Matrix account.',
      );
    }
    final json = await _jsonRequest(
      'POST',
      _endpoint(pin.homeserver!, '_matrix/client/v3/login'),
      pin,
      body: {
        'type': matrix.LoginType.mLoginPassword,
        'identifier': matrix.AuthenticationUserIdentifier(
          user: pin.user!,
        ).toJson(),
        'password': password,
        'device_id': pin.device,
        // No 'refresh_token': see [passwordLogin].
      },
    );
    final response = matrix.LoginResponse.fromJson(json);
    _verifyIdentity(response.userId, response.deviceId, pin, existing);
    await _apply(
      pin,
      pin.homeserver!,
      response.accessToken,
      response.userId,
      response.deviceId,
      refresh: response.refreshToken,
      expires: response.expiresInMs == null
          ? null
          : Duration(milliseconds: response.expiresInMs!),
      existing: existing,
    );
  });

  Future<Map<String, dynamic>?> _existingSession(
    _AccountPin pin, {
    bool required = false,
  }) async {
    if (pin.user == null || pin.device == null || pin.homeserver == null) {
      if (required) throw const ReauthenticationRequired();
      if (pin.user != null || pin.device != null || pin.token != null) {
        throw StateError('Incomplete Matrix session.');
      }
      return null;
    }
    _validateHttps(pin.homeserver!);
    final stored = await _wait(
      client.database.getClient(client.clientName),
      pin,
    );
    if (stored == null ||
        stored['user_id'] != pin.user ||
        stored['device_id'] != pin.device ||
        _parseHttps(stored['homeserver_url'] as String? ?? '') !=
            pin.homeserver) {
      throw StateError(
        'Stored Matrix account/device does not match this session.',
      );
    }
    if (stored['olm_account'] != null && client.encryption == null) {
      throw const MatrixAuthException(
        'Existing device encryption must be available before reauthentication.',
        retryable: false,
      );
    }
    return Map.of(stored);
  }

  void _verifyIdentity(
    String user,
    String? device,
    _AccountPin pin,
    Map<String, dynamic>? existing,
  ) {
    if (!user.startsWith('@') ||
        user.localpart?.isNotEmpty != true ||
        !user.isValidMatrixIdStrict(strictDomainCheck: true) ||
        device == null ||
        device.isEmpty) {
      throw const FormatException('Invalid Matrix login identity.');
    }
    if (existing != null && (user != pin.user || device != pin.device)) {
      throw StateError('Reauthentication returned another account or device.');
    }
  }

  Future<void> _apply(
    _AccountPin pin,
    Uri server,
    String token,
    String user,
    String? device, {
    String? refresh,
    Duration? expires,
    String? oidcId,
    Map<String, dynamic>? existing,
  }) async {
    _check(pin);
    _validateHttps(server);
    _verifyIdentity(user, device, pin, existing);
    if (token.isEmpty) {
      throw const FormatException('Missing Matrix access token.');
    }
    // Re-read after all remote awaits; never use a deleted/replaced DB session.
    if (existing != null) {
      final current = await _existingSession(pin, required: true);
      _check(pin);
      if (current!['token'] != existing['token'] ||
          current['refresh_token'] != existing['refresh_token']) {
        throw StateError('The stored Matrix credentials changed.');
      }
      existing = current;
    }
    if (existing?['olm_account'] != null && client.encryption == null) {
      // SDK soft-init persists encryption?.pickledOlmAccount, not
      // newOlmAccount. Refuse rather than replace a retained pickle with null.
      throw const MatrixAuthException(
        'Existing device encryption must be available before reauthentication.',
        retryable: false,
      );
    }
    // Exactly what this sign-in or renewal returned. A renewal that didn't
    // rotate its refresh token passes the old one in itself ([_refresh]). A
    // sign-in for an existing device that returns none means the session no
    // longer has one: the server cancelled the device's earlier tokens, so
    // keeping the stored one would leave a dead token to be tried later.
    final nextRefresh = refresh;
    final expiry = expires == null ? null : DateTime.now().add(expires);
    _applyingSession = true;
    try {
      _check(pin);
      if (existing != null &&
          client.onLoginStateChanged.value != matrix.LoginState.softLoggedOut) {
        // Client.init's loggedIn branch rejects reuse. Its softLoggedOut branch
        // updates tokens without disposing encryption, rooms or device keys.
        client.onLoginStateChanged.add(matrix.LoginState.softLoggedOut);
      }
      // SDK 14.1 soft-init stores only when refreshToken is non-null. Persist
      // explicitly for refresh-less password/SSO reauthentication too.
      if (existing != null && nextRefresh == null) {
        await _wait(
          client.database.storeClient(
            homeserverUrl: server.toString(),
            token: token,
            tokenExpiresAt: expiry,
            refreshToken: null,
            userId: user,
            deviceId: device,
            deviceName: existing['device_name'] as String?,
            prevBatch: existing['prev_batch'] as String?,
            olmAccount:
                client.encryption?.pickledOlmAccount ??
                existing['olm_account'] as String?,
            oidcClientId: oidcId ?? existing['oidc_client_id'] as String?,
          ),
          pin,
        );
      }
      _check(pin);
      await client.init(
        newToken: token,
        newTokenExpiresAt: expiry,
        newRefreshToken: nextRefresh,
        newHomeserver: server,
        newUserID: user,
        newDeviceID: device,
        newDeviceName: existing?['device_name'] as String? ?? 'Parallax',
        newOlmAccount:
            client.encryption?.pickledOlmAccount ??
            existing?['olm_account'] as String?,
        newOidcClientId: oidcId ?? existing?['oidc_client_id'] as String?,
        waitForFirstSync: false,
        waitUntilLoadCompletedLoaded: true,
        onInitStateChanged: (state) {
          if (_disposed || !ownerCurrent()) {
            throw StateError(
              'The Matrix authentication owner changed during commit.',
            );
          }
        },
      );
      if (_disposed ||
          !ownerCurrent() ||
          client.userID != user ||
          client.deviceID != device ||
          client.accessToken != token ||
          client.homeserver != server) {
        throw StateError(
          'The Matrix session changed while applying credentials.',
        );
      }
    } finally {
      _applyingSession = false;
    }
  }

  static String _random() {
    final random = Random.secure();
    return base64UrlEncode(
      List.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
  }

  static Map<String, String> _callback(String value, String state) {
    if (value.split('?').first != callbackUri.toString()) {
      throw StateError('The authentication callback did not match this app.');
    }
    final uri = Uri.parse(value);
    if (uri.scheme != callbackUri.scheme ||
        uri.authority != callbackUri.authority ||
        uri.path != callbackUri.path ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        uri.queryParametersAll.values.any((values) => values.length != 1)) {
      throw StateError('The authentication callback did not match this app.');
    }
    final parameters = uri.queryParameters;
    if (parameters['state'] != state || parameters.containsKey('error')) {
      throw StateError('The authentication callback state was rejected.');
    }
    return parameters;
  }

  static String _required(Map json, String name) {
    final value = json[name];
    if (value is! String || value.isEmpty) {
      throw const FormatException('Incomplete authentication response.');
    }
    return value;
  }

  /// Signs in a new device with the OAuth 2.0 device authorization grant
  /// (RFC 8628), as the new device does in MSC4108 QR code sign-in. Mirrors
  /// matrix-rust-sdk: a dynamically registered public client with the
  /// device-code grant, stable `urn:matrix:client:*` scopes binding a fresh
  /// device ID, polling with `interval`/`slow_down`, then whoami ownership
  /// checks before the session is committed with [_apply].
  ///
  /// [onGrant] receives the verification URIs and user code (never the
  /// device code) so they can be forwarded to the approving device; polling
  /// starts only after it returns. [cancelled] completing aborts the wait.
  Future<void> deviceAuthorizationLogin(
    String serverNameOrUrl, {
    required Future<void> Function(DeviceAuthorizationGrant grant) onGrant,
    Future<void>? cancelled,
    Future<void> Function(Duration)? delay,
  }) => _exclusive((pin) async {
    var stop = false;
    unawaited(cancelled?.then((_) => stop = true));
    void checkCancelled() {
      if (stop) {
        throw const DeviceAuthorizationException(
          DeviceAuthorizationFailure.cancelled,
        );
      }
    }

    if (await _existingSession(pin) != null) {
      throw StateError('Sign out before signing in with a QR code.');
    }
    _check(pin);
    final server = await _resolveHomeserver(serverNameOrUrl, pin);
    final metadata = await _deviceGrantMetadata(server, pin);
    final clientId = await _deviceGrantClient(metadata, pin);
    checkCancelled();
    final device = matrix.generateRandomDeviceId();
    // Stable scopes as matrix-rust-sdk; providers that predate them get the
    // MSC2967 names the browser sign-in uses.
    Map<String, dynamic>? authorization;
    for (final prefix in [
      'urn:matrix:client',
      'urn:matrix:org.matrix.msc2967.client',
    ]) {
      final (status, json) = await _exchange(
        'POST',
        metadata.deviceAuthorization,
        pin,
        form: {
          'client_id': clientId,
          'scope': '$prefix:api:* $prefix:device:$device',
        },
      );
      if (status >= 200 && status < 300 && json is Map<String, dynamic>) {
        authorization = json;
        break;
      }
      if (json is Map && json['error'] == 'invalid_scope') continue;
      throw MatrixAuthException(
        'The authentication server could not complete the request.',
        statusCode: status,
        retryable: status >= 500 || status == 408 || status == 429,
      );
    }
    if (authorization == null) {
      throw const DeviceAuthorizationException(
        DeviceAuthorizationFailure.unsupported,
      );
    }
    final deviceCode = _required(authorization, 'device_code');
    final userCode = _required(authorization, 'user_code');
    final verification = _verificationUri(
      _required(authorization, 'verification_uri'),
    );
    final completeValue = authorization['verification_uri_complete'];
    final complete = completeValue == null
        ? null
        : _verificationUri(
            _required(authorization, 'verification_uri_complete'),
          );
    final lifetime = authorization['expires_in'];
    final requestedInterval = authorization['interval'];
    if (userCode.length > 64 ||
        (lifetime != null && (lifetime is! int || lifetime <= 0)) ||
        (requestedInterval != null &&
            (requestedInterval is! int || requestedInterval < 0))) {
      throw const FormatException('Invalid device authorization response.');
    }
    // RFC 8628: interval defaults to 5 s; bound hostile values.
    var interval = Duration(
      seconds: ((requestedInterval as int?) ?? 5).clamp(1, 60),
    );
    final deadline = DateTime.now().add(
      Duration(seconds: ((lifetime as int?) ?? 600).clamp(1, 1800)),
    );
    await _wait(
      onGrant(
        DeviceAuthorizationGrant(
          deviceId: device,
          userCode: userCode,
          verificationUri: verification,
          verificationUriComplete: complete,
        ),
      ),
      pin,
    );
    final wait = delay ?? (Duration d) => Future<void>.delayed(d);
    Map<String, dynamic> tokens;
    while (true) {
      checkCancelled();
      if (DateTime.now().isAfter(deadline)) {
        throw const DeviceAuthorizationException(
          DeviceAuthorizationFailure.expired,
        );
      }
      await _wait(Future.any([wait(interval), ?cancelled]), pin);
      checkCancelled();
      final (status, json) = await _exchange(
        'POST',
        metadata.token,
        pin,
        form: {
          'grant_type': deviceCodeGrantType,
          'device_code': deviceCode,
          'client_id': clientId,
        },
      );
      if (status >= 200 && status < 300 && json is Map<String, dynamic>) {
        tokens = json;
        break;
      }
      final error = json is Map ? json['error'] : null;
      switch (error) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval += const Duration(seconds: 5);
          continue;
        case 'access_denied':
          throw const DeviceAuthorizationException(
            DeviceAuthorizationFailure.declined,
          );
        case 'expired_token':
          throw const DeviceAuthorizationException(
            DeviceAuthorizationFailure.expired,
          );
      }
      throw MatrixAuthException(
        'The authentication server could not complete the request.',
        statusCode: status,
        retryable: status >= 500 || status == 408 || status == 429,
      );
    }
    final token = _required(tokens, 'access_token');
    if (_required(tokens, 'token_type').toLowerCase() != 'bearer') {
      throw const FormatException('Unsupported OAuth token type.');
    }
    final refresh = tokens['refresh_token'];
    final expiresIn = tokens['expires_in'];
    if ((refresh != null && (refresh is! String || refresh.isEmpty)) ||
        (expiresIn != null && (expiresIn is! int || expiresIn <= 0))) {
      throw const FormatException('Invalid token response.');
    }
    // Resolve ownership using an isolated bearer request, not mutable Client.
    final identity = await _jsonRequest(
      'GET',
      _endpoint(server, '_matrix/client/v3/account/whoami'),
      pin,
      bearer: token,
    );
    final user = _required(identity, 'user_id');
    final returnedDevice = _required(identity, 'device_id');
    _verifyIdentity(user, returnedDevice, pin, null);
    if (returnedDevice != device) {
      throw StateError('The authorization server returned another device.');
    }
    await _apply(
      pin,
      server,
      token,
      user,
      returnedDevice,
      refresh: refresh as String?,
      expires: expiresIn == null ? null : Duration(seconds: expiresIn as int),
      oidcId: clientId,
    );
  });

  /// Verification URIs carry the user code in their query, so unlike
  /// endpoints they may have one; they must still be credential-free HTTPS.
  static Uri _verificationUri(String value) {
    final authority = RegExp(r'^[^:]+://([^/?#]*)').firstMatch(value)?.group(1);
    final uri = Uri.tryParse(value);
    if (authority == null ||
        authority.contains('@') ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.hasFragment ||
        value.length > 2048 ||
        RegExp(r'[\s\\\x00-\x1f\x7f]').hasMatch(value)) {
      throw const FormatException('Invalid verification URI.');
    }
    return uri;
  }

  static const deviceCodeGrantType =
      'urn:ietf:params:oauth:grant-type:device_code';

  /// Server name or HTTPS URL to a validated homeserver base URL, following
  /// `.well-known` delegation only to HTTPS.
  Future<Uri> _resolveHomeserver(String input, _AccountPin pin) async {
    var server = providerUri(input);
    try {
      final wellKnown = await _jsonRequest(
        'GET',
        _endpoint(server, '.well-known/matrix/client'),
        pin,
      );
      final hs = wellKnown['m.homeserver'];
      if (hs is Map && hs['base_url'] is String) {
        server = _parseHttps(hs['base_url'] as String);
      } else {
        throw const FormatException('Invalid Matrix homeserver discovery.');
      }
    } on MatrixAuthException catch (e) {
      if (e.statusCode != 404) rethrow;
    }
    final versions = await _jsonRequest(
      'GET',
      _endpoint(server, '_matrix/client/versions'),
      pin,
    );
    if (versions['versions'] is! List) {
      throw const FormatException('Invalid Matrix version response.');
    }
    return server;
  }

  /// Lenient auth metadata parsing: only the fields the device grant needs
  /// (the SDK parser rejects unknown account-management actions).
  Future<_DeviceGrantMetadata> _deviceGrantMetadata(
    Uri server,
    _AccountPin pin,
  ) async {
    Map<String, dynamic>? json;
    for (final path in [
      '_matrix/client/v1/auth_metadata',
      '_matrix/client/unstable/org.matrix.msc2965/auth_metadata',
    ]) {
      try {
        json = await _jsonRequest('GET', _endpoint(server, path), pin);
        break;
      } on MatrixAuthException catch (e) {
        if (e.statusCode != 404 && e.statusCode != 405) rethrow;
      }
    }
    if (json == null) {
      throw const DeviceAuthorizationException(
        DeviceAuthorizationFailure.unsupported,
      );
    }
    final grants = json['grant_types_supported'];
    final endpoint = json['device_authorization_endpoint'];
    if (endpoint == null ||
        (grants is List && !grants.contains(deviceCodeGrantType))) {
      throw const DeviceAuthorizationException(
        DeviceAuthorizationFailure.unsupported,
      );
    }
    return _DeviceGrantMetadata(
      issuer: _parseHttps(_required(json, 'issuer')),
      token: _parseHttps(_required(json, 'token_endpoint')),
      registration: _parseHttps(_required(json, 'registration_endpoint')),
      deviceAuthorization: _parseHttps(
        _required(json, 'device_authorization_endpoint'),
      ),
    );
  }

  /// Dynamic client registration including the device-code grant, cached
  /// separately from the browser OIDC registration (whose grant types MAS
  /// would reject for the device flow).
  Future<String> _deviceGrantClient(
    _DeviceGrantMetadata metadata,
    _AccountPin pin,
  ) async {
    final cacheKey =
        'parallax.oidc.device.${sha256.convert(utf8.encode('${metadata.issuer}\n$callbackUri\n$deviceCodeGrantType'))}';
    final cached = await _wait(_storage.read(cacheKey), pin);
    if (cached != null && cached.isNotEmpty) return cached;
    final information = matrix.OidcClientInformation(
      clientName: 'Parallax',
      clientUri: Uri.parse('https://samrusselltech.net/'),
      logoUri: null,
      tosUri: null,
      policyUri: null,
    );
    final registration = await _jsonRequest(
      'POST',
      metadata.registration,
      pin,
      body: {
        ...information.toJson(),
        'redirect_uris': [callbackUri.toString()],
        'application_type': matrix.OidcApplicationType.native.name,
        'token_endpoint_auth_method': 'none',
        'response_types': ['code'],
        'grant_types': [
          'authorization_code',
          'refresh_token',
          deviceCodeGrantType,
        ],
      },
    );
    final clientId = _required(registration, 'client_id');
    await _wait(_storage.write(cacheKey, clientId), pin);
    return clientId;
  }

  Future<Map<String, dynamic>> _jsonRequest(
    String method,
    Uri uri,
    _AccountPin pin, {
    Map<String, Object?>? body,
    Map<String, String>? form,
    String? bearer,
    bool reauthOnRejection = false,
  }) async {
    final (status, decoded) = await _exchange(
      method,
      uri,
      pin,
      body: body,
      form: form,
      bearer: bearer,
    );
    if (status < 200 || status >= 300) {
      if (reauthOnRejection &&
          status >= 400 &&
          status < 500 &&
          status != 408 &&
          status != 429) {
        throw const ReauthenticationRequired();
      }
      throw MatrixAuthException(
        'The authentication server could not complete the request.',
        statusCode: status,
        retryable: status >= 500 || status == 408 || status == 429,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid authentication response.');
    }
    return decoded;
  }

  /// One bounded, owner-pinned request. Returns the status and the decoded
  /// JSON body (null when the body is not JSON) without judging the status.
  Future<(int, Object?)> _exchange(
    String method,
    Uri uri,
    _AccountPin pin, {
    Map<String, Object?>? body,
    Map<String, String>? form,
    String? bearer,
  }) async {
    _check(pin);
    _validateHttps(uri);
    final request = http.Request(method, uri)..followRedirects = false;
    if (bearer != null) request.headers['authorization'] = 'Bearer $bearer';
    if (form != null) {
      request.bodyFields = form;
    } else if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      final response = await _wait(client.httpClient.send(request), pin);
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        _check(pin);
        if (bytes.length + chunk.length > 256 * 1024) {
          throw const MatrixAuthException(
            'Authentication response is too large.',
          );
        }
        bytes.addAll(chunk);
      }
      _check(pin);
      final status = response.statusCode;
      Object? decoded;
      if (status < 200 || status >= 300) {
        try {
          decoded = jsonDecode(utf8.decode(bytes));
        } on FormatException {
          decoded = null;
        }
        return (status, decoded);
      }
      return (status, jsonDecode(utf8.decode(bytes)));
    } on matrix.MatrixException {
      // Even an injected/wrapped transport must not cause SDK session deletion.
      throw const MatrixAuthException('The authentication request failed.');
    } on matrix.OidcException {
      throw const MatrixAuthException('The authentication request failed.');
    } on http.ClientException {
      throw const MatrixAuthException(
        'Could not connect to the authentication server.',
      );
    } on TimeoutException {
      throw const MatrixAuthException('The authentication server timed out.');
    }
  }
}

class _AuthLease {
  bool busy = false;
  bool applyingSession = false;
  Future<void>? refreshing;
}

class _AccountPin {
  _AccountPin(matrix.Client client)
    : user = client.userID,
      device = client.deviceID,
      token = client.accessToken,
      homeserver = client.homeserver;
  final String? user, device, token;
  final Uri? homeserver;
  bool matches(matrix.Client client) =>
      user == client.userID &&
      device == client.deviceID &&
      token == client.accessToken &&
      homeserver == client.homeserver;
}

class _DeviceGrantMetadata {
  const _DeviceGrantMetadata({
    required this.issuer,
    required this.token,
    required this.registration,
    required this.deviceAuthorization,
  });
  final Uri issuer;
  final Uri token;
  final Uri registration;
  final Uri deviceAuthorization;
}
