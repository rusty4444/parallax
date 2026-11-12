import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart';

/// Markdown formatting for the composer's Element X-style toolbar.
///
/// The composer keeps plain markdown text (drafts and the outbox store it
/// verbatim); these pure functions scan that text for live styling and
/// active-button state, and rewrite it for toolbar actions. Inline formats
/// are line-scoped: a multi-line selection is formatted line by line, which
/// keeps the markers inside paragraphs, list items and quotes.

/// Inline formats recognised in composer text.
enum InlineFormat {
  bold,
  italic,
  underline,
  strikethrough,
  inlineCode,
  link,

  /// A bare `https://…` URL (styled like a link, no markers).
  autolink,
  spoiler,
}

/// A recognised inline span. Offsets are absolute in the scanned text.
@immutable
class InlineFormatSpan {
  const InlineFormatSpan(
    this.format, {
    required this.start,
    required this.contentStart,
    required this.contentEnd,
    required this.end,
    this.url,
  });
  final InlineFormat format;

  /// Start of the opening marker.
  final int start;
  final int contentStart;
  final int contentEnd;

  /// End of the closing marker (exclusive).
  final int end;

  /// Link destination for [InlineFormat.link] / [InlineFormat.autolink].
  final String? url;

  int get openLength => contentStart - start;
  int get closeLength => end - contentEnd;

  @override
  String toString() =>
      'InlineFormatSpan($format, $start, $contentStart, $contentEnd, $end)';
}

/// Block role of a single line.
enum LineKind { text, bullet, numbered, quote, fence, code }

/// One line of composer text. Offsets are absolute and exclude the `\n`.
@immutable
class MarkdownLine {
  const MarkdownLine({
    required this.start,
    required this.end,
    required this.kind,
    required this.contentStart,
    this.indent = 0,
    this.number,
  });
  final int start;
  final int end;
  final LineKind kind;

  /// Leading spaces.
  final int indent;

  /// First offset after the block marker (`- `, `1. `, `> `), or after the
  /// indentation for other lines.
  final int contentStart;

  /// The number of a numbered list item.
  final int? number;

  bool get isList => kind == LineKind.bullet || kind == LineKind.numbered;
  bool get isCode => kind == LineKind.code || kind == LineKind.fence;

  /// Width of the list marker including its trailing space(s).
  int get markerWidth => contentStart - start - indent;

  bool isBlank(String text) => text.substring(start, end).trim().isEmpty;
}

/// The result of scanning composer text.
@immutable
class MarkdownScan {
  const MarkdownScan(this.text, this.lines, this.spans);
  final String text;
  final List<MarkdownLine> lines;
  final List<InlineFormatSpan> spans;

  /// Index of the line containing [offset] (the last line for the end).
  int lineIndexAt(int offset) {
    for (var i = 0; i < lines.length; i++) {
      if (offset <= lines[i].end) return i;
    }
    return lines.length - 1;
  }
}

final _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');
final _quote = RegExp(r'^( {0,3})>( ?)');
final _bullet = RegExp(r'^( *)([-*+]) +');
final _numbered = RegExp(r'^( *)(\d{1,9})([.)]) +');
final _link = RegExp(r'\[([^\[\]\n]*)\]\(([^()\s]*)\)');
final _autolink = RegExp(
  r'''(?:https?://|mailto:)[^\s<>()\[\]]*[^\s<>()\[\].,;:!?'"]''',
  caseSensitive: false,
);
final _underline = RegExp(r'<u>(.+?)</u>');
final _spoiler = RegExp(r'\|\|(.+?)\|\|');
final _strike = RegExp(r'~~(?=\S)(.+?)(?<=\S)~~');
final _boldStars = RegExp(r'\*\*(?=\S)(.+?)(?<=\S)\*\*');
final _boldUnderscores = RegExp(
  r'(?<![A-Za-z0-9_])__(?=\S)(.+?)(?<=\S)__(?![A-Za-z0-9_])',
);
final _italicStar = RegExp(r'(?<!\*)\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)');
final _italicUnderscore = RegExp(
  r'(?<![A-Za-z0-9_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![A-Za-z0-9_])',
);

const _maskCode = '\u0000';
const _maskMarker = '\u0001';
const _maskEscape = '\u0002';
const _maskUrl = '\u0003';

MarkdownScan? _lastScan;

