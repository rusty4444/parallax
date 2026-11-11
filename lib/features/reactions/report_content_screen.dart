import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../widgets.dart';
import 'message_action_features.dart';

const maxReportReasonLength = 1000;

/// What happened after a report was sent.
enum ReportOutcome { reported, reportedAndBlocked, reportedBlockFailed }

/// Element X ReportMessage: reason, optional "Block user", send.
class ReportContentScreen extends StatefulWidget {
  const ReportContentScreen({
    super.key,
    required this.backend,
    required this.features,
    required this.roomId,
    required this.entry,
    required this.palette,
  });

  final ChatBackend backend;
  final MessageActionFeatures features;
  final String roomId;
  final ChatEntry entry;
  final AppPalette palette;

  @override
  State<ReportContentScreen> createState() => _ReportContentScreenState();
}

class _ReportContentScreenState extends State<ReportContentScreen> {
  late final BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  final _reason = TextEditingController();
  bool _block = false;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reason.addListener(_onReasonChanged);
  }

  @override
  void dispose() {
    _reason
      ..removeListener(_onReasonChanged)
      ..dispose();
    _owner.release();
    super.dispose();
  }

  void _onReasonChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _send() async {
    final reason = _reason.text.trim();
    if (reason.isEmpty || _sending || !_owner.isCurrent) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.features.reportContent(
        widget.roomId,
        widget.entry.id,
        reason: reason,
      );
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        setState(() {
          _sending = false;
          _error = 'Couldn’t send this report. Try again.';
        });
      }
      return;
    }
    var outcome = ReportOutcome.reported;
    if (_block) {
      try {
        await widget.features.ignoreUser(widget.entry.sender);
        outcome = ReportOutcome.reportedAndBlocked;
      } catch (_) {
        outcome = ReportOutcome.reportedBlockFailed;
      }
    }
    if (!mounted || !_owner.isCurrent) return;
    Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final canSend = _reason.text.trim().isNotEmpty && !_sending;
    return Scaffold(
      body: GlowBackdrop(
        palette: p,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 20, 6),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Back',
                      onPressed: _sending ? null : () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Report content',
                        style: TextStyle(
                          color: p.foreground,
                          fontWeight: FontWeight.w700,
                          fontSize: 23,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
                  children: [
                    Eyebrow(
                      'Message from ${widget.entry.senderLabel}',
                      palette: p,
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: p.surface,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: p.stroke),
                      ),
                      child: Text(
                        widget.entry.body,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.muted),
                      ),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      key: const ValueKey('report-reason'),
                      controller: _reason,
                      enabled: !_sending,
                      minLines: 3,
                      maxLines: 6,
                      maxLength: maxReportReasonLength,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        hintText: 'Reason for reporting this content',
                        helperMaxLines: 3,
                        helperText:
                            'This message will be reported to your account '
                            'provider. They will not be able to read any '
                            'encrypted messages.',
                      ),
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile(
                      key: const ValueKey('report-block-user'),
                      contentPadding: EdgeInsets.zero,
                      value: _block,
                      activeThumbColor: p.accentOn,
                      activeTrackColor: p.accent,
                      inactiveThumbColor: p.muted,
                      inactiveTrackColor: p.raised,
                      onChanged: _sending
                          ? null
                          : (value) => setState(() => _block = value),
                      title: Text(
                        'Block user',
                        style: TextStyle(color: p.foreground),
                      ),
                      subtitle: Text(
                        'Hide this person’s future messages from you. '
                        'Messages already on this device may stay visible '
                        'until the room reloads.',
                        style: TextStyle(color: p.muted, fontSize: 13),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    ],
                    const SizedBox(height: 24),
                    AccentButton(
                      palette: p,
                      label: _sending ? 'Sending…' : 'Send report',
                      icon: Icons.flag_outlined,
                      onPressed: canSend ? _send : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
