import 'dart:convert';
import 'dart:typed_data';

import 'package:markdown/markdown.dart' as md;

import 'bounded_zip.dart';
import 'document_model.dart';
import 'office_parser.dart';

/// One file to preview. Sent to a background isolate.
class DocumentRequest {
  const DocumentRequest({
    required this.bytes,
    required this.format,
    required this.name,
    this.limits = DocumentLimits.full,
  });
  final Uint8List bytes;
  final DocumentFormat format;

  /// File name, for choices the format alone doesn't settle (tab-separated
  /// values, prose or code).
  final String name;
  final DocumentLimits limits;
}

/// Parses [request] within its limits. Returns null when the bytes aren't
/// what the name promised (binary data in a `.txt`, a damaged archive):
/// the caller then shows the plain file card.
///
/// Pure and synchronous. Run it off the UI isolate: it reads content the
/// sender controls.
DocumentPreview? parseDocument(DocumentRequest request) {
  try {
    return switch (request.format) {
      DocumentFormat.text => _parseText(request),
      DocumentFormat.markdown => _parseMarkdown(request),
      DocumentFormat.delimited => _parseDelimited(request),
      DocumentFormat.word => parseWord(
        BoundedZip.parse(request.bytes),
        request.limits,
      ),
      DocumentFormat.spreadsheet => parseSpreadsheet(
        BoundedZip.parse(request.bytes),
        request.limits,
      ),
      DocumentFormat.slides => parseSlides(
        BoundedZip.parse(request.bytes),
        request.limits,
      ),
      // Pages are drawn by the platform's renderer, not read as text.
      DocumentFormat.pdf => null,
    };
  } catch (_) {
    return null;
  }
}

String _extension(String name) {
  final lower = name.trim().toLowerCase();
  final dot = lower.lastIndexOf('.');
  return dot >= 0 && dot < lower.length - 1 ? lower.substring(dot + 1) : '';
}

/// Text decoded from a file, at most [maxChars] long.
class DecodedText {
  const DecodedText(this.text, {required this.truncated});
  final String text;
  final bool truncated;
}

/// Decodes [bytes] as text: UTF-8 or UTF-16 by byte-order mark, UTF-8
/// without one, Latin-1 when that fails. Returns null for binary data.
/// Line endings become `\n`.
DecodedText? decodeText(Uint8List bytes, {required int maxChars}) {
  if (bytes.isEmpty) return const DecodedText('', truncated: false);
  String text;
  var cut = false;
  final utf16Little = bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE;
  final utf16Big = bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF;
  if (utf16Little || utf16Big) {
    var units = (bytes.length - 2) ~/ 2;
    if (units > maxChars) {
      units = maxChars;
      cut = true;
    }
    final data = ByteData.sublistView(bytes, 2, 2 + units * 2);
    final endian = utf16Little ? Endian.little : Endian.big;
    text = String.fromCharCodes([
      for (var i = 0; i < units; i++) data.getUint16(i * 2, endian),
    ]);
  } else {
    // A character is at most four bytes; decode no more than could be shown.
    var start = 0;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      start = 3;
    }
    var end = bytes.length;
    final most = start + maxChars * 4;
    if (end > most) {
      end = most;
      cut = true;
      // Don't split a multi-byte character.
      for (var back = 0; back < 3 && end > start; back++) {
        if (bytes[end] & 0xC0 != 0x80) break;
        end--;
      }
    }
    final slice = Uint8List.sublistView(bytes, start, end);
    if (_looksBinary(slice)) return null;
    try {
      text = utf8.decode(slice);
    } on FormatException {
      text = latin1.decode(slice);
    }
  }
  if (text.contains('\r')) {
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }
  if (text.length > maxChars) {
    text = text.substring(0, maxChars);
    cut = true;
  }
  return DecodedText(text, truncated: cut);
}

bool _looksBinary(Uint8List bytes) {
  final sample = bytes.length < 8192 ? bytes.length : 8192;
  if (sample == 0) return false;
  var control = 0;
  for (var i = 0; i < sample; i++) {
    final byte = bytes[i];
    if (byte == 0) return true;
    // Tab, line feed, form feed, carriage return and escape are text.
    if (byte < 0x20 &&
        byte != 0x09 &&
        byte != 0x0A &&
        byte != 0x0C &&
        byte != 0x0D &&
        byte != 0x1B) {
      control++;
    }
  }
  return control * 20 > sample;
}

DocumentPreview? _parseText(DocumentRequest request) {
  final limits = request.limits;
  final decoded = decodeText(request.bytes, maxChars: limits.chars);
  if (decoded == null) return null;
  var text = decoded.text;
  var truncated = decoded.truncated;
  final extension = _extension(request.name);
  // A one-line JSON file is unreadable as sent; indent it.
  if (extension == 'json' &&
      !truncated &&
      text.length <= 512 * 1024 &&
      '\n'.allMatches(text.trimRight()).length < 2) {
    try {
      text = const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
      if (text.length > limits.chars) {
        text = text.substring(0, limits.chars);
        truncated = true;
      }
    } catch (_) {
      // Not valid JSON: shown as it is.
    }
  }
  return TextPreview(
    text,
    monospace: !const {'txt', 'text', ''}.contains(extension),
    truncated: truncated,
  );
}

