// Word, Excel and PowerPoint (Office Open XML) read for a preview.
//
// Each file is a ZIP of XML parts. Parts are inflated through [BoundedZip]
// and walked as a stream of XML events, never built into a tree, so memory
// and time stay proportional to what the preview shows. Element and
// attribute names are matched without their namespace prefix: `w:p` is the
// convention, not a rule.
import 'package:xml/xml_events.dart';

import 'bounded_zip.dart';
import 'document_model.dart';

const _smallPart = 4 * 1024 * 1024;

/// Events of [xml], ending quietly where the input stops being well formed
/// (a part cut off at the inflate limit ends mid-element).
Iterable<XmlEvent> _events(String xml) sync* {
  final iterator = parseEvents(xml).iterator;
  while (true) {
    try {
      if (!iterator.moveNext()) return;
    } catch (_) {
      return;
    }
    yield iterator.current;
  }
}

String _local(String name) {
  final colon = name.indexOf(':');
  return colon < 0 ? name : name.substring(colon + 1);
}

String? _attr(XmlStartElementEvent event, String local) {
  for (final attribute in event.attributes) {
    if (_local(attribute.name) == local) return attribute.value;
  }
  return null;
}

/// The relationship ID attribute (`r:id`), as opposed to a plain `id`.
String? _relationId(XmlStartElementEvent event) {
  for (final attribute in event.attributes) {
    if (attribute.name.contains(':') && _local(attribute.name) == 'id') {
      return attribute.value;
    }
  }
  return null;
}

/// False for `<w:b w:val="0"/>` and the like; true for a bare `<w:b/>`.
bool _enabled(XmlStartElementEvent event) =>
    !const {'0', 'false', 'none', 'off'}.contains(_attr(event, 'val'));

/// Relationship ID → target part, from a `.rels` part.
Map<String, String> _relationships(BoundedZip zip, String path, String base) {
  final part = zip.readText(path, maxBytes: _smallPart);
  final targets = <String, String>{};
  if (part == null) return targets;
  for (final event in _events(part.text)) {
    if (event is! XmlStartElementEvent ||
        _local(event.name) != 'Relationship') {
      continue;
    }
    final id = _attr(event, 'Id');
    final target = _attr(event, 'Target');
    if (id == null || target == null) continue;
    targets[id] = target.startsWith('/') ? target.substring(1) : '$base$target';
  }
  return targets;
}

/// Collects blocks up to the limits.
class _Blocks {
  _Blocks(this.limits);
  final DocumentLimits limits;
  final blocks = <DocBlock>[];
  int chars = 0;
  bool truncated = false;

  bool get full => truncated;

  void add(DocBlock block, [int length = 0]) {
    if (truncated) return;
    if (blocks.length >= limits.blocks || chars + length > limits.chars) {
      truncated = true;
      return;
    }
    blocks.add(block);
    chars += length;
  }
}

/// Runs of one paragraph; neighbours with the same style are joined (Word
/// splits a sentence into many runs).
class _Paragraph {
  final spans = <DocSpan>[];
  String? style;
  String? numberingId;
  int level = 0;
  int? outline;
  final _text = StringBuffer();
  bool _bold = false, _italic = false, _underline = false, _strike = false;

  void add(
    String text, {
    bool bold = false,
    bool italic = false,
    bool underline = false,
    bool strike = false,
  }) {
    if (text.isEmpty) return;
    if (_text.isNotEmpty &&
        (bold != _bold ||
            italic != _italic ||
            underline != _underline ||
            strike != _strike)) {
      _flush();
    }
    _bold = bold;
    _italic = italic;
    _underline = underline;
    _strike = strike;
    _text.write(text);
  }

  void _flush() {
    if (_text.isEmpty) return;
    spans.add(
      DocSpan(
        _text.toString(),
        bold: _bold,
        italic: _italic,
        underline: _underline,
        strike: _strike,
      ),
    );
    _text.clear();
  }

  List<DocSpan> finish() {
    _flush();
    return spans;
  }
}

// --- Word ------------------------------------------------------------------

/// Subtrees with no body text, or with text that must not be shown: the
/// fallback copy of a drawing, deleted and moved-away text, old formatting.
const _wordSkipped = {
  'Fallback',
  'drawing',
  'pict',
  'object',
  'del',
  'moveFrom',
  'rPrChange',
  'pPrChange',
  'sectPr',
  'tblPr',
  'tblGrid',
  'trPr',
  'tcPr',
};