/// Scans [text] into lines and inline spans. The last result is cached.
MarkdownScan scanMarkdown(String text) {
  final cached = _lastScan;
  if (cached != null && identical(cached.text, text)) return cached;
  if (cached != null && cached.text == text) return cached;
  final lines = <MarkdownLine>[];
  final spans = <InlineFormatSpan>[];
  String? fenceChar;
  var fenceLength = 0;
  var offset = 0;
  for (final raw in text.split('\n')) {
    final start = offset;
    final end = offset + raw.length;
    offset = end + 1;
    final fence = _fence.firstMatch(raw);
    if (fenceChar != null) {
      // Inside a fenced block: only a matching fence without info closes it.
      if (fence != null &&
          fence[1]![0] == fenceChar &&
          fence[1]!.length >= fenceLength &&
          fence[2]!.trim().isEmpty) {
        fenceChar = null;
        lines.add(
          MarkdownLine(
            start: start,
            end: end,
            kind: LineKind.fence,
            contentStart: end,
          ),
        );
      } else {
        lines.add(
          MarkdownLine(
            start: start,
            end: end,
            kind: LineKind.code,
            contentStart: start,
          ),
        );
      }
      continue;
    }
    if (fence != null && !(fence[1]![0] == '`' && fence[2]!.contains('`'))) {
      fenceChar = fence[1]![0];
      fenceLength = fence[1]!.length;
      lines.add(
        MarkdownLine(
          start: start,
          end: end,
          kind: LineKind.fence,
          contentStart: end,
        ),
      );
      continue;
    }
    final MarkdownLine line;
    final quote = _quote.firstMatch(raw);
    final numbered = _numbered.firstMatch(raw);
    final bullet = _bullet.firstMatch(raw);
    if (quote != null) {
      line = MarkdownLine(
        start: start,
        end: end,
        kind: LineKind.quote,
        indent: quote[1]!.length,
        contentStart: start + quote.end,
      );
    } else if (numbered != null) {
      line = MarkdownLine(
        start: start,
        end: end,
        kind: LineKind.numbered,
        indent: numbered[1]!.length,
        contentStart: start + numbered.end,
        number: int.tryParse(numbered[2]!),
      );
    } else if (bullet != null) {
      line = MarkdownLine(
        start: start,
        end: end,
        kind: LineKind.bullet,
        indent: bullet[1]!.length,
        contentStart: start + bullet.end,
      );
    } else {
      final indent = raw.length - raw.trimLeft().length;
      line = MarkdownLine(
        start: start,
        end: end,
        kind: LineKind.text,
        indent: indent,
        contentStart: start + indent,
      );
    }
    lines.add(line);
    spans.addAll(
      scanInline(
        text.substring(line.contentStart, end),
        base: line.contentStart,
      ),
    );
  }
  return _lastScan = MarkdownScan(text, List.unmodifiable(lines), spans);
}

bool _isAsciiPunctuation(int c) =>
    (c >= 0x21 && c <= 0x2F) ||
    (c >= 0x3A && c <= 0x40) ||
    (c >= 0x5B && c <= 0x60) ||
    (c >= 0x7B && c <= 0x7E);

/// Inline spans in a single line of text starting at [base].
List<InlineFormatSpan> scanInline(String line, {int base = 0}) {
  final spans = <InlineFormatSpan>[];
  final chars = line.split('');
  void mask(int from, int to, String with_) {
    for (var i = from; i < to; i++) {
      chars[i] = with_;
    }
  }

  // Code spans and backslash escapes, left to right (escapes do not apply
  // inside code spans; an escaped backtick cannot open one).
  const backtick = 0x60;
  const backslash = 0x5C;
  final n = line.length;
  var i = 0;
  while (i < n) {
    final c = line.codeUnitAt(i);
    if (c == backslash &&
        i + 1 < n &&
        _isAsciiPunctuation(line.codeUnitAt(i + 1))) {
      mask(i, i + 2, _maskEscape);
      i += 2;
      continue;
    }
    if (c == backtick) {
      var j = i;
      while (j < n && line.codeUnitAt(j) == backtick) {
        j++;
      }
      final run = j - i;
      int? close;
      var k = j;
      while (k < n) {
        if (line.codeUnitAt(k) == backtick) {
          var m = k;
          while (m < n && line.codeUnitAt(m) == backtick) {
            m++;
          }
          if (m - k == run) {
            close = k;
            break;
          }
          k = m;
        } else {
          k++;
        }
      }
      if (close != null) {
        spans.add(
          InlineFormatSpan(
            InlineFormat.inlineCode,
            start: base + i,
            contentStart: base + j,
            contentEnd: base + close,
            end: base + close + run,
          ),
        );
        mask(i, close + run, _maskCode);
        i = close + run;
        continue;
      }
      i = j;
      continue;
    }
    i++;
  }

  var masked = chars.join();
  for (final match in _link.allMatches(masked)) {
    final textStart = match.start + 1;
    final textEnd = textStart + match[1]!.length;
    final urlStart = textEnd + 2;
    spans.add(
      InlineFormatSpan(
        InlineFormat.link,
        start: base + match.start,
        contentStart: base + textStart,
        contentEnd: base + textEnd,
        end: base + match.end,
        url: line.substring(urlStart, match.end - 1),
      ),
    );
    mask(match.start, textStart, _maskMarker);
    mask(textEnd, match.end, _maskUrl);
  }
  masked = chars.join();
  for (final match in _autolink.allMatches(masked)) {
    spans.add(
      InlineFormatSpan(
        InlineFormat.autolink,
        start: base + match.start,
        contentStart: base + match.start,
        contentEnd: base + match.end,
        end: base + match.end,
        url: line.substring(match.start, match.end),
      ),
    );
    mask(match.start, match.end, _maskUrl);
  }

  void delimited(RegExp pattern, InlineFormat format, int open, int close) {
    final current = chars.join();
    for (final match in pattern.allMatches(current)) {
      spans.add(
        InlineFormatSpan(
          format,
          start: base + match.start,
          contentStart: base + match.start + open,
          contentEnd: base + match.end - close,
          end: base + match.end,
        ),
      );
      mask(match.start, match.start + open, _maskMarker);
      mask(match.end - close, match.end, _maskMarker);
    }
  }

  delimited(_underline, InlineFormat.underline, 3, 4);
  delimited(_spoiler, InlineFormat.spoiler, 2, 2);
  delimited(_strike, InlineFormat.strikethrough, 2, 2);
  delimited(_boldStars, InlineFormat.bold, 2, 2);
  delimited(_boldUnderscores, InlineFormat.bold, 2, 2);
  delimited(_italicStar, InlineFormat.italic, 1, 1);
  delimited(_italicUnderscore, InlineFormat.italic, 1, 1);
  return spans;
}

