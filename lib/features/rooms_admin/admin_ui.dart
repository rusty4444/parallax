// Shared visual building blocks for the room administration screens.
import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../room_avatar.dart';
import '../../room_details.dart';
import '../../widgets.dart';

/// A full-screen page in the Parallax visual language.
class AdminPage extends StatelessWidget {
  const AdminPage({
    super.key,
    required this.palette,
    required this.title,
    required this.body,
    this.actions = const [],
    this.busy = false,
    this.backTooltip = 'Back',
    this.onBack,
  });
  final AppPalette palette;
  final String title;
  final Widget body;
  final List<Widget> actions;
  final bool busy;
  final String backTooltip;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: GlowBackdrop(
      palette: palette,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
              child: Row(
                children: [
                  IconButton(
                    tooltip: backTooltip,
                    onPressed: onBack ?? () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: palette.foreground,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  ...actions,
                ],
              ),
            ),
            SizedBox(
              height: 3,
              child: busy ? const LinearProgressIndicator() : null,
            ),
            Expanded(child: body),
          ],
        ),
      ),
    ),
  );
}

/// A rounded card grouping related rows, with an optional eyebrow title and
/// footer explanation.
class AdminSection extends StatelessWidget {
  const AdminSection({
    super.key,
    required this.palette,
    required this.children,
    this.title,
    this.footer,
  });
  final AppPalette palette;
  final List<Widget> children;
  final String? title;
  final String? footer;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
            child: Eyebrow(title!, palette: palette),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: palette.surface.withValues(alpha: 0.86),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: palette.stroke),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Material(
              type: MaterialType.transparency,
              child: Column(children: children),
            ),
          ),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Text(
              footer!,
              style: TextStyle(color: palette.muted, fontSize: 12.5),
            ),
          ),
      ],
    ),
  );
}

class AdminTile extends StatelessWidget {
  const AdminTile({
    super.key,
    required this.palette,
    required this.title,
    this.icon,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
    this.leading,
  });
  final AppPalette palette;
  final String title;
  final IconData? icon;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final colour = destructive ? const Color(0xFFFF6B5E) : palette.foreground;
    return ListTile(
      leading:
          leading ??
          (icon == null
              ? null
              : Icon(icon, color: destructive ? colour : palette.secondary)),
      title: Text(
        title,
        style: TextStyle(color: colour, fontWeight: FontWeight.w600),
      ),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: TextStyle(color: palette.muted)),
      trailing: trailing,
      onTap: onTap,
      enabled: onTap != null || trailing != null || subtitle != null,
    );
  }
}

/// Circular avatar for a person or room, using the backend's bounded,
/// authenticated avatar loader.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.backend,
    required this.palette,
    required this.name,
    this.url,
    this.size = 44,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String name;
  final Uri? url;
  final double size;

  @override
  Widget build(BuildContext context) => RoomAvatar(
    room: ChatRoom(
      id: name,
      name: name.startsWith('@') && name.length > 1 ? name.substring(1) : name,
      preview: '',
      lastActivity: null,
      avatarUrl: url,
    ),
    backend: backend,
    palette: palette,
    size: size,
  );
}

class RoleBadge extends StatelessWidget {
  const RoleBadge({super.key, required this.role, required this.palette});
  final RoomRole role;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) => role == RoomRole.member
      ? const SizedBox.shrink()
      : Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: palette.accent.withValues(alpha: 0.16),
            border: Border.all(color: palette.accent.withValues(alpha: 0.4)),
          ),
          child: Text(
            role.label,
            style: TextStyle(
              color: palette.foreground,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
}

class AdminBadge extends StatelessWidget {
  const AdminBadge({
    super.key,
    required this.palette,
    required this.icon,
    required this.label,
    this.highlight = false,
  });
  final AppPalette palette;
  final IconData icon;
  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      color: highlight
          ? palette.secondary.withValues(alpha: 0.16)
          : palette.raised.withValues(alpha: 0.7),
      border: Border.all(color: palette.stroke),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: palette.secondary),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            color: palette.foreground,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

/// A circular action button in the room/user header row.
class HeaderAction extends StatelessWidget {
  const HeaderAction({
    super.key,
    required this.palette,
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final AppPalette palette;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 72,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          tooltip: label,
          onPressed: onPressed,
          style: IconButton.styleFrom(
            backgroundColor: palette.raised,
            foregroundColor: palette.secondary,
            fixedSize: const Size(52, 52),
          ),
          icon: Icon(icon),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: palette.muted, fontSize: 12),
        ),
      ],
    ),
  );
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  bool destructive = false,
  String cancel = 'Cancel',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(cancel),
        ),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFD7263D),
                  foregroundColor: Colors.white,
                )
              : null,
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return result == true;
}

/// Confirmation with an optional reason. Returns null when cancelled, or the
/// trimmed reason ('' for none).
Future<String?> askReason(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  String label = 'Reason (optional)',
  bool destructive = true,
  int maxLength = 500,
}) => showDialog<String>(
  context: context,
  builder: (_) => _ReasonDialog(
    title: title,
    message: message,
    confirm: confirm,
    label: label,
    destructive: destructive,
    maxLength: maxLength,
  ),
);

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({
    required this.title,
    required this.message,
    required this.confirm,
    required this.label,
    required this.destructive,
    required this.maxLength,
  });
  final String title;
  final String message;
  final String confirm;
  final String label;
  final bool destructive;
  final int maxLength;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          const SizedBox(height: 14),
          TextField(
            controller: _reason,
            maxLength: widget.maxLength,
            maxLines: 3,
            minLines: 1,
            decoration: InputDecoration(labelText: widget.label),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        style: widget.destructive
            ? FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD7263D),
                foregroundColor: Colors.white,
              )
            : null,
        onPressed: () => Navigator.pop(context, _reason.text.trim()),
        child: Text(widget.confirm),
      ),
    ],
  );
}

void showAdminMessage(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// Empty or error placeholder with an optional retry.
class AdminPlaceholder extends StatelessWidget {
  const AdminPlaceholder({
    super.key,
    required this.palette,
    required this.title,
    this.message,
    this.icon = Icons.info_outline_rounded,
    this.onRetry,
  });
  final AppPalette palette;
  final String title;
  final String? message;
  final IconData icon;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 42, color: palette.secondary),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: palette.foreground,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.muted),
            ),
          ],
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ],
      ),
    ),
  );
}
