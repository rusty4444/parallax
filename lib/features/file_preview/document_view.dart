import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../rich_timeline/message_actions.dart';
import 'document_model.dart';

/// Colours the document widgets draw with, so the same widgets work in the
/// viewer (app theme) and inside a message bubble (bubble palette).
@immutable
class DocumentColours {
  const DocumentColours({
    required this.text,
    required this.muted,
    required this.raised,
    required this.stroke,
    required this.accent,
  });

  factory DocumentColours.of(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DocumentColours(
      text: scheme.onSurface,
      muted: scheme.onSurface.withValues(alpha: 0.65),
      raised: scheme.onSurface.withValues(alpha: 0.07),
      stroke: scheme.outline,
      accent: scheme.primary,
    );
  }

  /// For content drawn on a bubble whose text colour is [onBubble].
  factory DocumentColours.onBubble(Color onBubble, Color accent) =>
      DocumentColours(
        text: onBubble,
        muted: onBubble.withValues(alpha: 0.7),
        raised: onBubble.withValues(alpha: 0.09),
        stroke: onBubble.withValues(alpha: 0.2),
        accent: accent,
      );

  final Color text;
  final Color muted;

  /// Background of code, table headers and the inline preview.
  final Color raised;
  final Color stroke;
  final Color accent;
}

const _monospace = 'monospace';

/// Shown under a preview that a limit cut short.
class _TruncatedNote extends StatelessWidget {
  const _TruncatedNote({required this.colours});
  final DocumentColours colours;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 22),
    child: Row(
      children: [
        Icon(Icons.content_cut_rounded, size: 16, color: colours.muted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'This preview shows the start of the file. Save or share it to '
            'see the rest.',
            style: TextStyle(color: colours.muted, fontSize: 12.5),
          ),
        ),
      ],
    ),
  );
}

/// A parsed file, full size and scrollable.
class DocumentPreviewView extends StatelessWidget {
  const DocumentPreviewView({super.key, required this.preview, this.colours});
  final DocumentPreview preview;
  final DocumentColours? colours;

  @override
  Widget build(BuildContext context) {
    final colours = this.colours ?? DocumentColours.of(context);
    return switch (preview) {
      final TextPreview text => _TextDocument(preview: text, colours: colours),
      final RichPreview rich => _RichDocument(preview: rich, colours: colours),
      final SheetPreview sheets => _SheetDocument(
        preview: sheets,
        colours: colours,
      ),
    };
  }
}

// --- Plain text ------------------------------------------------------------

class _TextDocument extends StatefulWidget {
  const _TextDocument({required this.preview, required this.colours});
  final TextPreview preview;
  final DocumentColours colours;

  @override
  State<_TextDocument> createState() => _TextDocumentState();
}

class _TextDocumentState extends State<_TextDocument> {
  /// Lines per list item: few enough to build lazily, enough that a text
  /// selection usually stays inside one item.
  static const _linesPerChunk = 40;
  late List<String> _chunks = _split(widget.preview.text);

  static List<String> _split(String text) {
    final lines = text.split('\n');
    return [
      for (var at = 0; at < lines.length; at += _linesPerChunk)
        lines
            .sublist(
              at,
              at + _linesPerChunk > lines.length
                  ? lines.length
                  : at + _linesPerChunk,
            )
            .join('\n'),
    ];
  }

  @override
  void didUpdateWidget(_TextDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.preview, widget.preview)) {
      _chunks = _split(widget.preview.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colours = widget.colours;
    final style = widget.preview.monospace
        ? TextStyle(
            color: colours.text,
            fontFamily: _monospace,
            fontSize: 12.5,
            height: 1.45,
          )
        : TextStyle(color: colours.text, fontSize: 15, height: 1.45);
    final note = widget.preview.truncated;
    return SelectionArea(
      child: ListView.builder(
        key: const ValueKey('document.text'),
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: _chunks.length + (note ? 1 : 0),
        itemBuilder: (context, index) => index == _chunks.length
            ? _TruncatedNote(colours: colours)
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(_chunks[index], style: style),
              ),
      ),
    );
  }
}

// --- Formatted text --------------------------------------------------------

/// Text with styled runs. Links open like links in a message: unsafe
/// schemes are refused and a misleading label asks first.
class DocumentSpans extends StatefulWidget {
  const DocumentSpans({
    super.key,
    required this.spans,
    required this.style,
    required this.colours,
    this.maxLines,
    this.interactive = true,
  });
  final List<DocSpan> spans;
  final TextStyle style;
  final DocumentColours colours;
  final int? maxLines;