DocumentPreview? _parseDelimited(DocumentRequest request) {
  final limits = request.limits;
  final decoded = decodeText(request.bytes, maxChars: limits.chars);
  if (decoded == null) return null;
  final extension = _extension(request.name);
  final delimiter = extension == 'tsv' || extension == 'tab'
      ? '\t'
      : sniffDelimiter(decoded.text);
  final table = parseDelimited(
    decoded.text,
    delimiter: delimiter,
    maxRows: limits.rows,
    maxColumns: limits.columns,
    maxCellChars: limits.cellChars,
    // A cut-off file ends part-way through a row.
    dropLastRow: decoded.truncated,
  );
  return SheetPreview([
    DocSheet(name: '', rows: table.rows, truncated: table.truncated),
  ], truncated: table.truncated || decoded.truncated);
}

/// Picks the separator of delimited [text] from its first lines, ignoring
/// quoted fields: the one that appears the same number of times on every
/// line (a decimal comma in `1,5;2,5` does not), else the most frequent.
/// Defaults to a comma.
String sniffDelimiter(String text) {
  const candidates = [',', ';', '\t', '|'];
  // Occurrences of each candidate on each of the first lines.
  final lines = <List<int>>[List<int>.filled(candidates.length, 0)];
  var quoted = false;
  for (var i = 0; i < text.length && i < 65536; i++) {
    final char = text[i];
    if (char == '"') {
      quoted = !quoted;
    } else if (!quoted) {
      if (char == '\n') {
        if (lines.length == 10) break;
        lines.add(List<int>.filled(candidates.length, 0));
      } else {
        final at = candidates.indexOf(char);
        if (at >= 0) lines.last[at]++;
      }
    }
  }
  // A trailing line break leaves an empty last line.
  if (lines.length > 1 && lines.last.every((count) => count == 0)) {
    lines.removeLast();
  }
  var best = 0;
  var bestScore = -1;
  for (var i = 0; i < candidates.length; i++) {
    var total = 0;
    var steady = true;
    for (final line in lines) {
      total += line[i];
      if (line[i] != lines.first[i]) steady = false;
    }
    if (total == 0) continue;
    final score = steady ? total + (1 << 20) : total;
    if (score > bestScore) {
      best = i;
      bestScore = score;
    }
  }
  return candidates[best];
}

class DelimitedTable {
  const DelimitedTable(this.rows, {required this.truncated});
  final List<List<String>> rows;
  final bool truncated;
}

/// Reads RFC 4180 style rows: fields may be quoted, quotes are doubled
/// inside a quoted field, and a quoted field may contain line breaks.
DelimitedTable parseDelimited(
  String text, {
  String delimiter = ',',
  required int maxRows,
  required int maxColumns,
  required int maxCellChars,
  bool dropLastRow = false,
}) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var truncated = false;
  var quoted = false;
  var wasQuoted = false;
  var complete = true;

  void endField() {
    if (row.length < maxColumns) {
      final value = field.toString();
      row.add(
        value.length > maxCellChars
            ? '${value.substring(0, maxCellChars)}…'
            : value,
      );
    } else {
      truncated = true;
    }
    field.clear();
    wasQuoted = false;
  }

  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (quoted) {
      if (char == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else if (field.length <= maxCellChars) {
        field.write(char);
      }
      continue;
    }
    if (char == '"' && field.isEmpty && !wasQuoted) {
      quoted = true;
      wasQuoted = true;
      complete = false;
    } else if (char == delimiter) {
      endField();
      complete = false;
    } else if (char == '\n') {
      endField();
      rows.add(row);
      row = <String>[];
      complete = true;
      if (rows.length >= maxRows) {
        if (i + 1 < text.length) truncated = true;
        break;
      }
    } else {
      if (field.length <= maxCellChars) field.write(char);
      complete = false;
    }
  }
  if (!complete && rows.length < maxRows) {
    if (dropLastRow) {
      truncated = true;
    } else {
      endField();
      rows.add(row);
    }
  }
  return DelimitedTable(rows, truncated: truncated);
}

DocumentPreview? _parseMarkdown(DocumentRequest request) {
  final limits = request.limits;
  final decoded = decodeText(request.bytes, maxChars: limits.chars);
  if (decoded == null) return null;
  final nodes = md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parse(decoded.text);
  final builder = _MarkdownBlocks(limits);
  builder.addAll(nodes, depth: 0, quoted: false);
  return RichPreview(
    builder.blocks,
    truncated: decoded.truncated || builder.truncated,
  );
}

class _MarkdownBlocks {
  _MarkdownBlocks(this.limits);
  final DocumentLimits limits;
  final blocks = <DocBlock>[];
  bool truncated = false;

  bool get _full {
    if (blocks.length < limits.blocks) return false;
    truncated = true;
    return true;
  }

