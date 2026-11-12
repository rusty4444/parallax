import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../widgets.dart';
import 'schedule_presets.dart';
import 'scheduled_features.dart';
import 'send_later_sheet.dart';

String scheduledCountLabel(int count) =>
    count == 1 ? '1 scheduled message' : '$count scheduled messages';

/// Room banner: "1 scheduled message", opening the list.
class ScheduledMessagesBanner extends StatefulWidget {
  const ScheduledMessagesBanner({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
    this.encrypted = false,
    this.clock = DateTime.now,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;
  final bool encrypted;
  final DateTime Function() clock;

  @override
  State<ScheduledMessagesBanner> createState() =>
      _ScheduledMessagesBannerState();
}

class _ScheduledMessagesBannerState extends State<ScheduledMessagesBanner> {
  ScheduledFeatures? _features;
  Timer? _due;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(ScheduledMessagesBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backend, widget.backend) ||
        oldWidget.roomId != widget.roomId) {
      _features?.scheduledUpdates.removeListener(_changed);
      _bind();
    }
  }

  void _bind() {
    final features = _features = scheduledFeaturesOf(widget.backend);
    features?.scheduledUpdates.addListener(_changed);
    features?.ensureScheduledLoaded();
    _armDue();
  }

  @override
  void dispose() {
    _due?.cancel();
    _features?.scheduledUpdates.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    _armDue();
    setState(() {});
  }

  /// Refreshes shortly after the next message is due, so a sent message
  /// leaves the banner without waiting for another trigger.
  void _armDue() {
    _due?.cancel();
    _due = null;
    final items = _features?.scheduledIn(widget.roomId) ?? const [];
    if (items.isEmpty) return;
    var wait =
        items.first.sendAt.difference(widget.clock()) +
        const Duration(seconds: 5);
    if (wait.isNegative) wait = const Duration(seconds: 5);
    if (wait > const Duration(hours: 1)) wait = const Duration(hours: 1);
    _due = Timer(wait, () {
      if (mounted) unawaited(_features?.refreshScheduled());
    });
  }