  /// False in the timeline, where a tap opens the viewer instead.
  final bool interactive;

  @override
  State<DocumentSpans> createState() => _DocumentSpansState();
}

class _DocumentSpansState extends State<DocumentSpans> {
  final _recognisers = <TapGestureRecognizer>[];

  void _release() {
    for (final recogniser in _recognisers) {
      recogniser.dispose();
    }
    _recognisers.clear();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  GestureRecognizer? _tap(DocSpan span) {
    final uri = Uri.tryParse(span.link ?? '');
    if (!widget.interactive || uri == null || !uri.hasScheme) return null;
    final recogniser = TapGestureRecognizer()
      ..onTap = () {
        if (mounted) {
          unawaited(openTimelineLink(context, uri, text: span.text));
        }
      };
    _recognisers.add(recogniser);
    return recogniser;
  }

  @override
  Widget build(BuildContext context) {
    _release();
    final colours = widget.colours;
    return Text.rich(
      TextSpan(
        style: widget.style,
        children: [
          for (final span in widget.spans)
            TextSpan(
              text: span.text,
              recognizer: _tap(span),
              style: TextStyle(
                fontWeight: span.bold ? FontWeight.w700 : null,
                fontStyle: span.italic ? FontStyle.italic : null,
                fontFamily: span.code ? _monospace : null,
                backgroundColor: span.code ? colours.raised : null,
                color: span.link != null ? colours.accent : null,
                decoration: span.underline || span.strike
                    ? TextDecoration.combine([
                        if (span.underline) TextDecoration.underline,
                        if (span.strike) TextDecoration.lineThrough,
                      ])
                    : null,
              ),
            ),
        ],
      ),
      maxLines: widget.maxLines,
      overflow: widget.maxLines == null ? null : TextOverflow.ellipsis,
    );
  }
}

class _RichDocument extends StatelessWidget {
  const _RichDocument({required this.preview, required this.colours});
  final RichPreview preview;
  final DocumentColours colours;

  @override
  Widget build(BuildContext context) {
    final blocks = preview.blocks;
    return SelectionArea(
      child: ListView.builder(
        key: const ValueKey('document.rich'),
        padding: const EdgeInsets.symmetric(vertical: 12),
        itemCount: blocks.length + (preview.truncated ? 1 : 0),
        itemBuilder: (context, index) => index == blocks.length
            ? _TruncatedNote(colours: colours)
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: DocumentBlockView(
                  block: blocks[index],
                  colours: colours,
                  first: index == 0,
                ),
              ),
      ),
    );
  }
}

/// One block of a formatted document.
class DocumentBlockView extends StatelessWidget {
  const DocumentBlockView({
    super.key,
    required this.block,
    required this.colours,
    this.first = false,
  });
  final DocBlock block;
  final DocumentColours colours;

  /// The first block needs no space above it.
  final bool first;

  /// Rows of a table drawn in a document; the rest are counted.
  static const maxTableRows = 100;

  static const _headingSizes = [24.0, 21.0, 18.0, 16.5, 15.5, 15.0];

  @override
  Widget build(BuildContext context) {
    final body = TextStyle(color: colours.text, fontSize: 15, height: 1.45);
    switch (block) {
      case HeadingBlock(:final level, :final spans):
        return Padding(
          padding: EdgeInsets.only(top: first ? 0 : 14, bottom: 6),
          child: DocumentSpans(
            spans: spans,
            colours: colours,
            style: TextStyle(
              color: colours.text,
              fontSize: _headingSizes[level.clamp(1, 6) - 1],
              fontWeight: FontWeight.w800,
              height: 1.25,
            ),
          ),
        );
      case ParagraphBlock(:final spans):
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: DocumentSpans(spans: spans, colours: colours, style: body),
        );
      case ListItemBlock(:final spans, :final depth, :final marker):
        return Padding(
          padding: EdgeInsets.only(left: 18.0 * depth, bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 16),
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Text(marker, style: body),
                ),
              ),
              Expanded(
                child: DocumentSpans(
                  spans: spans,
                  colours: colours,
                  style: body,
                ),
              ),
            ],
          ),
        );
      case QuoteBlock(:final spans):
        return Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(12, 4, 0, 4),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: colours.stroke, width: 3)),
          ),
          child: DocumentSpans(
            spans: spans,
            colours: colours,
            style: body.copyWith(color: colours.muted),
          ),
        );
      case CodeBlock(:final text):
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colours.raised,
            borderRadius: BorderRadius.circular(10),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              text,
              style: TextStyle(
                color: colours.text,
                fontFamily: _monospace,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        );
      case TableBlock(:final rows, :final header):
        return _DocumentTable(rows: rows, header: header, colours: colours);
      case RuleBlock():
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Divider(height: 1, color: colours.stroke),
        );
      case SlideBlock(:final number):
        return Padding(
          padding: EdgeInsets.only(top: first ? 0 : 18, bottom: 10),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: colours.raised,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'Slide $number',
                  style: TextStyle(
                    color: colours.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: Divider(height: 1, color: colours.stroke)),
            ],
          ),
        );
    }
  }
}

