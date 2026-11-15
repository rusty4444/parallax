import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../chat_network.dart';
import '../../created_room_wait.dart';
import '../../feature_settings_scope.dart';
import '../../network_logo.dart';
import '../../room_creation_request.dart';
import '../rooms_admin/admin_ui.dart';
import 'bridged_message_features.dart';
import 'bridged_message_models.dart';

/// Starts a configured bridged DM without sending a message. The room ID is
/// returned to Start chat only after Matrix exposes a joined room.
class NewBridgedMessageScreen extends StatefulWidget {
  const NewBridgedMessageScreen({
    super.key,
    required this.backend,
    required this.palette,
    required this.features,
  });

  final ChatBackend backend;
  final AppPalette palette;
  final BridgedMessageFeatures features;

  @override
  State<NewBridgedMessageScreen> createState() =>
      _NewBridgedMessageScreenState();
}

class _NewBridgedMessageScreenState extends State<NewBridgedMessageScreen> {
  late final BackendSessionOwner _owner;
  late final RoomCreationRequest _creation;
  late final TextEditingController _recipientController;
  final _accounts = <BridgeAccount>[];
  List<String> _serviceWarnings = const [];
  List<BridgeRecipient> _searchResults = const [];
  BridgeAccount? _selectedAccount;
  BridgeRecipient? _recipient;
  String? _reviewedInput;
  CreatedRoomWait? _roomWait;
  String? _waitingRoomId;
  String? _loadError;
  String? _operationError;
  bool _loading = true;
  bool _resolving = false;
  bool _hasSearched = false;
  int _generation = 0;
  int _resolutionGeneration = 0;

  @override
  void initState() {
    super.initState();
    _owner = BackendSessionOwner(widget.backend);
    _creation = RoomCreationRequest.forBackend(widget.backend);
    _creation.addListener(_creationChanged);
    _recipientController = TextEditingController();
    _loadAccounts();
    WidgetsBinding.instance.addPostFrameCallback((_) => _creationChanged());
  }

  @override
  void dispose() {
    _generation++;
    _resolutionGeneration++;
    _roomWait?.cancel();
    _creation.detach(_creationChanged);
    _recipientController.dispose();
    _owner.release();
    super.dispose();
  }

  bool get _current => mounted && _owner.isCurrent;
  bool get _busy =>
      _resolving ||
      _roomWait != null ||
      _loading ||
      (_creation.active && _creation.roomId == null);
  bool get _controlsLocked => _busy || _creation.active;
  bool get _hasCurrentRecipient {
    final recipient = _recipient;
    final account = _selectedAccount;
    return recipient != null &&
        account != null &&
        recipient.service == account.service &&
        recipient.accountId == account.accountId &&
        _reviewedInput == _recipientController.text;
  }

  bool get _hasCurrentSearchResults {
    final account = _selectedAccount;
    return account != null &&
        account.supportsSearch &&
        _hasSearched &&
        _reviewedInput == _recipientController.text;
  }

  String? get _defaultRegion =>
      widget.features.defaultPhoneRegion ??
      Localizations.maybeLocaleOf(context)?.countryCode;

