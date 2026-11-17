import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../feature_settings_scope.dart';
import '../../hooks/hook_types.dart';
import '../../media_preview_policy.dart';
import '../media/media_content.dart';
import 'document_loader.dart';
import 'document_model.dart';
import 'document_view.dart';
import 'pdf_thumbnails.dart';

/// The first lines (or first cells) of a document, or the top of a PDF's
/// first page, shown under its file card in the timeline.
///
/// Loads on its own only where media previews do (Settings → Media → In
/// chats), for files up to [DocumentPreviews.inlineMaxBytes] in a format
/// Parallax can read. Anything else shows nothing: the card above still
/// opens the viewer. The box has a fixed size from the moment it appears,
/// so the timeline doesn't jump when the file arrives.
class InlineDocumentPreview extends StatefulWidget {
  const InlineDocumentPreview({super.key, required this.ctx});
  final EntryHookContext ctx;

  static const width = 264.0;
  static const height = 98.0;

  @override
  State<InlineDocumentPreview> createState() => _InlineDocumentPreviewState();
}

class _InlineDocumentPreviewState extends State<InlineDocumentPreview> {
  late BackendSessionOwner _owner = BackendSessionOwner(widget.ctx.backend);
  bool _eligible = false;
  bool _started = false;
  bool _loading = false;
  int _generation = 0;

  /// This widget's handle on a PDF's thumbnail.
  ui.Image? _page;

  DocumentPreviews get _previews => DocumentPreviews.of(widget.ctx.backend);
  PdfThumbnails get _thumbnails => PdfThumbnails.of(widget.ctx.backend);

  bool get _pdf {
    final info = MediaInfo.fromEntry(widget.ctx.entry);
    return documentFormatFor(info.name, info.mimeType) == DocumentFormat.pdf;
  }

  /// Takes the thumbnail drawn for this file, if there is one.
  void _adopt() {
    final ctx = widget.ctx;
    final page = _thumbnails.imageFor(ctx.roomId, ctx.entry.id);
    _page?.dispose();
    _page = page;
  }

  /// Whether this file gets an inline preview at all. Looked up when the
  /// widget or the settings change, not on every build: the auto-load rule
  /// reads the room list.
  bool _checkEligible() {
    final entry = widget.ctx.entry;
    // A local echo isn't on the server yet.
    if (entry.redacted || !entry.id.startsWith(r'$')) return false;
    final info = MediaInfo.fromEntry(entry);
    final size = info.size;
    return documentFormatFor(info.name, info.mimeType) != null &&
        (size == null || size <= DocumentPreviews.inlineMaxBytes) &&
        autoLoadMediaFor(context, widget.ctx.backend, widget.ctx.roomId);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _eligible = _checkEligible();
    _start();
  }

  @override
  void didUpdateWidget(InlineDocumentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final changed =
        oldWidget.ctx.backend != widget.ctx.backend ||
        oldWidget.ctx.roomId != widget.ctx.roomId ||
        oldWidget.ctx.entry.id != widget.ctx.entry.id;
    if (oldWidget.ctx.backend != widget.ctx.backend) {
      _owner.release();
      _owner = BackendSessionOwner(widget.ctx.backend);
    }
    if (changed) {
      _generation++;
      _started = false;
      _loading = false;
      _page?.dispose();
      _page = null;
    }
    _eligible = _checkEligible();
    _start();
  }

  @override
  void dispose() {
    _generation++;
    _page?.dispose();
    _page = null;
    _owner.release();
    super.dispose();
  }

