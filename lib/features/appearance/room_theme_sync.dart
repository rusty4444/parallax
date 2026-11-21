import 'dart:async';

import 'package:matrix/matrix.dart' as matrix;

import '../../chat_backend.dart';
import '../../room_events.dart';
import 'bubble_colours.dart';

/// Syncs a room's bubble colours across the user's devices through Matrix
/// room account data (`net.samrusselltech.parallax.room_theme`). Custom photo
/// wallpapers stay on the device that picked them (they are local files); the
/// colour theme follows the account.
class RoomThemeSync {
  RoomThemeSync(this.backend);

  final ChatBackend backend;

  static const eventType = 'net.samrusselltech.parallax.room_theme';

  matrix.Client? get _client {
    final sdk = backend;
    return sdk is MatrixSdkAccess ? (sdk as MatrixSdkAccess).sdkClient : null;
  }

  bool _current(matrix.Client client) =>
      backend is MatrixSdkAccess &&
      (backend as MatrixSdkAccess).isSessionCurrent(client);

  String _path(matrix.Client client, String roomId) =>
      '/client/v3/user/${Uri.encodeComponent(client.userID!)}'
      '/rooms/${Uri.encodeComponent(roomId)}/account_data/$eventType';

  /// The synced account-data event instance for the room (identity changes
  /// when this or another device writes a newer theme), or null.
  Object? themeToken(String roomId) {
    final room = _client?.getRoomById(roomId);
    return room == null ? null : room.roomAccountData[eventType];
  }

  /// Bubble colours from the locally synced account data, or null.
  BubbleColours? coloursFromSync(String roomId) {
    final room = _client?.getRoomById(roomId);
    if (room == null) return null;
    final content = room.roomAccountData[eventType]?.content;
    final colours = content?['bubbleColours'];
    return colours == null ? null : BubbleColours.fromJson(colours);
  }

  /// Fresh read from the homeserver (rooms whose account data has not synced
  /// yet). Null when there is no theme or it cannot be read.
  Future<BubbleColours?> loadRemote(String roomId) async {
    final client = _client;
    if (client == null || client.userID == null) return null;
    try {
      final content = await client.request(
        matrix.RequestType.GET,
        _path(client, roomId),
      );
      if (!_current(client)) return null;
      final colours = content['bubbleColours'];
      return colours == null ? null : BubbleColours.fromJson(colours);
    } catch (_) {
      return null; // 404 (no theme) or transport error: fall back to local.
    }
  }

  /// Writes the theme to the account so other devices pick it up. Best-effort:
  /// a failure leaves the local theme intact.
  Future<void> push(String roomId, BubbleColours colours) async {
    final client = _client;
    if (client == null || client.userID == null) return;
    try {
      await client.request(
        matrix.RequestType.PUT,
        _path(client, roomId),
        data: {'version': 1, 'bubbleColours': colours.toJson()},
      );
    } catch (_) {
      // Offline or forbidden: the local theme still applies on this device.
    }
  }
}
