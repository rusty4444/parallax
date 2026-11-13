import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../chat_backend.dart';
import 'link_previews.dart';

/// Lazy native player for a link preview. No network request is made until
/// the user taps Play; leaving the message releases the controller.
class LinkVideoPlayer extends StatefulWidget {
  const LinkVideoPlayer({
    super.key,
    required this.video,
    required this.backend,
    this.poster,
    this.onFullScreen,
    this.autoPlay = false,
  });

  final LinkVideo video;
  final ChatBackend backend;
  final Uri? poster;
  final VoidCallback? onFullScreen;
  final bool autoPlay;

  @override
  State<LinkVideoPlayer> createState() => _LinkVideoPlayerState();
}

/// Opens the same native player in a full-screen route.
Future<void> showLinkVideoFullScreen(
  BuildContext context,
  LinkVideo video,
  ChatBackend backend, {
  Uri? poster,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(
          tooltip: 'Close full screen video',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: LinkVideoPlayer(
            video: video,
            backend: backend,
            poster: poster,
            autoPlay: true,
          ),
        ),
      ),
    ),
  ),
);

class _LinkVideoPlayerState extends State<LinkVideoPlayer> {
  VideoPlayerController? _controller;
  Future<Uint8List?>? _posterBytes;
  bool _starting = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _loadPoster();
    if (widget.autoPlay) unawaited(_start());
  }

  void _loadPoster() {
    final poster = widget.poster;
    _posterBytes = poster == null ? null : widget.backend.loadAvatar(poster);
  }

  @override
  void didUpdateWidget(LinkVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.video.url != widget.video.url) {
      unawaited(_disposeController());
      _failed = false;
      _starting = false;
    }
    if (oldWidget.poster != widget.poster) _loadPoster();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _failed = false;
    });
    final controller = VideoPlayerController.networkUrl(
      widget.video.url,
      videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: false),
    );
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      controller
        ..removeListener(_changed)
        ..addListener(_changed);
      await controller.play();
      if (mounted) setState(() => _starting = false);
    } catch (_) {
      await controller.dispose();
      if (mounted) {
        setState(() {
          _controller = null;
          _starting = false;
          _failed = true;
        });
      }
    }
  }

  Future<void> _toggle() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return _start();
    }
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
    if (mounted) setState(() {});
  }

  Future<void> _openFullScreen() async {
    final controller = _controller;
    if (controller?.value.isPlaying == true) await controller!.pause();
    widget.onFullScreen?.call();
  }

  Future<void> _disposeController() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    controller.removeListener(_changed);
    await controller.pause();
    await controller.dispose();
  }

  @override
  void dispose() {
    unawaited(_disposeController());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller?.value.isInitialized == true;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (ready)
              Center(
                child: AspectRatio(
                  aspectRatio: controller!.value.aspectRatio,
                  child: VideoPlayer(controller),
                ),
              )
            else
              _Poster(bytes: _posterBytes),
            if (_starting)
              const Center(child: CircularProgressIndicator())
            else if (_failed)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Couldn’t play this video. Open the link instead.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              )
            else
              Center(
                child: IconButton.filled(
                  tooltip: ready && controller!.value.isPlaying
                      ? 'Pause video'
                      : 'Play video',
                  onPressed: _toggle,
                  icon: Icon(
                    ready && controller!.value.isPlaying
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    size: 34,
                  ),
                ),
              ),
            if (widget.onFullScreen != null)
              Positioned(
                top: 4,
                right: 4,
                child: IconButton.filledTonal(
                  tooltip: 'Full screen video',
                  onPressed: _openFullScreen,
                  icon: const Icon(Icons.fullscreen_rounded),
                ),
              ),
            if (ready)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: VideoProgressIndicator(
                  controller!,
                  allowScrubbing: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Poster extends StatelessWidget {
  const _Poster({required this.bytes});
  final Future<Uint8List?>? bytes;

  @override
  Widget build(BuildContext context) {
    final future = bytes;
    if (future == null) return const SizedBox.expand();
    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null || data.isEmpty) return const SizedBox.expand();
        return Image.memory(data, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }
}
