import 'dart:async';

import 'package:flutter/material.dart';

import 'chat_backend.dart';
import 'features/media/animated_media_image.dart';
import 'media_player_owner.dart';
import 'messaging_features.dart';

export 'features/media/media_viewer_pager.dart'
    show openMediaViewer, MediaViewerPager, MediaViewerItem;

export 'media_player_owner.dart'
    show MediaLoader, MediaFileFactory, MediaPlayerFactory, MediaImageDecoder;

/// Original attachment viewer. Factories are injectable: widget tests never
/// need platform channels or real filesystem work in a fake-async zone.
class MediaViewer extends StatefulWidget {
  const MediaViewer({
    super.key,
    required this.backend,
    required this.roomId,
    required this.eventId,
    this.loader,
    this.fileFactory = createMediaTempFile,
    this.playerFactory = createNativeMediaPlayer,
    this.imageDecoder = decodeMediaImage,
    this.initializationTimeout = const Duration(seconds: 20),
    this.embedded = false,
    this.onCleanup,
    this.onZoomChanged,
  });
  final ChatBackend backend;
  final String roomId;
  final String eventId;
  final MediaLoader? loader;
  final MediaFileFactory fileFactory;
  final MediaPlayerFactory playerFactory;
  final MediaImageDecoder imageDecoder;
  final Duration initializationTimeout;

  /// A page inside [MediaViewerPager]: no route chrome or pop handling of its
  /// own; the pager owns the app bar and joins [onCleanup] futures.
  final bool embedded;

  /// Receives every resource cleanup this viewer starts, so an owner (the
  /// pager route) can join native disposal before temp files disappear.
  final void Function(Future<void> cleanup)? onCleanup;

  /// Reports whether the image is zoomed in (the pager locks swiping).
  final ValueChanged<bool>? onZoomChanged;

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

/// Joins a viewer page's cleanup. Used by [MediaViewerPager].
Future<void>? shutdownMediaViewerPage(GlobalKey key) {
  final state = key.currentState;
  return state is _MediaViewerState ? state._shutdown() : null;
}

class _MediaViewerState extends State<MediaViewer> with WidgetsBindingObserver {
  final _transform = TransformationController();
  bool _zoomed = false;
  MediaPlayerOwner? _owner;
  MediaPlaybackController? _listeningPlayer;
  Object? _identity;
  bool _loading = true;
  bool _failed = false;
  bool _ended = false;
  bool _foreground = true;
  int _generation = 0;

  Object? _accountIdentity() {
    final backend = widget.backend;
    return (
      backend.userId,
      backend is MessagingFeatures
          ? (backend as MessagingFeatures).accountKey
          : null,
    );
  }

  bool get _sessionValid =>
      widget.backend.userId != null &&
      widget.backend.connection != SessionStatus.signedOut &&
      _accountIdentity() == _identity;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _identity = _accountIdentity();
    widget.backend.addListener(_sessionChanged);
    _transform.addListener(_transformChanged);
    if (_sessionValid) {
      unawaited(_load());
    } else {
      _ended = true;
      _loading = false;
    }
  }