/// A table inside a document, scrolled sideways when it is wide.
class _DocumentTable extends StatelessWidget {
  const _DocumentTable({
    required this.rows,
    required this.header,
    required this.colours,
  });
  final List<List<String>> rows;
  final bool header;
  final DocumentColours colours;

  @override
  Widget build(BuildContext context) {
    final shown = rows.length > DocumentBlockView.maxTableRows
        ? rows.sublist(0, DocumentBlockView.maxTableRows)
        : rows;
    var columns = 0;
    for (final row in shown) {
      if (row.length > columns) columns = row.length;
    }
    if (columns == 0) return const SizedBox.shrink();
    final style = TextStyle(color: colours.text, fontSize: 13.5, height: 1.35);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Table(
              defaultColumnWidth: const IntrinsicColumnWidth(),
              border: TableBorder.all(color: colours.stroke),
              children: [
                for (var index = 0; index < shown.length; index++)
                  TableRow(
                    decoration: header && index == 0
                        ? BoxDecoration(color: colours.raised)
                        : null,
                    children: [
                      for (var column = 0; column < columns; column++)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 240),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 6,
                            ),
                            child: Text(
                              column < shown[index].length
                                  ? shown[index][column]
                                  : '',
                              style: header && index == 0
                                  ? style.copyWith(fontWeight: FontWeight.w700)
                                  : style,
                            ),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
          if (rows.length > shown.length)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${rows.length - shown.length} more rows',
                style: TextStyle(color: colours.muted, fontSize: 12.5),
              ),
            ),
        ],
      ),
    );
  }
}

// --- Sheets ----------------------------------------------------------------

class _SheetDocument extends StatefulWidget {
  const _SheetDocument({required this.preview, required this.colours});
  final SheetPreview preview;
  final DocumentColours colours;

  @override
  State<_SheetDocument> createState() => _SheetDocumentState();
}

class _SheetDocumentState extends State<_SheetDocument> {
  int _sheet = 0;

  @override
  void didUpdateWidget(_SheetDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.preview, widget.preview)) _sheet = 0;
  }

  @override
  Widget build(BuildContext context) {
    final colours = widget.colours;
    final sheets = widget.preview.sheets;
    if (sheets.isEmpty) return const SizedBox.shrink();
    final sheet = sheets[_sheet.clamp(0, sheets.length - 1)];
    final total = sheet.totalRows;
    final summary = [
      if (total != null)
        'Showing ${sheet.rows.length} of $total rows'
      else
        '${sheet.rows.length} ${sheet.rows.length == 1 ? 'row' : 'rows'}',
      '${sheet.columnCount} ${sheet.columnCount == 1 ? 'column' : 'columns'}',
      if (sheet.truncated && total == null) 'start of the sheet',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sheets.length > 1)
          SizedBox(
            height: 48,
            child: ListView.separated(
              key: const ValueKey('document.sheets'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              itemCount: sheets.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => ChoiceChip(
                label: Text(
                  sheets[index].name.isEmpty
                      ? 'Sheet ${index + 1}'
                      : sheets[index].name,
                ),
                selected: index == _sheet,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => setState(() => _sheet = index),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
          child: Text(
            summary,
            style: TextStyle(color: colours.muted, fontSize: 12.5),
          ),
        ),
        Expanded(
          child: SheetGrid(
            key: ValueKey('document.grid.$_sheet'),
            sheet: sheet,
            colours: colours,
          ),
        ),
        if (widget.preview.truncated) _TruncatedNote(colours: colours),
      ],
    );
  }
}