class _WordStyle {
  int? heading;
  String? numberingId;
}

/// Style ID → heading level and list, from `word/styles.xml`. Style IDs are
/// localised ("berschrift1"); the style's name ("heading 1") is not.
Map<String, _WordStyle> _wordStyles(BoundedZip zip) {
  final part = zip.readText('word/styles.xml', maxBytes: _smallPart);
  final styles = <String, _WordStyle>{};
  if (part == null) return styles;
  _WordStyle? style;
  for (final event in _events(part.text)) {
    if (event is XmlStartElementEvent) {
      switch (_local(event.name)) {
        case 'style':
          final id = _attr(event, 'styleId');
          style = id == null || event.isSelfClosing
              ? null
              : styles[id] = _WordStyle();
        case 'name':
          final name = (_attr(event, 'val') ?? '').toLowerCase();
          final match = RegExp(r'^heading ([1-9])$').firstMatch(name);
          if (match != null) {
            style?.heading = int.parse(match.group(1)!);
          } else if (name == 'title') {
            style?.heading = 1;
          } else if (name == 'subtitle') {
            style?.heading = 2;
          }
        case 'outlineLvl':
          final level = int.tryParse(_attr(event, 'val') ?? '');
          if (level != null && level >= 0 && level < 9) {
            style?.heading ??= level + 1;
          }
        case 'numId':
          style?.numberingId = _attr(event, 'val');
      }
    } else if (event is XmlEndElementEvent && _local(event.name) == 'style') {
      style = null;
    }
  }
  return styles;
}

/// List markers from `word/numbering.xml`, counting numbered items.
class _WordNumbering {
  _WordNumbering(BoundedZip zip) {
    final part = zip.readText('word/numbering.xml', maxBytes: _smallPart);
    if (part == null) return;
    String? abstractId;
    String? numberingId;
    int? level;
    for (final event in _events(part.text)) {
      if (event is XmlStartElementEvent) {
        switch (_local(event.name)) {
          case 'abstractNum':
            abstractId = _attr(event, 'abstractNumId');
            numberingId = null;
          case 'num':
            numberingId = _attr(event, 'numId');
            abstractId = null;
          case 'abstractNumId':
            final id = _attr(event, 'val');
            if (numberingId != null && id != null) {
              _abstractOf[numberingId] = id;
            }
          case 'lvl':
            level = int.tryParse(_attr(event, 'ilvl') ?? '');
          case 'numFmt':
            final format = _attr(event, 'val');
            if (abstractId != null && level != null && format != null) {
              _formats['$abstractId/$level'] = format;
            }
        }
      } else if (event is XmlEndElementEvent && _local(event.name) == 'lvl') {
        level = null;
      }
    }
  }

  final _abstractOf = <String, String>{};
  final _formats = <String, String>{};
  final _counters = <String, List<int>>{};

  String marker(String numberingId, int level) {
    final format =
        _formats['${_abstractOf[numberingId]}/$level'] ??
        (_abstractOf.containsKey(numberingId) ? 'decimal' : 'bullet');
    if (format == 'bullet') return '•';
    if (format == 'none') return '';
    final counters = _counters.putIfAbsent(
      numberingId,
      () => List<int>.filled(9, 0),
    );
    counters[level]++;
    for (var deeper = level + 1; deeper < counters.length; deeper++) {
      counters[deeper] = 0;
    }
    final n = counters[level];
    return switch (format) {
      'lowerLetter' => '${_letters(n)}.',
      'upperLetter' => '${_letters(n).toUpperCase()}.',
      'lowerRoman' => '${_roman(n)}.',
      'upperRoman' => '${_roman(n).toUpperCase()}.',
      _ => '$n.',
    };
  }

  static String _letters(int n) => columnLetters(n - 1).toLowerCase();

  static String _roman(int n) {
    if (n <= 0 || n >= 4000) return '$n';
    const values = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
    const symbols = [
      'm', 'cm', 'd', 'cd', 'c', 'xc', 'l', 'xl', 'x', 'ix', 'v', 'iv', 'i', //
    ];
    final out = StringBuffer();
    var rest = n;
    for (var i = 0; i < values.length; i++) {
      while (rest >= values[i]) {
        out.write(symbols[i]);
        rest -= values[i];
      }
    }
    return out.toString();
  }
}

