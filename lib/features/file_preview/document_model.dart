/// What a previewed file contains once parsed.
///
/// Plain data only: it is built on a background isolate from an untrusted
/// attachment and handed to the widgets, so nothing here refers to the
/// platform, the SDK or the widget layer.
library;

/// File types the previewer understands.
enum DocumentFormat {
  /// Plain text, logs, source code, JSON, XML, YAML…
  text,
  markdown,

  /// CSV and TSV.
  delimited,

  /// Word (.docx).
  word,

  /// Excel (.xlsx).
  spreadsheet,

  /// PowerPoint (.pptx).
  slides,
}

const _textExtensions = {
  'txt', 'text', 'log', 'json', 'jsonl', 'ndjson', 'xml', 'yaml', 'yml', //
  'toml', 'ini', 'cfg', 'conf', 'properties', 'env', 'html', 'htm', 'css',
  'js', 'mjs', 'ts', 'tsx', 'jsx', 'dart', 'py', 'rb', 'php', 'sh', 'bash',
  'zsh', 'bat', 'ps1', 'c', 'h', 'cc', 'cpp', 'hpp', 'cs', 'java', 'kt',
  'kts', 'swift', 'go', 'rs', 'lua', 'pl', 'r', 'sql', 'gradle', 'diff',
  'patch', 'srt', 'vtt', 'tex', 'rst', 'adoc', 'gitignore', 'dockerfile',
  'nfo', 'ics', 'vcf', 'plist', 'lock',
};

const _textMimeTypes = {
  'application/json',
  'application/ld+json',
  'application/xml',
  'application/x-yaml',
  'application/yaml',
  'application/toml',
  'application/javascript',
  'application/x-javascript',
  'application/x-sh',
  'application/x-shellscript',
  'application/sql',
  'application/x-httpd-php',
  'application/x-ndjson',
};

/// The preview format for a file called [name] of type [mimeType], or null
/// when it can't be previewed. The extension wins: bridges and some clients
/// send every file as `application/octet-stream`.
DocumentFormat? documentFormatFor(String name, String? mimeType) {
  final lower = name.trim().toLowerCase();
  final dot = lower.lastIndexOf('.');
  final extension = dot >= 0 && dot < lower.length - 1
      ? lower.substring(dot + 1)
      : (lower == 'dockerfile' || lower == 'makefile' ? 'txt' : '');
  final byExtension = switch (extension) {
    'md' || 'markdown' || 'mdown' || 'mkd' => DocumentFormat.markdown,
    'csv' || 'tsv' || 'tab' => DocumentFormat.delimited,
    'docx' || 'docm' || 'dotx' => DocumentFormat.word,
    'xlsx' || 'xlsm' || 'xltx' => DocumentFormat.spreadsheet,
    'pptx' || 'ppsx' || 'potx' => DocumentFormat.slides,
    _ => _textExtensions.contains(extension) ? DocumentFormat.text : null,
  };
  if (byExtension != null) return byExtension;
  final mime = (mimeType ?? '').split(';').first.trim().toLowerCase();
  if (mime.isEmpty) return null;
  if (mime == 'text/markdown' || mime == 'text/x-markdown') {
    return DocumentFormat.markdown;
  }
  if (mime == 'text/csv' || mime == 'text/tab-separated-values') {
    return DocumentFormat.delimited;
  }
  if (mime.endsWith('wordprocessingml.document')) return DocumentFormat.word;
  if (mime.endsWith('spreadsheetml.sheet')) return DocumentFormat.spreadsheet;
  if (mime.endsWith('presentationml.presentation')) {
    return DocumentFormat.slides;
  }
  if (mime.startsWith('text/') || _textMimeTypes.contains(mime)) {
    return DocumentFormat.text;
  }
  return null;
}

/// How much of a file a preview reads. Every number bounds work done on
/// content the sender controls.
class DocumentLimits {
  const DocumentLimits({
    required this.blocks,
    required this.chars,
    required this.rows,
    required this.columns,
    required this.sheets,
    required this.cellChars,
    required this.inflateBytes,
  });

  /// The full-screen viewer.
  static const full = DocumentLimits(
    blocks: 4000,
    chars: 1500000,
    rows: 5000,
    columns: 64,
    sheets: 12,
    cellChars: 4000,
    inflateBytes: 48 * 1024 * 1024,
  );

