// Hook implementations for the on-device translation module.
import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../hooks/hook_types.dart';
import '../../widgets.dart';
import 'translation.dart';

/// Long-press message action: "Translate".
List<MessageActionItem> translationMessageActions(
  BuildContext context,
  EntryHookContext ctx,
) {
  final entry = ctx.entry;
  final translatable =
      entry.kind == EntryKind.text ||
      entry.kind == EntryKind.emote ||
      entry.kind == EntryKind.notice;
  if (!translatable || entry.redacted || entry.body.trim().isEmpty) {
    return const [];
  }
  return [
    MessageActionItem(
      id: 'translation.translate',
      icon: Icons.translate_rounded,
      label: 'Translate',
      onSelected: (context) =>
          showTranslationSheet(context, text: entry.body, palette: ctx.palette),
    ),
  ];
}

Future<void> showTranslationSheet(
  BuildContext context, {
  required String text,
  required AppPalette palette,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: palette.background,
    builder: (_) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: _TranslationSheet(text: text, palette: palette),
    ),
  );
}

class _TranslationSheet extends StatefulWidget {
  const _TranslationSheet({required this.text, required this.palette});
  final String text;
  final AppPalette palette;

  @override
  State<_TranslationSheet> createState() => _TranslationSheetState();
}

class _TranslationSheetState extends State<_TranslationSheet> {
  String _target = 'en';
  bool _busy = false;
  String? _result;
  String? _error;

  Future<void> _translate() async {
    if (!await TranslationConsent.hasConsented()) {
      if (!mounted) return;
      final agreed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('On-device translation'),
          content: const Text(
            'Translation runs entirely on your phone. The first time you '
            'translate into a language, a small model (~30 MB) downloads. '
            'Your messages never leave the device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (agreed != true) return;
      await TranslationConsent.record();
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final result = await TranslationTools.translate(
        widget.text,
        target: _target,
      );
      if (mounted) setState(() => _result = result);
    } on TranslationUnavailable catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Translation failed. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.translate_rounded, color: p.secondary),
              const SizedBox(width: 8),
              Text(
                'Translate',
                style: TextStyle(
                  color: p.foreground,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: p.raised,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(widget.text, style: TextStyle(color: p.muted)),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('Into', style: TextStyle(color: p.foreground)),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButton<String>(
                  key: const ValueKey('translation-target'),
                  value: _target,
                  isExpanded: true,
                  dropdownColor: p.surface,
                  style: TextStyle(color: p.foreground),
                  items: [
                    for (final (code, name) in translationLanguages)
                      DropdownMenuItem(value: code, child: Text(name)),
                  ],
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _target = value ?? 'en'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          AccentButton(
            key: const ValueKey('translation-run'),
            palette: p,
            label: _busy ? 'Translating…' : 'Translate',
            icon: Icons.translate_rounded,
            onPressed: _busy ? null : _translate,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: p.accent)),
          ],
          if (_result != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: p.stroke),
              ),
              child: SelectableText(
                _result!,
                style: TextStyle(color: p.foreground, fontSize: 15),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
