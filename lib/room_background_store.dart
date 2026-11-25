import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Copies temporary picker images into private app storage. No URI grants survive.
class RoomBackgroundStore {
  RoomBackgroundStore({this.root});

  final Directory? root;
  static const maxBytes = 20 * 1024 * 1024;

  Future<Directory> _directory() async {
    final base = root ?? await getApplicationSupportDirectory();
    final directory = Directory(path.join(base.path, 'room_backgrounds'));
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  Future<File> _target(String roomId) async {
    if (roomId.isEmpty) throw ArgumentError('A room ID is required');
    final digest = sha256.convert(utf8.encode(roomId));
    return File(path.join((await _directory()).path, '$digest.image'));
  }

  Future<File?> fileFor(String roomId) async {
    final file = await _target(roomId);
    return await file.exists() ? file : null;
  }

  /// Replace only after a complete same-directory copy; preserve the old file
  /// if the provider read or write fails.
  Future<File> replace(String roomId, XFile source) async {
    final length = await source.length();
    if (length <= 0 || length > maxBytes) {
      throw ArgumentError('Choose an image smaller than 20 MB');
    }
    final target = await _target(roomId);
    final suffix = Random.secure().nextInt(0x7fffffff);
    final temporary = File('${target.path}.$suffix.tmp');
    try {
      final sink = temporary.openWrite();
      try {
        await sink.addStream(source.openRead());
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (await temporary.length() != length) {
        throw const FileSystemException('Background copy incomplete');
      }
      await temporary.rename(target.path);
      return target;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  /// Same as [replace], from bytes (a background synced from another device).
  Future<File> replaceBytes(String roomId, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw ArgumentError('Background must be smaller than 20 MB');
    }
    final target = await _target(roomId);
    final suffix = Random.secure().nextInt(0x7fffffff);
    final temporary = File('${target.path}.$suffix.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      if (await temporary.length() != bytes.length) {
        throw const FileSystemException('Background copy incomplete');
      }
      await temporary.rename(target.path);
      return target;
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> clear(String roomId) async {
    final target = await _target(roomId);
    if (await target.exists()) await target.delete();
  }
}
