import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/media/media_features.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/media_player_owner.dart';

const roomId = '!room:example.org';
const me = '@me:example.org';
final palette = paletteFor(VisualTheme.parallax);

ChatEntry mediaEntry(
  String id,
  EntryKind kind, {
  Map<String, Object?> content = const {},
  String body = 'file',
  bool mine = false,
  bool redacted = false,
  DateTime? time,
  String sender = '@alice:example.org',
}) => ChatEntry(
  id: id,
  sender: sender,
  senderName: sender == me ? 'Me' : 'Alice',
  body: body,
  time: time ?? DateTime.utc(2026, 11, 10, 9, 30),
  mine: mine,
  kind: kind,
  redacted: redacted,
  isImage: kind == EntryKind.image || kind == EntryKind.sticker,
  isAttachment: {
    EntryKind.file,
    EntryKind.audio,
    EntryKind.voice,
    EntryKind.video,
  }.contains(kind),
  content: {'body': body, ...content},
);

EntryHookContext hookFor(
  ChatBackend backend,
  ChatEntry entry, {
  List<ChatEntry> entries = const [],
}) => EntryHookContext(
  backend: backend,
  roomId: roomId,
  palette: palette,
  entry: entry,
  entries: entries,
);

/// A backend that implements [MediaFeatures] directly (no SDK).
class FakeMediaBackend extends ChatBackend implements MediaFeatures {
  String? identity = me;
  SessionStatus status = SessionStatus.ready;
  List<ChatEntry> timeline = const [];
  final loads = <String>[];
  final previews = <String>[];
  final deleted = <String>[];
  final historyRequests = <String?>[];
  final pages = <MediaHistoryPage>[];
  Object? historyError;
  Uint8List? previewBytes;
  DownloadedAttachment Function(String eventId)? original;

  @override
  String? get userId => identity;
  @override
  SessionStatus get connection => status;
  @override
  String? get activeRoomId => roomId;
  @override
  List<ChatEntry> get messages => timeline;

  void signOut() {
    identity = null;
    status = SessionStatus.signedOut;
    notifyListeners();
  }

  DownloadedAttachment _original(String eventId) =>
      original?.call(eventId) ??
      DownloadedAttachment(
        name: '$eventId.ogg',
        mimeType: 'audio/ogg',
        bytes: Uint8List.fromList([1, 2, 3]),
      );

  @override
  Future<DownloadedAttachment> loadAttachment(
    String room,
    String eventId,
  ) async {
    loads.add(eventId);
    return _original(eventId);
  }

  @override
  Future<Uint8List?> loadImage(String room, String eventId) async {
    previews.add(eventId);
    return previewBytes;
  }

  @override
  Future<Uint8List?> loadPreview(
    String room,
    String eventId, {
    int maxBytes = maxPreviewBytes,
  }) async {
    previews.add(eventId);
    return previewBytes;
  }

  @override
  Future<DownloadedAttachment> loadOriginal(
    String room,
    String eventId, {
    int maxBytes = maxOriginalBytes,
  }) async {
    loads.add(eventId);
    return _original(eventId);
  }

  @override
  Future<MediaHistoryPage> loadMediaHistory(String room, {String? from}) async {
    historyRequests.add(from);
    final error = historyError;
    if (error != null) {
      historyError = null;
      throw error;
    }
    return pages.isEmpty ? const MediaHistoryPage([]) : pages.removeAt(0);
  }

  @override
  Future<void> deleteMedia(String room, String eventId) async {
    deleted.add(eventId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A backend without media features (for hook gating).
class PlainBackend extends ChatBackend {
  @override
  String? get userId => me;
  @override
  SessionStatus get connection => SessionStatus.ready;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeTempFile implements MediaTempFile {
  FakeTempFile(this.log);
  final List<String> log;
  @override
  String get path => '/fake/private/media.ogg';
  @override
  Future<void> delete() async => log.add('delete');
}

class FakePlayer extends MediaPlaybackController {
  FakePlayer(this.log, {this.length = const Duration(seconds: 30)});
  final List<String> log;
  final Duration length;
  final speeds = <double>[];
  bool _playing = false;
  Duration _position = Duration.zero;

  @override
  MediaPlaybackValue get value => MediaPlaybackValue(
    duration: length,
    position: _position,
    playing: _playing,
  );
  @override
  Future<void> initialize() async => log.add('initialize');
  @override
  Future<void> play() async {
    log.add('play');
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    log.add('pause');
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration position) async {
    log.add('seek ${position.inMilliseconds}');
    _position = position;
    notifyListeners();
  }

  @override
  Future<void> setSpeed(double speed) async {
    speeds.add(speed);
    log.add('speed $speed');
  }

  @override
  Widget buildVideo(BuildContext context) => const Text('native video');
  @override
  Future<void> disposePlayer() async {
    log.add('dispose');
    super.dispose();
  }
}

Future<ui.Image> makeImage([int width = 8, int height = 6]) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const Color(0xffabcdef), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

/// Lets queued fake-async work (loads, closes) settle without animations.
Future<void> settle(dynamic tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

Future<void> nothing() => Future<void>.value();