/// Toolbar actions, in Element X order.
enum FormatAction {
  bold,
  italic,
  underline,
  strikethrough,
  link,
  bulletList,
  numberedList,
  indent,
  unindent,
  inlineCode,
  codeBlock,
  quote,
}

/// Which toolbar buttons are on (reversed) or disabled at the selection.
@immutable
class FormattingState {
  const FormattingState({this.active = const {}, this.disabled = const {}});
  final Set<FormatAction> active;
  final Set<FormatAction> disabled;

  @override
  bool operator ==(Object other) =>
      other is FormattingState &&
      _sameSet(other.active, active) &&
      _sameSet(other.disabled, disabled);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(active),
    Object.hashAllUnordered(disabled),
  );
}

bool _sameSet<T>(Set<T> a, Set<T> b) =>
    a.length == b.length && a.containsAll(b);

const _inlineActions = {
  FormatAction.bold: InlineFormat.bold,
  FormatAction.italic: InlineFormat.italic,
  FormatAction.underline: InlineFormat.underline,
  FormatAction.strikethrough: InlineFormat.strikethrough,
  FormatAction.inlineCode: InlineFormat.inlineCode,
  FormatAction.link: InlineFormat.link,
};

const _markers = {
  InlineFormat.bold: ('**', '**'),
  InlineFormat.italic: ('*', '*'),
  InlineFormat.underline: ('<u>', '</u>'),
  InlineFormat.strikethrough: ('~~', '~~'),
  InlineFormat.inlineCode: ('`', '`'),
};

/// The selection clamped to [value]'s text (an invalid selection is a caret
/// at the end).
TextSelection _selection(TextEditingValue value) {
  final length = value.text.length;
  final selection = value.selection;
  if (!selection.isValid) return TextSelection.collapsed(offset: length);
  return TextSelection(
    baseOffset: selection.start.clamp(0, length),
    extentOffset: selection.end.clamp(0, length),
  );
}

/// The lines touched by [selection]. A non-empty selection ending at the
/// start of a line does not include that line.
List<int> _touchedLines(MarkdownScan scan, TextSelection selection) {
  final first = scan.lineIndexAt(selection.start);
  var last = scan.lineIndexAt(selection.end);
  if (!selection.isCollapsed &&
      last > first &&
      selection.end == scan.lines[last].start) {
    last--;
  }
  return [for (var i = first; i <= last; i++) i];
}

/// Line segments of the selection eligible for inline formatting
/// (non-empty after trimming, outside code blocks).
List<(int, int)> _segments(MarkdownScan scan, TextSelection selection) {
  final segments = <(int, int)>[];
  for (final index in _touchedLines(scan, selection)) {
    final line = scan.lines[index];
    if (line.isCode) continue;
    var start = selection.start < line.contentStart
        ? line.contentStart
        : selection.start;
    var end = selection.end > line.end ? line.end : selection.end;
    final text = scan.text;
    while (start < end && text.codeUnitAt(start) <= 0x20) {
      start++;
    }
    while (end > start && text.codeUnitAt(end - 1) <= 0x20) {
      end--;
    }
    if (start < end) segments.add((start, end));
  }
  return segments;
}

