import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../room_avatar.dart';
import '../../room_screen.dart';
import '../spaces_admin/space_options_sheet.dart';
import '../spaces_admin/spaces_admin_features.dart';
import 'home_features.dart';

/// Element X HomeSpaces filter: pick a joined Space to show only its chats.
///
/// Long-press opens the Space menu (explore, manage rooms, settings, leave)
/// from the spaces_admin module, falling back to [onOptions] for backends
/// without Space administration. A trailing "New space" pill creates one.
class SpaceSwitcher extends StatelessWidget {
  const SpaceSwitcher({
    super.key,
    required this.spaces,
    required this.selected,
    required this.backend,
    required this.palette,
    required this.onSelected,
    required this.onOptions,
  });

  final List<HomeSpace> spaces;
  final String? selected;
  final ChatBackend backend;
  final AppPalette palette;
  final ValueChanged<String?> onSelected;
  final ValueChanged<HomeSpace> onOptions;

  Future<void> _spaceMenu(BuildContext context, HomeSpace space) =>
      showSpaceOptionsSheet(
        context,
        backend: backend,
        palette: palette,
        spaceId: space.id,
        spaceName: space.name,
        onOpenRoom: (roomId) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                RoomScreen(backend: backend, palette: palette, roomId: roomId),
          ),
        ),
        onLeft: () {
          if (selected == space.id) onSelected(null);
        },
      );

  Future<void> _newSpace(BuildContext context) async {
    final spaceId = await openCreateSpace(
      context,
      backend: backend,
      palette: palette,
    );
    if (spaceId != null && context.mounted) onSelected(spaceId);
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final spacesAdmin = spacesAdminFeaturesOf(backend) != null;
    Widget pill({
      required String label,
      required bool active,
      required VoidCallback onTap,
      VoidCallback? onLongPress,
      Widget? leading,
      String? tooltip,
    }) {
      final chip = Material(
        color: active ? p.secondary.withValues(alpha: 0.18) : p.surface,
        shape: StadiumBorder(
          side: BorderSide(color: active ? p.secondary : p.stroke),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: EdgeInsets.fromLTRB(leading == null ? 14 : 5, 5, 14, 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (leading != null) ...[leading, const SizedBox(width: 8)],
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 160),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active ? p.foreground : p.muted,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: tooltip == null ? chip : Tooltip(message: tooltip, child: chip),
      );
    }

    return SizedBox(
      height: 40,
      child: ListView(
        key: const ValueKey('home-space-switcher'),
        scrollDirection: Axis.horizontal,
        children: [
          pill(
            label: 'All chats',
            active: selected == null,
            onTap: () => onSelected(null),
            leading: Icon(Icons.forum_outlined, size: 18, color: p.secondary),
          ),
          for (final space in spaces)
            pill(
              label: space.name,
              active: space.id == selected,
              tooltip: 'Long-press for Space options',
              onTap: () => onSelected(space.id == selected ? null : space.id),
              onLongPress: () =>
                  spacesAdmin ? _spaceMenu(context, space) : onOptions(space),
              leading: RoomAvatar(
                room: ChatRoom(
                  id: space.id,
                  name: space.name,
                  preview: '',
                  lastActivity: null,
                  avatarUrl: space.avatarUrl,
                  isSpace: true,
                ),
                backend: backend,
                palette: p,
                size: 28,
              ),
            ),
          if (spacesAdmin)
            pill(
              label: 'New space',
              active: false,
              onTap: () => _newSpace(context),
              leading: Icon(Icons.add_rounded, size: 18, color: p.secondary),
            ),
        ],
      ),
    );
  }
}
