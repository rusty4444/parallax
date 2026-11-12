// Hook implementations for the Space administration feature module.
//
// Create Spaces, manage children, Space settings and leaving.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';

/// Room details sections (for example "Manage rooms" when the room is a Space,
/// or "Add to Space" for ordinary rooms).
List<Widget> spacesAdminRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) => const [];