/// A sheet as a grid: column letters across the top, row numbers down the
/// side, both staying in view. Rows are built as they scroll in; tapping a
/// cell shows all of its text.
class SheetGrid extends StatefulWidget {
  const SheetGrid({super.key, required this.sheet, required this.colours});
  final DocSheet sheet;
  final DocumentColours colours;

  static const rowHeight = 34.0;
  static const _numberWidth = 46.0;
  static const _minColumn = 64.0;
  static const _maxColumn = 260.0;

  @override
  State<SheetGrid> createState() => _SheetGridState();
}

class _SheetGridState extends State<SheetGrid> {
  final _horizontal = ScrollController();
  late List<double> _widths = _measure();

  /// Column widths from the text of the first rows (about 7.4 px a
  /// character at this size), within sensible bounds.
  List<double> _measure() {
    final sheet = widget.sheet;
    final longest = List<int>.filled(sheet.columnCount, 1);
    final sample = sheet.rows.length < 200 ? sheet.rows.length : 200;
    for (var index = 0; index < sample; index++) {
      final row = sheet.rows[index];
      for (var column = 0; column < row.length; column++) {
        final cell = row[column];
        final newline = cell.indexOf('\n');
        final length = newline < 0 ? cell.length : newline;
        if (length > longest[column]) longest[column] = length;
      }
    }
    return [
      for (final length in longest)
        (length * 7.4 + 22).clamp(SheetGrid._minColumn, SheetGrid._maxColumn),
    ];
  }

  @override
  void didUpdateWidget(SheetGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.sheet, widget.sheet)) _widths = _measure();
  }

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  int _rowNumber(int index) => widget.sheet.rowNumbers?[index] ?? index + 1;

  void _showCell(int row, int column, String text) {
    final colours = widget.colours;
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.6,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Cell ${columnLetters(column)}${_rowNumber(row)}',
                          style: Theme.of(sheetContext).textTheme.titleMedium,
                        ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('Copy'),
                        onPressed: () {
                          unawaited(
                            Clipboard.setData(ClipboardData(text: text)),
                          );
                          Navigator.pop(sheetContext);
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    text,
                    style: TextStyle(color: colours.text, fontSize: 15),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _cell(
    String text,
    double width, {
    bool heading = false,
    VoidCallback? onTap,
  }) {
    final colours = widget.colours;
    // Numbers sit on the right, as in a spreadsheet.
    final number = !heading && text.isNotEmpty && double.tryParse(text) != null;
    final content = Container(
      width: width,
      height: SheetGrid.rowHeight,
      alignment: heading
          ? Alignment.center
          : number
          ? Alignment.centerRight
          : Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: heading ? colours.raised : null,
        border: Border(
          right: BorderSide(color: colours.stroke, width: 0.5),
          bottom: BorderSide(color: colours.stroke, width: 0.5),
        ),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: heading ? colours.muted : colours.text,
          fontSize: 13,
          fontWeight: heading ? FontWeight.w700 : null,
        ),
      ),
    );
    return onTap == null ? content : InkWell(onTap: onTap, child: content);
  }

  @override
  Widget build(BuildContext context) {
    final sheet = widget.sheet;
    final colours = widget.colours;
    if (sheet.rows.isEmpty || _widths.isEmpty) {
      return Center(
        child: Text(
          'This sheet is empty.',
          style: TextStyle(color: colours.muted),
        ),
      );
    }
    var width = SheetGrid._numberWidth;
    for (final column in _widths) {
      width += column;
    }
    return Scrollbar(
      controller: _horizontal,
      // Always drawn: the only sign that a wide sheet continues sideways.
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _horizontal,
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          child: Column(
            children: [
              Row(
                children: [
                  _cell('', SheetGrid._numberWidth, heading: true),
                  for (var column = 0; column < _widths.length; column++)
                    _cell(
                      columnLetters(column),
                      _widths[column],
                      heading: true,
                    ),
                ],
              ),
              Expanded(
                child: ListView.builder(
                  key: const ValueKey('document.rows'),
                  itemExtent: SheetGrid.rowHeight,
                  itemCount: sheet.rows.length,
                  itemBuilder: (context, index) {
                    final row = sheet.rows[index];
                    return Row(
                      children: [
                        _cell(
                          '${_rowNumber(index)}',
                          SheetGrid._numberWidth,
                          heading: true,
                        ),
                        for (var column = 0; column < _widths.length; column++)
                          _cell(
                            column < row.length ? row[column] : '',
                            _widths[column],
                            onTap: column < row.length && row[column].isNotEmpty
                                ? () => _showCell(index, column, row[column])
                                : null,
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