/// The body text of a .docx file: headings, paragraphs, lists and tables.
/// Pictures, text boxes, headers, footers and footnotes are left out.
RichPreview parseWord(BoundedZip zip, DocumentLimits limits) {
  final main = zip.readText('word/document.xml', maxBytes: limits.inflateBytes);
  if (main == null) throw const FormatException('Not a Word document');
  final styles = _wordStyles(zip);
  final numbering = _WordNumbering(zip);
  final out = _Blocks(limits);

  var skip = 0;
  _Paragraph? paragraph;
  var inParagraphProperties = false;
  var inRun = false;
  var inRunProperties = false;
  var inText = false;
  var bold = false, italic = false, underline = false, strike = false;
  var tableDepth = 0;
  List<List<String>>? rows;
  List<String>? row;
  StringBuffer? cell;
  var tableChars = 0;

  void endParagraph() {
    final done = paragraph;
    paragraph = null;
    if (done == null) return;
    final spans = done.finish();
    final text = spansText(spans);
    if (tableDepth > 0) {
      final target = cell;
      if (target == null || text.trim().isEmpty) return;
      if (target.length < limits.cellChars) {
        if (target.isNotEmpty) target.write('\n');
        target.write(text);
      }
      return;
    }
    if (text.trim().isEmpty) return;
    final style = styles[done.style];
    final outline = done.outline;
    final heading =
        style?.heading ??
        (outline != null && outline >= 0 && outline < 9 ? outline + 1 : null);
    final list = done.numberingId ?? style?.numberingId;
    if (heading != null) {
      out.add(HeadingBlock(heading.clamp(1, 6), spans), text.length);
    } else if (list != null && list != '0') {
      final level = done.level.clamp(0, 8);
      out.add(
        ListItemBlock(
          spans,
          depth: level,
          marker: numbering.marker(list, level),
        ),
        text.length,
      );
    } else {
      out.add(ParagraphBlock(spans), text.length);
    }
  }

  for (final event in _events(main.text)) {
    if (out.full) break;
    if (event is XmlStartElementEvent) {
      final name = _local(event.name);
      if (skip > 0) {
        if (!event.isSelfClosing) skip++;
        continue;
      }
      if (_wordSkipped.contains(name)) {
        if (!event.isSelfClosing) skip = 1;
        continue;
      }
      switch (name) {
        case 'p':
          if (!event.isSelfClosing) paragraph = _Paragraph();
        case 'pPr':
          inParagraphProperties = !event.isSelfClosing;
        case 'pStyle':
          if (inParagraphProperties) paragraph?.style = _attr(event, 'val');
        case 'outlineLvl':
          if (inParagraphProperties) {
            paragraph?.outline = int.tryParse(_attr(event, 'val') ?? '');
          }
        case 'ilvl':
          if (inParagraphProperties) {
            paragraph?.level = int.tryParse(_attr(event, 'val') ?? '') ?? 0;
          }
        case 'numId':
          if (inParagraphProperties) {
            paragraph?.numberingId = _attr(event, 'val');
          }
        case 'r':
          if (!event.isSelfClosing && !inParagraphProperties) {
            inRun = true;
            bold = italic = underline = strike = false;
          }
        case 'rPr':
          inRunProperties = inRun && !event.isSelfClosing;
        case 'b':
          if (inRunProperties) bold = _enabled(event);
        case 'i':
          if (inRunProperties) italic = _enabled(event);
        case 'u':
          if (inRunProperties) underline = _enabled(event);
        case 'strike' || 'dstrike':
          if (inRunProperties) strike = _enabled(event);
        case 't':
          inText = inRun && !event.isSelfClosing;
        case 'tab':
          if (inRun && !inRunProperties) paragraph?.add('\t');
        case 'br' || 'cr':
          if (inRun && !inRunProperties) paragraph?.add('\n');
        case 'noBreakHyphen':
          if (inRun && !inRunProperties) paragraph?.add('-');
        case 'tbl':
          tableDepth++;
          if (tableDepth == 1) {
            rows = [];
            tableChars = 0;
          }
        case 'tr':
          if (tableDepth == 1) row = [];
        case 'tc':
          if (tableDepth == 1) cell = StringBuffer();
      }
    } else if (event is XmlEndElementEvent) {
      if (skip > 0) {
        skip--;
        continue;
      }
      switch (_local(event.name)) {
        case 'pPr':
          inParagraphProperties = false;
        case 'rPr':
          inRunProperties = false;
        case 'r':
          inRun = false;
          inText = false;
        case 't':
          inText = false;
        case 'p':
          endParagraph();
        case 'tc':
          if (tableDepth == 1) {
            final text = (cell?.toString() ?? '').trim();
            if ((row?.length ?? limits.columns) < limits.columns) {
              row!.add(text);
              tableChars += text.length;
            }
            cell = null;
          }
        case 'tr':
          if (tableDepth == 1 && row != null && rows != null) {
            if (rows.length < limits.rows) {
              rows.add(row);
            } else {
              out.truncated = true;
            }
            row = null;
          }
        case 'tbl':
          if (tableDepth > 0) tableDepth--;
          if (tableDepth == 0) {
            final table = rows;
            rows = null;
            if (table != null && table.any((r) => r.any((c) => c.isNotEmpty))) {
              out.add(TableBlock(table), tableChars);
            }
          }
      }
    } else if (inText && skip == 0) {
      final text = switch (event) {
        XmlTextEvent() => event.value,
        XmlCDATAEvent() => event.value,
        _ => '',
      };
      paragraph?.add(
        text,
        bold: bold,
        italic: italic,
        underline: underline,
        strike: strike,
      );
    }
  }
  return RichPreview(out.blocks, truncated: out.truncated || main.truncated);
}

