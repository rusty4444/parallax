import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../created_room_wait.dart';
import '../../feature_settings_scope.dart';
import '../../room_creation_request.dart';
import '../../widgets.dart';
import '../rooms_admin/admin_ui.dart';
import '../rooms_admin/avatar_picker.dart';
import '../rooms_admin/rooms_admin_models.dart';
import 'add_rooms_to_space_screen.dart';
import 'spaces_admin_features.dart';
import 'spaces_admin_models.dart';

/// Element X "New space" (ConfigureRoom with isSpace) or, with
/// [parentSpaceId], "New room" inside that Space. The create POST shares the
/// session-owned single-flight [RoomCreationRequest] with the inbox, so an
/// uncertain create is never repeated. Pops the created room ID.
class CreateSpaceScreen extends StatefulWidget {
  const CreateSpaceScreen({
    super.key,
    required this.backend,
    required this.palette,
    this.parentSpaceId,
    this.parentSpaceName,
    this.offerExistingRooms = true,
  });
  final ChatBackend backend;
  final AppPalette palette;

  /// Creates a room in this Space instead of a new Space.
  final String? parentSpaceId;
  final String? parentSpaceName;

  /// After creating a Space, offer to add existing rooms.
  final bool offerExistingRooms;

  @override
  State<CreateSpaceScreen> createState() => _CreateSpaceScreenState();
}