  /// The few lines shown under a file in the timeline.
  static const inline = DocumentLimits(
    blocks: 12,
    chars: 2000,
    rows: 6,
    columns: 6,
    sheets: 1,
    cellChars: 120,
    inflateBytes: 12 * 1024 * 1024,
  );

  /// Headings, paragraphs, list items, tables and slides.
  final int blocks;

  /// Characters of text across the document.
  final int chars;

  /// Rows per sheet or table.
  final int rows;
  final int columns;
  final int sheets;
  final int cellChars;

  /// Uncompressed bytes read from one part of an Office file.
  final int inflateBytes;
}

/// A parsed file. [truncated] is true when a limit cut it short.
sealed class DocumentPreview {
  const DocumentPreview({required this.truncated});
  final bool truncated;
}

/// Text shown as written.
class TextPreview extends DocumentPreview {
  const TextPreview(
    this.text, {
    this.monospace = true,
    super.truncated = false,
  });
  final String text;

  /// False for prose (.txt), which reads better in the app font.
  final bool monospace;
}

/// Formatted text: Markdown, Word and PowerPoint.
class RichPreview extends DocumentPreview {
  const RichPreview(this.blocks, {super.truncated = false});
  final List<DocBlock> blocks;
}

/// Tables: CSV, TSV and Excel.
class SheetPreview extends DocumentPreview {
  const SheetPreview(this.sheets, {super.truncated = false});
  final List<DocSheet> sheets;
}

class DocSheet {
  const DocSheet({
    required this.name,
    required this.rows,
    this.rowNumbers,
    this.totalRows,
    this.totalColumns,
    this.truncated = false,
  });
  final String name;

  /// Cell text, one list per row. Rows may differ in length.
  final List<List<String>> rows;

  /// The spreadsheet's own number for each row (rows may be skipped in an
  /// .xlsx file); null when rows are simply 1, 2, 3…
  final List<int>? rowNumbers;

  /// Size the file declares, when it is larger than what was read.
  final int? totalRows;
  final int? totalColumns;
  final bool truncated;

  int get columnCount {
    var widest = 0;
    for (final row in rows) {
      if (row.length > widest) widest = row.length;
    }
    return widest;
  }
}

/// A run of text with one style.
class DocSpan {
  const DocSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.code = false,
    this.link,
  });
  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool code;

  /// Link target (Markdown only). Untrusted.
  final String? link;
}

sealed class DocBlock {
  const DocBlock();
}

class HeadingBlock extends DocBlock {
  const HeadingBlock(this.level, this.spans);

  /// 1 (largest) to 6.
  final int level;
  final List<DocSpan> spans;
}

class ParagraphBlock extends DocBlock {
  const ParagraphBlock(this.spans);
  final List<DocSpan> spans;
}

class ListItemBlock extends DocBlock {
  const ListItemBlock(this.spans, {this.depth = 0, this.marker = '•'});
  final List<DocSpan> spans;

  /// Nesting level, 0 for a top-level item.
  final int depth;

  /// `•`, `1.`, `☐`…
  final String marker;
}

class QuoteBlock extends DocBlock {
  const QuoteBlock(this.spans);
  final List<DocSpan> spans;
}

class CodeBlock extends DocBlock {
  const CodeBlock(this.text);
  final String text;
}

class TableBlock extends DocBlock {
  const TableBlock(this.rows, {this.header = false});
  final List<List<String>> rows;

  /// Whether the first row is a header.
  final bool header;
}

class RuleBlock extends DocBlock {
  const RuleBlock();
}

/// Start of a slide in a presentation.
class SlideBlock extends DocBlock {
  const SlideBlock(this.number);
  final int number;
}

/// Plain text of [spans].
String spansText(List<DocSpan> spans) {
  if (spans.length == 1) return spans.first.text;
  final out = StringBuffer();
  for (final span in spans) {
    out.write(span.text);
  }
  return out.toString();
}

/// Spreadsheet column name for a zero-based [index]: A, B … Z, AA, AB…
String columnLetters(int index) {
  var n = index + 1;
  final out = <int>[];
  while (n > 0) {
    n--;
    out.add(0x41 + n % 26);
    n ~/= 26;
  }
  return String.fromCharCodes(out.reversed);
}
