import 'dart:async';

import 'package:flutter/material.dart';

import '../../chat_backend.dart';
import '../../feature_settings_scope.dart';
import '../../media_player_owner.dart';
import '../media/media_content.dart';
import '../media/media_features.dart';
import 'document_loader.dart';
import 'document_model.dart';
import 'document_view.dart';
import 'pdf_view.dart';

/// A file in the media viewer: its preview when Parallax can read the
/// format (text, Markdown, CSV, Word, Excel, PowerPoint, PDF), otherwise
/// [fallback], the plain file card.
///
/// The file is downloaded and decrypted in memory only. Text and Office
/// files are parsed on a background isolate; PDF pages are drawn by the
/// platform in an isolated process (see [PdfDocumentPage]).
class DocumentPage extends StatefulWidget {
  const DocumentPage({
    super.key,
    required this.backend,
    required this.roomId,
    required this.eventId,
    required this.loader,
    required this.info,
    required this.fallback,
  });
  final ChatBackend backend;
  final String roomId;
  final String eventId;
  final MediaLoader loader;
  final MediaInfo info;
  final Widget fallback;

  @override
  State<DocumentPage> createState() => _DocumentPageState();
}

enum _Status { loading, ready, unsupported, failed }

class _DocumentPageState extends State<DocumentPage> {
  late BackendSessionOwner _owner = BackendSessionOwner(widget.backend);
  _Status _status = _Status.unsupported;
  DocumentPreview? _preview;
  int _generation = 0;

  bool get _previewable {
    final info = widget.info;
    final size = info.size;
    return documentFormatFor(info.name, info.mimeType) != null &&
        (size == null || size <= maxOriginalBytes);
  }

  /// PDFs have their own page ([PdfDocumentPage]); nothing is loaded here.
  bool get _pdf =>
      documentFormatFor(widget.info.name, widget.info.mimeType) ==
      DocumentFormat.pdf;

  @override
  void initState() {
    super.initState();
    if (_previewable && !_pdf) unawaited(_load());
  }

  @override
  void didUpdateWidget(DocumentPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.backend != widget.backend) {
      _owner.release();
      _owner = BackendSessionOwner(widget.backend);
    }
    if (oldWidget.backend != widget.backend ||
        oldWidget.roomId != widget.roomId ||
        oldWidget.eventId != widget.eventId) {
      _generation++;
      _preview = null;
      _status = _Status.unsupported;
      if (_previewable && !_pdf) unawaited(_load());
    }
  }

  @override
  void dispose() {
    _generation++;
    _owner.release();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final owner = _owner;
    setState(() {
      _status = _Status.loading;
      _preview = null;
    });
    DocumentPreview? preview;
    var failed = false;
    try {
      preview = await DocumentPreviews.of(widget.backend).full(
        widget.roomId,
        widget.eventId,
        widget.loader,
        name: widget.info.name,
        mimeType: widget.info.mimeType,
      );
    } catch (_) {
      failed = true;
    }
    if (!mounted || generation != _generation || !owner.isCurrent) return;
    setState(() {
      _preview = preview;
      _status = failed
          ? _Status.failed
          : preview == null
          ? _Status.unsupported
          : _Status.ready;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_previewable && _pdf) {
      return PdfDocumentPage(
        key: ValueKey('pdf-${widget.roomId}/${widget.eventId}'),
        backend: widget.backend,
        loader: widget.loader,
        fallback: widget.fallback,
      );
    }
    switch (_status) {
      case _Status.unsupported:
        return widget.fallback;
      case _Status.loading:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Opening preview…'),
            ],
          ),
        );
      case _Status.failed:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  fileTypeIcon(widget.info.name, widget.info.mimeType),
                  size: 56,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Couldn’t load this file.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                const Text(
                  'Check your connection and try again.',
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
      case _Status.ready:
        return DocumentPreviewView(preview: _preview!);
    }
  }
}
