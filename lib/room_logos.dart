/// Per-room choice of app logo, saved on this phone: use the detected
/// network (automatic), force a particular app's logo, or force the letter.
/// Only used when the chat has no picture of its own, and only while
/// Settings → Appearance → App logos is on.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'chat_network.dart';

class RoomLogos extends ChangeNotifier {
  RoomLogos({this._directory, this.inMemory = false});

  /// The app's instance (replaceable in tests).
  static RoomLogos shared = RoomLogos();

  final Directory? _directory;

  /// Tests: keep choices in memory only, no file IO.
  final bool inMemory;
  Map<String, ChatNetwork> _overrides = const {};
  final _keys = <String, String>{};
  Future<void>? _loading;
  bool _disposed = false;

  String keyFor(String roomId) => _keys[roomId] ??= sha256
      .convert(utf8.encode(roomId))
      .toString()
      .substring(0, 40);

  Future<File> _file() async {
    final base = _directory ?? await getApplicationSupportDirectory();
    return File(path.join(base.path, 'room_logos.json'));
  }

  /// Reads the saved choices once. Failures just mean no overrides.
  Future<void> ensureLoaded() => inMemory
      ? Future.value()
      : _loading ??= () async {
          try {
            final file = await _file();
            if (!await file.exists()) return;
            final decoded = jsonDecode(await file.readAsString());
            if (decoded is! Map || decoded['overrides'] is! Map) return;
            final read = <String, ChatNetwork>{};
            for (final entry in (decoded['overrides'] as Map).entries) {
              final network = ChatNetwork.values
                  .where((n) => n.name == entry.value)
                  .firstOrNull;
              if (entry.key is String && network != null) {
                read[entry.key as String] = network;
              }
            }
            _overrides = {...read, ..._overrides};
          } catch (_) {}
        }();

  /// The user's choice for [roomId], or null for automatic detection.
  ChatNetwork? overrideFor(String roomId) {
    if (!inMemory && _loading == null) ensureLoaded();
    return _overrides[keyFor(roomId)];
  }

  /// Sets [roomId]'s logo; null goes back to automatic. Pass
  /// [ChatNetwork.otherBridge] for "no logo, show the letter".
  Future<void> set(String roomId, ChatNetwork? network) async {
    await ensureLoaded();
    final key = keyFor(roomId);
    final next = {..._overrides};
    if (network == null) {
      next.remove(key);
    } else {
      next[key] = network;
    }
    if (!inMemory) {
      final file = await _file();
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'overrides': {
            for (final entry in next.entries) entry.key: entry.value.name,
          },
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    }
    _overrides = next;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
