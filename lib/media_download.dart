import 'dart:typed_data';

import 'package:http/http.dart' as http;

Future<void> _cancelResponse(http.StreamedResponse response) async {
  final subscription = response.stream.listen((_) {});
  await subscription.cancel();
}

/// Downloads Matrix media with a wire-size cap and no bearer token on redirects.
Future<Uint8List> downloadMatrixMedia({
  required http.Client httpClient,
  required Uri homeserver,
  required Uri uri,
  required String accessToken,
  required int maxBytes,
}) async {
  if (maxBytes <= 0 ||
      homeserver.scheme != 'https' ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.host != homeserver.host ||
      uri.port != homeserver.port) {
    throw StateError('Untrusted media destination');
  }

  var current = uri;
  for (var redirect = 0; redirect < 4; redirect++) {
    if (current.scheme != 'https' || current.userInfo.isNotEmpty) {
      throw StateError('Untrusted media redirect');
    }
    final sameOrigin =
        current.host == homeserver.host && current.port == homeserver.port;
    final request = http.Request('GET', current)..followRedirects = false;
    if (sameOrigin) request.headers['authorization'] = 'Bearer $accessToken';
    final response = await httpClient.send(request);
    if (response.statusCode >= 300 && response.statusCode < 400) {
      final location = response.headers['location'];
      await _cancelResponse(response);
      if (location == null) throw StateError('Media redirect has no location');
      current = current.resolve(location);
      continue;
    }
    if (response.statusCode != 200 ||
        (response.contentLength ?? 0) > maxBytes) {
      await _cancelResponse(response);
      throw StateError('Media download failed or is too large');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      if (builder.length + chunk.length > maxBytes) {
        throw StateError('Media download is too large');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
  throw StateError('Too many media redirects');
}
