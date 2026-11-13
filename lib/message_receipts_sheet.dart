import 'dart:async';

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'chat_backend.dart';
import 'messaging_features.dart';
import 'room_avatar.dart';

Future<void> showMessageReceipts(
  BuildContext context, {
  required ChatBackend backend,
  required String roomId,
  required String eventId,
  AppPalette? palette,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => _MessageReceiptsSheet(
    backend: backend,
    roomId: roomId,
    eventId: eventId,
    palette: palette,
  ),
);

class _MessageReceiptsSheet extends StatefulWidget {
  const _MessageReceiptsSheet({
    required this.backend,
    required this.roomId,
    required this.eventId,
    this.palette,
  });
  final ChatBackend backend;
  final String roomId;
  final String eventId;
  final AppPalette? palette;

  @override
  State<_MessageReceiptsSheet> createState() => _MessageReceiptsSheetState();
}

class _MessageReceiptsSheetState extends State<_MessageReceiptsSheet> {
  int _generation = 0;
  String? _account;
  String? _userId;
  bool _expired = false;
  bool _loading = false;
  String? _error;
  List<MessageReader> _readers = const [];

  MessagingFeatures? get _features => switch (widget.backend) {
    final MessagingFeatures features => features,
    _ => null,
  };
  bool get _ownerCurrent =>
      !_expired &&
      _account == _features?.accountKey &&
      _userId == widget.backend.userId;
  bool _current(int generation) =>
      mounted && _ownerCurrent && generation == _generation;

  @override
  void initState() {
    super.initState();
    _account = _features?.accountKey;
    _userId = widget.backend.userId;
    widget.backend.addListener(_changed);
    unawaited(_load());
  }

  void _changed() {
    if (_expired) return;
    if (!_ownerCurrent) {
      _generation++;
      setState(() {
        _expired = true;
        _loading = false;
        _readers = const [];
        _error = null;
      });
    } else if (!_loading) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (!_ownerCurrent || _features == null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final readers = await _features!.messageReaders(
        widget.roomId,
        widget.eventId,
      );
      if (!_current(generation)) return;
      setState(() => _readers = readers);
    } catch (_) {
      if (_current(generation)) {
        setState(() {
          _readers = const [];
          _error = 'Couldn’t load read receipts.';
        });
      }
    } finally {
      if (_current(generation)) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _generation++;
    widget.backend.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .6,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Read receipts',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _expired || _features == null ? null : _load,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Latest shared receipt pointers for this message. Missing receipts do not mean a message is unread.',
            ),
          ),
          Expanded(
            child: _expired
                ? const Center(
                    child: Text('Account changed. Reopen read receipts.'),
                  )
                : _features == null
                ? const Center(
                    child: Text(
                      'Read receipts are unavailable for this account.',
                    ),
                  )
                : _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!),
                        TextButton(
                          onPressed: _load,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : _readers.isEmpty
                ? const Center(
                    child: Text('No shared read receipts for this message.'),
                  )
                : ListView.builder(
                    itemCount: _readers.length,
                    itemBuilder: (context, index) {
                      final reader = _readers[index];
                      final time = reader.time?.toLocal();
                      final localizations = MaterialLocalizations.of(context);
                      final palette =
                          widget.palette ?? paletteFor(VisualTheme.parallax);
                      final details = [
                        if (reader.name != reader.userId) reader.userId,
                        if (time != null)
                          '${localizations.formatMediumDate(time)} ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(time))}',
                      ];
                      return ListTile(
                        leading: UserAvatar(
                          key: ValueKey('receipt-avatar-${reader.userId}'),
                          name: reader.name,
                          url: reader.avatar,
                          backend: widget.backend,
                          palette: palette,
                          size: 36,
                        ),
                        title: Text(reader.name),
                        subtitle: details.isEmpty
                            ? null
                            : Text(details.join('\n')),
                        trailing: Icon(
                          Icons.done_all,
                          size: 18,
                          color: palette.secondary,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
