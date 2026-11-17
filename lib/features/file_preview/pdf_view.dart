import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../media_player_owner.dart';
import 'pdf_tools.dart';

/// A PDF in the media viewer: downloaded and decrypted in memory, opened by
/// the isolated renderer and shown page by page. [fallback] (the plain file
/// card) is shown when the file can't be read.
class PdfDocumentPage extends StatefulWidget {
  const PdfDocumentPage({
    super.key,
    required this.backend,
    required this.loader,
    required this.fallback,
  });
  final ChatBackend backend;
  final MediaLoader loader;
  final Widget fallback;

  @override
  State<PdfDocumentPage> createState() => _PdfDocumentPageState();
}

enum _Status { loading, ready, locked, failed, unreadable }

class _PdfDocumentPageState extends State<PdfDocumentPage> {
  late BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  _Status _status = _Status.loading;
  PdfDocument? _document;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(PdfDocumentPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend != widget.backend) {
      _owner.release();
      _owner = BackendSessionOwner(widget.backend);
    }
    if (oldWidget.backend != widget.backend ||
        oldWidget.loader != widget.loader) {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _generation++;
    _release();
    _owner.release();
    super.dispose();
  }

  void _release() {
    final document = _document;
    _document = null;
    if (document != null) unawaited(document.close());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final owner = _owner;
    _release();
    // Already the case on the first load, which runs from initState.
    if (mounted && _status != _Status.loading) {
      setState(() => _status = _Status.loading);
    }
    bool current() => mounted && generation == _generation && owner.isCurrent;
    final DownloadedAttachment file;
    try {
      file = await widget.loader();
    } catch (_) {
      if (current()) setState(() => _status = _Status.failed);
      return;
    }
    if (!current()) return;
    final PdfDocument document;
    try {
      document = await PdfTools.instance.open(file.bytes);
    } on PdfException catch (error) {
      if (current()) {
        setState(
          () => _status = error.failure == PdfFailure.passwordProtected
              ? _Status.locked
              : _Status.unreadable,
        );
      }
      return;
    } catch (_) {
      if (current()) setState(() => _status = _Status.unreadable);
      return;
    }
    if (!current()) {
      unawaited(document.close());
      return;
    }
    setState(() {
      _document = document;
      _status = _Status.ready;
    });
  }

  Widget _message(
    IconData icon,
    String title,
    String detail, {
    bool retry = false,
  }) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56),
          const SizedBox(height: 16),
          Text(title, textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(detail, textAlign: TextAlign.center),
          if (retry) ...[
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => unawaited(_load()),
              child: const Text('Retry'),
            ),
          ],
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!_owner.isCurrent) return const SizedBox.shrink();
    return switch (_status) {
      _Status.loading => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Opening PDF…'),
          ],
        ),
      ),
      _Status.failed => _message(
        Icons.picture_as_pdf_outlined,
        'Couldn’t load this file.',
        'Check your connection and try again.',
        retry: true,
      ),
      _Status.locked => _message(
        Icons.lock_outline_rounded,
        'This PDF is locked with a password.',
        'Save or share it to open it in another app.',
      ),
      _Status.unreadable => widget.fallback,
      _Status.ready => PdfDocumentView(document: _document!),
    };
  }
}

/// A request for one page image. Cancelled when its page scrolls away.
class _PageRequest {
  _PageRequest(this.index, this.width);
  final int index;
  final int width;
  bool cancelled = false;
  final done = Completer<ui.Image?>();
}

/// The pages of an open PDF in a scrolling column. Pinch or double-tap to
/// zoom; after zooming in, the pages in view are drawn again at a higher
/// resolution so small print stays sharp.
class PdfDocumentView extends StatefulWidget {
  const PdfDocumentView({super.key, required this.document});
  final PdfDocument document;

  static const _margin = 8.0;

  /// Widest a page is drawn, in pixels, at normal size and zoomed in.
  static const _maxWidth = 1600;
  static const _maxZoomedWidth = 2200;

  /// Most pixels asked for in one page (the renderer has its own limit).
  static const _maxPixels = 7000000;

  @override
  State<PdfDocumentView> createState() => _PdfDocumentViewState();
}