InlineFormatSpan? _spanCovering(
  MarkdownScan scan,
  InlineFormat format,
  int start,
  int end,
) {
  InlineFormatSpan? best;
  for (final span in scan.spans) {
    if (span.format != format) continue;
    // The segment lies within the span (markers included) and overlaps its
    // content.
    final covers =
        span.start <= start &&
        end <= span.end &&
        start < span.contentEnd &&
        end > span.contentStart;
    if (!covers) continue;
    // Prefer the innermost span.
    if (best == null || span.end - span.start < best.end - best.start) {
      best = span;
    }
  }
  return best;
}

/// Toolbar state for [value].
FormattingState formattingStateFor(TextEditingValue value) {
  final scan = scanMarkdown(value.text);
  final selection = _selection(value);
  final active = <FormatAction>{};
  final disabled = <FormatAction>{};
  final touched = _touchedLines(scan, selection);
  final lines = [for (final i in touched) scan.lines[i]];
  final inCode = lines.every((line) => line.isCode);

  // Inline formats.
  if (selection.isCollapsed) {
    final caret = selection.start;
    for (final entry in _inlineActions.entries) {
      for (final span in scan.spans) {
        if (span.format == entry.value &&
            span.contentStart <= caret &&
            caret <= span.contentEnd) {
          active.add(entry.key);
        }
      }
    }
  } else {
    final segments = _segments(scan, selection);
    for (final entry in _inlineActions.entries) {
      if (segments.isNotEmpty &&
          segments.every(
            (segment) =>
                _spanCovering(scan, entry.value, segment.$1, segment.$2) !=
                null,
          )) {
        active.add(entry.key);
      }
    }
  }
  if (inCode) {
    disabled.addAll(
      FormatAction.values.where((action) => action != FormatAction.codeBlock),
    );
    active.add(FormatAction.codeBlock);
  } else if (active.contains(FormatAction.inlineCode)) {
    disabled.addAll(const {
      FormatAction.bold,
      FormatAction.italic,
      FormatAction.underline,
      FormatAction.strikethrough,
      FormatAction.link,
    });
  }

  // Block formats.
  final content = [
    for (final line in lines)
      if (!line.isBlank(scan.text) || line.isList) line,
  ];
  final considered = content.isEmpty ? lines : content;
  if (considered.every((line) => line.kind == LineKind.bullet)) {
    active.add(FormatAction.bulletList);
  }
  if (considered.every((line) => line.kind == LineKind.numbered)) {
    active.add(FormatAction.numberedList);
  }
  if (lines.every((line) => line.kind == LineKind.quote)) {
    active.add(FormatAction.quote);
  }
  final allList = considered.every((line) => line.isList);
  if (!allList || !touched.any((i) => _previousSibling(scan, i) != null)) {
    disabled.add(FormatAction.indent);
  }
  if (!allList || !considered.any((line) => line.indent > 0)) {
    disabled.add(FormatAction.unindent);
  }
  return FormattingState(active: active, disabled: disabled);
}

/// The nearest previous list item at the same indentation as line [index]
/// within the same list, if any.
MarkdownLine? _previousSibling(MarkdownScan scan, int index) {
  final line = scan.lines[index];
  if (!line.isList) return null;
  for (var i = index - 1; i >= 0; i--) {
    final candidate = scan.lines[i];
    if (candidate.isBlank(scan.text) || candidate.isCode) return null;
    if (!candidate.isList) {
      if (candidate.indent > line.indent) continue; // Continuation text.
      return null;
    }
    if (candidate.indent == line.indent) return candidate;
    if (candidate.indent < line.indent) return null;
  }
  return null;
}

/// The nearest previous list item with smaller indentation (the parent).
MarkdownLine? _parentItem(MarkdownScan scan, int index) {
  final line = scan.lines[index];
  for (var i = index - 1; i >= 0; i--) {
    final candidate = scan.lines[i];
    if (candidate.isBlank(scan.text) || candidate.isCode) return null;
    if (candidate.isList && candidate.indent < line.indent) return candidate;
    if (!candidate.isList && candidate.indent < line.indent) return null;
  }
  return null;
}

/// A text replacement in the original text.
class _Edit {
  _Edit(this.start, this.end, this.replacement, this.order);
  final int start;
  final int end;
  final String replacement;
  final int order;
}

class _Edits {
  final _list = <_Edit>[];

  void replace(int start, int end, String replacement) =>
      _list.add(_Edit(start, end, replacement, _list.length));
  void insert(int at, String text) => replace(at, at, text);
  void delete(int start, int end) => replace(start, end, '');

  bool get isEmpty => _list.isEmpty;

