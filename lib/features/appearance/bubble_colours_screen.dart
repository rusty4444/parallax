import 'package:flutter/material.dart';

import '../../app_theme.dart';
import 'bubble_colours.dart';
import 'room_theme_sync.dart';
import 'colour_picker.dart';

/// Per-room bubble colours: your messages and everyone else's, each with a
/// bubble and a text colour, previewed live and saved as you change them.
class BubbleColoursScreen extends StatefulWidget {
  BubbleColoursScreen({
    super.key,
    required this.roomId,
    required this.roomName,
    required this.palette,
    RoomBubbleColourStore? store,
    this.themeSync,
  }) : store = store ?? _shared;

  static final _shared = RoomBubbleColourStore.shared;

  final String roomId;
  final String roomName;
  final AppPalette palette;
  final RoomBubbleColourStore store;

  /// When set, the chosen colours also sync to the account's other devices.
  final RoomThemeSync? themeSync;

  @override
  State<BubbleColoursScreen> createState() => _BubbleColoursScreenState();
}

enum _Side { mine, theirs }

class _BubbleColoursScreenState extends State<BubbleColoursScreen> {
  BubbleColours _colours = BubbleColours.none;
  bool _loaded = false;
  _Side _side = _Side.mine;
  Future<void> _saving = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _colours = widget.store.cached(widget.roomId) ?? BubbleColours.none;
    _loaded = widget.store.cached(widget.roomId) != null;
    widget.store.load(widget.roomId).then((colours) {
      if (!mounted || _loaded) return;
      setState(() {
        _colours = colours;
        _loaded = true;
      });
    });
  }

  void _update(BubbleColours colours) {
    setState(() {
      _colours = colours;
      _loaded = true;
    });
    // Serialised so a slider drag can't save an older colour last.
    _saving = _saving.then((_) async {
      try {
        await widget.store.save(widget.roomId, colours);
        // Uploads in the background; offline, it goes once back online.
        await widget.themeSync
            ?.coloursChanged(widget.roomId)
            .catchError((Object _) {});
      } catch (_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couldn’t save the colours. Try again.'),
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.palette;
    final applied = _colours.apply(base);
    final mine = _side == _Side.mine;
    final bubble = mine ? _colours.mine : _colours.theirs;
    final text = mine ? _colours.mineText : _colours.theirsText;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bubble colours'),
        actions: [
          TextButton(
            key: const ValueKey('bubble-colours-reset'),
            onPressed: _colours.isEmpty
                ? null
                : () => _update(BubbleColours.none),
            child: const Text('Reset'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'For ${widget.roomName}. Colours sync across your devices.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _Preview(palette: applied, background: base.background),
          const SizedBox(height: 16),
          SegmentedButton<_Side>(
            segments: const [
              ButtonSegment(
                value: _Side.mine,
                label: Text('Your messages'),
                icon: Icon(Icons.person_outline),
              ),
              ButtonSegment(
                value: _Side.theirs,
                label: Text('Their messages'),
                icon: Icon(Icons.people_outline),
              ),
            ],
            selected: {_side},
            onSelectionChanged: (value) => setState(() => _side = value.first),
          ),
          const SizedBox(height: 16),
          Text('Bubble', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ColourPicker(
            key: ValueKey('bubble-${_side.name}'),
            value: bubble,
            fallback: mine ? base.bubble : base.surface,
            defaultLabel: 'Theme colour',
            onChanged: (colour) => _update(
              mine
                  ? _colours.copyWith(mine: () => colour)
                  : _colours.copyWith(theirs: () => colour),
            ),
          ),
          const SizedBox(height: 24),
          Text('Text', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Automatic picks black or white, whichever reads best.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          ColourPicker(
            key: ValueKey('text-${_side.name}'),
            value: text,
            fallback: mine ? applied.bubbleText : applied.foreground,
            defaultLabel: 'Automatic',
            swatches: const [
              Color(0xFFFFFFFF),
              Color(0xFFF5F5F5),
              Color(0xFFE4E6EB),
              Color(0xFF141414),
              Color(0xFF050505),
              Color(0xFF3A3B3C),
              Color(0xFFFFE082),
              Color(0xFFB3E5FC),
            ],
            onChanged: (colour) => _update(
              mine
                  ? _colours.copyWith(mineText: () => colour)
                  : _colours.copyWith(theirsText: () => colour),
            ),
          ),
        ],
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.palette, required this.background});
  final AppPalette palette;
  final Color background;

  @override
  Widget build(BuildContext context) {
    Widget bubble(String text, {required bool mine}) => Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        decoration: BoxDecoration(
          color: mine ? palette.bubble : palette.surface,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(19),
            topRight: const Radius.circular(19),
            bottomLeft: Radius.circular(mine ? 19 : 5),
            bottomRight: Radius.circular(mine ? 5 : 19),
          ),
          border: mine ? null : Border.all(color: palette.stroke),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              text,
              style: TextStyle(
                color: mine ? palette.bubbleText : palette.foreground,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '9:41 am',
              style: TextStyle(
                fontSize: 10,
                color: mine
                    ? palette.bubbleText.withValues(alpha: 0.77)
                    : palette
                          .inkOn(palette.surface, text: palette.foreground)
                          .muted,
              ),
            ),
          ],
        ),
      ),
    );
    return Container(
      key: const ValueKey('bubble-colours-preview'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.stroke),
      ),
      child: Column(
        children: [
          bubble('Are we still on for Saturday?', mine: false),
          bubble('Yes! See you at 10 👋', mine: true),
        ],
      ),
    );
  }
}