class _PdfDocumentViewState extends State<PdfDocumentView>
    with SingleTickerProviderStateMixin {
  final _scroll = ScrollController();
  final _transform = TransformationController();
  final _page = ValueNotifier<int>(0);
  late final AnimationController _zoom = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
  );
  Animation<Matrix4>? _zoomAnimation;
  Offset _doubleTapAt = Offset.zero;
  int _detail = 1;
  bool _disposed = false;

  final _queue = <_PageRequest>[];
  bool _rendering = false;

  /// Top edge of each page in the list, for the page counter.
  List<double> _tops = const [];
  double _layoutWidth = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updatePage);
    _zoom.addListener(() {
      final animation = _zoomAnimation;
      if (animation != null) _transform.value = animation.value;
    });
    _zoom.addStatusListener((status) {
      if (status == AnimationStatus.completed) _zoomSettled();
    });
  }

  @override
  void didUpdateWidget(PdfDocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.document, widget.document)) {
      for (final request in _queue) {
        request.cancelled = true;
      }
      _layoutWidth = 0;
      _transform.value = Matrix4.identity();
      _detail = 1;
      _page.value = 0;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final request in _queue) {
      request.cancelled = true;
      if (!request.done.isCompleted) request.done.complete(null);
    }
    _queue.clear();
    _zoom.dispose();
    _scroll.dispose();
    _transform.dispose();
    _page.dispose();
    super.dispose();
  }

  /// Height of page [index] when it is [width] wide. Extreme shapes are
  /// limited so one page can't be a sliver or a mile long.
  double _pageHeight(int index, double width) {
    final size = widget.document.pageSize(index);
    final ratio = (size.height / size.width).clamp(0.2, 5.0);
    return width * ratio;
  }

  void _layout(double width) {
    if (width == _layoutWidth) return;
    _layoutWidth = width;
    final pageWidth = math.max(1.0, width - 2 * PdfDocumentView._margin);
    final tops = List<double>.filled(widget.document.pageCount, 0);
    var top = PdfDocumentView._margin;
    for (var index = 0; index < tops.length; index++) {
      tops[index] = top;
      top += _pageHeight(index, pageWidth) + PdfDocumentView._margin;
    }
    _tops = tops;
  }

  void _updatePage() {
    if (!_scroll.hasClients || _tops.isEmpty) return;
    final position = _scroll.position;
    // Scrolled to the end, the last page is the one being read, however
    // little of the screen a short page takes up.
    if (position.maxScrollExtent > 0 &&
        position.pixels >= position.maxScrollExtent - 1) {
      _page.value = _tops.length - 1;
      return;
    }
    // Otherwise it is the page a third of the way down the screen.
    final at = position.pixels + position.viewportDimension / 3;
    var low = 0;
    var high = _tops.length - 1;
    while (low < high) {
      final middle = (low + high + 1) ~/ 2;
      if (_tops[middle] <= at) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    _page.value = low;
  }

  // --- Rendering, one page at a time, most recently asked first ------------

  _PageRequest _schedule(int index, int width) {
    final request = _PageRequest(index, width);
    _queue.add(request);
    unawaited(_pump());
    return request;
  }

  Future<void> _pump() async {
    if (_rendering || _disposed) return;
    _rendering = true;
    try {
      while (!_disposed && _queue.isNotEmpty) {
        // The page that just came into view matters more than one the
        // reader has already scrolled past.
        final request = _queue.removeLast();
        if (request.cancelled) {
          request.done.complete(null);
          continue;
        }
        ui.Image? image;
        try {
          image = await widget.document.render(
            request.index,
            width: request.width,
          );
        } catch (_) {
          image = null;
        }
        if (request.cancelled || _disposed) {
          image?.dispose();
          if (!request.done.isCompleted) request.done.complete(null);
        } else {
          request.done.complete(image);
        }
      }
    } finally {
      _rendering = false;
    }
  }

  // --- Zoom ----------------------------------------------------------------

  void _zoomSettled() {
    if (_disposed) return;
    final detail = _transform.value.getMaxScaleOnAxis() > 1.3 ? 2 : 1;
    if (detail != _detail) setState(() => _detail = detail);
  }

  void _toggleZoom() {
    const scale = 2.5;
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.05;
    final target = zoomed
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translateByDouble(
              -_doubleTapAt.dx * (scale - 1),
              -_doubleTapAt.dy * (scale - 1),
              0,
              1,
            )
            ..scaleByDouble(scale, scale, 1, 1));
    _zoomAnimation = Matrix4Tween(
      begin: _transform.value,
      end: target,
    ).animate(CurvedAnimation(parent: _zoom, curve: Curves.easeOut));
    unawaited(_zoom.forward(from: 0));
  }

  @override
  Widget build(BuildContext context) {
    final document = widget.document;
    return LayoutBuilder(
      builder: (context, constraints) {
        _layout(constraints.maxWidth);
        final pageWidth = math.max(
          1.0,
          constraints.maxWidth - 2 * PdfDocumentView._margin,
        );
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onDoubleTapDown: (details) =>
                    _doubleTapAt = details.localPosition,
                onDoubleTap: _toggleZoom,
                child: InteractiveViewer(
                  transformationController: _transform,
                  minScale: 1,
                  maxScale: 5,
                  onInteractionEnd: (_) => _zoomSettled(),
                  child: ListView.builder(
                    key: const ValueKey('document.pdf'),
                    controller: _scroll,
                    padding: const EdgeInsets.only(
                      top: PdfDocumentView._margin,
                    ),
                    itemCount: document.pageCount,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.fromLTRB(
                        PdfDocumentView._margin,
                        0,
                        PdfDocumentView._margin,
                        PdfDocumentView._margin,
                      ),
                      child: _PdfPage(
                        key: ValueKey(index),
                        index: index,
                        pageCount: document.pageCount,
                        width: pageWidth,
                        height: _pageHeight(index, pageWidth),
                        detail: _detail,
                        schedule: _schedule,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (document.pageCount > 1)
              Positioned(
                left: 0,
                right: 0,
                bottom: 14,
                child: IgnorePointer(
                  // Each page announces its own number to screen readers.
                  child: ExcludeSemantics(
                    child: Center(
                      child: ValueListenableBuilder<int>(
                        valueListenable: _page,
                        builder: (context, page, _) => Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.62),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            '${page + 1} / ${document.pageCount}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One page: white paper with its image once drawn. Asks for a sharper
/// image when [detail] goes up and keeps the one it has until that arrives.
class _PdfPage extends StatefulWidget {
  const _PdfPage({
    super.key,
    required this.index,
    required this.pageCount,
    required this.width,
    required this.height,
    required this.detail,
    required this.schedule,
  });
  final int index;
  final int pageCount;
  final double width;
  final double height;
  final int detail;
  final _PageRequest Function(int index, int width) schedule;

  @override
  State<_PdfPage> createState() => _PdfPageState();
}

class _PdfPageState extends State<_PdfPage> {
  ui.Image? _image;

  /// The width asked for when [_image] was drawn. The renderer may hand
  /// back fewer pixels than asked (it has a limit), so the image's own
  /// width can't say whether it is sharp enough.
  int _imageTarget = 0;
  _PageRequest? _request;
  bool _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensure();
  }

  @override
  void didUpdateWidget(_PdfPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensure();
  }

  @override
  void dispose() {
    _request?.cancelled = true;
    _request = null;
    _image?.dispose();
    _image = null;
    super.dispose();
  }

  /// Pixel width wanted for this page at the current zoom.
  int _target() {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    var width = (widget.width * ratio * widget.detail).round();
    width = math.min(
      width,
      widget.detail > 1
          ? PdfDocumentView._maxZoomedWidth
          : PdfDocumentView._maxWidth,
    );
    final shape = widget.height / widget.width;
    final byArea = math.sqrt(PdfDocumentView._maxPixels / shape).floor();
    return math.max(16, math.min(width, byArea));
  }

  void _ensure({bool retry = false}) {
    final target = _target();
    final image = _image;
    if (!retry && image != null && target <= _imageTarget * 1.15) return;
    final waiting = _request;
    if (waiting != null && waiting.width >= target) return;
    if (!retry && _failed && image == null && waiting == null) return;
    waiting?.cancelled = true;
    final request = widget.schedule(widget.index, target);
    _request = request;
    unawaited(
      request.done.future.then((drawn) {
        if (!mounted || !identical(_request, request)) {
          drawn?.dispose();
          return;
        }
        _request = null;
        final previous = _image;
        setState(() {
          if (drawn != null) {
            _image = drawn;
            _imageTarget = request.width;
          }
          _failed = drawn == null && _image == null;
        });
        if (drawn != null) previous?.dispose();
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final label = 'Page ${widget.index + 1}';
    return Semantics(
      label: '$label of ${widget.pageCount}',
      image: true,
      child: SizedBox(
        key: ValueKey('document.pdf.page.${widget.index}'),
        width: widget.width,
        height: widget.height,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            color: Colors.white,
            boxShadow: [BoxShadow(color: Color(0x33000000), blurRadius: 3)],
          ),
          child: image != null
              ? RawImage(
                  image: image,
                  // The box has the page's shape; a page whose size wasn't
                  // known in advance is fitted, never stretched.
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                )
              : GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _failed
                      ? () {
                          setState(() => _failed = false);
                          _ensure(retry: true);
                        }
                      : null,
                  child: Center(
                    child: Text(
                      _failed ? 'Couldn’t draw $label. Tap to retry.' : label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF8A8A8A),
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
