// Hook implementations for the saved messages and chat folders feature module.
//
// Note to self, bookmarks and chat folders.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null / the input when not applicable.
import 'package:flutter/material.dart';

import '../../hooks/hook_types.dart';

List<MessageActionItem> savedMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) => const [];

List<Widget> savedSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) => const [];
