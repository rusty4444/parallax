import 'dart:async';

import 'package:flutter/material.dart';

import 'chat_backend.dart';
import 'messaging_features.dart';
import 'room_join.dart';
import 'send_cancellation.dart';

Future<String?> showRoomJoin(
  BuildContext context,
  ChatBackend backend,
  String roomId, {
  List<String> via = const [],
}) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _RoomJoinDialog(backend: backend, roomId: roomId, via: via),
);

class _RoomJoinDialog extends StatefulWidget {
  const _RoomJoinDialog({
    required this.backend,
    required this.roomId,
    this.via = const [],
  });
  final ChatBackend backend;
  final String roomId;
  final List<String> via;
  @override
  State<_RoomJoinDialog> createState() => _RoomJoinDialogState();
}

class _RoomJoinDialogState extends State<_RoomJoinDialog> {
  SendCancellation? _wait;
  Timer? _deadline;
  late final String? _user = widget.backend.userId;
  late final String? _account = _accountKey;
  bool _busy = true;
  bool _expired = false;
  String? get _accountKey => switch (widget.backend) {
    final MessagingFeatures features => features.accountKey,
    _ => null,
  };
  bool get _current =>
      !_expired && _user == widget.backend.userId && _account == _accountKey;

  @override
  void initState() {
    super.initState();
    // Capture ownership before an account change, not lazily on first response.
    _user;
    _account;
    widget.backend.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _current) _start();
    });
  }

  void _changed() {
    if (!_current && !_expired) {
      _stop();
      setState(() {
        _expired = true;
        _busy = false;
      });
    }
  }

  void _stop() {
    _deadline?.cancel();
    _wait?.cancel();
    _wait = null;
  }

  Future<void> _start() async {
    if (!_current) return;
    _stop();
    final wait = _wait = SendCancellation();
    setState(() => _busy = true);
    _deadline = Timer(const Duration(seconds: 30), () {
      if (!mounted || !identical(_wait, wait)) return;
      _stop();
      setState(() => _busy = false);
    });
    try {
      final backend = widget.backend;
      final id = backend is RecoverableRoomJoining
          ? await (backend as RecoverableRoomJoining).waitForRoomJoin(
              widget.roomId,
              wait,
              via: widget.via,
            )
          : await backend.joinPublicRoom(widget.roomId);
      if (mounted && _current && identical(_wait, wait)) {
        Navigator.pop(context, id);
      }
    } catch (_) {
      if (mounted && _current && identical(_wait, wait)) {
        _stop();
        setState(() => _busy = false);
      }
    } finally {
      if (identical(_wait, wait)) _stop();
    }
  }

  @override
  void dispose() {
    _stop();
    widget.backend.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      _expired
          ? 'Account changed'
          : _busy
          ? 'Joining room…'
          : 'Join not confirmed',
    ),
    content: Text(
      _expired
          ? 'Close this window and reopen the room for your current account.'
          : _busy
          ? 'Waiting up to 30 seconds for delivery and room sync. You can stop waiting.'
          : 'The request may already have reached your server. Check again to recover the existing join. A server rejection may require an invitation.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(_busy ? 'Stop waiting' : 'Close'),
      ),
      if (!_busy && !_expired)
        TextButton(onPressed: _start, child: const Text('Check again')),
    ],
  );
}