class _CreateSpaceScreenState extends State<CreateSpaceScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  late final _request = RoomCreationRequest.forBackend(widget.backend);
  final _name = TextEditingController();
  final _topic = TextEditingController();
  final _address = TextEditingController();
  bool _addressEdited = false;
  late SpaceCreationAccess _access = _inSpace
      ? SpaceCreationAccess.spaceMembers
      : SpaceCreationAccess.private;
  PickedImage? _avatar;
  bool _submitted = false;
  bool _waiting = false;
  bool _syncPending = false;
  bool _linking = false;
  String? _linkFailedRoom;
  CreatedRoomWait? _wait;

  bool get _inSpace => widget.parentSpaceId != null;
  SpacesAdminFeatures? get _spaces => spacesAdminFeaturesOf(widget.backend);
  bool get _current => mounted && _owner.isCurrent;
  String get _noun => _inSpace ? 'room' : 'space';

  @override
  void initState() {
    super.initState();
    _request.addListener(_changed);
    _name.addListener(_nameChanged);
    _address.addListener(() => setState(() {}));
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
    return !_access.needsAddress || isValidAliasLocalpart(_address.text.trim());
  }

  void _create() {
    final spaces = _spaces;
    if (spaces == null || !_valid || _request.active || !_owner.isCurrent) {
      return;
    }
    final options = SpaceCreationOptions(
      name: _name.text.trim(),
      topic: _topic.text.trim(),
      access: _access,
      aliasLocalpart: _access.needsAddress ? _address.text.trim() : null,
      avatar: _avatar,
    );
    final parent = widget.parentSpaceId;
    setState(() => _submitted = true);
    _request.startWith(
      () => parent == null
          ? spaces.createSpace(options)
          : spaces.createRoomInSpace(parent, options),
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
    _request.acknowledgeOpened(roomId);
    final parent = widget.parentSpaceId;
    if (parent != null) {
      await _link(parent, roomId);
      return;
    }
    if (widget.offerExistingRooms) {
      await Navigator.of(context).push<int>(
        MaterialPageRoute(
          builder: (_) => AddRoomsToSpaceScreen(
            backend: widget.backend,
            palette: widget.palette,
            spaceId: roomId,
            spaceName: _name.text.trim(),
            skippable: true,
          ),
        ),
      );
      if (!mounted || !_owner.isCurrent) return;
    }
    Navigator.pop(context, roomId);
  }

  /// Adds the new room to its Space; retryable without re-creating it.
  Future<void> _link(String spaceId, String roomId) async {
    final spaces = _spaces;
    if (spaces == null) return;
    setState(() {
      _waiting = false;
      _linking = true;
      _linkFailedRoom = null;
    });
    var ok = false;
    try {
      ok = (await spaces.addChildren(spaceId, [roomId])).isEmpty;
    } catch (_) {
      ok = false;
    }
    if (!mounted || !_owner.isCurrent) return;
    if (ok) {
      Navigator.pop(context, roomId);
      return;
    }
    setState(() {
      _linking = false;
      _linkFailedRoom = roomId;
    });
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

  List<(SpaceCreationAccess, String, String)> get _options {
    final space = widget.parentSpaceName?.trim().isNotEmpty == true
        ? widget.parentSpaceName!.trim()
        : 'the space';
    if (_inSpace) {
      return [
        (
          SpaceCreationAccess.spaceMembers,
          'Space members',
          'Anyone in $space can join.',
        ),
        (
          SpaceCreationAccess.askToJoinSpaceMembers,
          'Ask to join',
          'Anyone in $space can join but everyone else must request access.',
        ),
        (
          SpaceCreationAccess.private,
          'Private',
          'Only people invited can join. Messages are end-to-end encrypted.',
        ),
        (
          SpaceCreationAccess.public,
          'Public',
          'Anyone can join, including people outside your organisation.',
        ),
      ];
    }
    return const [
      (SpaceCreationAccess.private, 'Private', 'Only people invited can join.'),
      (
        SpaceCreationAccess.askToJoin,
        'Ask to join',
        'Anyone can ask to join but an administrator or a moderator must '
            'accept the request.',
      ),
      (
        SpaceCreationAccess.public,
        'Public',
        'Anyone can join, including people outside your organisation.',
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final spaces = _spaces;
    final server = spaces?.homeserverName ?? 'your server';
    final ours = _submitted;
    final pending = _request.active && !(ours && _syncPending);
    final failure = ours ? _request.failure : null;
    final uncertain = ours && _request.uncertain && _request.roomId == null;
    final locked = _request.active || _waiting || _linking;
    final avatar = _avatar;
    return AdminPage(
      palette: p,
      title: _inSpace ? 'New room' : 'New space',
      busy: pending || _waiting || _linking,
      body: spaces == null
          ? AdminPlaceholder(
              palette: p,
              icon: Icons.workspaces_outline,
              title: 'Spaces are unavailable for this account.',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 28),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: locked ? null : _pickAvatar,
                        child: Semantics(
                          button: true,
                          label: 'Choose $_noun avatar',
                          child: avatar == null
                              ? CircleAvatar(
                                  radius: 34,
                                  backgroundColor: p.raised,
                                  foregroundColor: p.secondary,
                                  child: const Icon(Icons.add_a_photo_outlined),
                                )
                              : ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    _inSpace ? 34 : 18,
                                  ),
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
                      const SizedBox(width: 14),
                      Expanded(
                        child: TextField(
                          controller: _name,
                          enabled: !locked,
                          autofocus: true,
                          maxLength: 255,
                          decoration: InputDecoration(
                            labelText: _inSpace ? 'Room name' : 'Space name',
                            hintText: 'Add name…',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
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
                    RadioGroup<SpaceCreationAccess>(
                      groupValue: _access,
                      onChanged: (value) {
                        if (!locked && value != null) {
                          setState(() => _access = value);
                        }
                      },
                      child: Column(
                        children: [
                          for (final (value, title, subtitle) in _options)
                            RadioListTile<SpaceCreationAccess>(
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
                if (_access.needsAddress)
                  AdminSection(
                    palette: p,
                    title: 'Address',
                    footer:
                        'You’ll need an address in order to make it visible '
                        'in the public directory.',
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: TextField(
                          controller: _address,
                          enabled: !locked,
                          autocorrect: false,
                          onChanged: (_) => _addressEdited = true,
                          decoration: InputDecoration(
                            labelText: _inSpace
                                ? 'Room address'
                                : 'Space address',
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
                    _inSpace ? 'Room not created' : 'Space not created',
                    failure.message,
                    Icons.error_outline_rounded,
                  ),
                if (uncertain)
                  _notice(
                    'Creation not confirmed',
                    'The request may already have reached your server. Check '
                        'your rooms before trying again.',
                    Icons.hourglass_bottom_rounded,
                  ),
                if (_syncPending)
                  _notice(
                    _inSpace ? 'Room created' : 'Space created',
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
                if (_linkFailedRoom case final roomId?)
                  _notice(
                    'Room created',
                    'It couldn’t be added to the space yet.',
                    Icons.link_off_rounded,
                    action: TextButton(
                      onPressed: () => _link(widget.parentSpaceId!, roomId),
                      child: const Text('Retry'),
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
                    label: _waiting || _linking
                        ? 'Creating…'
                        : (_inSpace ? 'Create room' : 'Create space'),
                    icon: Icons.check_rounded,
                    onPressed: _valid && !locked && _linkFailedRoom == null
                        ? _create
                        : null,
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
