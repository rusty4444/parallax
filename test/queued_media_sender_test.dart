import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;
import 'package:matrixpress/messaging_features.dart';
import 'package:matrixpress/queued_media_sender.dart';
import 'package:matrixpress/send_cancellation.dart';

void main() {
  late _UploadClient transport;
  late _Client client;
  late _Room room;
  late SendCancellation cancellation;
  late bool current;
  late List<double> progress;

  Future<void> send({
    String txid = 'stable-txid',
    MediaSelection? media,
    Timer Function(Duration, void Function())? createUploadTimer,
  }) => sendQueuedAttachment(
    client: client,
    room: room,
    media:
        media ??
        MediaSelection(
          bytes: Uint8List(150000),
          name: 'note.m4a',
          mimeType: 'audio/mp4',
          durationMs: 1234,
        ),
    transactionId: txid,
    ownerCurrent: () => current,
    cancellation: cancellation,
    onProgress: progress.add,
    caption: 'A caption',
    threadRootId: r'$root',
    createUploadTimer: createUploadTimer,
  );

  setUp(() {
    transport = _UploadClient();
    client = _Client(transport);
    room = _Room();
    cancellation = SendCancellation();
    current = true;
    progress = [];
  });

  test(
    'streams bounded audio with caption, duration, thread and stable txid',
    () async {
      await send();
      expect(transport.body, hasLength(150000));
      expect(transport.request!.url.origin, 'https://matrix.example');
      expect(transport.request!.url.path, '/prefix/_matrix/media/v3/upload');
      expect(transport.request!.followRedirects, isFalse);
      expect(transport.request!.headers['authorization'], 'Bearer test-token');
      expect(transport.request!.headers['content-type'], 'audio/mp4');
      expect(room.ids, ['stable-txid']);
      expect(room.threadRoots, [r'$root']);
      final content = room.contents.single;
      expect(content['msgtype'], 'm.audio');
      expect(content['body'], 'A caption');
      expect(content['filename'], 'note.m4a');
      expect((content['info'] as Map)['duration'], 1234);
      expect(content['url'], 'mxc://matrix.example/media');
      expect(progress.last, 1);
      expect(progress.where((p) => p > 0 && p < 1), isNotEmpty);
      await send();
      expect(room.ids, ['stable-txid', 'stable-txid']);
    },
  );

  test('oversized and empty media never reaches config or network', () async {
    for (final size in [0, 20 * 1024 * 1024 + 1]) {
      await expectLater(
        send(
          media: MediaSelection(
            bytes: Uint8List(size),
            name: 'file',
            mimeType: 'application/octet-stream',
          ),
        ),
        throwsArgumentError,
      );
    }
    expect(client.configCalls, 0);
    expect(transport.request, isNull);
  });

  test('crypto loss across media configuration await blocks upload', () async {
    final gate = Completer<matrix.MediaConfig>();
    client.configGate = gate;
    room.isEncrypted = true;
    final sent = send();
    final assertion = expectLater(sent, throwsStateError);
    client.cryptoAvailable = false;
    gate.complete(matrix.MediaConfig());
    await assertion;
    expect(transport.request, isNull);
    expect(room.ids, isEmpty);
  });

  test('session change after upload does not send the room event', () async {
    transport.onBody = () => current = false;
    await expectLater(send(), throwsStateError);
    expect(room.ids, isEmpty);
    expect(progress.contains(1), isFalse);
  });

  test(
    'cancellation during streaming stops the upload and final event',
    () async {
      transport.onChunk = () => cancellation.cancel();
      await expectLater(send(), throwsA(isA<SendCancelled>()));
      expect(room.ids, isEmpty);
    },
  );

  test('null SDK acknowledgement is failure, not delivered', () async {
    room.acknowledgement = null;
    await expectLater(send(), throwsStateError);
    expect(progress.contains(1), isFalse);
  });

  test('upload redirects and oversized responses are rejected', () async {
    transport.status = 307;
    await expectLater(send(), throwsStateError);
    expect(room.ids, isEmpty);
    transport.status = 200;
    transport.response = 'x' * (64 * 1024 + 1);
    await expectLater(send(), throwsStateError);
    expect(room.ids, isEmpty);
  });

  test('malformed MXC response cannot become a sent event', () async {
    for (final uri in [
      'https://matrix.example/file',
      'mxc://matrix.example',
      'mxc://user:pass@matrix.example/media',
      'mxc://@matrix.example/media',
      'mxc://matrix.example/media?secret=value',
    ]) {
      transport.response = jsonEncode({'content_uri': uri});
      await expectLater(send(), throwsStateError, reason: uri);
    }
    expect(room.ids, isEmpty);
  });

  test('deadline aborts stalled headers and cleans the timer', () async {
    final stalled = _AbortingTransport();
    client = _Client(stalled);
    late _ManualTimer timer;
    final sent = send(
      createUploadTimer: (_, callback) => timer = _ManualTimer(callback),
    );
    final assertion = expectLater(sent, throwsA(isA<TimeoutException>()));
    await stalled.started.future;
    timer.fire();
    await assertion;
    expect(stalled.aborted, isTrue);
    expect(timer.isActive, isFalse);
    expect(room.ids, isEmpty);
    expect(progress.contains(1), isFalse);
  });

  test('response trickling cannot reset the overall deadline', () async {
    final stalled = _AbortingTransport()..returnHeaders = true;
    client = _Client(stalled);
    late _ManualTimer timer;
    var timers = 0;
    final sent = send(
      createUploadTimer: (_, callback) {
        timers++;
        return timer = _ManualTimer(callback);
      },
    );
    final assertion = expectLater(sent, throwsA(isA<TimeoutException>()));
    await stalled.started.future;
    stalled.response.add(utf8.encode(' '));
    await Future<void>.value();
    stalled.response.add(utf8.encode(' '));
    timer.fire();
    await assertion;
    expect(timers, 1);
    expect(stalled.aborted, isTrue);
    expect(timer.isActive, isFalse);
    expect(room.ids, isEmpty);
  });

  test(
    'user cancellation aborts stalled headers without becoming a timeout',
    () async {
      final stalled = _AbortingTransport();
      client = _Client(stalled);
      late _ManualTimer timer;
      final sent = send(
        createUploadTimer: (_, callback) => timer = _ManualTimer(callback),
      );
      final assertion = expectLater(sent, throwsA(isA<SendCancelled>()));
      await stalled.started.future;
      cancellation.cancel();
      await assertion;
      expect(stalled.aborted, isTrue);
      expect(timer.isActive, isFalse);
      expect(room.ids, isEmpty);
    },
  );

  test(
    'successful upload cancels its deadline before sending the event',
    () async {
      late _ManualTimer timer;
      await send(
        createUploadTimer: (_, callback) => timer = _ManualTimer(callback),
      );
      expect(timer.isActive, isFalse);
      expect(room.ids, ['stable-txid']);
    },
  );
}

