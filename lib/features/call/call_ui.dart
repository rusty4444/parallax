// Room-level call UI: header button, ongoing-call banner and timeline items
// (Element X: RoomCallState header action, ActiveCallTimelineItemView,
// TimelineItemCallNotifyView, TimelineItemLegacyCallInviteView).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import 'call_features.dart';
import 'call_memberships.dart';
import 'call_screen.dart';
import 'widget_capabilities.dart';

/// Rebuilds when the room's MatrixRTC membership changes or a membership
/// expires.
class RoomCallBuilder extends StatefulWidget {
  const RoomCallBuilder({
    super.key,
    required this.features,
    required this.roomId,
    required this.builder,
  });

  final CallFeatures features;
  final String roomId;
  final Widget Function(BuildContext context, RoomCallSummary call) builder;

  @override
  State<RoomCallBuilder> createState() => _RoomCallBuilderState();
}

class _RoomCallBuilderState extends State<RoomCallBuilder> {
  StreamSubscription<String>? _subscription;
  Timer? _expiry;
  late RoomCallSummary _call;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(RoomCallBuilder old) {
    super.didUpdateWidget(old);
    if (!identical(old.features, widget.features) ||
        old.roomId != widget.roomId) {
      _detach();
      _attach();
    }
  }

  void _attach() {
    _call = _read();
    _subscription = widget.features.callChanges
        .where((room) => room == widget.roomId)
        .listen((_) => _refresh());
    _schedule();
  }

  void _detach() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    _expiry?.cancel();
  }

  RoomCallSummary _read() {
    try {
      return widget.features.roomCall(widget.roomId);
    } catch (_) {
      return RoomCallSummary.none;
    }
  }

  void _refresh() {
    if (!mounted) return;
    setState(() => _call = _read());
    _schedule();
  }

  void _schedule() {
    _expiry?.cancel();
    final next = _call.nextExpiry;
    if (next == null) return;
    var delay = next.difference(DateTime.now()) + const Duration(seconds: 1);
    if (delay < const Duration(seconds: 1)) delay = const Duration(seconds: 1);
    if (delay > const Duration(hours: 1)) delay = const Duration(hours: 1);
    _expiry = Timer(delay, _refresh);
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _call);
}

/// Video-call action in the room header (Element X: start or join).
class CallHeaderButton extends StatelessWidget {
  const CallHeaderButton({
    super.key,
    required this.features,
    required this.backend,
    required this.roomId,
    required this.palette,
  });

  final CallFeatures features;
  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) => RoomCallBuilder(
    features: features,
    roomId: roomId,
    builder: (context, call) {
      final allowed = features.canJoinCall(roomId);
      return IconButton(
        tooltip: !allowed
            ? 'You can’t start a call in this room'
            : call.active
            ? 'Join call'
            : 'Start a call',
        icon: Icon(
          call.active ? Icons.videocam_rounded : Icons.videocam_outlined,
          color: call.active ? palette.accent : palette.secondary,
        ),
        onPressed: allowed
            ? () => openCallScreen(
                context,
                backend: backend,
                roomId: roomId,
                palette: palette,
              )
            : null,
      );
    },
  );
}

String participantCountLabel(int count) =>
    count == 1 ? '1 person in the call' : '$count people in the call';

/// "Call in progress" strip under the room header.
class OngoingCallBanner extends StatelessWidget {
  const OngoingCallBanner({
    super.key,
    required this.features,
    required this.backend,
    required this.roomId,
    required this.palette,
    this.direct = false,
  });

  final CallFeatures features;
  final ChatBackend backend;
  final String roomId;
  final AppPalette palette;
  final bool direct;

