import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/secure_store.dart';

const scheduledRoomId = '!room:matrix.example';
const scheduledUserId = '@sam:matrix.example';

typedef Responder = Future<http.Response> Function(http.Request request);

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class ScheduledDatabase extends Fake implements matrix.DatabaseApi {
  @override
  Future<matrix.Event?> getEventById(String eventId, matrix.Room room) async =>
      null;
}

/// A signed-in SDK client whose HTTP goes to [transport].
class ScheduledClient extends matrix.Client {
  ScheduledClient(this.transport)
    : super(
        'scheduled-test',
        database: ScheduledDatabase(),
        httpClient: transport,
      ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
  }

  final http.Client transport;
  bool signedIn = true;

  @override
  String? get userID => signedIn ? scheduledUserId : null;
  @override
  String? get deviceID => signedIn ? 'DEVICE' : null;
  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

matrix.Room scheduledRoom(
  matrix.Client client, {
  bool encrypted = false,
  matrix.Membership membership = matrix.Membership.join,
  String id = scheduledRoomId,
}) {
  final room = matrix.Room(id: id, client: client, membership: membership);
  if (encrypted) {
    room.setState(
      matrix.Event.fromJson({
        'type': matrix.EventTypes.Encryption,
        'state_key': '',
        'sender': scheduledUserId,
        'event_id': r'$encryption',
        'origin_server_ts': 1000,
        'content': {'algorithm': matrix.AlgorithmTypes.megolmV1AesSha2},
      }, room),
    );
  }
  client.rooms.add(room);
  return room;
}

/// Records every request and answers from a route table.
class RecordingTransport extends http.BaseClient {
  RecordingTransport(this.respond);
  final Responder respond;
  final requests = <http.Request>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final copy = http.Request(request.method, request.url)
      ..headers.addAll(request.headers);
    final body = await request.finalize().toBytes();
    copy.bodyBytes = body;
    requests.add(copy);
    final response = await respond(copy);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }
}

class MemoryStore implements SecureValueStore {
  final values = <String, String>{};
  bool failRead = false;
  bool failWrite = false;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('secure storage unavailable');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('secure storage unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}
