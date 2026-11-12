// Hook implementations for link previews. Core screens call these through
// lib/hooks/registry.dart.
import 'package:flutter/material.dart';

import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../hooks/hook_types.dart';
import '../home/settings_widgets.dart';
import 'link_preview_card.dart';
import 'link_previews.dart';

/// The preview under a text message containing a web link. Null for media,
/// state events, redactions, messages without a link, backends that can't
/// fetch previews, and whenever the user's settings say no.
Widget? linkPreviewEntryFooter(BuildContext context, EntryHookContext ctx) {
  final entry = ctx.entry;
  if (entry.redacted) return null;
  if (entry.kind != EntryKind.text &&
      entry.kind != EntryKind.emote &&
      entry.kind != EntryKind.notice) {
    return null;
  }
  final backend = ctx.backend;
  if (backend is! LinkPreviewSource) return null;
  final source = backend as LinkPreviewSource;
  final preferences = FeatureSettingsScope.maybeOf(context)?.preferences;
  if (preferences == null || !preferences.linkPreviews) return null;
  // An unknown room is treated as encrypted: better no preview than the
  // homeserver learning a link from an encrypted message.
  if (ctx.room?.encrypted != false &&
      !preferences.linkPreviewsInEncryptedRooms) {
    return null;
  }
  final uri = firstPreviewableLink(entry.body);
  if (uri == null) return null;
  return LinkPreviewCard(
    key: ValueKey('link-preview-${entry.id}'),
    uri: uri,
    source: source,
    backend: ctx.backend,
    palette: ctx.palette,
    mine: entry.mine,
    timestamp: entry.time.millisecondsSinceEpoch,
  );
}

/// Settings → Media → Link previews.
List<Widget> linkPreviewSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) {
  final preferences = FeatureSettingsScope.maybeOf(context)?.preferences;
  if (preferences == null) return const [];
  return [
    ListenableBuilder(
      listenable: preferences,
      builder: (context, _) => SettingsGroup(
        palette: ctx.palette,
        title: 'Link previews',
        children: [
          SwitchListTile(
            key: const ValueKey('media.link_previews'),
            secondary: const Icon(Icons.link_rounded),
            title: const Text('Show link previews'),
            subtitle: const Text(
              'Show the page title and image for links in messages. '
              'Your homeserver fetches the preview, not your phone.',
            ),
            value: preferences.linkPreviews,
            onChanged: preferences.setLinkPreviews,
          ),
          SwitchListTile(
            key: const ValueKey('media.link_previews_encrypted'),
            secondary: const Icon(Icons.lock_outline_rounded),
            title: const Text('Preview links in encrypted chats'),
            subtitle: const Text(
              'Off by default. Turning this on lets your homeserver see '
              'the links in your encrypted messages.',
            ),
            value: preferences.linkPreviewsInEncryptedRooms,
            onChanged: preferences.linkPreviews
                ? preferences.setLinkPreviewsInEncryptedRooms
                : null,
          ),
        ],
      ),
    ),
  ];
}
