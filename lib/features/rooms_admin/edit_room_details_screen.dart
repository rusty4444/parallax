import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../room_avatar.dart';
import '../../room_details.dart';
import '../../widgets.dart';
import 'admin_ui.dart';
import 'avatar_picker.dart';
import 'rooms_admin_features.dart';
import 'rooms_admin_models.dart';

/// Element X "Edit details": avatar, name and topic, each permission-checked.
class EditRoomDetailsScreen extends StatefulWidget {
  const EditRoomDetailsScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.details,
    this.room,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final RoomDetails details;
  final ChatRoom? room;

  @override
  State<EditRoomDetailsScreen> createState() => _EditRoomDetailsScreenState();
}

enum _AvatarEdit { keep, replace, remove }

class _EditRoomDetailsScreenState extends State<EditRoomDetailsScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  late final _name = TextEditingController(
    text: widget.details.hasName ? widget.details.name : '',
  );
  late final _topic = TextEditingController(text: widget.details.topic);
  var _avatarEdit = _AvatarEdit.keep;
  PickedImage? _avatar;
  bool _saving = false;
  String? _error;

  RoomsAdminFeatures? get _admin => roomsAdminFeaturesOf(widget.backend);
  bool get _canAvatar => _admin != null && widget.details.canEditAvatar;

  @override
  void initState() {
    super.initState();
    _name.addListener(_changed);
    _topic.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _owner.release();
    _name.dispose();
    _topic.dispose();
    super.dispose();
  }

  bool get _nameChanged =>
      widget.details.can(RoomAction.name) &&
      _name.text.trim().isNotEmpty &&
      _name.text.trim() !=
          (widget.details.hasName ? widget.details.name.trim() : '');
  bool get _topicChanged =>
      widget.details.can(RoomAction.topic) &&
      _topic.text.trim() != widget.details.topic.trim();
  bool get _dirty =>
      _nameChanged || _topicChanged || _avatarEdit != _AvatarEdit.keep;

  Future<void> _pickAvatar() async {
    try {
      final image = await pickAvatarImage();
      if (image == null || !mounted) return;
      setState(() {
        _avatar = image;
        _avatarEdit = _AvatarEdit.replace;
      });
    } catch (_) {
      if (mounted) {
        showAdminMessage(context, 'Couldn’t use that image. Try another.');
      }
    }
  }

  Future<void> _save() async {
    if (_saving || !_dirty || !_owner.isCurrent) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final roomId = widget.details.roomId;
    try {
      if (_nameChanged) {
        await widget.backend.editRoomName(roomId, _name.text.trim());
      }
      if (_topicChanged) {
        await widget.backend.editRoomTopic(roomId, _topic.text.trim());
      }
      if (_avatarEdit != _AvatarEdit.keep && _canAvatar) {
        await _admin!.setRoomAvatar(
          roomId,
          _avatarEdit == _AvatarEdit.remove ? null : _avatar,
        );
      }
      if (mounted && _owner.isCurrent) Navigator.pop(context, true);
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        setState(
          () => _error =
              'Unable to update room. There was an unknown error and the '
              'information couldn’t be changed.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final details = widget.details;
    final avatar = _avatar;
    return AdminPage(
      palette: p,
      title: 'Edit details',
      busy: _saving,
      actions: [
        TextButton(
          onPressed: _dirty && !_saving ? _save : null,
          child: const Text('Save'),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
        children: [
          Center(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (_avatarEdit == _AvatarEdit.replace && avatar != null)
                  ClipOval(
                    child: Image.memory(
                      avatar.bytes,
                      width: 96,
                      height: 96,
                      cacheWidth: 288,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          InitialAvatar(name: _name.text, palette: p, size: 96),
                    ),
                  )
                else
                  RoomAvatar(
                    room: ChatRoom(
                      id: details.roomId,
                      name: _name.text.isEmpty ? details.name : _name.text,
                      preview: '',
                      lastActivity: null,
                      avatarUrl: _avatarEdit == _AvatarEdit.remove
                          ? null
                          : details.avatarUrl,
                    ),
                    backend: widget.backend,
                    palette: p,
                    size: 96,
                  ),
                if (_canAvatar)
                  Positioned(
                    right: -6,
                    bottom: -6,
                    child: PopupMenuButton<String>(
                      tooltip: 'Change avatar',
                      enabled: !_saving,
                      onSelected: (choice) {
                        if (choice == 'pick') {
                          _pickAvatar();
                        } else {
                          setState(() {
                            _avatar = null;
                            _avatarEdit = _AvatarEdit.remove;
                          });
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'pick',
                          child: Text('Choose a photo'),
                        ),
                        if (details.avatarUrl != null || avatar != null)
                          const PopupMenuItem(
                            value: 'remove',
                            child: Text('Remove avatar'),
                          ),
                      ],
                      child: CircleAvatar(
                        radius: 18,
                        backgroundColor: p.accent,
                        foregroundColor: p.accentOn,
                        child: const Icon(
                          Icons.photo_camera_outlined,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          TextField(
            controller: _name,
            enabled: details.can(RoomAction.name) && !_saving,
            maxLength: 255,
            decoration: InputDecoration(
              labelText: details.isSpace ? 'Space name' : 'Room name',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _topic,
            enabled: details.can(RoomAction.topic) && !_saving,
            minLines: 2,
            maxLines: 5,
            maxLength: 1000,
            decoration: const InputDecoration(labelText: 'Topic'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!, style: TextStyle(color: p.foreground)),
            ),
        ],
      ),
    );
  }
}
