// Hook implementations for the threads and search feature module.
//
// Thread list, thread summaries, local message search and jump-to-event.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';

List<Widget> threadRoomHeaderActions(
  BuildContext context,
  RoomHookContext ctx,
) => const [];

/// Footer under a message (for example a thread summary chip).
Widget? threadEntryFooter(BuildContext context, EntryHookContext ctx) => null;

List<MessageActionItem> threadMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) => const [];

List<Widget> threadRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) => const [];
