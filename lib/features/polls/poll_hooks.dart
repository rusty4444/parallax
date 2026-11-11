// Hook implementations for the polls and location feature module.
//
// Poll creation/voting/results and static location sharing.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';

Widget? pollEntryBody(BuildContext context, EntryHookContext ctx) => null;

Widget? locationEntryBody(BuildContext context, EntryHookContext ctx) => null;

List<ComposerAttachmentAction> pollComposerAttachments(
  BuildContext context,
  RoomHookContext ctx,
) => const [];

List<MessageActionItem> pollMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) => const [];

List<Widget> pollRoomDetailsSections(
  BuildContext context,
  RoomHookContext ctx,
) => const [];