// --- Excel -----------------------------------------------------------------

enum _DateKind { date, time, dateTime }

_DateKind? _builtInDate(int format) => switch (format) {
  >= 14 && <= 17 => _DateKind.date,
  >= 18 && <= 21 => _DateKind.time,
  22 => _DateKind.dateTime,
  >= 27 && <= 31 => _DateKind.date,
  >= 32 && <= 35 => _DateKind.time,
  36 => _DateKind.date,
  >= 45 && <= 47 => _DateKind.time,
  >= 50 && <= 58 => _DateKind.date,
  _ => null,
};

/// Whether a custom number format shows a date or time. Literal text,
/// colours and conditions (`"…"`, `[…]`, `\x`) are ignored first.
_DateKind? _customDate(String code) {
  final clean = code
      .replaceAll(RegExp(r'"[^"]*"'), '')
      .replaceAll(RegExp(r'\[[^\]]*\]'), '')
      .replaceAll(RegExp(r'\\.'), '')
      .toLowerCase();
  if (clean.contains('general')) return null;
  final time = clean.contains('h') || clean.contains('s');
  final date =
      clean.contains('d') ||
      clean.contains('y') ||
      (!time && clean.contains('m'));
  if (date && time) return _DateKind.dateTime;
  if (date) return _DateKind.date;
  if (time) return _DateKind.time;
  return null;
}

/// Date kind of each cell style (index into `cellXfs`), from `xl/styles.xml`.
List<_DateKind?> _dateStyles(BoundedZip zip) {
  final part = zip.readText('xl/styles.xml', maxBytes: _smallPart);
  if (part == null) return const [];
  final custom = <int, _DateKind?>{};
  final kinds = <_DateKind?>[];
  var inCellFormats = false;
  for (final event in _events(part.text)) {
    if (event is XmlStartElementEvent) {
      switch (_local(event.name)) {
        case 'numFmt':
          final id = int.tryParse(_attr(event, 'numFmtId') ?? '');
          final code = _attr(event, 'formatCode');
          if (id != null && code != null) custom[id] = _customDate(code);
        case 'cellXfs':
          inCellFormats = !event.isSelfClosing;
        case 'xf':
          if (inCellFormats && kinds.length < 65536) {
            final id = int.tryParse(_attr(event, 'numFmtId') ?? '') ?? 0;
            kinds.add(custom.containsKey(id) ? custom[id] : _builtInDate(id));
          }
      }
    } else if (event is XmlEndElementEvent && _local(event.name) == 'cellXfs') {
      inCellFormats = false;
    }
  }
  return kinds;
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov', //
  'Dec',
];

