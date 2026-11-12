import 'package:flutter/material.dart';

import 'markdown_format.dart';

/// Colours for live markdown styling in the composer.
@immutable
class MarkdownStyleColours {
  const MarkdownStyleColours({
    required this.marker,
    required this.accent,
    required this.quote,
    required this.codeBackground,
    required this.spoilerBackground,
  });

  factory MarkdownStyleColours.of(ColorScheme scheme) => MarkdownStyleColours(
    marker: scheme.onSurface.withValues(alpha: 0.42),
    accent: scheme.primary,
    quote: scheme.onSurfaceVariant,
    codeBackground: scheme.onSurface.withValues(alpha: 0.10),
    spoilerBackground: scheme.onSurface.withValues(alpha: 0.18),
  );

  /// Dimmed markdown markers (`**`, `- `, `](url)` …).
  final Color marker;

  /// Links and list markers.
  final Color accent;
  final Color quote;
  final Color codeBackground;
  final Color spoilerBackground;
}

// Style flags combined per text segment.
const _bold = 1 << 0;
const _italic = 1 << 1;
const _underline = 1 << 2;
const _strike = 1 << 3;
const _code = 1 << 4;
const _link = 1 << 5;
const _marker = 1 << 6;
const _quote = 1 << 7;
const _listMarker = 1 << 8;
const _spoiler = 1 << 9;
const _composing = 1 << 10;
const _flagCount = 11;

/// Longest text styled live; longer drafts render plain for responsiveness.
const maxStyledComposerLength = 20000;

/// Builds a styled span for composer markdown [text]. The span's plain text
/// is exactly [text] (markers are dimmed, never hidden), so selection and
/// caret offsets are unchanged.
TextSpan buildMarkdownTextSpan(
  String text, {
  TextStyle? style,
  required MarkdownStyleColours colours,
  TextRange? composing,
}) {
  if (text.isEmpty) return TextSpan(style: style, text: text);
  final scan = scanMarkdown(text);
  final ranges = <(int, int, int)>[];
  void add(int start, int end, int flag) {
    if (end > start) ranges.add((start, end, flag));
  }

  for (final line in scan.lines) {
    switch (line.kind) {
      case LineKind.fence:
        add(line.start, line.end, _marker | _code);
      case LineKind.code:
        add(line.start, line.end, _code);
      case LineKind.bullet || LineKind.numbered:
        add(line.start + line.indent, line.contentStart, _listMarker);
      case LineKind.quote:
        add(line.start, line.contentStart, _marker);
        add(line.contentStart, line.end, _quote);
      case LineKind.text:
        break;
    }
  }
  for (final span in scan.spans) {
    final content = switch (span.format) {
      InlineFormat.bold => _bold,
      InlineFormat.italic => _italic,
      InlineFormat.underline => _underline,
      InlineFormat.strikethrough => _strike,
      InlineFormat.inlineCode => _code,
      InlineFormat.link || InlineFormat.autolink => _link,
      InlineFormat.spoiler => _spoiler,
    };
    add(span.start, span.contentStart, _marker);
    add(span.contentStart, span.contentEnd, content);
    add(span.contentEnd, span.end, _marker);
  }
  if (composing != null &&
      composing.isValid &&
      !composing.isCollapsed &&
      composing.end <= text.length) {
    add(composing.start, composing.end, _composing);
  }
  if (ranges.isEmpty) return TextSpan(style: style, text: text);

  // Sweep the range boundaries, counting active flags per segment.
  final events = <(int, int, int)>[]; // (offset, flag, +1/-1)
  for (final (start, end, flags) in ranges) {
    for (var bit = 0; bit < _flagCount; bit++) {
      final flag = 1 << bit;
      if (flags & flag == 0) continue;
      events
        ..add((start, flag, 1))
        ..add((end, flag, -1));
    }
  }
  events.sort((a, b) => a.$1.compareTo(b.$1));
  final counts = List<int>.filled(_flagCount, 0);
  final children = <InlineSpan>[];
  var cursor = 0;
  var index = 0;
  while (cursor < text.length) {
    while (index < events.length && events[index].$1 <= cursor) {
      final (_, flag, delta) = events[index++];
      counts[flag.bitLength - 1] += delta;
    }
    final next = index < events.length ? events[index].$1 : text.length;
    final end = next > text.length ? text.length : next;
    if (end <= cursor) {
      if (index >= events.length) break;
      continue;
    }
    var flags = 0;
    for (var bit = 0; bit < _flagCount; bit++) {
      if (counts[bit] > 0) flags |= 1 << bit;
    }
    final segment = text.substring(cursor, end);
    children.add(
      flags == 0
          ? TextSpan(text: segment)
          : TextSpan(text: segment, style: _styleFor(flags, colours)),
    );
    cursor = end;
  }
  return TextSpan(style: style, children: children);
}

TextStyle _styleFor(int flags, MarkdownStyleColours colours) {
  final decorations = <TextDecoration>[
    if (flags & (_underline | _link | _composing) != 0)
      TextDecoration.underline,
    if (flags & _strike != 0) TextDecoration.lineThrough,
  ];
  Color? colour;
  if (flags & _marker != 0) {
    colour = colours.marker;
  } else if (flags & (_link | _listMarker) != 0) {
    colour = colours.accent;
  } else if (flags & _quote != 0) {
    colour = colours.quote;
  }
  return TextStyle(
    color: colour,
    fontWeight: flags & (_bold | _listMarker) != 0 ? FontWeight.w700 : null,
    fontStyle: flags & (_italic | _quote) != 0 ? FontStyle.italic : null,
    fontFamily: flags & _code != 0 ? 'monospace' : null,
    backgroundColor: flags & _code != 0 && flags & _marker == 0
        ? colours.codeBackground
        : flags & _spoiler != 0
        ? colours.spoilerBackground
        : null,
    decoration: decorations.isEmpty
        ? null
        : TextDecoration.combine(decorations),
    decorationColor: flags & _link != 0 ? colours.accent : null,
  );
}

/// A text controller that renders composer markdown with live inline
/// styling while keeping the plain markdown text as its value.
class ComposerTextController extends TextEditingController {
  ComposerTextController({super.text});
  ComposerTextController.fromValue(super.value) : super.fromValue();

  /// Live styling switch (for example off while staging a caption).
  bool styling = true;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!styling || text.isEmpty || text.length > maxStyledComposerLength) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    return buildMarkdownTextSpan(
      text,
      style: style,
      colours: MarkdownStyleColours.of(Theme.of(context).colorScheme),
      composing: withComposing && value.isComposingRangeValid
          ? value.composing
          : null,
    );
  }
}