  @override
  void didUpdateWidget(covariant MediaViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend != widget.backend) {
      oldWidget.backend.removeListener(_sessionChanged);
      widget.backend.addListener(_sessionChanged);
    }
    if (oldWidget.backend != widget.backend ||
        oldWidget.roomId != widget.roomId ||
        oldWidget.eventId != widget.eventId ||
        oldWidget.loader != widget.loader) {
      _generation++;
      _detachPlayer();
      final owner = _owner;
      if (owner != null) _observeCleanup(owner.close());
      _owner = null;
      _identity = _accountIdentity();
      _ended = !_sessionValid;
      if (!_ended) unawaited(_load());
    }
  }

  void _sessionChanged() {
    if (_ended || _sessionValid) return;
    _generation++;
    _ended = true; // Never revive this viewer if the old account logs in again.
    _loading = false;
    _detachPlayer();
    final owner = _owner;
    if (owner != null) _observeCleanup(owner.close());
    if (mounted) setState(() {});
  }

  void _detachPlayer() {
    _listeningPlayer?.removeListener(_playerChanged);
    _listeningPlayer = null;
  }

  void _transformChanged() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    _zoomed = zoomed;
    widget.onZoomChanged?.call(zoomed);
  }

  void _observeCleanup(Future<void> cleanup) {
    widget.onCleanup?.call(cleanup);
    unawaited(
      cleanup.catchError((Object error, StackTrace stack) {
        // Never include the decrypted file's path or server error in user-facing
        // text. Disposal failure retains the file rather than unsafe deletion.
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: StateError('Media resource cleanup failed.'),
            stack: stack,
            library: 'media viewer',
          ),
        );
      }),
    );
  }

  Future<void> _shutdown() {
    _generation++;
    _ended = true;
    _detachPlayer();
    final cleanup = _owner?.close() ?? Future<void>.value();
    _observeCleanup(cleanup);
    return cleanup;
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _loading = true;
    _failed = false;
    _detachPlayer();
    if (mounted) setState(() {});
    final previous = _owner;
    if (previous != null) {
      try {
        await previous.close();
      } catch (_) {
        if (mounted && generation == _generation) {
          setState(() {
            _loading = false;
            _failed = true;
          });
        }
        return;
      }
    }
    if (!mounted || _ended || generation != _generation || !_sessionValid) {
      return;
    }
    final owner = MediaPlayerOwner(
      loader:
          widget.loader ??
          () => widget.backend.loadAttachment(widget.roomId, widget.eventId),
      fileFactory: widget.fileFactory,
      playerFactory: widget.playerFactory,
      imageDecoder: widget.imageDecoder,
      initializationTimeout: widget.initializationTimeout,
    );
    _owner = owner;
    try {
      await owner.load();
      if (!mounted || _ended || generation != _generation || !_sessionValid) {
        _observeCleanup(owner.close());
        return;
      }
      _listeningPlayer = owner.player;
      _listeningPlayer?.addListener(_playerChanged);
      setState(() {
        _loading = false;
      });
      if (_listeningPlayer?.value.error != null) _playerChanged();
      if (!_foreground) _runCommand(owner.pause);
    } catch (_) {
      _observeCleanup(owner.close());
      if (!mounted || _ended || generation != _generation) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _playerChanged() {
    if (!mounted || _ended) return;
    if (_listeningPlayer?.value.error != null) {
      // Native callbacks may arrive during layout/build; defer UI mutation.
      scheduleMicrotask(() {
        if (mounted && !_ended && _listeningPlayer?.value.error != null) {
          _failPlayback();
        }
      });
    } else {
      setState(() {});
    }
  }

  void _failPlayback() {
    _detachPlayer();
    final owner = _owner;
    if (owner != null) _observeCleanup(owner.close());
    setState(() {
      _loading = false;
      _failed = true;
    });
  }

  void _runCommand(Future<void> Function() command) {
    final generation = _generation;
    unawaited(
      command().catchError((Object error, StackTrace stack) {
        if (mounted && !_ended && generation == _generation) _failPlayback();
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      final owner = _owner;
      if (owner != null) _runCommand(owner.pause);
    }
    // Deliberately do not auto-resume private media.
  }

  @override
  void dispose() {
    widget.backend.removeListener(_sessionChanged);
    WidgetsBinding.instance.removeObserver(this);
    _shutdown();
    _transform.removeListener(_transformChanged);
    _transform.dispose();
    super.dispose();
  }

  String _time(Duration duration) {
    final seconds = duration.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Widget _content() {
    if (_ended) {
      return const Center(child: Text('This media session has ended.'));
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.broken_image_outlined, size: 48),
              const SizedBox(height: 16),
              const Text('Could not open media.'),
              const SizedBox(height: 8),
              const Text(
                'The file may be unavailable, too large, or unsupported on this device.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => unawaited(_load()),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final owner = _owner!;
    final image = owner.image;
    if (image != null) {
      final label = 'Image: ${owner.name ?? 'Attachment'}. Pinch to zoom.';
      final animated = owner.animatedSource;
      return Center(
        child: InteractiveViewer(
          transformationController: _transform,
          minScale: 1,
          maxScale: 8,
          child: animated == null
              ? Semantics(
                  label: label,
                  image: true,
                  child: RawImage(image: image, fit: BoxFit.contain),
                )
              : AnimatedMediaImage(
                  bytes: animated,
                  poster: image,
                  semanticLabel: label,
                ),
        ),
      );
    }
    final player = owner.player;
    if (player == null) return const SizedBox.shrink();
    final value = player.value;
    final duration = value.duration.inMilliseconds.clamp(0, 1 << 53).toDouble();
    final position = value.position.inMilliseconds.toDouble().clamp(
      0.0,
      duration,
    );
    return Column(
      children: [
        Expanded(
          child: Center(
            child: owner.mimeType!.startsWith('video/')
                ? player.buildVideo(context)
                : const Icon(Icons.audio_file_outlined, size: 96),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Slider(
                value: position,
                max: duration > 0 ? duration : 1,
                onChanged: duration > 0
                    ? (value) => _runCommand(
                        () => owner.seek(Duration(milliseconds: value.round())),
                      )
                    : null,
                semanticFormatterCallback: (value) =>
                    _time(Duration(milliseconds: value.round())),
              ),
              Row(
                children: [
                  IconButton(
                    tooltip: value.playing ? 'Pause' : 'Play',
                    iconSize: 40,
                    onPressed: () {
                      if (!value.playing && !_foreground) return;
                      _runCommand(value.playing ? owner.pause : owner.play);
                    },
                    icon: Icon(
                      value.playing ? Icons.pause_circle : Icons.play_circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text('${_time(value.position)} / ${_time(value.duration)}'),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => widget.embedded
      ? _content()
      : PopScope<void>(
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) {
              _shutdown();
              if (mounted) setState(() {});
            }
          },
          child: Scaffold(
            appBar: AppBar(
              leading: IconButton(
                tooltip: 'Close media',
                icon: const Icon(Icons.close),
                onPressed: () {
                  _shutdown();
                  setState(() {});
                  Navigator.of(context).maybePop();
                },
              ),
              title: Text(
                _ended ? 'Media' : _owner?.name ?? 'Media',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            body: SafeArea(child: _content()),
          ),
        );
}