  List<_Edit> get _sorted => [..._list]
    ..sort(
      (a, b) => a.start != b.start
          ? a.start.compareTo(b.start)
          : a.end != b.end
          ? a.end.compareTo(b.end)
          : a.order.compareTo(b.order),
    );

  String apply(String text) {
    final buffer = StringBuffer();
    var cursor = 0;
    for (final edit in _sorted) {
      buffer
        ..write(text.substring(cursor, edit.start))
        ..write(edit.replacement);
      cursor = edit.end;
    }
    buffer.write(text.substring(cursor));
    return buffer.toString();
  }

  /// Maps an offset in the original text. Insertions exactly at [offset]
  /// count as before it when [afterInsertions] (selection starts, carets).
  int map(int offset, {required bool afterInsertions}) {
    var delta = 0;
    for (final edit in _sorted) {
      final removed = edit.end - edit.start;
      final inserted = edit.replacement.length;
      if (edit.end < offset ||
          (edit.end == offset && (removed > 0 || afterInsertions))) {
        delta += inserted - removed;
      } else if (edit.start < offset && offset < edit.end) {
        return edit.start + delta;
      }
    }
    return offset + delta;
  }

  TextEditingValue applyTo(TextEditingValue value, TextSelection selection) {
    final text = apply(value.text);
    if (selection.isCollapsed) {
      final caret = map(selection.start, afterInsertions: true);
      return TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: caret.clamp(0, text.length)),
      );
    }
    final start = map(selection.start, afterInsertions: true);
    final end = map(selection.end, afterInsertions: false);
    return TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: start.clamp(0, text.length),
        extentOffset: (end < start ? start : end).clamp(0, text.length),
      ),
    );
  }
}

/// Applies a toolbar [action] (all but [FormatAction.link], which needs the
/// link dialog: see [applyLink]). Returns [value] unchanged when the action
/// is disabled at the selection.
TextEditingValue applyFormat(TextEditingValue value, FormatAction action) {
  final state = formattingStateFor(value);
  if (state.disabled.contains(action)) return value;
  final next = switch (action) {
    FormatAction.bold => _toggleInline(value, InlineFormat.bold),
    FormatAction.italic => _toggleInline(value, InlineFormat.italic),
    FormatAction.underline => _toggleInline(value, InlineFormat.underline),
    FormatAction.strikethrough => _toggleInline(
      value,
      InlineFormat.strikethrough,
    ),
    FormatAction.inlineCode => _toggleInline(value, InlineFormat.inlineCode),
    FormatAction.bulletList => _toggleList(value, ordered: false),
    FormatAction.numberedList => _toggleList(value, ordered: true),
    FormatAction.quote => _toggleQuote(value),
    FormatAction.codeBlock => _toggleCodeBlock(value),
    FormatAction.indent => _indent(value, increase: true),
    FormatAction.unindent => _indent(value, increase: false),
    FormatAction.link => value,
  };
  return next.copyWith(composing: TextRange.empty);
}

(String, String) _markersFor(InlineFormat format, String content) {
  if (format != InlineFormat.inlineCode) return _markers[format]!;
  // A code span needs a backtick run longer than any inside it, padded with
  // a space when the content starts or ends with a backtick.
  var longest = 0;
  for (final run in RegExp('`+').allMatches(content)) {
    if (run[0]!.length > longest) longest = run[0]!.length;
  }
  final fence = '`' * (longest + 1);
  final pad = content.startsWith('`') || content.endsWith('`') ? ' ' : '';
  return ('$fence$pad', '$pad$fence');
}

