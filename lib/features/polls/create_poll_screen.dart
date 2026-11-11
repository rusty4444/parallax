import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_theme.dart';
import '../../widgets.dart';
import 'poll_features.dart';
import 'poll_model.dart';

/// Element X "Create Poll" / "Edit poll": question, 2–20 options, votes
/// allowed per person and "Hide votes" (undisclosed results).
class CreatePollScreen extends StatefulWidget {
  const CreatePollScreen({
    super.key,
    required this.palette,
    required this.roomId,
    required this.features,
    this.editing,
  });

  final AppPalette palette;
  final String roomId;
  final PollFeatures features;

  /// The poll being edited (its event ID and current content), if editing.
  final ({String pollId, PollStart poll})? editing;

  @override
  State<CreatePollScreen> createState() => _CreatePollScreenState();
}

class _CreatePollScreenState extends State<CreatePollScreen> {
  late final PollDraft _initial;
  late PollDraft _draft;
  late final TextEditingController _question;
  final _answers = <TextEditingController>[];
  final _answerKeys = <UniqueKey>[];
  bool _saving = false;
  String? _error;

  bool get _editing => widget.editing != null;
  bool get _dirty => _draft != _initial;

  @override
  void initState() {
    super.initState();
    final editing = widget.editing;
    _initial = editing == null
        ? const PollDraft()
        : PollDraft.fromPoll(editing.poll);
    _draft = _initial;
    _question = TextEditingController(text: _draft.question);
    for (final answer in _draft.answers) {
      _answers.add(TextEditingController(text: answer));
      _answerKeys.add(UniqueKey());
    }
  }