  @override
  Widget build(BuildContext context) {
    final features = _features;
    if (features == null) return const SizedBox.shrink();
    final items = features.scheduledIn(widget.roomId);
    if (items.isEmpty) return const SizedBox.shrink();
    final p = widget.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Material(
        color: p.raised.withValues(alpha: 0.94),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: p.accent.withValues(alpha: 0.45)),
        ),
        child: InkWell(
          key: const ValueKey('scheduled.banner'),
          onTap: () => showScheduledMessagesSheet(
            context,
            features: features,
            palette: p,
            roomId: widget.roomId,
            encrypted: widget.encrypted,
            clock: widget.clock,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
            child: Row(
              children: [
                Icon(Icons.schedule_send_outlined, color: p.secondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        scheduledCountLabel(items.length),
                        style: TextStyle(
                          color: p.foreground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        'Next: ${describeSendTime(items.first.sendAt, now: widget.clock())}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: p.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> showScheduledMessagesSheet(
  BuildContext context, {
  required ScheduledFeatures features,
  required AppPalette palette,
  required String roomId,
  bool encrypted = false,
  DateTime Function() clock = DateTime.now,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  backgroundColor: palette.surface,
  builder: (_) => ScheduledMessagesSheet(
    features: features,
    palette: palette,
    roomId: roomId,
    encrypted: encrypted,
    clock: clock,
  ),
);

/// The room's scheduled messages: Send now, Reschedule, Cancel.
class ScheduledMessagesSheet extends StatefulWidget {
  const ScheduledMessagesSheet({
    super.key,
    required this.features,
    required this.palette,
    required this.roomId,
    this.encrypted = false,
    this.clock = DateTime.now,
  });
  final ScheduledFeatures features;
  final AppPalette palette;
  final String roomId;
  final bool encrypted;
  final DateTime Function() clock;

  @override
  State<ScheduledMessagesSheet> createState() => _ScheduledMessagesSheetState();
}

class _ScheduledMessagesSheetState extends State<ScheduledMessagesSheet> {
  final _busy = <String>{};
  String? _status;

  @override
  void initState() {
    super.initState();
    widget.features.scheduledUpdates.addListener(_changed);
    unawaited(widget.features.refreshScheduled());
  }

  @override
  void dispose() {
    widget.features.scheduledUpdates.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _run(
    ScheduledMessage message,
    Future<String?> Function() action,
  ) async {
    if (!_busy.add(message.delayId)) return;
    setState(() => _status = null);
    try {
      final done = await action();
      if (mounted && done != null) setState(() => _status = done);
    } catch (error) {
      if (mounted) setState(() => _status = scheduledErrorMessage(error));
      unawaited(widget.features.refreshScheduled());
    } finally {
      if (mounted) setState(() => _busy.remove(message.delayId));
    }
  }

  Future<void> _sendNow(ScheduledMessage message) => _run(message, () async {
    await widget.features.sendScheduledNow(message);
    return 'Message sent.';
  });

  Future<void> _cancel(ScheduledMessage message) => _run(message, () async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Cancel this scheduled message?'),
        content: const Text('It won’t be sent.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Cancel message'),
          ),
        ],
      ),
    );
    if (confirmed != true) return null;
    await widget.features.cancelScheduled(message);
    return 'Scheduled message cancelled.';
  });

  Future<void> _reschedule(ScheduledMessage message) => _run(message, () async {
    final capability = await widget.features.delayedEventsCapability();
    if (!mounted) return null;
    final when = await showSendLaterPicker(
      context,
      palette: widget.palette,
      title: 'Reschedule',
      preview: message.preview ?? 'Scheduled message',
      encrypted: message.encrypted,
      maxDelay: capability.maxDelay,
      clock: widget.clock,
    );
    if (when == null) return null;
    final copy = await widget.features.rescheduleScheduled(message, when);
    return 'Rescheduled for '
        '${describeSendTime(copy.sendAt, now: widget.clock())}.';
  });

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final features = widget.features;
    final items = features.scheduledIn(widget.roomId);
    final state = features.scheduledState;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
          children: [
            Eyebrow('Scheduled messages', palette: p),
            const SizedBox(height: 8),
            if (_status != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _status!,
                  key: const ValueKey('scheduled.status'),
                  style: TextStyle(color: p.secondary),
                ),
              ),
            if (state == ScheduledLoadState.failed)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Couldn’t refresh from your homeserver. '
                      'Showing what’s saved on this device.',
                      style: TextStyle(color: p.muted, fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        unawaited(widget.features.refreshScheduled()),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: state == ScheduledLoadState.loading
                      ? CircularProgressIndicator(color: p.accent)
                      : Text(
                          'No scheduled messages in this room.',
                          style: TextStyle(color: p.muted),
                        ),
                ),
              ),
            for (final item in items) _tile(item, p),
            if (items.any((item) => item.encrypted))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Encrypted messages were encrypted when you scheduled them. '
                  'People who joined after that won’t be able to read them.',
                  style: TextStyle(color: p.muted, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _tile(ScheduledMessage item, AppPalette p) {
    final busy = _busy.contains(item.delayId);
    return Container(
      key: ValueKey('scheduled.item.${item.delayId}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 4),
      decoration: BoxDecoration(
        color: p.raised,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.schedule_rounded, size: 16, color: p.secondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  describeSendTime(item.sendAt, now: widget.clock()),
                  style: TextStyle(
                    color: p.foreground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (item.encrypted)
                Icon(Icons.lock_outline, size: 14, color: p.muted),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            item.preview ?? 'Message preview isn’t available on this device.',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: p.foreground),
          ),
          if (!item.confirmed)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Not confirmed with your homeserver yet.',
                style: TextStyle(color: p.muted, fontSize: 12),
              ),
            ),
          Wrap(
            alignment: WrapAlignment.end,
            children: [
              TextButton(
                onPressed: busy ? null : () => _sendNow(item),
                child: const Text('Send now'),
              ),
              if (item.canReschedule)
                TextButton(
                  onPressed: busy ? null : () => _reschedule(item),
                  child: const Text('Reschedule'),
                ),
              TextButton(
                onPressed: busy ? null : () => _cancel(item),
                style: TextButton.styleFrom(foregroundColor: p.accent),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
