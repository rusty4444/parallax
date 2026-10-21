import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrixpress/media_download.dart';

void main() {
  final homeserver = Uri.parse('https://matrix.example');
  final media = Uri.parse(
    'https://matrix.example/_matrix/client/v1/media/download/a/b',
  );

  test('rejects a foreign initial URL without sending a token', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response('unexpected', 200);
    });
    await expectLater(
      downloadMatrixMedia(
        httpClient: client,
        homeserver: homeserver,
        uri: Uri.parse('https://attacker.example/file'),
        accessToken: 'test-token',
        maxBytes: 1024,
      ),
      throwsStateError,
    );
    expect(requests, 0);
  });

  test(
    'HTTPS CDN redirect never receives the homeserver bearer token',
    () async {
      final seen = <http.Request>[];
      final client = MockClient((request) async {
        seen.add(request);
        if (request.url.host == 'matrix.example') {
          return http.Response(
            '',
            302,
            headers: {'location': 'https://cdn.example/file'},
          );
        }
        return http.Response('image', 200);
      });
      final bytes = await downloadMatrixMedia(
        httpClient: client,
        homeserver: homeserver,
        uri: media,
        accessToken: 'test-token',
        maxBytes: 1024,
      );
      expect(bytes, 'image'.codeUnits);
      expect(seen.first.headers['authorization'], 'Bearer test-token');
      expect(seen.last.headers.containsKey('authorization'), isFalse);
    },
  );

  test('refuses HTTP redirect before making another request', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return http.Response(
        '',
        302,
        headers: {'location': 'http://cdn.example/file'},
      );
    });
    await expectLater(
      downloadMatrixMedia(
        httpClient: client,
        homeserver: homeserver,
        uri: media,
        accessToken: 'test-token',
        maxBytes: 1024,
      ),
      throwsStateError,
    );
    expect(requests, 1);
  });

  test('caps streamed bytes even without a Content-Length', () async {
    final client = _StreamClient(
      () => http.StreamedResponse(
        Stream.value(Uint8List.fromList([1, 2, 3, 4, 5])),
        200,
      ),
    );
    await expectLater(
      downloadMatrixMedia(
        httpClient: client,
        homeserver: homeserver,
        uri: media,
        accessToken: 'test-token',
        maxBytes: 4,
      ),
      throwsStateError,
    );
  });
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.response);
  final http.StreamedResponse Function() response;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response();
}
