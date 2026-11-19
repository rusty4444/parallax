// Hook implementations for the platform integration feature module.
//
// Share intents, deep links and UnifiedPush.
// Core screens call these through lib/hooks/registry.dart. Keep the function
// signatures stable; return empty lists / null when not applicable.
//
// For in-app link taps, other modules import
// `lib/features/platform/matrix_link_opener.dart` and call
// `openMatrixLink(context, backend, palette, uri)`; it returns false for
// non-Matrix links so the caller can fall back to the browser.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../hooks/hook_types.dart';
import '../../widgets.dart';
import 'matrix_link_opener.dart';
import 'platform_intents_host.dart';
import 'share_shortcuts.dart';
import 'windows_bootstrap.dart';

/// Wraps the signed-in app to route share intents and matrix.to links, and
/// to offer its recent chats in Android's share sheet.
Widget wrapWithPlatformIntents(
  BuildContext context,
  AppHookContext ctx,
  Widget child,
) => PlatformIntentsHost(
  app: ctx,
  child: ShareShortcutsHost(
    // Another account starts from an empty list.
    key: ValueKey(
      'share-shortcuts:${BackendSessionOwner.keyFor(ctx.backend) ?? ''}',
    ),
    app: ctx,
    child: child,
  ),
);

List<Widget> platformSettingsSections(
  BuildContext context,
  SettingsHookContext ctx,
) => [_LinksAndSharingSection(backend: ctx.backend, palette: ctx.palette)];

class _LinksAndSharingSection extends StatelessWidget {
  const _LinksAndSharingSection({required this.backend, required this.palette});
  final ChatBackend backend;
  final AppPalette palette;

  Future<void> _openLink(BuildContext context) async {
    final controller = TextEditingController();
    try {
      final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Open a Matrix link'),
          content: TextField(
            controller: controller,
            autofocus: true,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Link',
              hintText: 'https://matrix.to/#/#room:example.org',
            ),
            onSubmitted: (value) => Navigator.pop(context, value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Open'),
            ),
          ],
        ),
      );
      if (value == null || value.isEmpty || !context.mounted) return;
      final uri = Uri.tryParse(value);
      final opened =
          uri != null && await openMatrixLink(context, backend, palette, uri);
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Enter a matrix.to link or a matrix: link to a room or person.',
            ),
          ),
        );
      }
    } finally {
      controller.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Eyebrow('Links and sharing', palette: p),
        const SizedBox(height: 10),
        Material(
          color: p.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: p.stroke),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isWindowsDesktop
                      ? 'Share photos, videos, files and text to Parallax by '
                            'dragging them onto the window or opening them with '
                            'Parallax. Your most recent chats appear in the '
                            'taskbar jump list, unless a screen lock PIN is set. '
                            'matrix.to and matrix: links open here too.'
                      : (!kIsWeb &&
                            (defaultTargetPlatform == TargetPlatform.iOS ||
                                defaultTargetPlatform == TargetPlatform.macOS))
                      ? 'On iPhone and iPad, share photos, videos, files and '
                            'text to Parallax from the share sheet. On Mac, '
                            'drag-and-drop sharing is not available yet. '
                            'matrix.to and matrix: links open here on both.'
                      : 'Share photos, videos, files and text to Parallax from other '
                            'apps. Android’s share menu suggests your most recent chats, '
                            'unless a screen lock PIN is set. matrix.to and matrix: links '
                            'open here too.',
                  style: TextStyle(color: p.muted, fontSize: 12),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.link_rounded, color: p.secondary),
                  title: const Text('Open a Matrix link'),
                  subtitle: const Text('Paste a room, message or user link'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => unawaited(_openLink(context)),
                ),
              ],
            ),
          ),
        ),
        // Same spacing as SettingsGroup on the settings pages.
        const SizedBox(height: 18),
      ],
    );
  }
}