TextEditingValue _toggleInline(TextEditingValue value, InlineFormat format) {
  final text = value.text;
  final scan = scanMarkdown(text);
  final selection = _selection(value);
  final edits = _Edits();
  if (selection.isCollapsed) {
    final caret = selection.start;
    // Empty markers just inserted at the caret (`**|**`): remove them.
    final (open, close) = _markersFor(format, '');
    if (caret >= open.length &&
        caret + close.length <= text.length &&
        text.substring(caret - open.length, caret) == open &&
        text.substring(caret, caret + close.length) == close) {
      return TextEditingValue(
        text: text.replaceRange(caret - open.length, caret + close.length, ''),
        selection: TextSelection.collapsed(offset: caret - open.length),
      );
    }
    InlineFormatSpan? span;
    for (final candidate in scan.spans) {
      if (candidate.format == format &&
          candidate.contentStart <= caret &&
          caret <= candidate.contentEnd) {
        if (span == null ||
            candidate.end - candidate.start < span.end - span.start) {
          span = candidate;
        }
      }
    }
    if (span != null && span.contentStart == span.contentEnd) {
      // Empty markers: remove them.
      edits.delete(span.start, span.end);
      return TextEditingValue(
        text: edits.apply(text),
        selection: TextSelection.collapsed(offset: span.start),
      );
    }
    if (span != null && caret == span.contentEnd) {
      // At the end of the formatted text: step out of the format.
      return value.copyWith(
        selection: TextSelection.collapsed(offset: span.end),
      );
    }
    if (span != null) {
      edits
        ..delete(span.start, span.contentStart)
        ..delete(span.contentEnd, span.end);
      return edits.applyTo(value, selection);
    }
    return TextEditingValue(
      text: text.replaceRange(caret, caret, '$open$close'),
      selection: TextSelection.collapsed(offset: caret + open.length),
    );
  }

  final segments = _segments(scan, selection);
  if (segments.isEmpty) return value;
  final covering = [
    for (final segment in segments)
      _spanCovering(scan, format, segment.$1, segment.$2),
  ];
  if (covering.every((span) => span != null)) {
    final removed = <InlineFormatSpan>{};
    for (final span in covering) {
      if (!removed.add(span!)) continue;
      edits
        ..delete(span.start, span.contentStart)
        ..delete(span.contentEnd, span.end);
    }
  } else {
    for (var i = 0; i < segments.length; i++) {
      if (covering[i] != null) continue;
      final (start, end) = segments[i];
      // Merge: drop markers of the same format wholly inside the segment.
      for (final inner in scan.spans) {
        if (inner.format == format &&
            start <= inner.start &&
            inner.end <= end) {
          edits
            ..delete(inner.start, inner.contentStart)
            ..delete(inner.contentEnd, inner.end);
        }
      }
      final (open, close) = _markersFor(format, text.substring(start, end));
      edits
        ..insert(start, open)
        ..insert(end, close);
    }
  }
  // Keep the formatted text selected (not the markers).
  final first = segments.first.$1;
  final last = segments.last.$2;
  final start = selection.start < first ? first : selection.start;
  final end = selection.end > last ? last : selection.end;
  return edits.applyTo(
    value,
    TextSelection(baseOffset: start, extentOffset: end),
  );
}

TextEditingValue _toggleList(TextEditingValue value, {required bool ordered}) {
  final text = value.text;
  final scan = scanMarkdown(text);
  final selection = _selection(value);
  final kind = ordered ? LineKind.numbered : LineKind.bullet;
  final touched = _touchedLines(scan, selection);
  final lines = [for (final i in touched) scan.lines[i]];
  if (lines.any((line) => line.isCode)) return value;
  final content = [
    for (final line in lines)
      if (!line.isBlank(text) || line.isList) line,
  ];
  final targets = content.isEmpty ? lines : content;
  final edits = _Edits();
  if (targets.every((line) => line.kind == kind)) {
    for (final line in targets) {
      edits.delete(line.start + line.indent, line.contentStart);
    }
    return edits.applyTo(value, selection);
  }
  var number = 0;
  for (final line in targets) {
    final marker = ordered ? '${++number}. ' : '- ';
    if (line.isList) {
      edits.replace(line.start + line.indent, line.contentStart, marker);
    } else {
      edits.insert(line.start + line.indent, marker);
    }
  }
  final next = edits.applyTo(value, selection);
  return ordered ? _renumber(next) : next;
}

TextEditingValue _toggleQuote(TextEditingValue value) {
  final text = value.text;
  final scan = scanMarkdown(text);
  final selection = _selection(value);
  final lines = [for (final i in _touchedLines(scan, selection)) scan.lines[i]];
  if (lines.any((line) => line.isCode)) return value;
  final edits = _Edits();
  if (lines.every((line) => line.kind == LineKind.quote)) {
    for (final line in lines) {
      edits.delete(line.start, line.contentStart);
    }
  } else {
    for (final line in lines) {
      if (line.kind == LineKind.quote) continue;
      edits.insert(line.start, line.start == line.end ? '>' : '> ');
    }
  }
  return edits.applyTo(value, selection);
}

TextEditingValue _toggleCodeBlock(TextEditingValue value) {
  final text = value.text;
  final scan = scanMarkdown(text);
  final selection = _selection(value);
  final touched = _touchedLines(scan, selection);
  final first = touched.first;
  final last = touched.last;
  final edits = _Edits();
  if (scan.lines[first].isCode) {
    // Remove the fences of the block containing the selection start.
    for (final (open, close) in _fencedBlocks(scan)) {
      if (open <= first && first <= (close ?? scan.lines.length - 1)) {
        return _removeFences(value, scan, open, close, selection);
      }
    }
    return value;
  }
  final start = scan.lines[first].start;
  final end = scan.lines[last].end;
  edits
    ..insert(start, '```\n')
    ..insert(end, '\n```');
  final newText = edits.apply(text);
  if (selection.isCollapsed) {
    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: selection.start + 4),
    );
  }
  return TextEditingValue(
    text: newText,
    selection: TextSelection(
      baseOffset: selection.start + 4,
      extentOffset: selection.end + 4,
    ),
  );
}

