import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../chat_backend.dart';
import '../../media_player_owner.dart';
import '../media/media_content.dart';
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
  double get aspectRatio {
    final v = _controller.value;
    if (v.isInitialized) {
      final corrected = videoDisplayAspectRatio(v.size);
      if (corrected != null) return corrected;
    }
    return v.aspectRatio;
  }

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
    this.posterLoader,
    this.initialAspectRatio,
    this.fullScreen = false,
    this.onFullScreen,
    this.autoPlay = false,
    this.controllerFactory = createNetworkLinkVideoController,
  });

  final LinkVideo video;
  final ChatBackend backend;
  final Uri? poster;
  final Future<Uint8List?> Function(Uri)? posterLoader;
  final double? initialAspectRatio;
  final bool fullScreen;
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
  Future<Uint8List?> Function(Uri)? posterLoader,
  double? initialAspectRatio,
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
            posterLoader: posterLoader,
            initialAspectRatio: initialAspectRatio,
            fullScreen: true,
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
  double? _posterAspect;
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
    _posterAspect = null;
    final loader = widget.posterLoader ?? widget.backend.loadAvatar;
    _posterBytes = poster == null ? null : loader(poster);
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
    if (oldWidget.poster != widget.poster ||
        oldWidget.posterLoader != widget.posterLoader) {
      _loadPoster();
    }
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

  double _effectiveAspectRatio() {
    final controller = _controller;
    if (controller != null && controller.isInitialized) {
      final ratio = controller.aspectRatio;
      if (ratio.isFinite && ratio > 0) return ratio;
    }
    final declared = widget.initialAspectRatio;
    final poster = _posterAspect;
    if (poster != null &&
        poster.isFinite &&
        poster > 0 &&
        (declared == null ||
            !declared.isFinite ||
            declared <= 0 ||
            (declared > 1) != (poster > 1))) {
      return poster;
    }
    if (declared != null && declared.isFinite && declared > 0) {
      return declared;
    }
    return 16 / 9;
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready = controller?.isInitialized == true;
    final playing = _activelyPlaying;
    final rawAspect = _effectiveAspectRatio();
    final boxAspect = widget.fullScreen
        ? rawAspect.clamp(0.2, 5.0)
        : rawAspect.clamp(9 / 16, 21 / 9);
    return AspectRatio(
      aspectRatio: boxAspect,
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
              _Poster(
                bytes: _posterBytes,
                fit: widget.fullScreen ? BoxFit.contain : BoxFit.cover,
                onImageSize: (imgSize) {
                  final ratio = imgSize.width / imgSize.height;
                  if (ratio.isFinite && ratio > 0 && _posterAspect != ratio) {
                    setState(() => _posterAspect = ratio);
                  }
                },
              ),
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

class _Poster extends StatefulWidget {
  const _Poster({
    required this.bytes,
    this.fit = BoxFit.cover,
    this.onImageSize,
  });
  final Future<Uint8List?>? bytes;
  final BoxFit fit;
  final ValueChanged<Size>? onImageSize;

  @override
  State<_Poster> createState() => _PosterState();
}

class _PosterState extends State<_Poster> {
  Uint8List? _sizedBytes;
  ImageStream? _sizeStream;
  ImageStreamListener? _sizeListener;

  void _untrackSize() {
    final stream = _sizeStream;
    final listener = _sizeListener;
    _sizeStream = null;
    _sizeListener = null;
    if (stream != null && listener != null) {
      stream.removeListener(listener);
    }
  }

  @override
  void didUpdateWidget(_Poster oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bytes != widget.bytes) {
      _untrackSize();
      _sizedBytes = null;
    }
  }

  @override
  void dispose() {
    _untrackSize();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final future = widget.bytes;
    if (future == null) return const SizedBox.expand();
    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null || data.isEmpty) return const SizedBox.expand();
        final provider = boundedMemoryImage(data, maxEdge: 768);
        if (widget.onImageSize != null && !identical(_sizedBytes, data)) {
          _untrackSize();
          _sizedBytes = data;
          final stream = provider.resolve(ImageConfiguration.empty);
          late final ImageStreamListener listener;
          listener = ImageStreamListener((info, _) {
            final w = info.image.width.toDouble();
            final h = info.image.height.toDouble();
            _untrackSize();
            if (mounted && w > 0 && h > 0) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) widget.onImageSize?.call(Size(w, h));
              });
            }
          }, onError: (_, _) => _untrackSize());
          _sizeStream = stream;
          _sizeListener = listener;
          stream.addListener(listener);
        }
        return Image(image: provider, fit: widget.fit, gaplessPlayback: true);
      },
    );
  }
}
