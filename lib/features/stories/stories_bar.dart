import 'package:flutter/material.dart';

import '../../app_theme.dart';
import '../../chat_backend.dart';
import 'post_story_screen.dart';
import 'stories.dart';
import 'story_viewer_screen.dart';

/// Horizontal story rings shown at the top of the inbox (opt-in).
class StoriesBar extends StatefulWidget {
  const StoriesBar({
    super.key,
    required this.backend,
    required this.controller,
    required this.palette,
  });

  final ChatBackend backend;
  final StoriesController controller;
  final AppPalette palette;

  @override
  State<StoriesBar> createState() => _StoriesBarState();
}

class _StoriesBarState extends State<StoriesBar> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _openPost() async {
    final posted = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => PostStoryScreen(
          controller: widget.controller,
          palette: widget.palette,
        ),
      ),
    );
    if (posted == true && mounted) setState(() {});
  }

  void _openViewer(StoryRoom room) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => StoryViewerScreen(
          controller: widget.controller,
          room: room,
          palette: widget.palette,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final rooms = widget.controller.storyRooms();
    return SizedBox(
      height: 96,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _AddStoryRing(palette: p, onTap: _openPost),
          for (final room in rooms)
            _StoryRing(
              key: ValueKey('story-ring-${room.roomId}'),
              room: room,
              palette: p,
              onTap: () => _openViewer(room),
            ),
        ],
      ),
    );
  }
}

class _AddStoryRing extends StatelessWidget {
  const _AddStoryRing({required this.palette, required this.onTap});
  final AppPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: GestureDetector(
        key: const ValueKey('story-add'),
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: p.raised,
              foregroundColor: p.secondary,
              child: const Icon(Icons.add_rounded, size: 28),
            ),
            const SizedBox(height: 4),
            Text('Add story', style: TextStyle(color: p.muted, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

class _StoryRing extends StatelessWidget {
  const _StoryRing({
    super.key,
    required this.room,
    required this.palette,
    required this.onTap,
  });
  final StoryRoom room;
  final AppPalette palette;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [p.accent, p.secondary]),
              ),
              child: CircleAvatar(
                radius: 26,
                backgroundColor: p.surface,
                foregroundColor: p.foreground,
                child: Text(
                  room.name.characters.first.toUpperCase(),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: 64,
              child: Text(
                room.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(color: p.muted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
