import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' as matrix;

import 'encrypted_media.dart';
import 'features/media/image_optimiser.dart';
import 'features/media/media_preferences.dart';
import 'features/media/voice_waveform.dart';
import 'homeserver_security.dart';
import 'messaging_features.dart';
import 'send_cancellation.dart';
import 'features/media/video_prep.dart';

/// Uploads only after preparation/encryption, then uses the stable outbox txid.
///
/// JPEG/PNG images are prepared in a background isolate first: dimensions,
/// an 800×600 thumbnail for large images and, when "Optimise image upload
/// quality" is on ([uploadOptions], default: saved preference), a 2048 px /
/// quality 80 re-encode. Recorder voice clips gain MSC3245 voice markers and
/// an MSC1767 waveform. Every upload (thumbnail included) is encrypted before
/// it leaves the device in an encrypted room.
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
  MediaUploadOptions? uploadOptions,
  ImagePreparer? prepareImage,
  Future<VideoInfo?> Function(Uint8List bytes)? probeVideo,
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
  final preparable = isPreparableImage(media.mimeType);
  // Optimised images are checked against the limit after preparation.
  if (!preparable &&
      maximum != null &&
      maximum > 0 &&
      media.bytes.length > maximum) {
    throw ArgumentError('Attachment exceeds the homeserver upload limit');
  }
  PreparedImage? prepared;
  if (preparable) {
    final options =
        uploadOptions ?? await MediaPreferences.shared.resolveUploadOptions();
    check();
    try {
      prepared = await (prepareImage ?? prepareImageForUpload)(
        ImagePrepareRequest(
          bytes: media.bytes,
          mimeType: media.mimeType,
          optimise: options.optimiseImages,
        ),
      );
    } catch (_) {
      prepared = null; // Unreadable images are sent unchanged.
    }
    check();
    if (prepared != null &&
        (prepared.bytes.isEmpty ||
            prepared.bytes.length > media.bytes.length)) {
      prepared = null;
    }
  }
  final uploadLength = prepared?.bytes.length ?? media.bytes.length;
  if (maximum != null && maximum > 0 && uploadLength > maximum) {
    throw ArgumentError('Attachment exceeds the homeserver upload limit');
  }
  final voice = _voiceMetadata(media);
  // Videos: dimensions, duration and a poster frame, read natively. A video
  // that can't be read is still sent (players show it without a poster).
  VideoInfo? video;
  if (isVideoMime(media.mimeType)) {
    try {
      video = await (probeVideo ?? probeVideoBytes)(media.bytes);
    } catch (_) {
      video = null;
    }
    check();
  }
  final file = prepared != null
      ? matrix.MatrixImageFile(
          bytes: prepared.bytes,
          name: _renamed(media.name, prepared.mimeType),
          mimeType: prepared.mimeType,
          width: prepared.width,
          height: prepared.height,
        )
      : media.mimeType.startsWith('audio/')
      ? matrix.MatrixAudioFile(
          bytes: media.bytes,
          name: media.name,
          mimeType: media.mimeType,
          duration: media.durationMs,
        )
      : isVideoMime(media.mimeType)
      ? matrix.MatrixVideoFile(
          bytes: media.bytes,
          name: media.name,
          mimeType: media.mimeType,
          width: video?.width,
          height: video?.height,
          duration: video?.durationMs ?? media.durationMs,
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
  Uri uploadUri(String filename) => Uri.parse(
    '$base/_matrix/media/v3/upload',
  ).replace(queryParameters: {'filename': filename});
  final info = Map<String, dynamic>.of(file.info);
  final thumbnail = prepared?.thumbnail ?? video?.thumbnail;
  if (thumbnail != null) {
    final thumbMime = prepared?.thumbnailMimeType ?? 'image/jpeg';
    final thumbFile = matrix.MatrixFile(
      bytes: thumbnail,
      name: thumbMime == 'image/png' ? 'thumbnail.png' : 'thumbnail.jpg',
      mimeType: thumbMime,
    );
    final thumbEncrypted = encryptedRoom ? await thumbFile.encrypt() : null;
    check();
    final thumbMxc = await _uploadContent(
      client.httpClient,
      uploadUri(thumbEncrypted == null ? thumbFile.name : 'crypt'),
      thumbEncrypted?.data ?? thumbFile.bytes,
      accessToken: accessToken,
      contentType: thumbEncrypted == null
          ? thumbMime
          : 'application/octet-stream',
      cancellation: cancellation,
      check: check,
      onProgress: (fraction) => onProgress(fraction * 0.05),
      deadline: uploadTimeout,
      createTimer: createUploadTimer ?? Timer.new,
    );
    info['thumbnail_info'] = {
      'w': prepared?.thumbnailWidth ?? video?.thumbnailWidth,
      'h': prepared?.thumbnailHeight ?? video?.thumbnailHeight,
      'mimetype': thumbMime,
      'size': thumbnail.length,
    };
    if (thumbEncrypted == null) {
      info['thumbnail_url'] = thumbMxc.toString();
    } else {
      info['thumbnail_file'] = encryptedFileContent(
        thumbMxc,
        thumbMime,
        thumbEncrypted,
      );
    }
  }
  final mxc = await _uploadContent(
    client.httpClient,
    uploadUri(encrypted == null ? file.name : 'crypt'),
    bytes,
    accessToken: accessToken,
    contentType: encrypted == null ? file.mimeType : 'application/octet-stream',
    cancellation: cancellation,
    check: check,
    onProgress: (fraction) =>
        onProgress(thumbnail == null ? fraction * 0.9 : 0.05 + fraction * 0.85),
    deadline: uploadTimeout,
    createTimer: createUploadTimer ?? Timer.new,
  );
  final trimmedCaption = caption?.trim();
  final content = <String, dynamic>{
    'msgtype': file.msgType,
    'body': trimmedCaption?.isNotEmpty == true
        ? trimmedCaption
        : voice != null
        ? 'Voice message'
        : file.name,
    'filename': file.name,
    'info': info,
    if (encrypted == null) 'url': mxc.toString(),
    if (encrypted != null)
      'file': encryptedFileContent(mxc, file.mimeType, encrypted),
    if (voice != null) ...{
      'org.matrix.msc1767.audio': {
        'duration': voice.durationMs,
        if (voice.waveform.isNotEmpty) 'waveform': voice.waveform,
      },
      'org.matrix.msc3245.voice': <String, dynamic>{},
    },
  };
  content.addAll(media.extraContent);
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

/// Voice metadata for a clip recorded in-app: the waveform registered by the
/// recorder (matched by content), or duration only for a recorder clip that
/// was restored from the outbox after a restart. Picked audio files have no
/// recorder duration and stay ordinary audio.
VoiceMetadata? _voiceMetadata(MediaSelection media) {
  if (!media.mimeType.startsWith('audio/')) return null;
  final registered = VoiceMessageRegistry.instance.lookup(media.bytes);
  if (registered != null) return registered;
  final duration = media.durationMs;
  if (duration != null &&
      media.mimeType == 'audio/mp4' &&
      VoiceMessageRegistry.isRecorderName(media.name)) {
    return VoiceMetadata(durationMs: duration, waveform: const []);
  }
  return null;
}

/// Keeps the base name and fixes the extension after re-encoding.
String _renamed(String name, String mimeType) {
  final extension = mimeType == 'image/png' ? 'png' : 'jpg';
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  final current = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
  if (current == extension || (extension == 'jpg' && current == 'jpeg')) {
    return name;
  }
  return '$base.$extension';
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
