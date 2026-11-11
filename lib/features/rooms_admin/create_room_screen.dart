import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../created_room_wait.dart';
import '../../feature_settings_scope.dart';
import '../../room_creation_request.dart';
import '../../widgets.dart';
import 'admin_ui.dart';
import 'avatar_picker.dart';
import 'invite_people_screen.dart';
import 'rooms_admin_features.dart';
import 'rooms_admin_models.dart';

enum _Access { private, askToJoin, public }

/// Element X "New room" (ConfigureRoom) followed by "Invite people". The
/// create POST shares the session-owned single-flight [RoomCreationRequest]
/// with the inbox, so an uncertain create can never be repeated. Pops the
/// created room ID.
class CreateRoomScreen extends StatefulWidget {
  const CreateRoomScreen({
    super.key,
    required this.backend,
    required this.palette,
  });
  final ChatBackend backend;
  final AppPalette palette;

  @override
  State<CreateRoomScreen> createState() => _CreateRoomScreenState();
}

class _CreateRoomScreenState extends State<CreateRoomScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  late final _request = RoomCreationRequest.forBackend(widget.backend);
  final _name = TextEditingController();
  final _topic = TextEditingController();
  final _address = TextEditingController();
  bool _addressEdited = false;
  _Access _access = _Access.private;
  PickedImage? _avatar;
  bool _submitted = false;
  bool _waiting = false;
  bool _syncPending = false;
  CreatedRoomWait? _wait;

  RoomsAdminFeatures? get _admin => roomsAdminFeaturesOf(widget.backend);
  bool get _current => mounted && _owner.isCurrent;
  bool get _public => _access != _Access.private;

  @override
  void initState() {
    super.initState();
    _request.addListener(_changed);
    _name.addListener(_nameChanged);
    _address.addListener(() => setState(() {}));
    _topic.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _wait?.cancel();
    _request.detach(_changed);
    _owner.release();
    _name.dispose();
    _topic.dispose();
    _address.dispose();
    super.dispose();
  }

  void _nameChanged() {
    if (!_addressEdited) {
      final suggestion = roomAliasLocalpartFor(_name.text);
      if (_address.text != suggestion) _address.text = suggestion;
    }
    setState(() {});
  }

  void _changed() {
    if (!mounted || !_owner.isCurrent || !_submitted) return;
    setState(() {});
    final roomId = _request.roomId;
    if (roomId != null && !_waiting && !_syncPending) _afterCreate(roomId);
  }

  bool get _valid {
    final name = _name.text.trim();
    if (name.isEmpty || name.length > 255) return false;
    return !_public || isValidAliasLocalpart(_address.text.trim());
  }

  void _create() {
    if (!_valid || _request.active || !_owner.isCurrent) return;
    final admin = _admin;
    final options = RoomCreationOptions(
      name: _name.text.trim(),
      topic: _topic.text.trim(),
      visibility: _public
          ? RoomVisibilityOption.public
          : RoomVisibilityOption.private,
      askToJoin: _access == _Access.askToJoin,
      aliasLocalpart: _public ? _address.text.trim() : null,
      avatar: _avatar,
    );
    setState(() => _submitted = true);
    _request.startWith(
      () => admin != null
          ? admin.createConfiguredRoom(options)
          : widget.backend.createRoom(options.name, encrypted: true),
    );
  }

  Future<void> _afterCreate(String roomId) async {
    if (_waiting) return;
    setState(() {
      _waiting = true;
      _syncPending = false;
    });
    final wait = _wait = CreatedRoomWait(
      backend: widget.backend,
      roomId: roomId,
      isCurrent: () => _current,
    );
    final ready = await wait.result;
    wait.cancel();
    if (identical(_wait, wait)) _wait = null;
    if (!mounted || !_owner.isCurrent) return;
    if (!ready) {
      setState(() {
        _waiting = false;
        _syncPending = true;
      });
      return;
    }
    await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => InvitePeopleScreen(
          backend: widget.backend,
          palette: widget.palette,
          roomId: roomId,
          skippable: true,
          excluded: {?widget.backend.userId},
        ),
      ),
    );
    if (!mounted || !_owner.isCurrent) return;
    _request.acknowledgeOpened(roomId);
    Navigator.pop(context, roomId);
  }

  Future<void> _pickAvatar() async {
    try {
      final image = await pickAvatarImage();
      if (image != null && mounted) setState(() => _avatar = image);
    } catch (_) {
      if (mounted) {
        showAdminMessage(context, 'Couldn’t use that image. Try another.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final admin = _admin;
    final server = admin?.homeserverName ?? 'your server';
    final ours = _submitted;
    final pending = _request.active && !(ours && _syncPending);
    final failure = ours ? _request.failure : null;
    final uncertain = ours && _request.uncertain && _request.roomId == null;
    final locked = _request.active || _waiting;
    final avatar = _avatar;
    return AdminPage(
      palette: p,
      title: 'New room',
      busy: pending || _waiting,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 28),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Row(
              children: [
                if (admin != null)
                  GestureDetector(
                    onTap: locked ? null : _pickAvatar,
                    child: Semantics(
                      button: true,
                      label: 'Choose room avatar',
                      child: avatar == null
                          ? CircleAvatar(
                              radius: 34,
                              backgroundColor: p.raised,
                              foregroundColor: p.secondary,
                              child: const Icon(Icons.add_a_photo_outlined),
                            )
                          : ClipOval(
                              child: Image.memory(
                                avatar.bytes,
                                width: 68,
                                height: 68,
                                cacheWidth: 204,
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) => InitialAvatar(
                                  name: _name.text,
                                  palette: p,
                                  size: 68,
                                ),
                              ),
                            ),
                    ),
                  ),
                if (admin != null) const SizedBox(width: 14),
                Expanded(
                  child: TextField(
                    controller: _name,
                    enabled: !locked,
                    autofocus: true,
                    maxLength: 255,
                    decoration: const InputDecoration(
                      labelText: 'Room name',
                      hintText: 'Add name…',
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (admin != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: TextField(
                controller: _topic,
                enabled: !locked,
                minLines: 1,
                maxLines: 4,
                maxLength: 1000,
                decoration: const InputDecoration(
                  labelText: 'Topic (optional)',
                  hintText: 'Add description…',
                ),
              ),
            ),
          AdminSection(
            palette: p,
            title: 'Who has access',
            children: [
              RadioGroup<_Access>(
                groupValue: _access,
                onChanged: (value) {
                  if (!locked && value != null) {
                    setState(() => _access = value);
                  }
                },
                child: Column(
                  children: [
                    for (final (value, title, subtitle) in [
                      (
                        _Access.private,
                        'Private',
                        'Only people invited can join. Messages are '
                            'end-to-end encrypted.',
                      ),
                      if (admin != null)
                        (
                          _Access.askToJoin,
                          'Ask to join',
                          'Anyone can ask to join but an administrator or a '
                              'moderator must accept the request.',
                        ),
                      if (admin != null)
                        (
                          _Access.public,
                          'Public',
                          'Anyone can join, including people outside your '
                              'organisation.',
                        ),
                    ])
                      RadioListTile<_Access>(
                        value: value,
                        enabled: !locked,
                        title: Text(
                          title,
                          style: TextStyle(color: p.foreground),
                        ),
                        subtitle: Text(
                          subtitle,
                          style: TextStyle(color: p.muted),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (_public)
            AdminSection(
              palette: p,
              title: 'Address',
              footer:
                  'You’ll need an address in order to make it visible in the '
                  'public directory. Public rooms are not end-to-end '
                  'encrypted.',
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    controller: _address,
                    enabled: !locked,
                    autocorrect: false,
                    onChanged: (_) => _addressEdited = true,
                    decoration: InputDecoration(
                      labelText: 'Room address',
                      prefixText: '#',
                      suffixText: ':$server',
                      errorText:
                          _address.text.isEmpty ||
                              isValidAliasLocalpart(_address.text.trim())
                          ? null
                          : 'Not a valid address',
                    ),
                  ),
                ),
              ],
            ),
          if (failure != null)
            _notice(
              'Room not created',
              failure.message,
              Icons.error_outline_rounded,
            ),
          if (uncertain)
            _notice(
              'Room creation not confirmed',
              'The request may already have reached your server. Check your '
                  'rooms before trying again.',
              Icons.hourglass_bottom_rounded,
            ),
          if (_syncPending)
            _notice(
              'Room created',
              'Sync is not ready yet. Check again in a moment.',
              Icons.sync_rounded,
              action: TextButton(
                onPressed: () {
                  final id = _request.roomId;
                  if (id != null) _afterCreate(id);
                },
                child: const Text('Check again'),
              ),
            ),
          if (_request.active && !ours)
            _notice(
              'A room is still being created',
              'Wait for the previous request to finish.',
              Icons.hourglass_bottom_rounded,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: AccentButton(
              palette: p,
              label: _waiting ? 'Creating…' : 'Create room',
              icon: Icons.check_rounded,
              onPressed: _valid && !locked ? _create : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _notice(
    String title,
    String message,
    IconData icon, {
    Widget? action,
  }) {
    final p = widget.palette;
    return AdminSection(
      palette: p,
      children: [
        ListTile(
          leading: Icon(icon, color: p.secondary),
          title: Text(
            title,
            style: TextStyle(color: p.foreground, fontWeight: FontWeight.w700),
          ),
          subtitle: Text(message, style: TextStyle(color: p.muted)),
          trailing: action,
        ),
      ],
    );
  }
}
