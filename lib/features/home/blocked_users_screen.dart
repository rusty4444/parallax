import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import 'home_features.dart';
import 'settings_widgets.dart';

/// Ignored users with unblock (Element X BlockedUsersView).
class BlockedUsersScreen extends StatefulWidget {
  const BlockedUsersScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.features,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final AccountFeatures features;

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  String? _unblocking;
  final _removed = <String>{};

  @override
  void dispose() {
    _owner.release();
    super.dispose();
  }

  Future<void> _unblock(String userId) async {
    if (_unblocking != null || !_owner.isCurrent) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unblock user'),
        content: Text('You’ll be able to see all messages from $userId again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Unblock'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !_owner.isCurrent) return;
    setState(() => _unblocking = userId);
    try {
      await widget.features.unblockUser(userId);
      if (mounted && _owner.isCurrent) setState(() => _removed.add(userId));
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t unblock this user.')),
        );
      }
    } finally {
      if (mounted) setState(() => _unblocking = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return AnimatedBuilder(
      animation: widget.backend,
      builder: (context, _) {
        final users = widget.features.blockedUsers
            .where((user) => !_removed.contains(user))
            .toList();
        return SettingsPage(
          palette: p,
          eyebrow: 'Privacy',
          title: 'Blocked users',
          children: [
            SettingsGroup(
              palette: p,
              footer:
                  'Blocked users can’t message you and their messages are '
                  'hidden. Block someone from their profile in a room.',
              children: [
                if (users.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.block_rounded),
                    title: Text('You have no blocked users'),
                  )
                else
                  for (final user in users)
                    ListTile(
                      leading: const Icon(Icons.person_off_outlined),
                      title: Text(user),
                      trailing: TextButton(
                        onPressed: _unblocking != null
                            ? null
                            : () => _unblock(user),
                        child: Text(
                          _unblocking == user ? 'Unblocking…' : 'Unblock',
                        ),
                      ),
                    ),
              ],
            ),
          ],
        );
      },
    );
  }
}
