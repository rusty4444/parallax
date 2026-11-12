import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../room_details.dart';
import 'admin_ui.dart';
import 'rooms_admin_features.dart';
import 'rooms_admin_models.dart';

/// Element X "Report room" (`POST /rooms/{roomId}/report`, MSC4151), with an
/// option to leave afterwards.
class ReportRoomScreen extends StatefulWidget {
  const ReportRoomScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.details,
    this.isDirect = false,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final RoomDetails details;
  final bool isDirect;

  @override
  State<ReportRoomScreen> createState() => _ReportRoomScreenState();
}

class _ReportRoomScreenState extends State<ReportRoomScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  final _reason = TextEditingController();
  bool _leave = false;
  bool _busy = false;
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

  Future<void> _report() async {
    final admin = roomsAdminFeaturesOf(widget.backend);
    final reason = _reason.text.trim();
    if (admin == null || reason.isEmpty || _busy || !_owner.isCurrent) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await admin.reportRoom(widget.details.roomId, reason);
    } on ReportRoomUnsupported {
      if (mounted) {
        setState(() {
          _busy = false;
          _error =
              'Your account provider doesn’t support reporting rooms yet. '
              'You can still leave the room or block people in it.';
        });
      }
      return;
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Couldn’t send the report. Check your connection and retry.';
        });
      }
      return;
    }
    if (!mounted || !_owner.isCurrent) return;
    if (_leave) {
      try {
        await widget.backend.leaveRoom(widget.details.roomId);
      } catch (_) {
        if (mounted) {
          setState(() {
            _busy = false;
            _error =
                'Your report was submitted successfully, but we encountered '
                'an issue while trying to leave the room. Please try again.';
          });
        }
        return;
      }
      if (!mounted) return;
      setState(() => _busy = false);
      showAdminMessage(context, 'Report sent. You left the room.');
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    showAdminMessage(context, 'Report sent.');
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return AdminPage(
      palette: p,
      title: 'Report room',
      busy: _busy,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 28),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _reason,
              enabled: !_busy,
              minLines: 3,
              maxLines: 6,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'Describe the reason to report…',
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Report this chat to your account provider. If the messages '
              'are encrypted, your account provider will not be able to read '
              'them.',
              style: TextStyle(color: p.muted, fontSize: 12.5),
            ),
          ),
          AdminSection(
            palette: p,
            children: [
              SwitchListTile(
                title: Text(
                  widget.isDirect ? 'Leave conversation' : 'Leave room',
                  style: TextStyle(color: p.foreground),
                ),
                value: _leave,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _leave = value),
              ),
            ],
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Text(_error!, style: TextStyle(color: p.foreground)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFD7263D),
                foregroundColor: Colors.white,
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: _reason.text.trim().isEmpty || _busy ? null : _report,
              icon: const Icon(Icons.flag_outlined),
              label: const Text('Report'),
            ),
          ),
        ],
      ),
    );
  }
}
