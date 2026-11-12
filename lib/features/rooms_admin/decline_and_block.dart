import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import 'admin_ui.dart';
import 'rooms_admin_features.dart';
import 'rooms_admin_models.dart';

/// Element X "Decline and block" for an invitation: decline, optionally
/// block the inviter and optionally report the room. Pops true once the
/// invitation was declined.
class DeclineAndBlockScreen extends StatefulWidget {
  const DeclineAndBlockScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
    this.roomName,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;
  final String? roomName;

  @override
  State<DeclineAndBlockScreen> createState() => _DeclineAndBlockScreenState();
}

class _DeclineAndBlockScreenState extends State<DeclineAndBlockScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  late final String? _inviter = roomsAdminFeaturesOf(
    widget.backend,
  )?.inviterOf(widget.roomId);
  final _reason = TextEditingController();
  late bool _block = _inviter != null;
  bool _report = false;
  bool _busy = false;
  bool _reported = false;
  bool _blocked = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reason.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _owner.release();
    _reason.dispose();
    super.dispose();
  }

  bool get _ready =>
      !_busy &&
      (_block || _report) &&
      (!_report || _reason.text.trim().isNotEmpty);

  Future<void> _decline() async {
    final admin = roomsAdminFeaturesOf(widget.backend);
    if (!_ready || !_owner.isCurrent) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Report and block first: they need the invite's state, and a retry
      // after a partial failure skips steps that already succeeded.
      if (_report && !_reported) {
        if (admin == null) throw const ReportRoomUnsupported();
        await admin.reportRoom(widget.roomId, _reason.text.trim());
        _reported = true;
      }
      if (_block && !_blocked && _inviter != null) {
        await admin!.setIgnored(_inviter, true);
        _blocked = true;
      }
      await widget.backend.declineInvite(widget.roomId);
      if (mounted && _owner.isCurrent) Navigator.pop(context, true);
    } on ReportRoomUnsupported {
      if (mounted) {
        setState(
          () => _error =
              'Your account provider doesn’t support reporting rooms. Turn '
              'off “Report room” to decline and block.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Something went wrong. ${_reported ? 'The report was sent. ' : ''}'
              '${_blocked ? 'The user is blocked. ' : ''}Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return AdminPage(
      palette: p,
      title: 'Decline and block',
      busy: _busy,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 28),
        children: [
          AdminSection(
            palette: p,
            children: [
              SwitchListTile(
                title: Text(
                  'Block user',
                  style: TextStyle(color: p.foreground),
                ),
                subtitle: Text(
                  _inviter == null
                      ? 'The inviter isn’t known.'
                      : 'You will not see any messages or room invites from '
                            '$_inviter.',
                  style: TextStyle(color: p.muted),
                ),
                value: _block,
                onChanged: _busy || _inviter == null
                    ? null
                    : (value) => setState(() => _block = value),
              ),
              SwitchListTile(
                title: Text(
                  'Report room',
                  style: TextStyle(color: p.foreground),
                ),
                subtitle: Text(
                  'Report this room to your account provider.',
                  style: TextStyle(color: p.muted),
                ),
                value: _report,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _report = value),
              ),
            ],
          ),
          if (_report)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _reason,
                enabled: !_busy,
                minLines: 2,
                maxLines: 5,
                maxLength: 1000,
                decoration: const InputDecoration(
                  labelText: 'Reason',
                  hintText: 'Describe the reason to report…',
                ),
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Text(_error!, style: TextStyle(color: p.foreground)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD7263D),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: _ready ? _decline : null,
              child: const Text('Decline'),
            ),
          ),
        ],
      ),
    );
  }
}
