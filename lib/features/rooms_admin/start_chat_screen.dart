import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../directory_screen.dart';
import '../../messaging_features.dart';
import '../../room_avatar.dart';
import '../../space_browser_screen.dart';
import '../bridged_messages/bridged_message_features.dart';
import '../bridged_messages/new_bridged_message_screen.dart';
import '../spaces_admin/space_options_sheet.dart' show openCreateSpace;
import '../spaces_admin/spaces_admin_features.dart';
import 'admin_ui.dart';
import 'create_room_screen.dart';
import 'join_room_screen.dart';
import 'rooms_admin_features.dart';
import 'rooms_admin_models.dart';
import 'share_text.dart';
import 'user_search.dart';

/// Element X "Start chat": find someone to message, create a room, join one
/// by address or browse the directory. Pops the room ID to open.
class StartChatScreen extends StatefulWidget {
  const StartChatScreen({
    super.key,
    required this.backend,
    required this.palette,
  });
  final ChatBackend backend;
  final AppPalette palette;

  @override
  State<StartChatScreen> createState() => _StartChatScreenState();
}

class _StartChatScreenState extends State<StartChatScreen>
    with UserSearchMixin {
  bool _starting = false;

  @override
  ChatBackend get searchBackend => widget.backend;

  RoomsAdminFeatures? get _admin => roomsAdminFeaturesOf(widget.backend);

  @override
  void initState() {
    super.initState();
    searchOwner; // Pin the session before any account change.
  }

  @override
  void dispose() {
    disposeSearch();
    super.dispose();
  }

  void _finish(String? roomId) {
    if (mounted && searchOwner.isCurrent && roomId != null) {
      Navigator.pop(context, roomId);
    }
  }

  Future<void> _message(DirectoryUser user) async {
    if (_starting) return;
    final admin = _admin;
    final existing = admin?.existingDirectChat(user.id);
    if (existing != null) return _finish(existing);
    final name = user.name?.trim().isNotEmpty == true ? user.name! : user.id;
    final confirmed = await confirmAction(
      context,
      title: 'Start chat',
      message: 'Start a chat with $name?',
      confirm: 'Start chat',
    );
    if (!confirmed || !mounted || !searchOwner.isCurrent) return;
    setState(() => _starting = true);
    try {
      String? roomId;
      if (admin != null) {
        roomId = await admin.startDirectChat(user.id);
      } else {
        await widget.backend.createDirectChat(user.id);
        roomId = widget.backend.activeRoomId;
      }
      _finish(roomId);
    } catch (_) {
      if (mounted && searchOwner.isCurrent) {
        showAdminMessage(
          context,
          'An error occurred when trying to start a chat.',
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _push(Widget screen) async {
    final roomId = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => screen));
    _finish(roomId);
  }

  /// Element X "Create space": after creating it, browse the new Space;
  /// a room opened there is returned to the inbox.
  Future<void> _newSpace() async {
    final spaceId = await openCreateSpace(
      context,
      backend: widget.backend,
      palette: widget.palette,
    );
    if (spaceId == null || !mounted || !searchOwner.isCurrent) return;
    final roomId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => SpaceBrowserScreen(
          backend: widget.backend,
          palette: widget.palette,
          spaceId: spaceId,
        ),
      ),
    );
    if (!mounted || !searchOwner.isCurrent) return;
    Navigator.pop(context, roomId);
  }

  Future<void> _invitePeople() async {
    final userId = widget.backend.userId;
    if (userId == null) return;
    try {
      await shareText(
        'Hey, talk to me on Parallax: ${matrixToLink(userId)}',
        subject: 'Chat with me on Parallax',
      );
    } catch (_) {
      if (mounted && searchOwner.isCurrent) {
        showAdminMessage(context, 'Couldn’t open sharing.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final term = searchController.text.trim();
    final candidates = searchCandidates;
    final bridgedMessages = bridgedMessageFeaturesOf(widget.backend);
    final recent = [
      for (final room in widget.backend.rooms)
        if (room.isDirect && !room.invited) room,
    ].take(5).toList();
    return AdminPage(
      palette: p,
      title: 'Start chat',
      busy: _starting || searching,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UserSearchField(
            controller: searchController,
            enabled: !_starting,
            onChanged: (text) => queueSearch(text),
            onSubmitted: (text) => queueSearch(text, immediate: true),
          ),
          Expanded(
            child: term.isEmpty
                ? ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: [
                      AdminSection(
                        palette: p,
                        children: [
                          AdminTile(
                            palette: p,
                            icon: Icons.add_comment_outlined,
                            title: 'New room',
                            onTap: _starting
                                ? null
                                : () => _push(
                                    CreateRoomScreen(
                                      backend: widget.backend,
                                      palette: p,
                                    ),
                                  ),
                          ),
                          if (spacesAdminFeaturesOf(widget.backend) != null)
                            AdminTile(
                              palette: p,
                              icon: Icons.workspaces_outline,
                              title: 'New space',
                              onTap: _starting ? null : _newSpace,
                            ),
                          if (_admin != null)
                            AdminTile(
                              palette: p,
                              icon: Icons.tag_rounded,
                              title: 'Join room by address',
                              onTap: _starting
                                  ? null
                                  : () => _push(
                                      JoinRoomScreen(
                                        backend: widget.backend,
                                        palette: p,
                                      ),
                                    ),
                            ),
                          AdminTile(
                            palette: p,
                            icon: Icons.travel_explore_rounded,
                            title: 'Room directory',
                            onTap: _starting
                                ? null
                                : () => _push(
                                    DirectoryScreen(
                                      backend: widget.backend,
                                      palette: p,
                                    ),
                                  ),
                          ),
                          if (bridgedMessages != null)
                            AdminTile(
                              key: const ValueKey('startChat.bridgedMessage'),
                              palette: p,
                              icon: Icons.add_comment_outlined,
                              title: 'New bridged message',
                              subtitle: 'Use a connected messaging account',
                              onTap: _starting
                                  ? null
                                  : () => _push(
                                      NewBridgedMessageScreen(
                                        backend: widget.backend,
                                        palette: p,
                                        features: bridgedMessages,
                                      ),
                                    ),
                            ),
                          AdminTile(
                            palette: p,
                            icon: Icons.share_outlined,
                            title: 'Invite people to Parallax',
                            onTap: _invitePeople,
                          ),
                        ],
                      ),
                      if (recent.isNotEmpty)
                        AdminSection(
                          palette: p,
                          title: 'Recent',
                          children: [
                            for (final room in recent)
                              ListTile(
                                leading: RoomAvatar(
                                  room: room,
                                  backend: widget.backend,
                                  palette: p,
                                  size: 42,
                                ),
                                title: Text(
                                  room.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: p.foreground,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                onTap: () => _finish(room.id),
                              ),
                          ],
                        ),
                    ],
                  )
                : candidates.isEmpty
                ? AdminPlaceholder(
                    palette: p,
                    icon: Icons.person_search_outlined,
                    title:
                        searchError ??
                        (searching ? 'Searching…' : 'No people found'),
                    message: searching
                        ? null
                        : 'Try a full Matrix ID, like @alex:example.org.',
                    onRetry: searchError == null
                        ? null
                        : () => queueSearch(term, immediate: true),
                  )
                : ListView.builder(
                    itemCount: candidates.length,
                    itemBuilder: (context, index) => UserResultTile(
                      backend: widget.backend,
                      palette: p,
                      user: candidates[index],
                      onTap: _starting
                          ? null
                          : () => _message(candidates[index]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
