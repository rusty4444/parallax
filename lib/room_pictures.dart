/// Chat pictures set on this phone: a picture only you see, used instead of
/// a chat's own (or missing) picture everywhere the app shows it.
///
/// Each is cropped to a 256 px square JPEG (a few tens of KB) off the UI
/// thread, saved under the app's private support folder and kept in memory
/// once loaded, so showing one costs no disk or network access.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Edge of the saved square picture, in pixels.
const roomPictureSize = 256;

/// Largest image accepted before resizing.
const maxRoomPictureSourceBytes = 20 * 1024 * 1024;

/// Crops [source] (any format `package:image` decodes) to a centred square,
/// applies its EXIF rotation and returns a [roomPictureSize] px JPEG. Runs
/// in a background isolate via [RoomPictures.setFromImage].
Uint8List prepareRoomPicture(Uint8List source) {
  final decoded = img.decodeImage(source);
  if (decoded == null) throw const FormatException('Not a supported image');
  final upright = img.bakeOrientation(decoded);
  final square = img.copyResizeCropSquare(
    upright,
    size: roomPictureSize,
    interpolation: img.Interpolation.average,
  );
  return img.encodeJpg(square, quality: 85);
}

/// Where chat pictures are kept, by [RoomPictures.keyFor] key.
abstract interface class RoomPictureStorage {
  Future<Map<String, Uint8List>> readAll();
  Future<void> write(String key, Uint8List bytes);
  Future<void> delete(String key);
}

/// Files under the app support folder (`room_pictures/<key>.jpg`).
class DiskRoomPictureStorage implements RoomPictureStorage {
  const DiskRoomPictureStorage({this.root});

  /// Base folder instead of the app support folder (tests).
  final Directory? root;

  Future<Directory> _directory() async {
    final base = root ?? await getApplicationSupportDirectory();
    return Directory(path.join(base.path, 'room_pictures'));
  }

  @override
  Future<Map<String, Uint8List>> readAll() async {
    final directory = await _directory();
    if (!await directory.exists()) return const {};
    final pictures = <String, Uint8List>{};
    await for (final entity in directory.list()) {
      final name = path.basename(entity.path);
      if (entity is! File || !name.endsWith('.jpg')) continue;
      try {
        final bytes = await entity.readAsBytes();
        if (bytes.isNotEmpty) {
          pictures[name.substring(0, name.length - 4)] = bytes;
        }
      } catch (_) {}
    }
    return pictures;
  }

  @override
  Future<void> write(String key, Uint8List bytes) async {
    final directory = await _directory();
    await directory.create(recursive: true);
    final target = File(path.join(directory.path, '$key.jpg'));
    final temporary = File(
      '${target.path}.${Random.secure().nextInt(0x7fffffff)}.tmp',
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<void> delete(String key) async {
    final target = File(path.join((await _directory()).path, '$key.jpg'));
    if (await target.exists()) await target.delete();
  }
}

/// Chat pictures set on this phone, loaded once and kept in memory.
class RoomPictures extends ChangeNotifier {
  RoomPictures({
    this._storage = const DiskRoomPictureStorage(),
    Future<Uint8List> Function(Uint8List source)? prepare,
  }) : _prepare = prepare ?? ((source) => compute(prepareRoomPicture, source));

  /// The app's instance (replaceable in tests).
  static RoomPictures shared = RoomPictures();

  final RoomPictureStorage _storage;
  final Future<Uint8List> Function(Uint8List source) _prepare;
  Map<String, Uint8List> _pictures = const {};
  final _keys = <String, String>{};
  Future<void>? _loading;
  bool _loaded = false;
  bool _disposed = false;

  /// File name for [roomId] (no room IDs on disk).
  String keyFor(String roomId) => _keys[roomId] ??= sha256
      .convert(utf8.encode(roomId))
      .toString()
      .substring(0, 40);

  bool get loaded => _loaded;

  /// Reads the saved pictures once. Safe to call repeatedly. If the folder
  /// can't be read the app carries on without them (no retry on every
  /// frame); pictures set afterwards still show and are saved.
  Future<void> ensureLoaded() => _loading ??= () async {
    Map<String, Uint8List> read;
    try {
      read = await _storage.readAll();
    } catch (_) {
      read = const {};
    }
    // Pictures set while loading win over what was on disk.
    _pictures = {...read, ..._pictures};
    _loaded = true;
    if (read.isNotEmpty) _notify();
  }();

  /// [roomId]'s picture, or null. Starts loading on first use.
  Uint8List? pictureFor(String roomId) {
    if (!_loaded) unawaited(ensureLoaded());
    return _pictures[keyFor(roomId)];
  }

  bool has(String roomId) => pictureFor(roomId) != null;

  /// Crops [source] to a square, saves it as [roomId]'s picture and shows
  /// it straight away. Throws [ArgumentError] for images over 20 MB and
  /// [FormatException] for files that aren't images.
  Future<void> setFromImage(String roomId, Uint8List source) async {
    if (source.isEmpty || source.lengthInBytes > maxRoomPictureSourceBytes) {
      throw ArgumentError('Choose an image smaller than 20 MB.');
    }
    final picture = await _prepare(source);
    await ensureLoaded();
    final key = keyFor(roomId);
    await _storage.write(key, picture);
    _pictures = {..._pictures, key: picture};
    _notify();
  }

  Future<void> remove(String roomId) async {
    await ensureLoaded();
    final key = keyFor(roomId);
    await _storage.delete(key);
    if (!_pictures.containsKey(key)) return;
    _pictures = {..._pictures}..remove(key);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