/// A spreadsheet serial day number as text, e.g. `5 Nov 2026 14:30`.
String formatSerialDate(double serial, {bool date1904 = false, int kind = 0}) {
  final type = _DateKind.values[kind];
  // 1900 system: day 1 is 1 January 1900 and day 60 is the 29 February 1900
  // that never happened, so later days count from 30 December 1899.
  final epoch = date1904
      ? DateTime.utc(1904)
      : (serial < 60 ? DateTime.utc(1899, 12, 31) : DateTime.utc(1899, 12, 30));
  final moment = epoch.add(Duration(seconds: (serial * 86400).round()));
  String two(int n) => n.toString().padLeft(2, '0');
  final day = '${moment.day} ${_months[moment.month - 1]} ${moment.year}';
  final clock =
      '${two(moment.hour)}:${two(moment.minute)}'
      '${moment.second == 0 ? '' : ':${two(moment.second)}'}';
  return switch (type) {
    _DateKind.date => day,
    _DateKind.time => clock,
    _DateKind.dateTime => '$day $clock',
  };
}

/// A stored number as Excel would show it under the General format: no
/// binary-fraction noise (0.30000000000000004), no trailing zeros, and an
/// exponent for very large or very small values.
String formatCellNumber(String raw) {
  final value = double.tryParse(raw);
  if (value == null || !value.isFinite) return raw;
  final size = value.abs();
  if (value == value.roundToDouble() && size < 1e15) {
    return value.toInt().toString();
  }
  String trimmed(String digits) {
    if (!digits.contains('.')) return digits;
    final text = digits.replaceFirst(RegExp(r'0+$'), '');
    return text.endsWith('.') ? text.substring(0, text.length - 1) : text;
  }

  if (size >= 1e15 || size < 1e-9) {
    final parts = value.toStringAsExponential(11).split('e');
    final exponent = int.parse(parts[1]);
    return '${trimmed(parts[0])}E${exponent < 0 ? '-' : '+'}'
        '${exponent.abs().toString().padLeft(2, '0')}';
  }
  final text = value.toStringAsPrecision(12);
  return text.contains('e') ? value.toString() : trimmed(text);
}

/// Zero-based column of a cell reference such as `BC12`; null if malformed.
int? _columnOf(String? reference) {
  if (reference == null) return null;
  var column = 0;
  var letters = 0;
  for (final unit in reference.codeUnits) {
    final upper = unit >= 0x61 && unit <= 0x7A ? unit - 0x20 : unit;
    if (upper < 0x41 || upper > 0x5A) break;
    column = column * 26 + (upper - 0x40);
    if (++letters > 3) return null;
  }
  return letters == 0 ? null : column - 1;
}

int? _rowOf(String? reference) {
  if (reference == null) return null;
  final match = RegExp(r'(\d+)$').firstMatch(reference);
  return match == null ? null : int.tryParse(match.group(1)!);
}

class _SheetRef {
  _SheetRef(this.name, this.relationId);
  final String name;
  final String? relationId;
}

class _SheetData {
  _SheetData(this.name);
  final String name;
  final rows = <List<String>>[];
  final numbers = <int>[];

  /// Cells still holding a shared-string index: (row, column, index).
  final shared = <(int, int, int)>[];
  int? totalRows;
  int? totalColumns;
  bool truncated = false;
}

/// The visible sheets of an .xlsx file, as the text of their cells. Formula
/// cells show their last calculated value; dates and times are formatted,
/// other number formats (currency, percent) are not applied.
SheetPreview parseSpreadsheet(BoundedZip zip, DocumentLimits limits) {
  final workbook = zip.readText('xl/workbook.xml', maxBytes: _smallPart);
  if (workbook == null) throw const FormatException('Not an Excel workbook');
  final refs = <_SheetRef>[];
  var date1904 = false;
  for (final event in _events(workbook.text)) {
    if (event is! XmlStartElementEvent) continue;
    switch (_local(event.name)) {
      case 'workbookPr':
        date1904 = const {'1', 'true'}.contains(_attr(event, 'date1904'));
      case 'sheet':
        final state = _attr(event, 'state');
        if (state != 'hidden' && state != 'veryHidden' && refs.length < 256) {
          refs.add(
            _SheetRef(_attr(event, 'name') ?? 'Sheet', _relationId(event)),
          );
        }
    }
  }
  final targets = _relationships(zip, 'xl/_rels/workbook.xml.rels', 'xl/');
  final dateStyles = _dateStyles(zip);
  final sheets = <_SheetData>[];
  final needed = <int>{};
  var more = false;
  for (var index = 0; index < refs.length; index++) {
    if (sheets.length >= limits.sheets) {
      more = true;
      break;
    }
    final ref = refs[index];
    final path =
        targets[ref.relationId] ?? 'xl/worksheets/sheet${index + 1}.xml';
    final part = zip.readText(path, maxBytes: limits.inflateBytes);
    if (part == null) continue;
    final sheet = _readSheet(
      ref.name,
      part,
      limits: limits,
      dateStyles: dateStyles,
      date1904: date1904,
    );
    for (final (_, _, shared) in sheet.shared) {
      needed.add(shared);
    }
    sheets.add(sheet);
  }
  if (sheets.isEmpty) throw const FormatException('No readable sheet');
  final strings = needed.isEmpty
      ? const <int, String>{}
      : _sharedStrings(zip, needed, limits);
  return SheetPreview([
    for (final sheet in sheets) _finishSheet(sheet, strings),
  ], truncated: more || sheets.any((sheet) => sheet.truncated));
}

