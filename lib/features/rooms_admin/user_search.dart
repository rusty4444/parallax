import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../messaging_features.dart';
import 'admin_ui.dart';
import 'rooms_admin_models.dart';

/// Debounced, generation-safe user directory search shared by Start chat and
/// Invite people. A typed full Matrix ID is always offered, so people outside
/// the server's directory can still be reached.
mixin UserSearchMixin<T extends StatefulWidget> on State<T> {
  ChatBackend get searchBackend;

  final searchController = TextEditingController();
  late final searchOwner = BackendSessionOwner(searchBackend);
  Timer? _debounce;
  int _generation = 0;
  bool searching = false;
  String? searchError;
  List<DirectoryUser> searchResults = const [];

  MessagingFeatures? get _features => switch (searchBackend) {
    final MessagingFeatures features => features,
    _ => null,
  };

  bool get directorySearchAvailable => _features != null;

  void disposeSearch() {
    _generation++;
    _debounce?.cancel();
    searchOwner.release();
    searchController.dispose();
  }

  bool _current(int generation) =>
      mounted && searchOwner.isCurrent && generation == _generation;

  void queueSearch(String text, {bool immediate = false}) {
    _debounce?.cancel();
    final generation = ++_generation;
    final term = text.trim();
    final features = _features;
    setState(() {
      searchResults = const [];
      searchError = null;
      searching = term.isNotEmpty && features != null;
    });
    if (term.isEmpty || features == null) return;
    Future<void> run() async {
      if (!_current(generation)) return;
      try {
        final users = await features.searchUsers(term);
        if (!_current(generation)) return;
        setState(() => searchResults = users.take(50).toList());
      } catch (_) {
        if (!_current(generation)) return;
        setState(
          () => searchError = 'Couldn’t search the user directory. Try again.',
        );
      } finally {
        if (_current(generation)) setState(() => searching = false);
      }
    }

    if (immediate) {
      unawaited(run());
    } else {
      _debounce = Timer(const Duration(milliseconds: 300), () => run());
    }
  }

  /// Directory results plus the typed Matrix ID when it is valid.
  List<DirectoryUser> get searchCandidates {
    final term = searchController.text.trim();
    final own = searchBackend.userId;
    final results = [
      for (final user in searchResults)
        if (user.id != own) user,
    ];
    if (isValidUserId(term) &&
        term != own &&
        !results.any((user) => user.id == term)) {
      results.insert(0, DirectoryUser(id: term));
    }
    return results;
  }
}

class UserSearchField extends StatelessWidget {
  const UserSearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onSubmitted,
    this.autofocus = false,
    this.enabled = true,
  });
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final bool autofocus;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: TextField(
      controller: controller,
      autofocus: autofocus,
      enabled: enabled,
      autocorrect: false,
      textInputAction: TextInputAction.search,
      decoration: const InputDecoration(
        labelText: 'Search for someone',
        hintText: 'Name or @user:server',
        prefixIcon: Icon(Icons.person_search_outlined),
      ),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
    ),
  );
}

class UserResultTile extends StatelessWidget {
  const UserResultTile({
    super.key,
    required this.backend,
    required this.palette,
    required this.user,
    this.onTap,
    this.trailing,
    this.subtitle,
  });
  final ChatBackend backend;
  final AppPalette palette;
  final DirectoryUser user;
  final VoidCallback? onTap;
  final Widget? trailing;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final name = user.name?.trim();
    final label = name == null || name.isEmpty ? user.id : name;
    return ListTile(
      leading: PersonAvatar(
        backend: backend,
        palette: palette,
        name: label,
        url: user.avatar,
        size: 42,
      ),
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: palette.foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle ?? user.id,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: palette.muted),
      ),
      trailing: trailing,
      onTap: onTap,
    );
  }
}
