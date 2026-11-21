import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_theme.dart';
import 'stories.dart';

/// Full-screen, tap-through story viewer with 24-hour expiry.
class StoryViewerScreen extends StatefulWidget {
  const StoryViewerScreen({
    super.key,
    required this.controller,
    required this.room,
    required this.palette,
  });

  final StoriesController controller;
  final StoryRoom room;
  final AppPalette palette;

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> {
  final _pageController = PageController();
  List<Story>? _stories;
  int _index = 0;
  Timer? _advance;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _advance?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final stories = await widget.controller.activeStories(widget.room.roomId);
      if (!mounted) return;
      setState(() => _stories = stories);
      _armAdvance();
    } catch (_) {
      if (mounted) setState(() => _error = 'Couldn’t load stories.');
    }
  }

  void _armAdvance() {
    _advance?.cancel();
    final stories = _stories;
    if (stories == null || stories.isEmpty) return;
    _advance = Timer(const Duration(seconds: 6), () {
      if (!mounted) return;
      if (_index < stories.length - 1) {
        _pageController.nextPage(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      } else {
        Navigator.pop(context);
      }
    });
  }

  void _onPageChanged(int index) {
    setState(() => _index = index);
    _armAdvance();
  }

  void _tapLeft() {
    if (_index > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  void _tapRight() {
    final stories = _stories;
    if (stories == null) return;
    if (_index < stories.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stories = _stories;
    return Scaffold(
      backgroundColor: Colors.black,
      body: stories == null
          ? Center(
              child: _error != null
                  ? Text(_error!, style: const TextStyle(color: Colors.white70))
                  : const CircularProgressIndicator(color: Colors.white),
            )
          : stories.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'No active stories',
                    style: TextStyle(color: Colors.white, fontSize: 18),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close'),
                  ),
                ],
              ),
            )
          : Stack(
              children: [
                PageView.builder(
                  controller: _pageController,
                  itemCount: stories.length,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, index) => _StoryPage(
                    controller: widget.controller,
                    room: widget.room,
                    story: stories[index],
                  ),
                ),
                // Tap zones.
                Positioned.fill(
                  child: Row(
                    children: [
                      Expanded(child: GestureDetector(onTap: _tapLeft)),
                      Expanded(child: GestureDetector(onTap: _tapRight)),
                    ],
                  ),
                ),
                // Progress bars + header.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              for (var i = 0; i < stories.length; i++)
                                Expanded(
                                  child: Container(
                                    height: 3,
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: i <= _index
                                          ? Colors.white
                                          : Colors.white24,
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  widget.room.name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              IconButton(
                                key: const ValueKey('story-close'),
                                onPressed: () => Navigator.pop(context),
                                icon: const Icon(
                                  Icons.close,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _StoryPage extends StatelessWidget {
  const _StoryPage({
    required this.controller,
    required this.room,
    required this.story,
  });
  final StoriesController controller;
  final StoryRoom room;
  final Story story;

  @override
  Widget build(BuildContext context) {
    final imageUrl = story.imageUrl;
    if (imageUrl != null) {
      return FutureBuilder(
        future: controller.storyImageBytes(room.roomId, story.eventId),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (bytes != null)
                Image.memory(bytes, fit: BoxFit.contain)
              else
                const ColoredBox(color: Color(0xFF111111)),
              if (story.text.trim().isNotEmpty)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 48,
                  child: Text(
                    story.text,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      shadows: [Shadow(blurRadius: 8, color: Colors.black)],
                    ),
                  ),
                ),
            ],
          );
        },
      );
    }
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF7A1FA2), Color(0xFFE65100)],
        ),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: Text(
        story.text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 26,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}