  Future<void> _loadAccounts() async {
    final generation = ++_generation;
    _resolutionGeneration++;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final accounts = await widget.features.loadAccounts();
      if (!_current || generation != _generation) return;
      final previousKey = _selectedAccount?.key;
      setState(() {
        _accounts
          ..clear()
          ..addAll(accounts);
        _serviceWarnings = List.unmodifiable(widget.features.serviceWarnings);
        _selectedAccount = _accounts.length == 1
            ? _accounts.single
            : previousKey == null
            ? null
            : _accounts
                  .where((account) => account.key == previousKey)
                  .firstOrNull;
        _recipient = null;
        _reviewedInput = null;
        _searchResults = const [];
        _hasSearched = false;
        _operationError = null;
        _loading = false;
      });
    } catch (error) {
      if (!_current || generation != _generation) return;
      setState(() {
        _loading = false;
        _serviceWarnings = const [];
        _loadError = error is BridgedMessageException
            ? error.message
            : 'Couldn’t load the connected accounts. Try again.';
      });
    }
  }

  void _selectAccount(String? key) {
    if (_controlsLocked || !_current) return;
    _resolutionGeneration++;
    setState(() {
      _selectedAccount = key == null
          ? null
          : _accounts.where((account) => account.key == key).firstOrNull;
      _recipient = null;
      _reviewedInput = null;
      _searchResults = const [];
      _hasSearched = false;
      _operationError = null;
    });
  }

  Future<void> _reviewPhoneRecipient() async {
    final account = _selectedAccount;
    if (account == null ||
        !account.canCreate ||
        !account.supportsPhone ||
        _controlsLocked ||
        !_current) {
      return;
    }
    final submittedInput = _recipientController.text;
    final generation = ++_resolutionGeneration;
    setState(() {
      _operationError = null;
      _recipient = null;
      _reviewedInput = null;
      _searchResults = const [];
      _hasSearched = false;
    });
    late final String normalized;
    try {
      normalized = normalizePhoneNumber(
        submittedInput,
        defaultRegion: _defaultRegion,
      );
    } on BridgedMessageException catch (error) {
      if (_current && generation == _resolutionGeneration) {
        setState(() => _operationError = error.message);
      }
      return;
    }
    setState(() => _resolving = true);
    bool resolutionIsCurrent() =>
        _current &&
        generation == _resolutionGeneration &&
        _selectedAccount?.key == account.key &&
        _recipientController.text == submittedInput;
    try {
      // This is deliberately a separate read-only call. Selecting or typing a
      // recipient never invokes the create_dm endpoint.
      final recipient = await widget.features.resolveRecipient(
        account,
        normalized,
      );
      if (!resolutionIsCurrent()) return;
      setState(() {
        _recipient = recipient;
        _reviewedInput = submittedInput;
      });
    } catch (error) {
      if (!resolutionIsCurrent()) return;
      setState(() {
        _operationError = error is BridgedMessageException
            ? error.message
            : 'Couldn’t check that recipient. Try again.';
      });
    } finally {
      // No second review can be admitted while this one owns _resolving.
      // Input changes invalidate its result, not its resource cleanup.
      if (_current) setState(() => _resolving = false);
    }
  }

  Future<void> _searchRecipients() async {
    final account = _selectedAccount;
    if (account == null ||
        !account.canCreate ||
        !account.supportsSearch ||
        _controlsLocked ||
        !_current) {
      return;
    }
    final submittedInput = _recipientController.text;
    final generation = ++_resolutionGeneration;
    setState(() {
      _operationError = null;
      _recipient = null;
      _reviewedInput = null;
      _searchResults = const [];
      _hasSearched = false;
    });
    late final String normalizedQuery;
    try {
      normalizedQuery = normalizeSearchQuery(submittedInput);
    } on BridgedMessageException catch (error) {
      if (_current && generation == _resolutionGeneration) {
        setState(() => _operationError = error.message);
      }
      return;
    }
    setState(() => _resolving = true);
    bool searchIsCurrent() =>
        _current &&
        generation == _resolutionGeneration &&
        _selectedAccount?.key == account.key &&
        _recipientController.text == submittedInput;
    try {
      // Explicit submitted search only (never search-as-you-type). Search
      // updates ghost metadata on the bridge without creating any room or DM.
      final results = await widget.features.searchRecipients(
        account,
        normalizedQuery,
      );
      if (!searchIsCurrent()) return;
      setState(() {
        _searchResults = results;
        _hasSearched = true;
        _reviewedInput = submittedInput;
      });
    } catch (error) {
      if (!searchIsCurrent()) return;
      setState(() {
        _operationError = error is BridgedMessageException
            ? error.message
            : 'Couldn’t search ${account.service.label}. Try again.';
      });
    } finally {
      if (_current) setState(() => _resolving = false);
    }
  }

  void _selectSearchResult(BridgeRecipient candidate) {
    final account = _selectedAccount;
    if (account == null ||
        _controlsLocked ||
        !_current ||
        candidate.service != account.service ||
        candidate.accountId != account.accountId ||
        !_hasCurrentSearchResults) {
      return;
    }
    setState(() {
      _operationError = null;
      _recipient = candidate;
    });
  }

  void _openConversation() {
    final account = _selectedAccount;
    final recipient = _recipient;
    if (account == null ||
        recipient == null ||
        !_hasCurrentRecipient ||
        _creation.active ||
        !_current) {
      return;
    }
    setState(() => _operationError = null);
    _creation.startWith(() async {
      try {
        final conversation = await widget.features.ensureDirectConversation(
          account,
          recipient,
        );
        return conversation.roomId;
      } on BridgedMessageException catch (error) {
        if (error.definiteNonCreation) {
          throw RoomCreationFailure.notSubmitted(error.message);
        }
        rethrow;
      }
    });
  }

  void _creationChanged() {
    if (!_current) return;
    final roomId = _creation.roomId;
    if (roomId != null && _waitingRoomId != roomId) {
      unawaited(_waitForRoom(roomId));
    }
    if (mounted) setState(() {});
  }

  Future<void> _waitForRoom(String roomId) async {
    if (_roomWait != null || !_current) return;
    final wait = CreatedRoomWait(
      backend: widget.backend,
      roomId: roomId,
      isCurrent: () => _current,
    );
    _roomWait = wait;
    _waitingRoomId = roomId;
    if (_current) setState(() {});
    try {
      final ready = await wait.result;
      if (!mounted || !_current || _waitingRoomId != roomId) return;
      if (ready && ModalRoute.of(context)?.isCurrent == true) {
        _creation.acknowledgeOpened(roomId);
        Navigator.pop(context, roomId);
        return;
      }
    } finally {
      wait.cancel();
      if (identical(_roomWait, wait)) _roomWait = null;
      if (_current && _waitingRoomId == roomId) {
        _waitingRoomId = null;
        setState(() {});
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return AdminPage(
      palette: p,
      title: 'New bridged message',
      busy: _busy,
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (_loadError != null)
            AdminPlaceholder(
              palette: p,
              icon: Icons.cloud_off_outlined,
              title: 'Couldn’t load accounts',
              message: _loadError!,
              onRetry: _loadAccounts,
            )
          else if (!_loading && _accounts.isEmpty)
            AdminPlaceholder(
              palette: p,
              icon: Icons.link_off_outlined,
              title: 'No compatible accounts',
              message: _serviceWarnings.isNotEmpty
                  ? _serviceWarnings.join(' ')
                  : 'Connect a supported account in your Matrix bridge, then try again.',
              onRetry: _loadAccounts,
            )
          else if (!_loading) ...[
            if (_serviceWarnings.isNotEmpty) _warningsBanner(p),
            _accountSelector(p),
            _recipientInput(p),
            if (_operationError != null)
              _errorCard(
                p,
                _operationError!,
                key: const ValueKey('bridged.operation_error'),
              ),
            if (_hasCurrentSearchResults) _searchResultsSection(p),
            if (_creation.failure != null)
              _errorCard(
                p,
                _creation.failure!.message,
                key: const ValueKey('bridged.creation_error'),
              ),
            if (_hasCurrentRecipient)
              Semantics(
                key: const ValueKey('bridged.confirmation_semantics'),
                container: true,
                liveRegion: true,
                child: _confirmation(p, _recipient!),
              ),
            _creationStatus(p),
          ],
        ],
      ),
    );
  }

  Widget _warningsBanner(AppPalette p) => Semantics(
    key: const ValueKey('bridged.service_warnings'),
    container: true,
    liveRegion: true,
    child: AdminSection(
      palette: p,
      title: 'Some bridges unavailable',
      children: [
        for (final warning in _serviceWarnings)
          ListTile(
            leading: Icon(Icons.warning_amber_rounded, color: p.accent),
            title: Text(warning, style: TextStyle(color: p.foreground)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('bridged.refresh_accounts'),
              onPressed: _controlsLocked ? null : _loadAccounts,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Refresh accounts'),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _accountSelector(AppPalette p) => AdminSection(
    palette: p,
    title: 'Service & account',
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        child: DropdownButtonFormField<String>(
          key: const ValueKey('bridged.account'),
          initialValue: _selectedAccount?.key,
          decoration: const InputDecoration(labelText: 'Connected account'),
          items: [
            for (final account in _accounts)
              DropdownMenuItem(
                value: account.key,
                child: Text(
                  '${account.service.label} · ${account.displayName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: _controlsLocked ? null : _selectAccount,
        ),
      ),
      if (_selectedAccount?.availability ==
          BridgeAccountAvailability.disconnected)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Text(
            'This account is disconnected. Reconnect it in the bridge before starting a conversation.',
            style: TextStyle(color: p.muted),
          ),
        ),
      if (_selectedAccount?.capabilities.canCreateDirectConversation == false)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Text(
            'This account does not support starting new conversations.',
            style: TextStyle(color: p.muted),
          ),
        ),
    ],
  );

  Widget _recipientInput(AppPalette p) {
    final account = _selectedAccount;
    final supportsSearch = account?.supportsSearch == true;
    final supportsPhone = account?.supportsPhone == true;
    if (supportsSearch && (!supportsPhone || account!.service.isMeta)) {
      return _searchRecipientInput(p, account!);
    }
    final region = _defaultRegion;
    final canReview =
        account?.canCreate == true && supportsPhone && !_controlsLocked;
    final footer = _creation.roomId != null
        ? 'A room has already been confirmed. Check that room again or go back; the recipient is locked so a different room cannot be opened by mistake.'
        : account == null
        ? 'Select an account first.'
        : !account.canCreate
        ? 'Starting conversations is unavailable for this account. Choose a connected account with conversation creation support.'
        : supportsPhone
        ? 'Use + and the country code, or enter a national number${region == null ? '' : ' for $region'}. Name search is not supported by this account.'
        : 'This account does not support phone-number or search conversations.';
    return AdminSection(
      palette: p,
      title: 'Recipient',
      footer: footer,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: TextField(
            key: const ValueKey('bridged.recipient'),
            controller: _recipientController,
            enabled: canReview,
            keyboardType: TextInputType.phone,
            autocorrect: false,
            maxLength: 64,
            inputFormatters: [LengthLimitingTextInputFormatter(64)],
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Phone number',
              hintText: '+61 400 000 000',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
            onChanged: _onRecipientInputChanged,
            onSubmitted: (_) {
              if (canReview) unawaited(_reviewPhoneRecipient());
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: FilledButton.icon(
            key: const ValueKey('bridged.review'),
            onPressed: canReview ? _reviewPhoneRecipient : null,
            icon: const Icon(Icons.person_search_outlined),
            label: const Text('Review recipient'),
          ),
        ),
      ],
    );
  }

  Widget _searchRecipientInput(AppPalette p, BridgeAccount account) {
    final canSearch =
        account.canCreate && account.supportsSearch && !_controlsLocked;
    final isInstagram = account.service == BridgedService.instagram;
    final footer = _creation.roomId != null
        ? 'A room has already been confirmed. Check that room again or go back; the recipient is locked so a different room cannot be opened by mistake.'
        : !account.canCreate
        ? 'Starting conversations is unavailable for this account. Choose a connected account with conversation creation support.'
        : isInstagram
        ? 'Submit a name or Instagram username search, then select a person to review. Searching does not create a conversation or send a message.'
        : 'Submit a name or username search, then select a person to review. Searching does not create a conversation or send a message.';
    return AdminSection(
      palette: p,
      title: 'Recipient',
      footer: footer,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
          child: TextField(
            key: const ValueKey('bridged.recipient'),
            controller: _recipientController,
            enabled: canSearch,
            keyboardType: TextInputType.text,
            autocorrect: false,
            maxLength: 64,
            inputFormatters: [LengthLimitingTextInputFormatter(64)],
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: isInstagram ? 'Name or @username' : 'Name or username',
              hintText: isInstagram
                  ? '@username or full name'
                  : 'Full name or username',
              prefixIcon: const Icon(Icons.search_rounded),
            ),
            onChanged: _onRecipientInputChanged,
            onSubmitted: (_) {
              if (canSearch) unawaited(_searchRecipients());
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: FilledButton.icon(
            key: const ValueKey('bridged.search'),
            onPressed: canSearch ? _searchRecipients : null,
            icon: const Icon(Icons.person_search_outlined),
            label: const Text('Search people'),
          ),
        ),
      ],
    );
  }

  void _onRecipientInputChanged(String _) {
    _resolutionGeneration++;
    if (_recipient != null ||
        _reviewedInput != null ||
        _searchResults.isNotEmpty ||
        _hasSearched ||
        _operationError != null) {
      setState(() {
        _recipient = null;
        _reviewedInput = null;
        _searchResults = const [];
        _hasSearched = false;
        _operationError = null;
      });
    }
  }

  Widget _searchResultsSection(AppPalette p) {
    final account = _selectedAccount!;
    return Semantics(
      key: const ValueKey('bridged.search_results_semantics'),
      container: true,
      liveRegion: true,
      child: _searchResults.isEmpty
          ? AdminSection(
              palette: p,
              title: 'Search results',
              children: [
                ListTile(
                  leading: Icon(Icons.person_off_outlined, color: p.muted),
                  title: Text(
                    'No matching people found',
                    style: TextStyle(
                      color: p.foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    'Try a full name or exact username.',
                    style: TextStyle(color: p.muted),
                  ),
                ),
              ],
            )
          : AdminSection(
              palette: p,
              title: 'Search results',
              footer: account.service == BridgedService.instagram
                  ? 'Select a person to review before opening a conversation. Instagram search can include accounts that restrict message requests.'
                  : 'Select a person to review before opening a conversation.',
              children: [
                for (final candidate in _searchResults) ...[
                  _searchResultTile(p, candidate),
                ],
              ],
            ),
    );
  }

  Widget _searchResultTile(AppPalette p, BridgeRecipient candidate) {
    final selected =
        _recipient?.canonicalIdentifier == candidate.canonicalIdentifier &&
        _recipient?.accountId == candidate.accountId &&
        _recipient?.service == candidate.service;
    final subtitle =
        candidate.formattedIdentifiers ?? '${candidate.service.label} profile';
    return ListTile(
      key: ValueKey('bridged.result.${candidate.canonicalIdentifier}'),
      selected: selected,
      leading: PersonAvatar(
        backend: widget.backend,
        palette: p,
        name: candidate.displayLabel,
        url: candidate.avatar,
        size: 42,
      ),
      title: Text(
        candidate.displayLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: p.foreground, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: p.muted),
      ),
      trailing: Icon(
        selected ? Icons.check_circle_rounded : Icons.chevron_right_rounded,
        color: selected ? p.accent : p.muted,
      ),
      onTap: _controlsLocked ? null : () => _selectSearchResult(candidate),
    );
  }

  Widget _confirmation(AppPalette p, BridgeRecipient recipient) {
    final account = _selectedAccount!;
    final network = switch (recipient.service) {
      BridgedService.googleMessages => ChatNetwork.googleMessages,
      BridgedService.messenger => ChatNetwork.messenger,
      BridgedService.instagram => ChatNetwork.instagram,
    };
    final footer = switch (recipient.service) {
      BridgedService.googleMessages =>
        'The number is syntactically valid. Reachability and RCS availability have not been verified. Google Messages chooses the transport when you send.',
      BridgedService.messenger =>
        'Messenger requests remote thread setup immediately when you open the conversation, but bridge confirmation alone does not guarantee Messenger accepted the thread. Verify delivery when you send your first message.',
      BridgedService.instagram =>
        'Opening a conversation prepares a Matrix room if no Instagram thread exists yet; the Instagram DM starts only when you send your first text message. Send text before sending photos or other media.',
    };
    final actionNote = switch (recipient.service) {
      BridgedService.googleMessages =>
        'This opens an existing conversation or creates one. No message will be sent automatically.',
      BridgedService.messenger =>
        'This opens an existing conversation or requests a new Messenger thread. No message will be sent automatically.',
      BridgedService.instagram =>
        'This opens an existing conversation or prepares a room without creating a remote DM yet. No message will be sent automatically.',
    };
    final accountLabel = '${account.service.label} · ${account.displayName}';
    final handles = recipient.formattedIdentifiers;
    final subtitle = handles == null
        ? accountLabel
        : '$handles · $accountLabel';
    final leading = recipient.service.isMeta
        ? PersonAvatar(
            backend: widget.backend,
            palette: p,
            name: recipient.displayLabel,
            url: recipient.avatar,
            size: 40,
          )
        : NetworkLogo(network: network, palette: p, size: 40);
    return AdminSection(
      palette: p,
      title: 'Confirm recipient',
      footer: footer,
      children: [
        ListTile(
          leading: leading,
          title: Text(
            recipient.displayLabel,
            style: TextStyle(color: p.foreground, fontWeight: FontWeight.w700),
          ),
          subtitle: Text(subtitle, style: TextStyle(color: p.muted)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: FilledButton.icon(
            key: const ValueKey('bridged.open'),
            onPressed: _creation.active ? null : _openConversation,
            icon: const Icon(Icons.forum_outlined),
            label: const Text('Open conversation'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Text(
            actionNote,
            style: TextStyle(color: p.muted, fontSize: 12.5),
          ),
        ),
      ],
    );
  }

  Widget _creationStatus(AppPalette p) {
    if (_creation.active && _creation.roomId == null) {
      return Semantics(
        key: const ValueKey('bridged.creation_pending_semantics'),
        container: true,
        liveRegion: true,
        child: AdminSection(
          palette: p,
          title: _creation.uncertain
              ? 'Confirmation delayed'
              : 'Opening conversation',
          footer: _creation.uncertain
              ? 'The outcome is uncertain. Check your conversations before trying again; Parallax will not submit another create request.'
              : 'Wait for the bridge to confirm. You can leave this screen, but do not submit the same recipient again.',
          children: const [
            Padding(
              padding: EdgeInsets.all(20),
              child: Center(
                child: CircularProgressIndicator(
                  semanticsLabel:
                      'Waiting for the bridge to confirm the conversation',
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (_creation.roomId != null) {
      final waiting = _roomWait != null;
      return Semantics(
        key: const ValueKey('bridged.room_wait_semantics'),
        container: true,
        liveRegion: true,
        child: AdminSection(
          palette: p,
          title: 'Waiting for Matrix',
          footer: waiting
              ? 'The bridge returned a room. Parallax is waiting for joined-room sync before enabling the composer.'
              : 'The room is not ready yet. Use Check room again after it appears in your conversations. No second create request will be sent.',
          children: [
            if (waiting)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(
                  child: CircularProgressIndicator(
                    semanticsLabel: 'Waiting for joined-room sync',
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  key: const ValueKey('bridged.retry_room'),
                  onPressed: () => _waitForRoom(_creation.roomId!),
                  icon: const Icon(Icons.sync_rounded),
                  label: const Text('Check room again'),
                ),
              ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _errorCard(AppPalette p, String message, {Key? key}) => Semantics(
    key: key,
    container: true,
    liveRegion: true,
    child: AdminSection(
      palette: p,
      children: [
        ListTile(
          leading: const Icon(Icons.error_outline, color: Color(0xFFFF6B5E)),
          title: Text(message, style: TextStyle(color: p.foreground)),
        ),
      ],
    ),
  );
}
