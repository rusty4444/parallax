import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../room_details.dart';
import '../spaces_admin/manage_authorised_spaces_screen.dart';
import '../spaces_admin/spaces_admin_features.dart';
import '../spaces_admin/spaces_admin_models.dart';
import 'admin_ui.dart';
import 'rooms_admin_features.dart';
import 'rooms_admin_models.dart';

/// Element X "Security & privacy": access (join rule), address and public
/// directory, encryption and history visibility. Each change is written
/// immediately and re-read from the server.
///
/// "Space members" access (`restricted` / `knock_restricted`) and its
/// authorised Spaces come from the spaces_admin module (Element X
/// ManageAuthorizedSpaces). For a Space, encryption and history visibility
/// are hidden as in Element X.
class SecurityPrivacyScreen extends StatefulWidget {
  const SecurityPrivacyScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.roomId,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final String roomId;

  @override
  State<SecurityPrivacyScreen> createState() => _SecurityPrivacyScreenState();
}

class _SecurityPrivacyScreenState extends State<SecurityPrivacyScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  RoomDetails? _details;
  AuthorisedSpaces? _authorised;
  bool? _published;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  int _generation = 0;

  RoomsAdminFeatures? get _admin => roomsAdminFeaturesOf(widget.backend);
  SpacesAdminFeatures? get _spaces => spacesAdminFeaturesOf(widget.backend);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _generation++;
    _owner.release();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final details = await widget.backend.getRoomDetails(widget.roomId);
      if (!mounted || !_owner.isCurrent || generation != _generation) return;
      AuthorisedSpaces? authorised;
      try {
        authorised = _spaces?.authorisedSpacesFor(
          widget.roomId,
          details.allowedRoomIds,
        );
      } catch (_) {
        authorised = null;
      }
      setState(() {
        _details = details;
        _authorised = authorised;
      });
      bool? published;
      try {
        published = await _admin?.isPublishedInDirectory(widget.roomId);
      } catch (_) {
        published = null;
      }
      if (mounted && _owner.isCurrent && generation == _generation) {
        setState(() => _published = published);
      }
    } catch (_) {
      if (mounted && _owner.isCurrent && generation == _generation) {
        setState(() {
          _details = null;
          _authorised = null;
          _error = 'Couldn’t load room settings. Check your connection.';
        });
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _write(String failure, Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted && _owner.isCurrent) showAdminMessage(context, failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted && _owner.isCurrent) await _load();
  }

  Future<void> _setJoinRule(String rule) async {
    final admin = _admin;
    if (admin == null || rule == _details?.joinRule) return;
    await _write(
      'Couldn’t change who can join.',
      () => admin.setJoinRule(widget.roomId, rule),
    );
  }

  /// Element X: with one candidate Space it is used directly, otherwise the
  /// user picks the authorised Spaces first.
  Future<void> _selectSpaceMembers(String rule) async {
    final details = _details;
    final authorised = _authorised;
    if (details == null || authorised == null || rule == details.joinRule) {
      return;
    }
    final askToJoin = rule == 'knock_restricted';
    final current = details.joinRule;
    List<String>? ids;
    if ((current == 'restricted' || current == 'knock_restricted') &&
        details.allowedRoomIds.isNotEmpty) {
      // Switching between the two Space-member variants keeps the list.
      ids = details.allowedRoomIds;
    } else if (authorised.count == 1) {
      ids = [
        ...authorised.selectable.map((space) => space.id),
        ...authorised.unknown,
      ];
    } else {
      ids = await _pickSpaces(details, authorised);
    }
    if (ids == null || ids.isEmpty || !mounted || !_owner.isCurrent) return;
    await _writeSpaces(ids, askToJoin: askToJoin);
  }

  Future<List<String>?> _pickSpaces(
    RoomDetails details,
    AuthorisedSpaces authorised,
  ) => Navigator.of(context).push<List<String>>(
    MaterialPageRoute(
      builder: (_) => ManageAuthorisedSpacesScreen(
        backend: widget.backend,
        palette: widget.palette,
        spaces: authorised,
        initial: details.allowedRoomIds,
      ),
    ),
  );

  Future<void> _manageSpaces() async {
    final details = _details;
    final authorised = _authorised;
    if (details == null || authorised == null) return;
    final ids = await _pickSpaces(details, authorised);
    if (ids == null || ids.isEmpty || !mounted || !_owner.isCurrent) return;
    final current = details.allowedRoomIds.toSet();
    if (ids.length == current.length && current.containsAll(ids)) return;
    await _writeSpaces(ids, askToJoin: details.joinRule == 'knock_restricted');
  }

  Future<void> _writeSpaces(List<String> ids, {required bool askToJoin}) async {
    final spaces = _spaces;
    if (spaces == null) return;
    await _write(
      'Couldn’t change who can join.',
      () =>
          spaces.setAuthorisedSpaces(widget.roomId, ids, askToJoin: askToJoin),
    );
  }

  String _spaceMembersDescription(
    RoomDetails details, {
    required bool askToJoin,
  }) {
    final authorised = _authorised;
    final ids = details.allowedRoomIds.isNotEmpty
        ? details.allowedRoomIds
        : [
            ...?authorised?.selectable.map((space) => space.id),
            ...?authorised?.unknown,
          ];
    final single = ids.length == 1
        ? (authorised?.nameOf(ids.single) ?? 'the authorised space')
        : null;
    final who = single == null
        ? 'Anyone in authorised spaces can join'
        : 'Anyone in $single can join';
    return askToJoin ? '$who, but everyone else must request access.' : '$who.';
  }

  Future<void> _setHistory(String visibility) async {
    final admin = _admin;
    if (admin == null || visibility == _details?.historyVisibility) return;
    await _write(
      'Couldn’t change who can read history.',
      () => admin.setHistoryVisibility(widget.roomId, visibility),
    );
  }

  Future<void> _enableEncryption() async {
    final admin = _admin;
    if (admin == null) return;
    final confirmed = await confirmAction(
      context,
      title: 'Enable encryption?',
      message:
          'Once enabled, encryption for a room cannot be disabled. Message '
          'history will only be visible for room members since they were '
          'invited or since they joined the room. No one besides the room '
          'members will be able to read messages. This may prevent bots and '
          'bridges from working correctly.',
      confirm: 'Yes, enable encryption',
    );
    if (!confirmed || !mounted || !_owner.isCurrent) return;
    await _write(
      'Couldn’t enable encryption.',
      () => admin.enableEncryption(widget.roomId),
    );
  }

  Future<void> _editAddress(RoomDetails details) async {
    final admin = _admin;
    final server = admin?.homeserverName;
    if (admin == null || server == null) return;
    final current = details.canonicalAlias;
    final initial = current != null && serverNameOf(current) == server
        ? current.substring(1, current.lastIndexOf(':'))
        : roomAliasLocalpartFor(details.hasName ? details.name : '');
    final localpart = await showDialog<String>(
      context: context,
      builder: (_) => _AddressDialog(initial: initial, server: server),
    );
    if (localpart == null || !mounted || !_owner.isCurrent) return;
    await _write(
      'Couldn’t set that address. It may already be taken.',
      () => admin.setRoomAddress(widget.roomId, localpart),
    );
  }

  Future<void> _removeAddress() async {
    final admin = _admin;
    if (admin == null) return;
    final confirmed = await confirmAction(
      context,
      title: 'Remove address?',
      message:
          'People will no longer be able to find or join this room with its '
          'address. The room will also need an address to stay in the public '
          'directory.',
      confirm: 'Remove',
      destructive: true,
    );
    if (!confirmed || !mounted || !_owner.isCurrent) return;
    await _write(
      'Couldn’t remove the address.',
      () => admin.setRoomAddress(widget.roomId, null),
    );
  }

  Future<void> _setPublished(bool published) async {
    final admin = _admin;
    if (admin == null) return;
    await _write(
      'Couldn’t change the directory listing.',
      () => admin.setPublishedInDirectory(widget.roomId, published),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final details = _details;
    return AdminPage(
      palette: p,
      title: 'Security & privacy',
      busy: _loading || _busy,
      body: details == null
          ? (_loading
                ? const SizedBox.shrink()
                : AdminPlaceholder(
                    palette: p,
                    icon: Icons.cloud_off_rounded,
                    title: 'Settings unavailable',
                    message: _error,
                    onRetry: _load,
                  ))
          : ListView(
              padding: const EdgeInsets.only(bottom: 28),
              children: _sections(details, !_busy && !_loading),
            ),
    );
  }

  Widget _radio<T>({
    required T value,
    required String title,
    String? subtitle,
    bool enabled = true,
  }) {
    final p = widget.palette;
    return RadioListTile<T>(
      value: value,
      enabled: enabled,
      title: Text(title, style: TextStyle(color: p.foreground)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: TextStyle(color: p.muted)),
    );
  }

  List<Widget> _sections(RoomDetails details, bool idle) {
    final p = widget.palette;
    final rule = details.joinRule == 'private' ? 'invite' : details.joinRule;
    final spaceMembers =
        details.joinRule == 'restricted' ||
        details.joinRule == 'knock_restricted';
    final spaceOptions = _spaces != null && (_authorised?.count ?? 0) > 0;
    final showRestricted =
        details.joinRule == 'restricted' ||
        (spaceOptions && details.supportsRestricted);
    final showKnockRestricted =
        details.joinRule == 'knock_restricted' ||
        (spaceOptions && supportsKnockRestricted(details));
    final showVisibility = details.isPublic || details.isKnockable;
    final history = details.historyVisibility;
    final worldReadableAllowed =
        details.isPublic && !details.encrypted || history == 'world_readable';
    final server = _admin?.homeserverName;
    return [
      if (details.canChangeJoinRule)
        AdminSection(
          palette: p,
          title: 'Access',
          children: [
            RadioGroup<String>(
              groupValue: rule,
              onChanged: (value) {
                if (!idle || value == null) return;
                if (value == 'restricted' || value == 'knock_restricted') {
                  _selectSpaceMembers(value);
                } else {
                  _setJoinRule(value);
                }
              },
              child: Column(
                children: [
                  _radio(
                    value: 'invite',
                    title: 'Invite only',
                    subtitle: 'Only invited people can join.',
                    enabled: idle,
                  ),
                  if (showRestricted)
                    _radio(
                      value: 'restricted',
                      title: 'Space members',
                      subtitle: _spaceMembersDescription(
                        details,
                        askToJoin: false,
                      ),
                      enabled: idle && spaceOptions,
                    ),
                  _radio(
                    value: 'knock',
                    title: 'Ask to join',
                    subtitle: details.supportsKnock
                        ? 'Everyone must request access.'
                        : 'Needs a newer room version.',
                    enabled: idle && details.supportsKnock,
                  ),
                  _radio(
                    value: 'public',
                    title: 'Anyone',
                    subtitle:
                        'Anyone can join, including people outside your '
                        'organisation.',
                    enabled: idle,
                  ),
                  if (showKnockRestricted)
                    _radio(
                      value: 'knock_restricted',
                      title: 'Ask to join (space members join directly)',
                      subtitle: _spaceMembersDescription(
                        details,
                        askToJoin: true,
                      ),
                      enabled: idle && spaceOptions,
                    ),
                ],
              ),
            ),
            if (spaceMembers && spaceOptions)
              AdminTile(
                palette: p,
                icon: Icons.workspaces_outline,
                title: 'Manage spaces',
                subtitle: details.allowedRoomIds.length == 1
                    ? '1 authorised space'
                    : '${details.allowedRoomIds.length} authorised spaces',
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: idle ? _manageSpaces : null,
              ),
          ],
        ),
      if (showVisibility && details.canChangeAddress)
        AdminSection(
          palette: p,
          title: 'Visibility',
          footer:
              'Addresses are a way to find and access rooms. You’ll need an '
              'address in order to make it visible in the public directory.',
          children: [
            AdminTile(
              palette: p,
              icon: Icons.alternate_email_rounded,
              title: details.canonicalAlias ?? 'Add address',
              subtitle: details.canonicalAlias == null
                  ? 'e.g. #room-name:${server ?? 'example.org'}'
                  : 'Room address',
              trailing: details.canonicalAlias == null
                  ? const Icon(Icons.add_rounded)
                  : IconButton(
                      tooltip: 'Remove address',
                      onPressed: idle ? _removeAddress : null,
                      icon: const Icon(Icons.delete_outline_rounded),
                    ),
              onTap: idle ? () => _editAddress(details) : null,
            ),
            SwitchListTile(
              title: Text(
                'Visible in public directory',
                style: TextStyle(color: p.foreground),
              ),
              subtitle: Text(
                _published == null
                    ? 'Couldn’t check the directory.'
                    : 'Allow to be found by searching the public directory.',
                style: TextStyle(color: p.muted),
              ),
              value: _published ?? false,
              onChanged:
                  idle &&
                      _published != null &&
                      (details.canonicalAlias != null || _published == true)
                  ? _setPublished
                  : null,
            ),
          ],
        ),
      if (!details.isSpace &&
          (details.encrypted || details.canEnableEncryption))
        AdminSection(
          palette: p,
          title: 'Encryption',
          footer: 'Once enabled, encryption cannot be disabled.',
          children: [
            SwitchListTile(
              title: Text(
                'Enable end-to-end encryption',
                style: TextStyle(color: p.foreground),
              ),
              value: details.encrypted,
              onChanged: idle && !details.encrypted
                  ? (_) => _enableEncryption()
                  : null,
            ),
          ],
        ),
      if (details.canChangeHistory && !details.isSpace)
        AdminSection(
          palette: p,
          title: 'Who can read history',
          footer: 'Changes won’t affect past messages, only new ones.',
          children: [
            RadioGroup<String>(
              groupValue: history,
              onChanged: (value) {
                if (idle && value != null) _setHistory(value);
              },
              child: Column(
                children: [
                  _radio(
                    value: 'shared',
                    title: 'Members (full history)',
                    enabled: idle,
                  ),
                  _radio(
                    value: 'invited',
                    title: 'Members since invited',
                    enabled: idle,
                  ),
                  if (history == 'joined')
                    _radio(
                      value: 'joined',
                      title: 'Members since joining',
                      enabled: idle,
                    ),
                  if (worldReadableAllowed)
                    _radio(
                      value: 'world_readable',
                      title: 'Anyone (history is public)',
                      enabled: idle,
                    ),
                ],
              ),
            ),
          ],
        ),
    ];
  }
}

class _AddressDialog extends StatefulWidget {
  const _AddressDialog({required this.initial, required this.server});
  final String initial;
  final String server;

  @override
  State<_AddressDialog> createState() => _AddressDialogState();
}

class _AddressDialogState extends State<_AddressDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = _controller.text.trim();
    final valid = isValidAliasLocalpart(value);
    return AlertDialog(
      title: const Text('Edit address'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        onChanged: (_) => setState(() {}),
        decoration: InputDecoration(
          labelText: 'Address',
          prefixText: '#',
          suffixText: ':${widget.server}',
          errorText: value.isEmpty || valid ? null : 'Not a valid address',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: valid ? () => Navigator.pop(context, value) : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
