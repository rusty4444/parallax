import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../chat_backend.dart';
import 'link_previews.dart';

typedef LinkVideoControllerFactory = LinkVideoController Function(Uri url);

/// Minimal surface over [VideoPlayerController] so widget tests can drive
/// inline link-preview playback deterministically without platform channels.
abstract class LinkVideoController implements Listenable {
  bool get isInitialized;
  bool get isPlaying;
  double get aspectRatio;
  Duration get duration;
  Duration get position;

  Future<void> initialize();
  Future<void> play();
  Future<void> pause();
  Future<void> seekTo(Duration position);
  Future<void> dispose();
  Widget buildVideo(BuildContext context);
  Widget buildProgress(BuildContext context);
}

LinkVideoController createNetworkLinkVideoController(Uri url) =>
    _NetworkLinkVideoController(url);

class _NetworkLinkVideoController implements LinkVideoController {
  _NetworkLinkVideoController(Uri url)
    : _controller = VideoPlayerController.networkUrl(
        url,
        videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: false),
      );

  final VideoPlayerController _controller;

  @override
  void addListener(VoidCallback listener) => _controller.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _controller.removeListener(listener);

  @override
  bool get isInitialized => _controller.value.isInitialized;

  @override
  bool get isPlaying => _controller.value.isPlaying;

  @override
  double get aspectRatio => _controller.value.aspectRatio;

  @override
  Duration get duration => _controller.value.duration;

  @override
  Duration get position => _controller.value.position;

  @override
  Future<void> initialize() => _controller.initialize();

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> seekTo(Duration position) => _controller.seekTo(position);

  @override
  Future<void> dispose() => _controller.dispose();

  @override
  Widget buildVideo(BuildContext context) => VideoPlayer(_controller);

  @override
  Widget buildProgress(BuildContext context) => VideoProgressIndicator(
    _controller,
    allowScrubbing: true,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
  );
}

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
    this.controllerFactory = createNetworkLinkVideoController,
  });

  final LinkVideo video;
  final ChatBackend backend;
  final Uri? poster;
  final VoidCallback? onFullScreen;
  final bool autoPlay;
  final LinkVideoControllerFactory controllerFactory;

  @override
  State<LinkVideoPlayer> createState() => _LinkVideoPlayerState();
}

/// Opens the same native player in a full-screen route.
Future<void> showLinkVideoFullScreen(
  BuildContext context,
  LinkVideo video,
  ChatBackend backend, {
  Uri? poster,
  LinkVideoControllerFactory controllerFactory =
      createNetworkLinkVideoController,
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
            controllerFactory: controllerFactory,
          ),
        ),
      ),
    ),
  ),
);

class _LinkVideoPlayerState extends State<LinkVideoPlayer>
    with SingleTickerProviderStateMixin {
  static const _controlsFadeTotal = Duration(milliseconds: 800);

  late final AnimationController _controlsFade = AnimationController(
    vsync: this,
    duration: _controlsFadeTotal,
  );
  late final Animation<double> _controlsOpacity =
      Tween<double>(begin: 1, end: 0).animate(
        CurvedAnimation(
          parent: _controlsFade,
          curve: const Interval(0.55, 1, curve: Curves.easeOut),
        ),
      );
  LinkVideoController? _controller;
  Future<Uint8List?>? _posterBytes;
  bool _starting = false;
  bool _failed = false;
  bool _wasPlaying = false;

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
      _wasPlaying = false;
      _controlsFade.value = 0;
    }
    if (oldWidget.poster != widget.poster) _loadPoster();
  }

  bool get _activelyPlaying =>
      !_starting &&
      (_controller?.isInitialized == true) &&
      (_controller?.isPlaying == true);

  void _syncControlsFade() {
    final playing = _activelyPlaying;
    if (playing == _wasPlaying) return;
    _wasPlaying = playing;
    if (playing) {
      _controlsFade.forward(from: 0);
    } else {
      _controlsFade.value = 0;
    }
  }

  void _changed() {
    if (!mounted) return;
    _syncControlsFade();
    setState(() {});
  }

  Future<void> _start() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _failed = false;
      _syncControlsFade();
    });
    final controller = widget.controllerFactory(widget.video.url);
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted || !identical(_controller, controller)) {
        await controller.dispose();
        return;
      }
      controller
        ..removeListener(_changed)
        ..addListener(_changed);
      await controller.play();
      if (!mounted || !identical(_controller, controller)) {
        controller.removeListener(_changed);
        await controller.dispose();
        return;
      }
      setState(() {
        _starting = false;
        _syncControlsFade();
      });
    } catch (_) {
      controller.removeListener(_changed);
      await controller.dispose();
      if (mounted && identical(_controller, controller)) {
        setState(() {
          _controller = null;
          _starting = false;
          _failed = true;
          _syncControlsFade();
        });
      }
    }
  }

  Future<void> _toggle() async {
    final controller = _controller;
    if (controller == null || !controller.isInitialized) {
      return _start();
    }
    if (controller.isPlaying) {
      await controller.pause();
    } else {
      if (controller.duration > Duration.zero &&
          controller.position >= controller.duration) {
        await controller.seekTo(Duration.zero);
      }
      await controller.play();
    }
    if (mounted && identical(_controller, controller)) {
      _syncControlsFade();
      setState(() {});
    }
  }

  Future<void> _openFullScreen() async {
    final controller = _controller;
    if (controller?.isPlaying == true) await controller!.pause();
    if (mounted) _syncControlsFade();
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
    _controlsFade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller?.isInitialized == true;
    final playing = _activelyPlaying;
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
                  aspectRatio: controller!.aspectRatio,
                  child: controller.buildVideo(context),
                ),
              )
            else
              _Poster(bytes: _posterBytes),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggle,
              ),
            ),
            if (_starting)
              const IgnorePointer(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_failed)
              const IgnorePointer(
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Couldn’t play this video. Open the link instead.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              )
            else
              Center(
                child: AnimatedBuilder(
                  animation: _controlsOpacity,
                  builder: (context, child) {
                    final opacity = playing ? _controlsOpacity.value : 1.0;
                    return IgnorePointer(
                      ignoring: opacity == 0,
                      child: Opacity(opacity: opacity, child: child),
                    );
                  },
                  child: IconButton.filled(
                    tooltip: playing ? 'Pause video' : 'Play video',
                    onPressed: _toggle,
                    icon: Icon(
                      playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      size: 34,
                    ),
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
                child: controller!.buildProgress(context),
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