DocSheet _finishSheet(_SheetData sheet, Map<int, String> strings) {
  for (final (row, column, index) in sheet.shared) {
    sheet.rows[row][column] = strings[index] ?? '';
  }
  // Drop rows that turned out to hold nothing (cells with only a style).
  final rows = <List<String>>[];
  final numbers = <int>[];
  for (var index = 0; index < sheet.rows.length; index++) {
    final row = sheet.rows[index];
    if (row.every((cell) => cell.isEmpty)) continue;
    rows.add(row);
    numbers.add(sheet.numbers[index]);
  }
  final total = sheet.totalRows;
  final columns = sheet.totalColumns;
  return DocSheet(
    name: sheet.name,
    rows: rows,
    rowNumbers: numbers,
    totalRows: sheet.truncated && total != null && total > rows.length
        ? total
        : null,
    totalColumns: sheet.truncated ? columns : null,
    truncated: sheet.truncated,
  );
}

_SheetData _readSheet(
  String name,
  ZipText part, {
  required DocumentLimits limits,
  required List<_DateKind?> dateStyles,
  required bool date1904,
}) {
  final sheet = _SheetData(name)..truncated = part.truncated;
  var rowNumber = 0;
  List<String>? row;
  var column = -1;
  String? type;
  int? style;
  var inValue = false;
  var inInline = false;
  var inInlineText = false;
  var phonetic = 0;
  final value = StringBuffer();
  var hasCell = false;

  for (final event in _events(part.text)) {
    if (event is XmlStartElementEvent) {
      switch (_local(event.name)) {
        case 'dimension':
          final reference = _attr(event, 'ref')?.split(':').last;
          sheet.totalRows = _rowOf(reference);
          final last = _columnOf(reference);
          sheet.totalColumns = last == null ? null : last + 1;
        case 'row':
          if (sheet.rows.length >= limits.rows) {
            sheet.truncated = true;
            return sheet;
          }
          rowNumber = int.tryParse(_attr(event, 'r') ?? '') ?? rowNumber + 1;
          column = -1;
          row = event.isSelfClosing ? null : <String>[];
        case 'c':
          column = _columnOf(_attr(event, 'r')) ?? column + 1;
          type = _attr(event, 't');
          style = int.tryParse(_attr(event, 's') ?? '');
          value.clear();
          hasCell = !event.isSelfClosing;
        case 'v':
          inValue = hasCell && !event.isSelfClosing;
        case 'is':
          inInline = hasCell && !event.isSelfClosing;
        case 'rPh':
          if (!event.isSelfClosing) phonetic++;
        case 't':
          inInlineText = inInline && phonetic == 0 && !event.isSelfClosing;
      }
    } else if (event is XmlEndElementEvent) {
      switch (_local(event.name)) {
        case 'v':
          inValue = false;
        case 'is':
          inInline = false;
        case 'rPh':
          if (phonetic > 0) phonetic--;
        case 't':
          inInlineText = false;
        case 'c':
          final target = row;
          if (!hasCell || target == null) break;
          hasCell = false;
          final raw = value.toString();
          if (raw.isEmpty) break;
          if (column >= limits.columns) {
            sheet.truncated = true;
            break;
          }
          while (target.length <= column) {
            target.add('');
          }
          if (type == 's') {
            final index = int.tryParse(raw.trim());
            if (index != null && index >= 0) {
              sheet.shared.add((sheet.rows.length, column, index));
            }
            break;
          }
          final kind = style != null && style >= 0 && style < dateStyles.length
              ? dateStyles[style]
              : null;
          final number = double.tryParse(raw);
          var text = switch (type) {
            'b' => raw.trim() == '1' ? 'TRUE' : 'FALSE',
            'str' || 'inlineStr' || 'e' || 'd' => raw,
            _ =>
              kind != null && number != null && number >= 0 && number < 2958466
                  ? formatSerialDate(
                      number,
                      date1904: date1904,
                      kind: kind.index,
                    )
                  : formatCellNumber(raw),
          };
          if (text.length > limits.cellChars) {
            text = '${text.substring(0, limits.cellChars)}…';
          }
          target[column] = text;
        case 'row':
          final done = row;
          row = null;
          if (done == null) break;
          // A row whose cells hold only shared strings is all '' for now;
          // the strings are filled in once they have been read.
          if (done.isEmpty) break;
          sheet.rows.add(done);
          sheet.numbers.add(rowNumber);
      }
    } else if (inValue || inInlineText) {
      if (value.length <= limits.cellChars) {
        value.write(switch (event) {
          XmlTextEvent() => event.value,
          XmlCDATAEvent() => event.value,
          _ => '',
        });
      }
    }
  }
  return sheet;
}