  void addAll(List<md.Node> nodes, {required int depth, required bool quoted}) {
    // Loose inline nodes between blocks (raw HTML, text) form a paragraph.
    final loose = <md.Node>[];
    void flush() {
      if (loose.isEmpty) return;
      _text(loose.toList(), quoted: quoted);
      loose.clear();
    }

    for (final node in nodes) {
      if (_full) return;
      if (node is md.Element && _blockTags.contains(node.tag)) {
        flush();
        _block(node, depth: depth, quoted: quoted);
      } else {
        loose.add(node);
      }
    }
    flush();
  }

  static const _blockTags = {
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'ul', 'ol', 'pre', //
    'blockquote', 'hr', 'table', 'div', 'section',
  };

  void _text(List<md.Node> nodes, {required bool quoted}) {
    final spans = _inline(nodes);
    if (spansText(spans).trim().isEmpty) return;
    blocks.add(quoted ? QuoteBlock(spans) : ParagraphBlock(spans));
  }

  void _block(md.Element element, {required int depth, required bool quoted}) {
    final children = element.children ?? const <md.Node>[];
    switch (element.tag) {
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        blocks.add(HeadingBlock(int.parse(element.tag[1]), _inline(children)));
      case 'p':
        _text(children, quoted: quoted);
      case 'blockquote':
        addAll(children, depth: depth, quoted: true);
      case 'ul' || 'ol':
        var number = int.tryParse(element.attributes['start'] ?? '') ?? 1;
        for (final child in children) {
          if (_full) return;
          if (child is! md.Element || child.tag != 'li') continue;
          _item(
            child,
            depth: depth,
            marker: element.tag == 'ol' ? '${number++}.' : '•',
          );
        }
      case 'pre':
        final code = element.textContent;
        blocks.add(
          CodeBlock(
            code.endsWith('\n') ? code.substring(0, code.length - 1) : code,
          ),
        );
      case 'hr':
        blocks.add(const RuleBlock());
      case 'table':
        final rows = <List<String>>[];
        void collect(md.Node node) {
          if (node is! md.Element) return;
          if (node.tag == 'tr') {
            if (rows.length >= limits.rows) {
              truncated = true;
              return;
            }
            rows.add([
              for (final cell in node.children ?? const <md.Node>[])
                if (cell is md.Element &&
                    (cell.tag == 'td' || cell.tag == 'th') &&
                    rows.length <= limits.rows)
                  cell.textContent.trim(),
            ]);
          } else {
            (node.children ?? const <md.Node>[]).forEach(collect);
          }
        }
        children.forEach(collect);
        if (rows.isNotEmpty) blocks.add(TableBlock(rows, header: true));
      default:
        addAll(children, depth: depth, quoted: quoted);
    }
  }

  void _item(md.Element item, {required int depth, required String marker}) {
    final children = item.children ?? const <md.Node>[];
    var label = marker;
    final inline = <md.Node>[];
    final nested = <md.Element>[];
    for (final child in children) {
      if (child is md.Element && child.tag == 'input') {
        label = child.attributes.containsKey('checked') ? '☑' : '☐';
      } else if (child is md.Element &&
          (child.tag == 'ul' || child.tag == 'ol')) {
        nested.add(child);
      } else if (child is md.Element && child.tag == 'p' && inline.isEmpty) {
        // A loose list wraps each item's text in a paragraph.
        inline.addAll(child.children ?? const <md.Node>[]);
      } else if (child is md.Element && _blockTags.contains(child.tag)) {
        nested.add(child);
      } else {
        inline.add(child);
      }
    }
    final spans = _inline(inline);
    if (spansText(spans).trim().isNotEmpty || nested.isEmpty) {
      blocks.add(ListItemBlock(spans, depth: depth, marker: label));
    }
    for (final child in nested) {
      if (_full) return;
      _block(child, depth: depth + 1, quoted: false);
    }
  }

  List<DocSpan> _inline(List<md.Node> nodes) {
    final spans = <DocSpan>[];
    void walk(
      md.Node node, {
      bool bold = false,
      bool italic = false,
      bool strike = false,
      bool code = false,
      String? link,
    }) {
      if (node is md.Text) {
        if (node.text.isEmpty) return;
        spans.add(
          DocSpan(
            node.text,
            bold: bold,
            italic: italic,
            strike: strike,
            code: code,
            underline: link != null,
            link: link,
          ),
        );
        return;
      }
      if (node is! md.Element) return;
      switch (node.tag) {
        case 'br':
          spans.add(const DocSpan('\n'));
          return;
        case 'img':
          final alt = node.attributes['alt'] ?? '';
          spans.add(DocSpan(alt.isEmpty ? '[image]' : '[$alt]', italic: true));
          return;
      }
      for (final child in node.children ?? const <md.Node>[]) {
        walk(
          child,
          bold: bold || node.tag == 'strong',
          italic: italic || node.tag == 'em',
          strike: strike || node.tag == 'del',
          code: code || node.tag == 'code',
          link: node.tag == 'a' ? node.attributes['href'] : link,
        );
      }
    }

    for (final node in nodes) {
      walk(node);
    }
    return spans;
  }
}
