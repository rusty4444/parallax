import 'package:flutter/widgets.dart';

import 'chat_backend.dart';
import 'feature_settings_scope.dart';

/// Whether media previews should load automatically in [roomId], following
/// Settings → Media and privacy ("Always", "In private rooms", "Never").
/// A room missing from the inbox projection is treated as private.
bool autoLoadMediaFor(
  BuildContext context,
  ChatBackend backend,
  String roomId,
) {
  final preferences = FeatureSettingsScope.maybeOf(context)?.preferences;
  if (preferences == null) return true;
  final room = backend.rooms.where((room) => room.id == roomId).firstOrNull;
  return preferences.autoLoadMediaIn(publicRoom: room?.isPublic ?? false);
}