/// The shared strings at the [needed] indexes, from `xl/sharedStrings.xml`.
Map<int, String> _sharedStrings(
  BoundedZip zip,
  Set<int> needed,
  DocumentLimits limits,
) {
  final part = zip.readText(
    'xl/sharedStrings.xml',
    maxBytes: limits.inflateBytes,
  );
  final strings = <int, String>{};
  if (part == null) return strings;
  final last = needed.reduce((a, b) => a > b ? a : b);
  var index = -1;
  var wanted = false;
  var inText = false;
  var phonetic = 0;
  final text = StringBuffer();
  for (final event in _events(part.text)) {
    if (event is XmlStartElementEvent) {
      switch (_local(event.name)) {
        case 'si':
          index++;
          if (index > last) return strings;
          wanted = needed.contains(index);
          text.clear();
          if (event.isSelfClosing && wanted) strings[index] = '';
        case 'rPh':
          if (!event.isSelfClosing) phonetic++;
        case 't':
          inText = wanted && phonetic == 0 && !event.isSelfClosing;
      }
    } else if (event is XmlEndElementEvent) {
      switch (_local(event.name)) {
        case 't':
          inText = false;
        case 'rPh':
          if (phonetic > 0) phonetic--;
        case 'si':
          if (wanted) {
            final value = text.toString();
            strings[index] = value.length > limits.cellChars
                ? '${value.substring(0, limits.cellChars)}…'
                : value;
          }
      }
    } else if (inText && text.length <= limits.cellChars) {
      text.write(switch (event) {
        XmlTextEvent() => event.value,
        XmlCDATAEvent() => event.value,
        _ => '',
      });
    }
  }
  return strings;
}

// --- PowerPoint ------------------------------------------------------------

/// Slide parts in presentation order.
List<String> _slideOrder(BoundedZip zip) {
  final targets = _relationships(
    zip,
    'ppt/_rels/presentation.xml.rels',
    'ppt/',
  );
  final order = <String>[];
  final presentation = zip.readText(
    'ppt/presentation.xml',
    maxBytes: _smallPart,
  );
  if (presentation != null) {
    for (final event in _events(presentation.text)) {
      if (event is XmlStartElementEvent && _local(event.name) == 'sldId') {
        final target = targets[_relationId(event)];
        if (target != null && zip.contains(target) && order.length < 2000) {
          order.add(target);
        }
      }
    }
  }
  if (order.isNotEmpty) return order;
  // No usable list: fall back to slide1.xml, slide2.xml…
  final pattern = RegExp(r'^ppt/slides/slide(\d+)\.xml$');
  final numbered = <(int, String)>[
    for (final name in zip.names)
      if (pattern.firstMatch(name) case final match?)
        (int.parse(match.group(1)!), name),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, name) in numbered.take(2000)) name];
}

/// The text of a .pptx file, slide by slide: titles, body text and tables.
/// Pictures, charts and speaker notes are left out.
RichPreview parseSlides(BoundedZip zip, DocumentLimits limits) {
  final order = _slideOrder(zip);
  if (order.isEmpty) throw const FormatException('Not a presentation');
  final out = _Blocks(limits);
  var cut = false;
  for (var index = 0; index < order.length && !out.full; index++) {
    final part = zip.readText(order[index], maxBytes: _smallPart * 2);
    if (part == null) continue;
    cut = cut || part.truncated;
    out.add(SlideBlock(index + 1));
    _readSlide(part.text, out, limits);
  }
  return RichPreview(out.blocks, truncated: out.truncated || cut);
}

