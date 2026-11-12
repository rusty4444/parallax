import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/packs/pack_features.dart';
import 'package:parallax/features/packs/pack_model.dart';

const packsRoomId = '!room:example.org';
const packsOtherRoomId = '!other:example.org';
final packsPalette = paletteFor(VisualTheme.parallax);

/// A tiny 3×2 PNG.
final Uint8List tinyPng = Uint8List.fromList(
  img.encodePng(img.Image(width: 3, height: 2)),
);

PackImage packImage(
  String code,
  String media, {
  List<String>? usage,
  String? body,
}) => PackImage(
  shortcode: code,
  url: Uri.parse('mxc://example.org/$media'),
  usage: usage,
  body: body,
  info: const {'w': 64, 'h': 64, 'mimetype': 'image/png', 'size': 1234},
);

ImagePack pack(List<PackImage> images, {String? name, List<String>? usage}) =>
    ImagePack(
      images: {for (final image in images) image.shortcode: image},
      displayName: name,
      usage: usage,
    );

/// In-memory [PacksFeatures] on a minimal [ChatBackend].
class FakePacksBackend extends ChatBackend implements PacksFeatures {
  ImagePack personal = ImagePack.empty;
  final Map<PackRef, ImagePack> roomState = {};
  final Set<PackRef> everywhere = {};
  final Map<String, String> roomNames = {
    packsRoomId: 'Kangaroo Club',
    packsOtherRoomId: 'Wombats',
  };
  bool canEdit = true;
  bool failSticker = false;
  String? active = packsRoomId;
  final stickers = <(String, PackImage)>[];
  final uploads = <String>[];
  final writes = <PackRef>[];
  final loads = <Uri>[];
  final updates = ChangeNotifierHook();

  void changed() => updates.ping();

  @override
  String? get userId => '@sam:example.org';
  @override
  SessionStatus get connection => SessionStatus.ready;
  @override
  String? get activeRoomId => active;
  @override
  List<ChatRoom> get rooms => const [];
  @override
  List<ChatEntry> get messages => const [];
  @override
  Future<Uint8List?> loadAvatar(Uri url) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  // --- PacksFeatures -------------------------------------------------------

  @override
  Listenable get packUpdates => updates;

  RoomPackState _state(PackRef ref, ImagePack value) => RoomPackState(
    ref: ref,
    pack: value,
    roomName: roomNames[ref.roomId] ?? ref.roomId!,
  );

  @override
  AvailablePacks availablePacks(String? roomId) => mergeAvailablePacks(
    personal: personal,
    roomPacks: roomId == null ? const [] : roomPacks(roomId),
    globalPacks: globalPacks(),
  );

  @override
  void ensurePacksLoaded(String? roomId) {}

  @override
  List<RoomPackState> roomPacks(String roomId) => [
    for (final entry in roomState.entries)
      if (entry.key.roomId == roomId) _state(entry.key, entry.value),
  ]..sort((a, b) => a.ref.stateKey.compareTo(b.ref.stateKey));

  @override
  List<RoomPackState> globalPacks() => [
    for (final ref in everywhere)
      if (roomState[ref] case final value?) _state(ref, value),
  ];

  @override
  ImagePack personalPack() => personal;

  @override
  bool canEditRoomPacks(String roomId) => canEdit;

  @override
  bool isEnabledEverywhere(PackRef ref) => everywhere.contains(ref);

  @override
  Uint8List? cachedPackImage(Uri url) => null;

  @override
  Future<Uint8List?> loadPackImage(Uri url) async {
    loads.add(url);
    return tinyPng;
  }

  @override
  Future<ImagePack> updatePack(
    PackRef ref,
    ImagePack Function(ImagePack current) change,
  ) async {
    final current = ref.personal
        ? personal
        : (roomState[ref] ?? ImagePack.empty);
    final next = change(current);
    writes.add(ref);
    if (ref.personal) {
      personal = next;
    } else {
      roomState[ref] = next;
    }
    changed();
    return next;
  }

  @override
  Future<PackRef> createRoomPack(String roomId, String name) async {
    final ref = PackRef.room(
      roomId,
      roomState.keys.any((r) => r.roomId == roomId) ? packSlug(name) : '',
    );
    roomState[ref] = ImagePack(displayName: name);
    changed();
    return ref;
  }

  @override
  Future<void> deleteRoomPack(PackRef ref) async {
    roomState.remove(ref);
    everywhere.remove(ref);
    changed();
  }

  @override
  Future<void> setEnabledEverywhere(
    PackRef ref, {
    required bool enabled,
  }) async {
    enabled ? everywhere.add(ref) : everywhere.remove(ref);
    changed();
  }

  @override
  Future<Uri> uploadPackImage(
    Uint8List bytes, {
    required String fileName,
    required String mimeType,
  }) async {
    uploads.add('$fileName $mimeType ${bytes.length}');
    return Uri.parse('mxc://example.org/upload${uploads.length}');
  }

  @override
  Future<String> sendSticker(String roomId, PackImage image) async {
    if (failSticker) throw StateError('offline');
    stickers.add((roomId, image));
    return r'$sticker';
  }
}

class ChangeNotifierHook extends ChangeNotifier {
  void ping() => notifyListeners();
}

/// A tall phone-sized surface.
void phoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2600);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}

Widget packsApp(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(body: child),
);