/// Fenced code blocks as (opening line, closing line or null) indices.
List<(int, int?)> _fencedBlocks(MarkdownScan scan) {
  final blocks = <(int, int?)>[];
  int? open;
  for (var i = 0; i < scan.lines.length; i++) {
    if (scan.lines[i].kind != LineKind.fence) continue;
    if (open == null) {
      open = i;
    } else {
      blocks.add((open, i));
      open = null;
    }
  }
  if (open != null) blocks.add((open, null));
  return blocks;
}

TextEditingValue _removeFences(
  TextEditingValue value,
  MarkdownScan scan,
  int open,
  int? close,
  TextSelection selection,
) {
  final text = value.text;
  final edits = _Edits();
  final opener = scan.lines[open];
  // Remove the opening fence line with its newline (or the preceding one at
  // the very end of the text).
  if (opener.end < text.length) {
    edits.delete(opener.start, opener.end + 1);
  } else {
    edits.delete(opener.start > 0 ? opener.start - 1 : 0, opener.end);
  }
  if (close != null) {
    final closer = scan.lines[close];
    edits.delete(closer.start - 1, closer.end);
  }
  return edits.applyTo(value, selection);
}

TextEditingValue _indent(TextEditingValue value, {required bool increase}) {
  final text = value.text;
  final scan = scanMarkdown(text);
  final selection = _selection(value);
  final edits = _Edits();
  final pending = <int, int>{}; // line index → new indent
  for (final index in _touchedLines(scan, selection)) {
    final line = scan.lines[index];
    if (!line.isList) continue;
    int target;
    if (increase) {
      final sibling = _previousSibling(scan, index);
      if (sibling == null) continue;
      final siblingIndent = pending[scan.lines.indexOf(sibling)];
      target = (siblingIndent ?? sibling.indent) + sibling.markerWidth;
    } else {
      if (line.indent == 0) continue;
      final parent = _parentItem(scan, index);
      target = parent?.indent ?? (line.indent - line.markerWidth);
      if (target < 0) target = 0;
    }
    pending[index] = target;
    edits.replace(line.start, line.start + line.indent, ' ' * target);
  }
  if (edits.isEmpty) return value;
  return _renumber(edits.applyTo(value, selection));
}

/// Renumbers every numbered list in [value] sequentially per indentation,
/// starting at 1 (lists are separated by blank or non-list lines).
TextEditingValue _renumber(TextEditingValue value) {
  final scan = scanMarkdown(value.text);
  final edits = _Edits();
  final counters = <int, int>{};
  for (final line in scan.lines) {
    if (line.isCode || line.isBlank(value.text)) {
      counters.clear();
      continue;
    }
    if (!line.isList) {
      if (line.indent == 0) counters.clear();
      continue;
    }
    counters.removeWhere((indent, _) => indent > line.indent);
    if (line.kind == LineKind.bullet) {
      counters.remove(line.indent);
      continue;
    }
    final expected = (counters[line.indent] ?? 0) + 1;
    counters[line.indent] = expected;
    if (line.number != expected) {
      final digitsStart = line.start + line.indent;
      final digits = '${line.number ?? ''}'.length;
      edits.replace(digitsStart, digitsStart + digits, '$expected');
    }
  }
  if (edits.isEmpty) return value;
  return edits.applyTo(value, _selection(value));
}

/// The link at the selection, for the link dialog.
@immutable
class LinkTarget {
  const LinkTarget({required this.text, this.url, this.span});

  /// Link text (the selected text for a new link).
  final String text;
  final String? url;

  /// The existing link being edited, if any.
  final InlineFormatSpan? span;
}

/// What the link dialog should edit at the selection.
LinkTarget linkTargetAt(TextEditingValue value) {
  final scan = scanMarkdown(value.text);
  final selection = _selection(value);
  for (final span in scan.spans) {
    if (span.format != InlineFormat.link) continue;
    if (span.start <= selection.start && selection.end <= span.end) {
      return LinkTarget(
        text: value.text.substring(span.contentStart, span.contentEnd),
        url: span.url,
        span: span,
      );
    }
  }
  return LinkTarget(text: value.text.substring(selection.start, selection.end));
}

