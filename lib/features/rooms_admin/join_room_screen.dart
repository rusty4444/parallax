import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../room_join_dialog.dart';
import 'admin_ui.dart';
import 'rooms_admin_features.dart';
import 'rooms_admin_models.dart';

/// Element X "Join room by address": resolve `#alias:server` (or a matrix.to
/// link), preview the room where the server allows it, then join, accept an
/// invitation or ask to join. Pops the joined room ID.
class JoinRoomScreen extends StatefulWidget {
  const JoinRoomScreen({
    super.key,
    required this.backend,
    required this.palette,
    this.initialAddress,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String? initialAddress;

  @override
  State<JoinRoomScreen> createState() => _JoinRoomScreenState();
}

enum _Lookup { idle, invalid, resolving, found, notFound }

class _JoinRoomScreenState extends State<JoinRoomScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  late final _address = TextEditingController(text: widget.initialAddress);
  final _message = TextEditingController();
  Timer? _debounce;
  int _generation = 0;
  _Lookup _lookup = _Lookup.idle;
  RoomPreview? _preview;
  bool _busy = false;
  bool _knockSent = false;

  RoomsAdminFeatures? get _admin => roomsAdminFeaturesOf(widget.backend);
  bool get _current => mounted && _owner.isCurrent;

  @override
  void initState() {
    super.initState();
    _message.addListener(() => setState(() {}));
    if (widget.initialAddress?.trim().isNotEmpty == true) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _queue(_address.text, immediate: true),
      );
    }
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _owner.release();
    _address.dispose();
    _message.dispose();
    super.dispose();
  }

  void _queue(String text, {bool immediate = false}) {
    _debounce?.cancel();
    final generation = ++_generation;
    final value = text.trim();
    final address = parseRoomAddress(value);
    setState(() {
      _preview = null;
      _knockSent = false;
      _lookup = value.isEmpty
          ? _Lookup.idle
          : address == null
          ? _Lookup.invalid
          : _Lookup.resolving;
    });
    if (address == null) return;
    Future<void> run() async {
      final admin = _admin;
      if (admin == null || !_current || generation != _generation) return;
      try {
        final preview = await admin.previewRoom(address);
        if (!mounted || !_owner.isCurrent || generation != _generation) return;
        setState(() {
          _preview = preview;
          _lookup = _Lookup.found;
          _knockSent = preview.knocked;
        });
      } catch (_) {
        if (mounted && _owner.isCurrent && generation == _generation) {
          setState(() => _lookup = _Lookup.notFound);
        }
      }
    }

    if (immediate) {
      unawaited(run());
    } else {
      _debounce = Timer(const Duration(milliseconds: 500), () => run());
    }
  }

  Future<void> _join(RoomPreview preview) async {
    if (_busy) return;
    if (preview.joined) {
      Navigator.pop(context, preview.roomId);
      return;
    }
    setState(() => _busy = true);
    try {
      if (preview.invited) {
        await widget.backend.acceptInvite(preview.roomId);
        if (mounted && _owner.isCurrent) Navigator.pop(context, preview.roomId);
        return;
      }
      final id = await showRoomJoin(
        context,
        widget.backend,
        preview.roomId,
        via: preview.via,
      );
      if (mounted && _owner.isCurrent && id != null) Navigator.pop(context, id);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showAdminMessage(
          context,
          'Joining failed. You either need to be invited to join or there '
          'might be restrictions to access.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _knock(RoomPreview preview) async {
    final admin = _admin;
    if (admin == null || _busy) return;
    setState(() => _busy = true);
    try {
      await admin.knockRoom(
        preview.roomId,
        via: preview.via,
        reason: _message.text,
      );
      if (mounted && _owner.isCurrent) setState(() => _knockSent = true);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showAdminMessage(context, 'Couldn’t send your request. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelKnock(RoomPreview preview) async {
    final admin = _admin;
    if (admin == null || _busy) return;
    final confirmed = await confirmAction(
      context,
      title: 'Cancel request to join',
      message:
          'Are you sure that you want to cancel your request to join this '
          'room?',
      confirm: 'Yes, cancel',
      cancel: 'No',
    );
    if (!confirmed || !mounted || !_owner.isCurrent) return;
    setState(() => _busy = true);
    try {
      await admin.cancelKnock(preview.roomId);
      if (mounted && _owner.isCurrent) setState(() => _knockSent = false);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        showAdminMessage(context, 'Couldn’t cancel the request.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final preview = _preview;
    final status = switch (_lookup) {
      _Lookup.idle => 'e.g. #room-name:matrix.org',
      _Lookup.invalid => 'Not a valid address',
      _Lookup.resolving => 'Looking up the room…',
      _Lookup.found => 'Matching room found',
      _Lookup.notFound => 'Room not found',
    };
    return AdminPage(
      palette: p,
      title: 'Join room by address',
      busy: _busy || _lookup == _Lookup.resolving,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 28),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _address,
              autofocus: widget.initialAddress == null,
              autocorrect: false,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'Room address',
                hintText: 'Enter address…',
                helperText: status,
                errorText:
                    _lookup == _Lookup.invalid || _lookup == _Lookup.notFound
                    ? status
                    : null,
                prefixIcon: const Icon(Icons.tag_rounded),
              ),
              onChanged: (text) => _queue(text),
              onSubmitted: (text) => _queue(text, immediate: true),
            ),
          ),
          if (preview != null) _previewCard(preview),
        ],
      ),
    );
  }

  Widget _previewCard(RoomPreview preview) {
    final p = widget.palette;
    final idle = !_busy;
    Widget action;
    if (preview.banned) {
      action = Text(
        'You were banned from this room.',
        style: TextStyle(color: p.foreground),
      );
    } else if (_knockSent) {
      action = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Request to join sent',
            style: TextStyle(color: p.foreground, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'You will receive an invite to join the room if your request is '
            'accepted.',
            style: TextStyle(color: p.muted),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: idle ? () => _cancelKnock(preview) : null,
            child: const Text('Cancel request'),
          ),
        ],
      );
    } else if (preview.canKnock && !preview.joined && !preview.invited) {
      action = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Tap the button below and a room administrator will be notified. '
            'You’ll be able to join the conversation once approved.',
            style: TextStyle(color: p.muted),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _message,
            enabled: idle,
            maxLength: 500,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Message (optional)'),
          ),
          FilledButton(
            onPressed: idle ? () => _knock(preview) : null,
            child: const Text('Send request to join'),
          ),
        ],
      );
    } else {
      action = FilledButton(
        onPressed: idle ? () => _join(preview) : null,
        child: Text(
          preview.joined
              ? 'Open room'
              : preview.invited
              ? 'Accept invite'
              : 'Join',
        ),
      );
    }
    final restricted =
        preview.joinRule == 'invite' && !preview.invited && !preview.joined;
    return AdminSection(
      palette: p,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  PersonAvatar(
                    backend: widget.backend,
                    palette: p,
                    name: preview.displayName,
                    url: preview.avatarUrl,
                    size: 56,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          preview.displayName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: p.foreground,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          [
                            ?preview.alias,
                            if (preview.memberCount != null)
                              '${preview.memberCount} '
                                  '${preview.memberCount == 1 ? 'member' : 'members'}',
                          ].join(' · '),
                          style: TextStyle(color: p.muted, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (preview.topic?.trim().isNotEmpty == true) ...[
                const SizedBox(height: 12),
                Text(
                  preview.topic!.trim(),
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: p.foreground, height: 1.35),
                ),
              ],
              if (preview.name == null && preview.joinRule == null) ...[
                const SizedBox(height: 10),
                Text(
                  'Preview is not available. You may still be able to join.',
                  style: TextStyle(color: p.muted),
                ),
              ],
              if (restricted) ...[
                const SizedBox(height: 10),
                Text(
                  'You need an invite in order to join.',
                  style: TextStyle(color: p.muted),
                ),
              ],
              const SizedBox(height: 14),
              action,
            ],
          ),
        ),
      ],
    );
  }
}
