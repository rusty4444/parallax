import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../room_avatar.dart';
import '../../widgets.dart';
import 'forward_content.dart';
import 'message_action_features.dart';
import 'message_previews.dart';

const _suggestionCount = 5;
const _selectableHistory = 50;

/// Result of a completed forward, for the confirmation snackbar.
@immutable
class ForwardResult {
  const ForwardResult({required this.messages, required this.rooms});
  final int messages;
  final int rooms;

  /// Element X: "1 message forwarded" / "N messages forwarded".
  String get summary =>
      messages == 1 ? '1 message forwarded' : '$messages messages forwarded';
}

/// Opens the forward picker and confirms the outcome with a snackbar.
Future<void> openForwardScreen(
  BuildContext context, {
  required ChatBackend backend,
  required MessageActionFeatures features,
  required AppPalette palette,
  required ChatEntry entry,
  List<ChatEntry> candidates = const [],
}) async {
  if (!canForward(entry)) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final result = await Navigator.of(context).push<ForwardResult>(
    MaterialPageRoute(
      builder: (_) => ForwardScreen(
        backend: backend,
        features: features,
        palette: palette,
        initial: entry,
        candidates: candidates,
      ),
    ),
  );
  if (result == null) return;
  messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(result.summary)));
}

/// Element X Forward: pick up to [maxForwardRooms] joined rooms (recent rooms
/// suggested first), optionally select up to [maxForwardMessages] messages,
/// then re-send each message's content through the guarded send path.
class ForwardScreen extends StatefulWidget {
  const ForwardScreen({
    super.key,
    required this.backend,
    required this.features,
    required this.palette,
    required this.initial,
    this.candidates = const [],
  });

  final ChatBackend backend;
  final MessageActionFeatures features;
  final AppPalette palette;
  final ChatEntry initial;

  /// Loaded timeline (oldest first) for multi-select.
  final List<ChatEntry> candidates;

  @override
  State<ForwardScreen> createState() => _ForwardScreenState();
}

class _ForwardScreenState extends State<ForwardScreen> {
  late final BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  final _query = TextEditingController();
  late List<ChatEntry> _messages = [widget.initial];
  final _selected = <String>[];
  final _delivered = <String, int>{};
  final _completed = <String>{};
  bool _sending = false;
  String? _error;

