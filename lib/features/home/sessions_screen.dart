import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import 'home_features.dart';
import 'settings_widgets.dart';

/// This and other sessions (devices): rename, sign out others with password
/// UIA, or hand off to the account provider when authentication is delegated.
class SessionsScreen extends StatefulWidget {
  const SessionsScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.features,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final AccountFeatures features;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  late final _owner = BackendSessionOwner(widget.backend);
  List<HomeSession>? _sessions;
  AccountManagement? _management;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _owner.release();
    super.dispose();
  }

  bool _current(int generation) =>
      mounted && _owner.isCurrent && generation == _generation;

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sessions = await widget.features.sessions();
      if (!_current(generation)) return;
      _sessions = sessions;
      _management ??= await widget.features.accountManagement();
    } catch (_) {
      if (_current(generation)) _error = 'Couldn’t load your sessions.';
    } finally {
      if (_current(generation)) setState(() => _loading = false);
    }
  }

  void _snack(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  String _lastSeen(HomeSession session) {
    final seen = session.lastSeen;
    if (session.current) return 'This device';
    if (seen == null) return 'Last activity unknown';
    final age = DateTime.now().difference(seen);
    final when = age.inMinutes < 1
        ? 'just now'
        : age.inHours < 1
        ? '${age.inMinutes} min ago'
        : age.inDays < 1
        ? '${age.inHours} h ago'
        : age.inDays < 90
        ? '${age.inDays} days ago'
        : 'over 90 days ago (inactive)';
    return 'Last active $when';
  }

  Future<void> _rename(HomeSession session) async {
    final controller = TextEditingController(text: session.name ?? '');
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Rename session'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 100,
            decoration: const InputDecoration(labelText: 'Session name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (name == null || name.isEmpty || !mounted || !_owner.isCurrent) {
        return;
      }
      setState(() => _busy = true);
      try {
        await widget.features.renameSession(session.id, name);
        if (mounted && _owner.isCurrent) await _load();
      } catch (_) {
        if (mounted && _owner.isCurrent) _snack('Couldn’t rename the session.');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _signOut(List<HomeSession> sessions) async {
    if (sessions.isEmpty || _busy || !_owner.isCurrent) return;
    final management = _management;
    if (management?.delegated ?? false) {
      final url = sessions.length == 1
          ? management!.sessionEndUrl(sessions.single.id)
          : management!.url;
      if (url != null) await openExternalLink(context, url);
      return;
    }
    final single = sessions.length == 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          single ? 'Sign out ${sessions.single.label}?' : 'Sign out others?',
        ),
        content: Text(
          single
              ? 'This session will be signed out and lose access to '
                    'encrypted messages unless its keys are backed up.'
              : 'All ${sessions.length} other sessions will be signed out.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !_owner.isCurrent) return;
    final ids = [for (final session in sessions) session.id];
    setState(() => _busy = true);
    try {
      try {
        await widget.features.signOutSessions(ids);
      } on PasswordRequired {
        if (!mounted || !_owner.isCurrent) return;
        final password = await askAccountPassword(
          context,
          title: 'Confirm it’s you',
          message: 'Enter your account password to sign out sessions.',
          action: 'Sign out',
        );
        if (password == null || !mounted || !_owner.isCurrent) return;
        await widget.features.signOutSessions(ids, password: password);
      }
      if (mounted && _owner.isCurrent) {
        _snack(single ? 'Session signed out.' : 'Other sessions signed out.');
        await _load();
      }
    } on UnsupportedAuthentication {
      if (mounted && _owner.isCurrent) {
        _snack(
          'Your homeserver needs a different sign-in step. '
          'Use another client or your account page.',
        );
      }
    } catch (_) {
      if (mounted && _owner.isCurrent) {
        _snack('Couldn’t sign out. Check your password and try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _tile(HomeSession session) => ListTile(
    key: ValueKey('session-${session.id}'),
    leading: Icon(
      session.current ? Icons.smartphone_rounded : Icons.devices_other_rounded,
    ),
    title: Text(session.label, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: Text(
      [
        _lastSeen(session),
        session.id,
        if (session.verified == true) 'Verified',
        if (session.verified == false) 'Not verified',
      ].join(' · '),
    ),
    trailing: PopupMenuButton<String>(
      tooltip: 'Session options',
      enabled: !_busy,
      onSelected: (choice) =>
          choice == 'rename' ? _rename(session) : _signOut([session]),
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'rename', child: Text('Rename')),
        if (!session.current)
          const PopupMenuItem(value: 'signout', child: Text('Sign out')),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final sessions = _sessions;
    final current = sessions?.where((s) => s.current).toList() ?? const [];
    final others = sessions?.where((s) => !s.current).toList() ?? const [];
    return SettingsPage(
      palette: p,
      eyebrow: 'Account',
      title: 'Devices',
      trailing: IconButton(
        tooltip: 'Refresh sessions',
        onPressed: _loading ? null : _load,
        icon: const Icon(Icons.refresh_rounded),
      ),
      children: [
        if (_loading && sessions == null)
          const Center(child: CircularProgressIndicator())
        else if (sessions == null)
          SettingsGroup(
            palette: p,
            children: [
              ListTile(
                title: Text(_error ?? 'Unavailable'),
                trailing: TextButton(
                  onPressed: _load,
                  child: const Text('Retry'),
                ),
              ),
            ],
          )
        else ...[
          SettingsGroup(
            palette: p,
            title: 'Current session',
            children: [for (final session in current) _tile(session)],
          ),
          SettingsGroup(
            palette: p,
            title: 'Other sessions',
            footer: (_management?.delegated ?? false)
                ? 'Your account provider manages sign-outs; you’ll be taken '
                      'to its page.'
                : 'Sign out any session you don’t recognise.',
            children: [
              if (others.isEmpty)
                const ListTile(title: Text('No other sessions'))
              else
                for (final session in others) _tile(session),
            ],
          ),
          if (others.length > 1)
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _signOut(others),
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Sign out of all other sessions'),
            ),
        ],
      ],
    );
  }
}