  @override
  void dispose() {
    _question.dispose();
    for (final controller in _answers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _addAnswer() {
    if (!_draft.canAddAnswer || _saving) return;
    setState(() {
      _draft = _draft.withNewAnswer();
      _answers.add(TextEditingController());
      _answerKeys.add(UniqueKey());
    });
  }

  void _removeAnswer(int index) {
    if (!_draft.canDeleteAnswer || _saving) return;
    setState(() {
      _draft = _draft.withAnswerRemoved(index);
      _answers.removeAt(index).dispose();
      _answerKeys.removeAt(index);
    });
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty || _saving) return !_saving;
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_editing ? 'Edit poll' : 'Create Poll'),
        content: const Text(
          'Your changes have not been saved. '
          'Are you sure you want to go back?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return discard == true;
  }

  Future<void> _save() async {
    if (!_draft.isValid || _saving) return;
    final editing = widget.editing;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final poll = _draft.toPoll(previous: editing?.poll);
      if (editing == null) {
        await widget.features.createPoll(widget.roomId, poll);
      } else {
        await widget.features.editPoll(widget.roomId, editing.pollId, poll);
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = editing == null
            ? 'Couldn’t create this poll. Check your connection and try again.'
            : 'Couldn’t save this poll. Check your connection and try again.';
      });
    }
  }

  Future<void> _delete() async {
    final editing = widget.editing;
    if (editing == null || _saving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Poll'),
        content: const Text('Are you sure you want to delete this poll?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.features.deletePoll(widget.roomId, editing.pollId);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Couldn’t delete this poll. Try again.';
      });
    }
  }

  InputDecoration _field(String label, {String? hint, Widget? suffix}) {
    final p = widget.palette;
    return InputDecoration(
      labelText: label,
      hintText: hint,
      suffixIcon: suffix,
      filled: true,
      fillColor: p.surface,
      counterText: '',
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: p.stroke),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: p.stroke),
      ),
    );
  }

  Widget _card(List<Widget> children) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: widget.palette.surface.withValues(alpha: 0.86),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: widget.palette.stroke),
    ),
    child: Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final draft = _draft;
    return PopScope(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmDiscard() && mounted) navigator.pop();
      },
      child: Scaffold(
        body: GlowBackdrop(
          palette: p,
          child: SafeArea(
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    Expanded(
                      child: Text(
                        _editing ? 'Edit poll' : 'Create Poll',
                        style: TextStyle(
                          color: p.foreground,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (_editing)
                      IconButton(
                        tooltip: 'Delete Poll',
                        onPressed: _saving ? null : _delete,
                        icon: const Icon(Icons.delete_outline_rounded),
                      ),
                  ],
                ),
                if (_saving) const LinearProgressIndicator(),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    children: [
                      _card([
                        Eyebrow('Question or topic', palette: p),
                        const SizedBox(height: 10),
                        TextField(
                          key: const ValueKey('poll-question'),
                          controller: _question,
                          enabled: !_saving,
                          maxLength: pollMaxQuestionLength,
                          maxLengthEnforcement: MaxLengthEnforcement.enforced,
                          minLines: 1,
                          maxLines: 4,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: _field(
                            'Question',
                            hint: 'What is the poll about?',
                          ),
                          onChanged: (text) => setState(
                            () => _draft = _draft.copyWith(question: text),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 14),
                      _card([
                        Eyebrow('Options', palette: p),
                        const SizedBox(height: 10),
                        for (var i = 0; i < _answers.length; i++)
                          Padding(
                            key: _answerKeys[i],
                            padding: const EdgeInsets.only(bottom: 10),
                            child: TextField(
                              key: ValueKey('poll-answer-$i'),
                              controller: _answers[i],
                              enabled: !_saving,
                              maxLength: pollMaxAnswerLength,
                              maxLengthEnforcement:
                                  MaxLengthEnforcement.enforced,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: _field(
                                'Option ${i + 1}',
                                suffix: draft.canDeleteAnswer
                                    ? IconButton(
                                        tooltip: 'Delete option ${i + 1}',
                                        onPressed: _saving
                                            ? null
                                            : () => _removeAnswer(i),
                                        icon: const Icon(
                                          Icons.remove_circle_outline_rounded,
                                        ),
                                      )
                                    : null,
                              ),
                              onChanged: (text) => setState(
                                () =>
                                    _draft = _draft.withAnswerChanged(i, text),
                              ),
                            ),
                          ),
                        if (draft.canAddAnswer)
                          TextButton.icon(
                            onPressed: _saving ? null : _addAnswer,
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Add option'),
                          ),
                      ]),
                      const SizedBox(height: 14),
                      _card([
                        Eyebrow('Settings', palette: p),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Votes allowed per person',
                                style: TextStyle(color: p.foreground),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Decrease votes allowed per person',
                              onPressed: _saving || draft.maxSelections <= 1
                                  ? null
                                  : () => setState(
                                      () => _draft = _draft.copyWith(
                                        maxSelections: draft.maxSelections - 1,
                                      ),
                                    ),
                              icon: const Icon(Icons.remove_rounded),
                            ),
                            Text(
                              '${draft.maxSelections}',
                              style: TextStyle(
                                color: p.foreground,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Increase votes allowed per person',
                              onPressed:
                                  _saving ||
                                      draft.maxSelections >=
                                          draft.answers.length
                                  ? null
                                  : () => setState(
                                      () => _draft = _draft.copyWith(
                                        maxSelections: draft.maxSelections + 1,
                                      ),
                                    ),
                              icon: const Icon(Icons.add_rounded),
                            ),
                          ],
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Hide votes'),
                          subtitle: const Text(
                            'Show results only after poll ends',
                          ),
                          value: !draft.disclosed,
                          onChanged: _saving
                              ? null
                              : (hide) => setState(
                                  () => _draft = _draft.copyWith(
                                    disclosed: !hide,
                                  ),
                                ),
                        ),
                      ]),
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Text(_error!, style: TextStyle(color: p.foreground)),
                      ],
                      const SizedBox(height: 18),
                      AccentButton(
                        palette: p,
                        label: _editing ? 'Done' : 'Create',
                        icon: _editing
                            ? Icons.check_rounded
                            : Icons.poll_outlined,
                        onPressed: draft.isValid && !_saving ? _save : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens "Create Poll" for [roomId]; returns whether a poll was sent.
Future<bool> openCreatePoll(
  BuildContext context, {
  required AppPalette palette,
  required String roomId,
  required PollFeatures features,
}) async {
  final sent = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => CreatePollScreen(
        palette: palette,
        roomId: roomId,
        features: features,
      ),
    ),
  );
  return sent ?? false;
}

/// Opens "Edit poll" for [pollId] with its current (edited) content.
Future<bool> openEditPoll(
  BuildContext context, {
  required AppPalette palette,
  required String roomId,
  required String pollId,
  required PollStart poll,
  required PollFeatures features,
}) async {
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => CreatePollScreen(
        palette: palette,
        roomId: roomId,
        features: features,
        editing: (pollId: pollId, poll: poll),
      ),
    ),
  );
  return saved ?? false;
}