void _readSlide(String xml, _Blocks out, DocumentLimits limits) {
  var skip = 0;
  String? placeholder;
  var hasPlaceholder = false;
  var inBody = false;
  _Paragraph? paragraph;
  var inRun = false;
  var inText = false;
  var bold = false, italic = false, underline = false, strike = false;
  List<List<String>>? rows;
  List<String>? row;
  StringBuffer? cell;
  var tableChars = 0;

  for (final event in _events(xml)) {
    if (out.full) return;
    if (event is XmlStartElementEvent) {
      final name = _local(event.name);
      if (skip > 0) {
        if (!event.isSelfClosing) skip++;
        continue;
      }
      if (name == 'Fallback') {
        if (!event.isSelfClosing) skip = 1;
        continue;
      }
      switch (name) {
        case 'sp':
          placeholder = null;
          hasPlaceholder = false;
        case 'ph':
          hasPlaceholder = true;
          placeholder = _attr(event, 'type');
        case 'txBody':
          inBody = !event.isSelfClosing;
        case 'p':
          if (inBody && !event.isSelfClosing) paragraph = _Paragraph();
        case 'pPr':
          paragraph?.level = int.tryParse(_attr(event, 'lvl') ?? '') ?? 0;
        case 'r' || 'fld':
          if (paragraph != null && !event.isSelfClosing) {
            inRun = true;
            bold = italic = underline = strike = false;
          }
        case 'rPr':
          if (inRun) {
            bold = const {'1', 'true'}.contains(_attr(event, 'b'));
            italic = const {'1', 'true'}.contains(_attr(event, 'i'));
            final line = _attr(event, 'u');
            underline = line != null && line != 'none';
            final struck = _attr(event, 'strike');
            strike = struck != null && struck != 'noStrike';
          }
        case 't':
          inText = inRun && !event.isSelfClosing;
        case 'br':
          paragraph?.add('\n');
        case 'tbl':
          rows = [];
          tableChars = 0;
        case 'tr':
          if (rows != null) row = [];
        case 'tc':
          if (row != null) cell = StringBuffer();
      }
    } else if (event is XmlEndElementEvent) {
      if (skip > 0) {
        skip--;
        continue;
      }
      switch (_local(event.name)) {
        case 'sp':
          placeholder = null;
          hasPlaceholder = false;
        case 'txBody':
          inBody = false;
        case 'r' || 'fld':
          inRun = false;
          inText = false;
        case 't':
          inText = false;
        case 'p':
          final done = paragraph;
          paragraph = null;
          if (done == null) break;
          final spans = done.finish();
          final text = spansText(spans);
          if (text.trim().isEmpty) break;
          final target = cell;
          if (target != null) {
            if (target.length < limits.cellChars) {
              if (target.isNotEmpty) target.write('\n');
              target.write(text);
            }
          } else if (placeholder == 'title' || placeholder == 'ctrTitle') {
            out.add(HeadingBlock(2, spans), text.length);
          } else if (hasPlaceholder && placeholder != 'subTitle') {
            out.add(
              ListItemBlock(spans, depth: done.level.clamp(0, 8)),
              text.length,
            );
          } else {
            out.add(ParagraphBlock(spans), text.length);
          }
        case 'tc':
          final text = (cell?.toString() ?? '').trim();
          cell = null;
          if (row != null && row.length < limits.columns) {
            row.add(text);
            tableChars += text.length;
          }
        case 'tr':
          if (row != null && rows != null) {
            if (rows.length < limits.rows) {
              rows.add(row);
            } else {
              out.truncated = true;
            }
          }
          row = null;
        case 'tbl':
          final table = rows;
          rows = null;
          if (table != null && table.any((r) => r.any((c) => c.isNotEmpty))) {
            out.add(TableBlock(table, header: true), tableChars);
          }
      }
    } else if (inText && skip == 0) {
      paragraph?.add(
        switch (event) {
          XmlTextEvent() => event.value,
          XmlCDATAEvent() => event.value,
          _ => '',
        },
        bold: bold,
        italic: italic,
        underline: underline,
        strike: strike,
      );
    }
  }
}