class _ManualTimer implements Timer {
  _ManualTimer(this.callback);
  final void Function() callback;
  bool _active = true;
  @override
  bool get isActive => _active;
  @override
  int get tick => _active ? 0 : 1;
  void fire() {
    if (!_active) return;
    _active = false;
    callback();
  }

  @override
  void cancel() => _active = false;
}

class _AbortingTransport extends http.BaseClient {
  final started = Completer<void>();
  final response = StreamController<List<int>>();
  bool returnHeaders = false;
  bool aborted = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await request.finalize().drain<void>();
    final abort = (request as http.Abortable).abortTrigger!;
    if (returnHeaders) {
      unawaited(
        abort.then((_) {
          aborted = true;
          response.addError(http.RequestAbortedException(request.url));
          unawaited(response.close());
        }),
      );
      started.complete();
      return http.StreamedResponse(response.stream, 200);
    }
    started.complete();
    await abort;
    aborted = true;
    throw http.RequestAbortedException(request.url);
  }
}

class _UploadClient extends http.BaseClient {
  http.BaseRequest? request;
  final body = <int>[];
  int status = 200;
  String response = '{"content_uri":"mxc://matrix.example/media"}';
  void Function()? onBody;
  void Function()? onChunk;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request;
    body.clear();
    await for (final chunk in request.finalize()) {
      body.addAll(chunk);
      onChunk?.call();
    }
    onBody?.call();
    return http.StreamedResponse(Stream.value(utf8.encode(response)), status);
  }
}

class _Client extends Fake implements matrix.Client {
  _Client(this.transport);
  final http.Client transport;
  bool cryptoAvailable = true;
  int configCalls = 0;
  Completer<matrix.MediaConfig>? configGate;
  @override
  Uri get homeserver => Uri.parse('https://matrix.example/prefix');
  @override
  String get accessToken => 'test-token';
  @override
  http.Client get httpClient => transport;
  @override
  bool get fileEncryptionEnabled => cryptoAvailable;
  @override
  bool get encryptionEnabled => cryptoAvailable;
  @override
  Future<matrix.MediaConfig> getConfig({
    Duration cacheLifetime = const Duration(days: 3),
    bool throwOnUpdateFailure = false,
  }) async {
    configCalls++;
    return configGate?.future ?? matrix.MediaConfig();
  }
}

class _Room extends Fake implements matrix.Room {
  bool isEncrypted = false;
  String? acknowledgement = r'$accepted';
  final contents = <Map<String, dynamic>>[];
  final ids = <String?>[];
  final threadRoots = <String?>[];
  @override
  bool get encrypted => isEncrypted;
  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = matrix.EventTypes.Message,
    String? txid,
    matrix.Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
  }) async {
    contents.add(content);
    ids.add(txid);
    threadRoots.add(threadRootEventId);
    return acknowledgement;
  }
}