  void _start() {
    if (_started || !_eligible) return;
    final ctx = widget.ctx;
    final Future<void> Function() load;
    if (_pdf) {
      if (_thumbnails.has(ctx.roomId, ctx.entry.id)) {
        if (_page == null) _adopt();
        return;
      }
      final ratio = MediaQuery.devicePixelRatioOf(context);
      load = () => _thumbnails.load(
        ctx.roomId,
        ctx.entry.id,
        width: (InlineDocumentPreview.width * ratio).round(),
        height: (InlineDocumentPreview.height * ratio).round(),
      );
    } else {
      if (_previews.hasInline(ctx.roomId, ctx.entry.id)) return;
      final info = MediaInfo.fromEntry(ctx.entry);
      load = () => _previews.inline(
        ctx.roomId,
        ctx.entry.id,
        name: info.name,
        mimeType: info.mimeType,
      );
    }
    _started = true;
    _loading = true;
    final generation = ++_generation;
    final owner = _owner;
    final pdf = _pdf;
    unawaited(
      load().catchError((Object _) => null).then((_) {
        if (!mounted || generation != _generation || !owner.isCurrent) {
          return;
        }
        setState(() {
          _loading = false;
          if (pdf) _adopt();
        });
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    if (!_owner.isCurrent || !_eligible) return const SizedBox.shrink();
    final page = _pdf ? _page : null;
    final preview = _pdf
        ? null
        : _previews.inlineOrNull(ctx.roomId, ctx.entry.id);
    final empty = page == null && preview == null;
    if (empty && !_loading) return const SizedBox.shrink();
    final colours = DocumentColours.onBubble(ctx.onBubble, ctx.palette.accent);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Semantics(
        label: empty
            ? 'Loading preview'
            : 'Preview of ${MediaInfo.fromEntry(ctx.entry).name}',
        child: Container(
          key: const ValueKey('document.inline'),
          width: InlineDocumentPreview.width,
          height: InlineDocumentPreview.height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            // The page is paper: white whatever the bubble's colour.
            color: page != null ? Colors.white : colours.raised,
            borderRadius: BorderRadius.circular(12),
          ),
          child: page != null
              ? RawImage(
                  key: const ValueKey('document.inline.pdf'),
                  image: page,
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  filterQuality: FilterQuality.medium,
                )
              : preview == null
              ? _Skeleton(colours: colours)
              : ExcludeSemantics(
                  child: InlineDocumentSnippet(
                    preview: preview,
                    colours: colours,
                  ),
                ),
        ),
      ),
    );
  }
}

/// Placeholder bars while the file loads (still, so nothing animates in
/// rooms full of documents).
class _Skeleton extends StatelessWidget {
  const _Skeleton({required this.colours});
  final DocumentColours colours;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final fraction in const [0.9, 0.7, 0.8, 0.45])
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: FractionallySizedBox(
              widthFactor: fraction,
              child: Container(
                height: 9,
                decoration: BoxDecoration(
                  color: colours.raised,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// The start of a parsed document at thumbnail size.
class InlineDocumentSnippet extends StatelessWidget {
  const InlineDocumentSnippet({
    super.key,
    required this.preview,
    required this.colours,
  });
  final DocumentPreview preview;
  final DocumentColours colours;

  static const _lines = 5;

  @override
  Widget build(BuildContext context) => switch (preview) {
    final TextPreview text => Padding(
      padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
      child: Text(
        text.text.trimRight(),
        maxLines: _lines,
        overflow: TextOverflow.ellipsis,
        style: text.monospace
            ? TextStyle(
                color: colours.text,
                fontFamily: 'monospace',
                fontSize: 11.5,
                height: 1.4,
              )
            : TextStyle(color: colours.text, fontSize: 12.5, height: 1.3),
      ),
    ),
    final RichPreview rich => Padding(
      padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
      child: Text.rich(
        TextSpan(children: _richLines(rich)),
        maxLines: _lines,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colours.text, fontSize: 12.5, height: 1.3),
      ),
    ),
    final SheetPreview sheets => _MiniSheet(
      sheet: sheets.sheets.first,
      colours: colours,
    ),
  };

  List<InlineSpan> _richLines(RichPreview rich) {
    final lines = <InlineSpan>[];
    void line(String text, {TextStyle? style}) {
      final clean = text.replaceAll('\n', ' ').trim();
      if (clean.isEmpty || lines.length >= _lines * 2) return;
      if (lines.isNotEmpty) lines.add(const TextSpan(text: '\n'));
      lines.add(TextSpan(text: clean, style: style));
    }

    for (final block in rich.blocks) {
      switch (block) {
        case HeadingBlock(:final spans):
          line(
            spansText(spans),
            style: const TextStyle(fontWeight: FontWeight.w800),
          );
        case ParagraphBlock(:final spans):
          line(spansText(spans));
        case ListItemBlock(:final spans, :final marker):
          line('$marker ${spansText(spans)}');
        case QuoteBlock(:final spans):
          line(
            spansText(spans),
            style: const TextStyle(fontStyle: FontStyle.italic),
          );
        case CodeBlock(:final text):
          line(
            text.split('\n').first,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
          );
        case TableBlock(:final rows):
          if (rows.isNotEmpty) line(rows.first.join('  ·  '));
        case RuleBlock() || SlideBlock():
          break;
      }
    }
    return lines;
  }
}

/// The top-left corner of a sheet: up to four rows of three columns.
class _MiniSheet extends StatelessWidget {
  const _MiniSheet({required this.sheet, required this.colours});
  final DocSheet sheet;
  final DocumentColours colours;

  @override
  Widget build(BuildContext context) {
    final rows = sheet.rows.take(4).toList();
    var columns = 0;
    for (final row in rows) {
      if (row.length > columns) columns = row.length;
    }
    if (columns > 3) columns = 3;
    final line = BorderSide(color: colours.stroke, width: 0.5);
    return Column(
      children: [
        for (var index = 0; index < rows.length; index++)
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: index == rows.length - 1 ? null : Border(bottom: line),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var column = 0; column < columns; column++)
                    Expanded(
                      child: Container(
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        decoration: BoxDecoration(
                          border: column == columns - 1
                              ? null
                              : Border(right: line),
                        ),
                        child: Text(
                          column < rows[index].length
                              ? rows[index][column].replaceAll('\n', ' ')
                              : '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colours.text,
                            fontSize: 12,
                            fontWeight: index == 0 ? FontWeight.w700 : null,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        // Keep row heights steady when the sheet has fewer than four rows.
        for (var index = rows.length; index < 4; index++)
          const Expanded(child: SizedBox.expand()),
      ],
    );
  }
}
