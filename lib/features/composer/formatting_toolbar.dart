import 'package:flutter/material.dart';

import 'markdown_format.dart';

/// Element X's text formatting row (`TextFormatting.kt`): same order and
/// accessibility labels. Buttons show on (reversed) and disabled states.
class FormattingToolbar extends StatelessWidget {
  const FormattingToolbar({
    super.key,
    required this.state,
    required this.onAction,
  });

  final FormattingState state;
  final ValueChanged<FormatAction> onAction;

  static String labelFor(FormatAction action) => switch (action) {
    FormatAction.bold => 'Apply bold format',
    FormatAction.italic => 'Apply italic format',
    FormatAction.underline => 'Apply underline format',
    FormatAction.strikethrough => 'Apply strikethrough format',
    FormatAction.link => 'Set link',
    FormatAction.bulletList => 'Toggle bullet list',
    FormatAction.numberedList => 'Toggle numbered list',
    FormatAction.indent => 'Indent',
    FormatAction.unindent => 'Unindent',
    FormatAction.inlineCode => 'Apply inline code format',
    FormatAction.codeBlock => 'Toggle code block',
    FormatAction.quote => 'Toggle quote',
  };

  static IconData iconFor(FormatAction action) => switch (action) {
    FormatAction.bold => Icons.format_bold_rounded,
    FormatAction.italic => Icons.format_italic_rounded,
    FormatAction.underline => Icons.format_underlined_rounded,
    FormatAction.strikethrough => Icons.format_strikethrough_rounded,
    FormatAction.link => Icons.link_rounded,
    FormatAction.bulletList => Icons.format_list_bulleted_rounded,
    FormatAction.numberedList => Icons.format_list_numbered_rounded,
    FormatAction.indent => Icons.format_indent_increase_rounded,
    FormatAction.unindent => Icons.format_indent_decrease_rounded,
    FormatAction.inlineCode => Icons.code_rounded,
    FormatAction.codeBlock => Icons.data_object_rounded,
    FormatAction.quote => Icons.format_quote_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      key: const ValueKey('composer-formatting-toolbar'),
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          for (final action in FormatAction.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: _FormattingButton(
                action: action,
                selected: state.active.contains(action),
                enabled: !state.disabled.contains(action),
                scheme: scheme,
                onPressed: () => onAction(action),
              ),
            ),
        ],
      ),
    );
  }
}

class _FormattingButton extends StatelessWidget {
  const _FormattingButton({
    required this.action,
    required this.selected,
    required this.enabled,
    required this.scheme,
    required this.onPressed,
  });
  final FormatAction action;
  final bool selected;
  final bool enabled;
  final ColorScheme scheme;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = FormattingToolbar.labelFor(action);
    final toggleable =
        action != FormatAction.indent && action != FormatAction.unindent;
    return Semantics(
      toggled: toggleable && enabled ? selected : null,
      child: IconButton(
        key: ValueKey('format-${action.name}'),
        tooltip: label,
        isSelected: selected,
        onPressed: enabled ? onPressed : null,
        style: IconButton.styleFrom(
          backgroundColor: selected
              ? scheme.primary.withValues(alpha: 0.18)
              : Colors.transparent,
          foregroundColor: selected ? scheme.primary : scheme.onSurfaceVariant,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          visualDensity: VisualDensity.compact,
        ),
        icon: Icon(FormattingToolbar.iconFor(action), size: 22),
      ),
    );
  }
}

/// The link dialog's outcome.
@immutable
class LinkDialogResult {
  const LinkDialogResult.save({required this.text, required String this.url})
    : remove = false;
  const LinkDialogResult.remove() : text = '', url = null, remove = true;
  final String text;
  final String? url;
  final bool remove;
}

/// Element X's "Create a link" / "Edit link" dialog: text and link, with
/// http, https and mailto validation.
Future<LinkDialogResult?> showComposerLinkDialog(
  BuildContext context,
  LinkTarget target,
) => showDialog<LinkDialogResult>(
  context: context,
  builder: (context) => _LinkDialog(target: target),
);

class _LinkDialog extends StatefulWidget {
  const _LinkDialog({required this.target});
  final LinkTarget target;

  @override
  State<_LinkDialog> createState() => _LinkDialogState();
}

class _LinkDialogState extends State<_LinkDialog> {
  late final _text = TextEditingController(text: widget.target.text);
  late final _url = TextEditingController(text: widget.target.url ?? '');
  String? _error;
  bool _closed = false;

  bool get _editing => widget.target.span != null;

  @override
  void dispose() {
    _text.dispose();
    _url.dispose();
    super.dispose();
  }

  void _save() {
    if (_closed) return;
    final url = normaliseLinkUrl(_url.text);
    if (url == null) {
      setState(
        () => _error =
            'Enter a valid link starting with https://, http:// '
            'or mailto:.',
      );
      return;
    }
    _closed = true;
    Navigator.pop(context, LinkDialogResult.save(text: _text.text, url: url));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_editing ? 'Edit link' : 'Create a link'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          key: const ValueKey('composer-link-text'),
          controller: _text,
          maxLength: 500,
          decoration: const InputDecoration(labelText: 'Text', counterText: ''),
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('composer-link-url'),
          controller: _url,
          autofocus: widget.target.text.isNotEmpty,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: InputDecoration(labelText: 'Link', errorText: _error),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _save(),
        ),
      ],
    ),
    actions: [
      if (_editing)
        TextButton(
          onPressed: () {
            if (_closed) return;
            _closed = true;
            Navigator.pop(context, const LinkDialogResult.remove());
          },
          child: const Text('Remove link'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