  late final List<ChatEntry> _selectable = () {
    final seen = <String>{};
    final all = [
      for (final entry in [...widget.candidates, widget.initial])
        if (canForward(entry) && seen.add(entry.id)) entry,
    ]..sort((a, b) => a.time.compareTo(b.time));
    return all.length > _selectableHistory
        ? all.sublist(all.length - _selectableHistory)
        : all;
  }();

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQuery);
  }

  @override
  void dispose() {
    _query
      ..removeListener(_onQuery)
      ..dispose();
    _owner.release();
    super.dispose();
  }

  void _onQuery() {
    if (mounted) setState(() {});
  }

  List<ChatRoom> _rooms() => [
    for (final room in widget.backend.rooms)
      if (!room.invited && widget.features.permissions(room.id).canSendMessages)
        room,
  ];

  void _toggle(ChatRoom room) {
    if (_sending || _completed.contains(room.id)) return;
    if (_selected.contains(room.id)) {
      setState(() => _selected.remove(room.id));
      return;
    }
    if (_selected.length >= maxForwardRooms) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'You can forward to up to $maxForwardRooms rooms at once.',
            ),
          ),
        );
      return;
    }
    setState(() {
      _selected.add(room.id);
      _error = null;
    });
  }

  Future<void> _chooseMessages() async {
    if (_sending) return;
    final chosen = await showModalBottomSheet<List<ChatEntry>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: widget.palette.surface,
      builder: (_) => _MessageSelectionSheet(
        palette: widget.palette,
        entries: _selectable,
        selected: {for (final m in _messages) m.id},
      ),
    );
    if (!mounted || chosen == null || chosen.isEmpty) return;
    setState(() {
      _messages = chosen;
      // A different message set restarts delivery bookkeeping.
      _delivered.clear();
      _completed.clear();
      _error = null;
    });
  }

  Future<void> _forward() async {
    if (_sending || _selected.isEmpty || !_owner.isCurrent) return;
    final payloads = [
      for (final message in _messages) ?forwardPayloadFor(message),
    ];
    if (payloads.isEmpty) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final failed = <String>[];
    for (final roomId in List.of(_selected)) {
      // Resume after the last delivered message so a retry never duplicates.
      var done = _delivered[roomId] ?? 0;
      try {
        while (done < payloads.length) {
          final payload = payloads[done];
          await widget.features.forwardEvent(
            roomId,
            payload.type,
            payload.content,
          );
          done++;
          _delivered[roomId] = done;
          if (!mounted || !_owner.isCurrent) return;
        }
        _completed.add(roomId);
      } catch (_) {
        if (!mounted || !_owner.isCurrent) return;
        failed.add(roomId);
      }
    }
    if (!mounted || !_owner.isCurrent) return;
    if (failed.isEmpty) {
      Navigator.of(
        context,
      ).pop(ForwardResult(messages: payloads.length, rooms: _completed.length));
      return;
    }
    final names = {for (final room in widget.backend.rooms) room.id: room.name};
    setState(() {
      _sending = false;
      _selected
        ..clear()
        ..addAll(failed);
      _error =
          'Couldn’t forward to ${failed.map((id) => names[id] ?? id).join(', ')}. '
          '${_completed.isEmpty ? '' : 'Sent to ${_completed.length} other '
                    '${_completed.length == 1 ? 'room' : 'rooms'}. '}'
          'Try again.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    return PopScope(
      canPop: !_sending,
      child: Scaffold(
        body: GlowBackdrop(
          palette: p,
          child: SafeArea(
            child: ListenableBuilder(
              listenable: widget.backend,
              builder: (context, _) => _body(context, p),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, AppPalette p) {
    if (!_owner.isCurrent) {
      return Center(
        child: Text(
          'Account changed. Forward again from the message.',
          style: TextStyle(color: p.muted),
        ),
      );
    }
    final rooms = _rooms();
    final query = _query.text.trim().toLowerCase();
    final matches = query.isEmpty
        ? rooms
        : rooms.where((r) => r.name.toLowerCase().contains(query)).toList();
    final suggestions = query.isEmpty
        ? matches.take(_suggestionCount).toList()
        : const <ChatRoom>[];
    final rest = query.isEmpty ? matches.skip(suggestions.length) : matches;
    final count = _messages.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 20, 6),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back',
                onPressed: _sending ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  count == 1 ? 'Forward message' : 'Forward $count messages',
                  style: TextStyle(
                    color: p.foreground,
                    fontWeight: FontWeight.w700,
                    fontSize: 23,
                  ),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 10, 22, 4),
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: p.stroke),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final message in _messages.take(3))
                        Text(
                          '${message.senderLabel}: ${messagePreviewText(message)}',
                          maxLines: count == 1 ? 2 : 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.foreground, fontSize: 13),
                        ),
                      if (count > 3)
                        Text(
                          '+${count - 3} more',
                          style: TextStyle(color: p.muted, fontSize: 12),
                        ),
                    ],
                  ),
                ),
                if (_selectable.length > 1)
                  TextButton(
                    onPressed: _sending ? null : _chooseMessages,
                    child: const Text('Select messages'),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 12, 22, 4),
          child: TextField(
            key: const ValueKey('forward-search'),
            controller: _query,
            enabled: !_sending,
            decoration: const InputDecoration(
              hintText: 'Search rooms',
              prefixIcon: Icon(Icons.search_rounded),
            ),
          ),
        ),
        Expanded(
          child: matches.isEmpty
              ? Center(
                  child: Text(
                    rooms.isEmpty
                        ? 'No rooms you can post in yet.'
                        : 'No rooms match your search.',
                    style: TextStyle(color: p.muted),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  children: [
                    if (suggestions.isNotEmpty) ...[
                      _label('Suggestions', p),
                      for (final room in suggestions) _roomTile(room, p),
                      if (rest.isNotEmpty) _label('All rooms', p),
                    ],
                    for (final room in rest) _roomTile(room, p),
                  ],
                ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 4, 22, 4),
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 13),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 6, 22, 16),
          child: AccentButton(
            palette: p,
            icon: Icons.forward_rounded,
            label: _sending
                ? 'Forwarding…'
                : _selected.isEmpty
                ? 'Choose rooms'
                : _selected.length == 1
                ? 'Forward to 1 room'
                : 'Forward to ${_selected.length} rooms',
            onPressed: _selected.isEmpty || _sending ? null : _forward,
          ),
        ),
      ],
    );
  }

  Widget _label(String text, AppPalette p) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
    child: Eyebrow(text, palette: p),
  );

  Widget _roomTile(ChatRoom room, AppPalette p) {
    final selected = _selected.contains(room.id);
    final done = _completed.contains(room.id);
    return ListTile(
      key: ValueKey('forward-room-${room.id}'),
      enabled: !_sending && !done,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      selected: selected,
      selectedTileColor: p.accent.withValues(alpha: 0.12),
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
        style: TextStyle(color: p.foreground, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        done
            ? 'Forwarded'
            : room.encrypted
            ? 'Encrypted'
            : 'Not encrypted',
        style: TextStyle(color: p.muted, fontSize: 12),
      ),
      trailing: done
          ? Icon(Icons.check_circle_rounded, color: p.secondary)
          : Checkbox(
              value: selected,
              activeColor: p.accent,
              side: BorderSide(color: p.muted, width: 1.6),
              onChanged: _sending ? null : (_) => _toggle(room),
            ),
      onTap: () => _toggle(room),
    );
  }
}