/// Validates and normalises a link destination: `http`, `https` or
/// `mailto` only. A bare domain gets `https://`; a bare address `mailto:`.
/// Returns null when the input is not an acceptable link.
String? normaliseLinkUrl(String input) {
  var url = input.trim();
  if (url.isEmpty || url.length > 2048 || RegExp(r'\s').hasMatch(url)) {
    return null;
  }
  final hasScheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*:').hasMatch(url);
  if (!hasScheme) {
    if (RegExp(r'^[^@/]+@[^@/]+\.[^@/]+$').hasMatch(url)) {
      url = 'mailto:$url';
    } else if (RegExp(r'^[^/:]+\.[A-Za-z]{2,}').hasMatch(url) ||
        url.startsWith('localhost')) {
      url = 'https://$url';
    } else {
      return null;
    }
  }
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  switch (uri.scheme.toLowerCase()) {
    case 'http' || 'https':
      if (uri.host.isEmpty) return null;
      return url;
    case 'mailto':
      return uri.path.contains('@') ? url : null;
    default:
      return null;
  }
}

String _escapeLinkText(String text) => text
    .replaceAll('\n', ' ')
    .replaceAll(r'\', r'\\')
    .replaceAll('[', r'\[')
    .replaceAll(']', r'\]');

String _escapeLinkUrl(String url) => url
    .replaceAll(' ', '%20')
    .replaceAll('(', '%28')
    .replaceAll(')', '%29')
    .replaceAll('<', '%3C')
    .replaceAll('>', '%3E');

/// Markdown for a link. [url] must already be validated.
String linkMarkdown(String text, String url) {
  final label = text.trim().isEmpty ? url : text;
  return '[${_escapeLinkText(label)}](${_escapeLinkUrl(url)})';
}

/// Inserts or replaces the link at the selection with `[text](url)`.
/// [url] must come from [normaliseLinkUrl]. The caret ends after the link.
TextEditingValue applyLink(
  TextEditingValue value, {
  required String text,
  required String url,
}) {
  final target = linkTargetAt(value);
  final selection = _selection(value);
  final start = target.span?.start ?? selection.start;
  final end = target.span?.end ?? selection.end;
  final markdown = linkMarkdown(text, url);
  return TextEditingValue(
    text: value.text.replaceRange(start, end, markdown),
    selection: TextSelection.collapsed(offset: start + markdown.length),
  );
}

/// Replaces the link at the selection with its plain text.
TextEditingValue removeLink(TextEditingValue value) {
  final span = linkTargetAt(value).span;
  if (span == null) return value;
  final label = value.text.substring(span.contentStart, span.contentEnd);
  return TextEditingValue(
    text: value.text.replaceRange(span.start, span.end, label),
    selection: TextSelection.collapsed(offset: span.start + label.length),
  );
}

/// Continues a list when a newline was typed at the end of a list item
/// (`- a⏎` → `- a\n- `), and ends it on an empty item (`- ⏎` → ``).
/// Returns null when [next] is not such an edit.
TextEditingValue? continueListOnNewline(
  TextEditingValue previous,
  TextEditingValue next,
) {
  final before = previous.text;
  final after = next.text;
  if (after.length != before.length + 1 ||
      !next.selection.isCollapsed ||
      next.composing.isValid) {
    return null;
  }
  final caret = next.selection.start;
  if (caret < 1 || after.codeUnitAt(caret - 1) != 0x0A) return null;
  if (before.substring(0, caret - 1) != after.substring(0, caret - 1) ||
      before.substring(caret - 1) != after.substring(caret)) {
    return null;
  }
  final scan = scanMarkdown(before);
  final line = scan.lines[scan.lineIndexAt(caret - 1)];
  if (caret - 1 != line.end) return null; // Only at the end of the line.
  if (line.kind == LineKind.quote) {
    if (line.contentStart == line.end) {
      // Empty quote line: leave the quote.
      return TextEditingValue(
        text: before.replaceRange(line.start, line.end, ''),
        selection: TextSelection.collapsed(offset: line.start),
      );
    }
    final marker = before.substring(line.start, line.contentStart);
    return TextEditingValue(
      text: after.replaceRange(caret, caret, marker),
      selection: TextSelection.collapsed(offset: caret + marker.length),
    );
  }
  if (!line.isList) return null;
  if (line.contentStart == line.end) {
    // Empty item: end the list.
    return TextEditingValue(
      text: before.replaceRange(line.start, line.end, ''),
      selection: TextSelection.collapsed(offset: line.start),
    );
  }
  final indent = ' ' * line.indent;
  final marker = line.kind == LineKind.numbered
      ? '$indent${(line.number ?? 0) + 1}${before[line.start + line.indent + '${line.number ?? ''}'.length]} '
      : '$indent${before[line.start + line.indent]} ';
  final inserted = TextEditingValue(
    text: after.replaceRange(caret, caret, marker),
    selection: TextSelection.collapsed(offset: caret + marker.length),
  );
  return line.kind == LineKind.numbered ? _renumber(inserted) : inserted;
}
