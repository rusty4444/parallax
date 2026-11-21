import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'user_status.dart';

/// Set or clear your status / note.
class UserStatusScreen extends StatefulWidget {
  const UserStatusScreen({
    super.key,
    required this.controller,
    required this.palette,
  });

  final UserStatusController controller;
  final AppPalette palette;

  @override
  State<UserStatusScreen> createState() => _UserStatusScreenState();
}

class _UserStatusScreenState extends State<UserStatusScreen> {
  late final TextEditingController _text;
  late String _emoji;
  Duration? _expiry;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final current = widget.controller.status;
    _text = TextEditingController(text: current.text);
    _emoji = current.emoji;
    final expiresAt = current.expiresAt;
    if (expiresAt != null) {
      final remaining = expiresAt.difference(DateTime.now());
      _expiry = remaining.isNegative ? null : remaining;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.controller.setStatus(_text.text, _emoji, _expiry);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _clear() async {
    setState(() => _saving = true);
    await widget.controller.clear();
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return Scaffold(
      backgroundColor: p.background,
      appBar: AppBar(
        title: const Text('Your status'),
        backgroundColor: p.background,
        actions: [
          TextButton(
            key: const ValueKey('status-clear'),
            onPressed: _saving ? null : _clear,
            child: const Text('Clear'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            key: const ValueKey('status-text'),
            controller: _text,
            maxLength: 100,
            enabled: !_saving,
            decoration: const InputDecoration(
              labelText: 'Status',
              hintText: 'What’s happening?',
            ),
          ),
          const SizedBox(height: 8),
          Text('Emoji', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final emoji in statusEmojis)
                ChoiceChip(
                  key: ValueKey('status-emoji-$emoji'),
                  label: Text(emoji, style: const TextStyle(fontSize: 18)),
                  selected: _emoji == emoji,
                  onSelected: _saving
                      ? null
                      : (selected) =>
                            setState(() => _emoji = selected ? emoji : ''),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text('Clear after', style: Theme.of(context).textTheme.titleSmall),
          RadioGroup<Duration?>(
            groupValue: _expiry,
            onChanged: (value) => setState(() => _expiry = value),
            child: Column(
              children: [
                for (final (label, value) in statusExpiries)
                  RadioListTile<Duration?>(
                    key: ValueKey(
                      'status-expiry-${label.replaceAll(' ', '-')}',
                    ),
                    value: value,
                    title: Text(label, style: TextStyle(color: p.foreground)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AccentButton(
            key: const ValueKey('status-save'),
            palette: p,
            label: _saving ? 'Saving…' : 'Save status',
            icon: Icons.check_rounded,
            onPressed: _saving ? null : _save,
          ),
        ],
      ),
    );
  }
}
