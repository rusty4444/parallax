import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_theme.dart';
import '../../widgets.dart';

/// Parallax settings page chrome: glow backdrop, back button, eyebrow, title.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.palette,
    required this.eyebrow,
    required this.title,
    required this.children,
    this.trailing,
  });

  final AppPalette palette;
  final String eyebrow;
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: GlowBackdrop(
      palette: palette,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 34),
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Back',
                  onPressed: () => Navigator.maybePop(context),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                const Spacer(),
                ?trailing,
              ],
            ),
            const SizedBox(height: 14),
            Eyebrow(eyebrow, palette: palette),
            const SizedBox(height: 4),
            Text(
              title,
              style: TextStyle(
                color: palette.foreground,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                letterSpacing: -1.4,
              ),
            ),
            const SizedBox(height: 22),
            ...children,
          ],
        ),
      ),
    ),
  );
}

/// A rounded card grouping related settings rows.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.palette,
    required this.children,
    this.title,
    this.footer,
  });

  final AppPalette palette;
  final String? title;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final visible = children.whereType<Widget>().toList();
    if (visible.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Eyebrow(title!, palette: palette),
            const SizedBox(height: 8),
          ],
          Material(
            color: palette.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: palette.stroke),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final (index, child) in visible.indexed) ...[
                  if (index > 0) Divider(height: 1, indent: 16, endIndent: 16),
                  child,
                ],
              ],
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 8, 6, 0),
              child: Text(
                footer!,
                style: TextStyle(color: palette.muted, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

/// Opens only https/http/mailto links outside the app.
Future<bool> openExternalLink(BuildContext context, Uri uri) async {
  if (!const {'https', 'http', 'mailto'}.contains(uri.scheme)) return false;
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    opened = false;
  }
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          uri.scheme == 'mailto'
              ? 'No email app found. Write to ${uri.path}.'
              : 'Couldn’t open ${uri.host.isEmpty ? uri : uri.host}.',
        ),
      ),
    );
  }
  return opened;
}

/// A password prompt for user-interactive authentication. Returns null when
/// cancelled. The value is held only in memory and cleared on close.
Future<String?> askAccountPassword(
  BuildContext context, {
  required String title,
  required String message,
  String action = 'Continue',
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      _PasswordDialog(title: title, message: message, action: action),
);

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({
    required this.title,
    required this.message,
    required this.action,
  });
  final String title;
  final String message;
  final String action;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.clear();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.message),
        const SizedBox(height: 14),
        TextField(
          controller: _controller,
          autofocus: true,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.visiblePassword,
          decoration: const InputDecoration(labelText: 'Password'),
          onSubmitted: (value) =>
              value.isEmpty ? null : Navigator.pop(context, value),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => FilledButton(
          onPressed: _controller.text.isEmpty
              ? null
              : () => Navigator.pop(context, _controller.text),
          child: Text(widget.action),
        ),
      ),
    ],
  );
}