  @override
  Widget build(BuildContext context) => RoomCallBuilder(
    features: features,
    roomId: roomId,
    builder: (context, call) {
      if (!call.active) return const SizedBox.shrink();
      final p = palette;
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          decoration: BoxDecoration(
            color: p.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: p.accent.withValues(alpha: 0.55)),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  gradient: accentGradient(p),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  call.audioOnly ? Icons.call_rounded : Icons.videocam_rounded,
                  color: p.accentOn,
                  size: 21,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      direct ? 'Call in progress' : 'Group call in progress',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: p.foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      call.includesMe
                          ? 'You’re in this call on another device'
                          : participantCountLabel(call.participants.length),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: features.canJoinCall(roomId)
                    ? () => openCallScreen(
                        context,
                        backend: backend,
                        roomId: roomId,
                        palette: p,
                      )
                    : null,
                style: FilledButton.styleFrom(
                  backgroundColor: p.accent,
                  foregroundColor: p.accentOn,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text('Join'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Timeline body for call entries.
class CallTimelineBody extends StatefulWidget {
  const CallTimelineBody({
    super.key,
    required this.eventType,
    required this.content,
    required this.time,
    required this.mine,
    required this.palette,
    required this.textColor,
    required this.backend,
    required this.roomId,
    this.features,
  });

  final String eventType;
  final Map<String, Object?> content;
  final DateTime time;
  final bool mine;
  final AppPalette palette;
  final Color textColor;
  final ChatBackend backend;
  final String roomId;
  final CallFeatures? features;

  @override
  State<CallTimelineBody> createState() => _CallTimelineBodyState();
}

class _CallTimelineBodyState extends State<CallTimelineBody> {
  Timer? _ringEnd;

  bool get _legacy => widget.eventType == 'm.call.invite';
  bool get _audio => widget.content['m.call.intent'] == 'audio';

  DateTime? get _ringExpiry {
    if (!rtcNotificationTypes.contains(widget.eventType) ||
        widget.content['notification_type'] != 'ring') {
      return null;
    }
    return rtcNotificationExpiry(widget.content, originServerTs: widget.time);
  }

  @override
  void initState() {
    super.initState();
    _scheduleRingEnd();
  }

  @override
  void didUpdateWidget(CallTimelineBody old) {
    super.didUpdateWidget(old);
    _scheduleRingEnd();
  }

  void _scheduleRingEnd() {
    _ringEnd?.cancel();
    final expiry = _ringExpiry;
    if (expiry == null) return;
    final left = expiry.difference(DateTime.now());
    if (left.isNegative) return;
    _ringEnd = Timer(left + const Duration(milliseconds: 200), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ringEnd?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final color = widget.textColor;
    if (_legacy) {
      return _row(
        icon: Icons.phone_disabled_rounded,
        title: 'Unsupported call',
        subtitle:
            'Ask if the caller can use Element Call, for example in the '
            'Element X app.',
        color: color,
      );
    }
    final expiry = _ringExpiry;
    final ringing = expiry != null && DateTime.now().isBefore(expiry);
    final title = ringing
        ? (widget.mine ? 'Calling…' : 'Ringing…')
        : 'Call started';
    final subtitle = _audio ? 'Voice call' : 'Video call';
    final features = widget.features;
    final row = _row(
      icon: _audio ? Icons.call_rounded : Icons.videocam_rounded,
      title: title,
      subtitle: subtitle,
      color: color,
    );
    if (features == null) return row;
    return RoomCallBuilder(
      features: features,
      roomId: widget.roomId,
      builder: (context, call) {
        if (!call.active || call.includesMe) return row;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row,
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: features.canJoinCall(widget.roomId)
                  ? () => openCallScreen(
                      context,
                      backend: widget.backend,
                      roomId: widget.roomId,
                      palette: p,
                    )
                  : null,
              icon: const Icon(Icons.call_made_rounded, size: 18),
              label: Text(
                'Join · ${participantCountLabel(call.participants.length)}',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: color,
                side: BorderSide(color: color.withValues(alpha: 0.6)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _row({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
  }) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 1),
        child: Icon(icon, size: 20, color: color.withValues(alpha: 0.9)),
      ),
      const SizedBox(width: 10),
      Flexible(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(
                color: color.withValues(alpha: 0.78),
                fontSize: 12.5,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