class _MessageSelectionSheet extends StatefulWidget {
  const _MessageSelectionSheet({
    required this.palette,
    required this.entries,
    required this.selected,
  });

  final AppPalette palette;

  /// Forwardable messages, oldest first.
  final List<ChatEntry> entries;
  final Set<String> selected;

  @override
  State<_MessageSelectionSheet> createState() => _MessageSelectionSheetState();
}

class _MessageSelectionSheetState extends State<_MessageSelectionSheet> {
  late final Set<String> _selected = {...widget.selected};

  void _toggle(ChatEntry entry) {
    setState(() {
      if (_selected.remove(entry.id)) return;
      if (_selected.length >= maxForwardMessages) return;
      _selected.add(entry.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final newestFirst = widget.entries.reversed.toList();
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.75,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Eyebrow('Select messages', palette: p),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                '${_selected.length} of up to $maxForwardMessages selected',
                style: TextStyle(color: p.muted, fontSize: 13),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: newestFirst.length,
                itemBuilder: (context, index) {
                  final entry = newestFirst[index];
                  final checked = _selected.contains(entry.id);
                  final full =
                      !checked && _selected.length >= maxForwardMessages;
                  return CheckboxListTile(
                    key: ValueKey('forward-select-${entry.id}'),
                    value: checked,
                    activeColor: p.accent,
                    side: BorderSide(color: p.muted, width: 1.6),
                    onChanged: full ? null : (_) => _toggle(entry),
                    title: Text(
                      entry.senderLabel,
                      style: TextStyle(
                        color: p.foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      messagePreviewText(entry),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.muted),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: AccentButton(
                palette: p,
                icon: Icons.check_rounded,
                label: 'Done',
                onPressed: _selected.isEmpty
                    ? null
                    : () => Navigator.pop(context, [
                        for (final entry in widget.entries)
                          if (_selected.contains(entry.id)) entry,
                      ]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
