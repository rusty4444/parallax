import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;

import 'encrypted_media.dart';
import 'homeserver_security.dart';
import 'messaging_features.dart';
import 'send_cancellation.dart';

/// Uploads only after preparation/encryption, then uses the stable outbox txid.
Future<void> sendQueuedAttachment({
  required matrix.Client client,
  required matrix.Room room,
  required MediaSelection media,
  required String transactionId,
  required bool Function() ownerCurrent,
  required SendCancellation cancellation,
  required void Function(double) onProgress,
  String? caption,
  matrix.Event? inReplyTo,
  String? threadRootId,
  Duration uploadTimeout = const Duration(minutes: 2),
  Timer Function(Duration, void Function())? createUploadTimer,
}) async {
  final encryptedRoom = room.encrypted;
  void check() {
    cancellation.check();
    if (!ownerCurrent() ||
        room.encrypted != encryptedRoom ||
        (encryptedRoom &&
            (!client.encryptionEnabled || !client.fileEncryptionEnabled))) {
      throw StateError('Attachment session or encryption changed');
    }
  }

  check();
  if (media.bytes.isEmpty || media.bytes.length > 20 * 1024 * 1024) {
    throw ArgumentError('Choose an attachment smaller than 20 MB');
  }
  final maximum = (await client.getConfig()).mUploadSize;
  check();
  if (maximum != null && maximum > 0 && media.bytes.length > maximum) {
    throw ArgumentError('Attachment exceeds the homeserver upload limit');
  }
  final file = media.mimeType.startsWith('audio/')
      ? matrix.MatrixAudioFile(
          bytes: media.bytes,
          name: media.name,
          mimeType: media.mimeType,
          duration: media.durationMs,
        )
      : matrix.MatrixFile.fromMimeType(
          bytes: media.bytes,
          name: media.name,
          mimeType: media.mimeType,
        );
  final encrypted = encryptedRoom ? await file.encrypt() : null;
  check();
  final bytes = encrypted?.data ?? file.bytes;
  final homeserver = client.homeserver;
  final accessToken = client.accessToken;
  if (!isSecureHomeserver(homeserver) || accessToken == null) {
    throw StateError('Attachment homeserver is unavailable');
  }
  final base = homeserver!.toString().replaceFirst(RegExp(r'/+$'), '');
  final uri = Uri.parse('$base/_matrix/media/v3/upload').replace(
    queryParameters: {'filename': encrypted == null ? file.name : 'crypt'},
  );
  final mxc = await _uploadContent(
    client.httpClient,
    uri,
    bytes,
    accessToken: accessToken,
    contentType: encrypted == null ? file.mimeType : 'application/octet-stream',
    cancellation: cancellation,
    check: check,
    onProgress: (fraction) => onProgress(fraction * 0.9),
    deadline: uploadTimeout,
    createTimer: createUploadTimer ?? Timer.new,
  );
  final content = <String, dynamic>{
    'msgtype': file.msgType,
    'body': caption?.trim().isNotEmpty == true ? caption!.trim() : file.name,
    'filename': file.name,
    'info': file.info,
    if (encrypted == null) 'url': mxc.toString(),
    if (encrypted != null)
      'file': encryptedFileContent(mxc, file.mimeType, encrypted),
  };
  check();
  final eventId = await room.sendEvent(
    content,
    txid: transactionId,
    inReplyTo: inReplyTo,
    threadRootEventId: threadRootId,
  );
  check();
  if (eventId == null) throw StateError('Attachment was not acknowledged');
  onProgress(1);
}

Future<Uri> _uploadContent(
  http.Client client,
  Uri uri,
  Uint8List bytes, {
  required String accessToken,
  required String contentType,
  required SendCancellation cancellation,
  required void Function() check,
  required void Function(double) onProgress,
  required Duration deadline,
  required Timer Function(Duration, void Function()) createTimer,
}) async {
  if (deadline <= Duration.zero) {
    throw ArgumentError('Upload deadline must be positive');
  }
  final uploadCancellation = SendCancellation();
  unawaited(
    cancellation.whenCancelled.then((_) => uploadCancellation.cancel()),
  );
  var timedOut = false;
  final timer = createTimer(deadline, () {
    timedOut = true;
    uploadCancellation.cancel();
  });
  try {
    final request = _ProgressUpload(uri, bytes, uploadCancellation, onProgress)
      ..headers['authorization'] = 'Bearer $accessToken'
      ..headers['content-type'] = contentType;
    check();
    // Unlike a response-stream inactivity timeout, this deadline also aborts
    // transmission/stalled headers and cannot be extended by response trickling.
    final response = await client.send(request);
    final replyBytes = <int>[];
    await for (final chunk in response.stream) {
      check();
      uploadCancellation.check();
      if (replyBytes.length + chunk.length > 64 * 1024) {
        throw StateError('Invalid oversized media upload response');
      }
      replyBytes.addAll(chunk);
    }
    check();
    uploadCancellation.check();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Media upload failed (HTTP ${response.statusCode})');
    }
    final decoded = jsonDecode(utf8.decode(replyBytes));
    final contentUri = decoded is Map ? decoded['content_uri'] : null;
    final mxc = contentUri is String ? Uri.tryParse(contentUri) : null;
    if (mxc == null ||
        // Uri parsing canonicalizes empty userinfo away; validate the source
        // authority too, rather than repairing an invalid response token.
        RegExp(
          r'^mxc://[^/]*@',
          caseSensitive: false,
        ).hasMatch(contentUri as String) ||
        mxc.scheme != 'mxc' ||
        mxc.host.isEmpty ||
        mxc.userInfo.isNotEmpty ||
        mxc.hasQuery ||
        mxc.hasFragment ||
        mxc.pathSegments.length != 1 ||
        mxc.pathSegments.single.isEmpty) {
      throw StateError('Invalid media upload response');
    }
    return mxc;
  } catch (_) {
    cancellation.check();
    if (timedOut) {
      throw TimeoutException('Attachment upload timed out', deadline);
    }
    rethrow;
  } finally {
    timer.cancel();
    uploadCancellation.cancel();
  }
}

class _ProgressUpload extends http.BaseRequest with http.Abortable {
  _ProgressUpload(Uri uri, this.bytes, this.cancellation, this.onProgress)
    : super('POST', uri) {
    contentLength = bytes.length;
    followRedirects = false;
  }
  final Uint8List bytes;
  final SendCancellation cancellation;
  final void Function(double) onProgress;
  @override
  Future<void> get abortTrigger => cancellation.whenCancelled;

  @override
  http.ByteStream finalize() {
    super.finalize();
    Stream<List<int>> chunks() async* {
      const chunkSize = 64 * 1024;
      for (var offset = 0; offset < bytes.length; offset += chunkSize) {
        cancellation.check();
        final end = (offset + chunkSize).clamp(0, bytes.length);
        yield Uint8List.sublistView(bytes, offset, end);
        onProgress(end / bytes.length);
      }
    }

    return http.ByteStream(chunks());
  }
}
