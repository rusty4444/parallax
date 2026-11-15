import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../app_theme.dart';
import '../../chat_backend.dart';
import '../packs/pack_image.dart';
import '../packs/pack_model.dart';
import '../../message_copy_targets.dart';
import 'linkify.dart';
import 'permalinks.dart';

/// Formatted bodies longer than this fall back to the plain body.
const maxFormattedBodyLength = 65536;
const _maxDepth = 48;
const _maxListItems = 300;
const _maxTableRows = 100;
const _maxTableCells = 12;
const _maxRenderedChars = 40000;
const _maxCodeChars = 20000;

/// Custom emoji images rendered per message; the rest show their alt text.
const _maxEmoticons = 100;

/// Tags whose content is never rendered (including `<mx-reply>` fallbacks).
const _droppedTags = {
  'mx-reply',
  'script',
  'style',
  'head',
  'title',
  'iframe',
  'object',
  'embed',
  'noscript',
  'template',
  'svg',
  'math',
  'audio',
  'video',
  'canvas',
  'form',
  'input',
  'button',
  'select',
  'textarea',
  'link',
  'meta',
  'base',
};

typedef LinkHandler = void Function(Uri uri, String text);
typedef PermalinkHandler = void Function(MatrixPermalink link);
typedef NameResolver = String? Function(String userId);

/// Renders a timeline entry's text: sanitised HTML `formatted_body` or a
/// linkified plain body, plus emote/notice/undecryptable/redacted styling.
class MessageContentView extends StatefulWidget {
  const MessageContentView({
    super.key,
    required this.entry,
    required this.style,
    required this.palette,
    this.ownUserId,
    this.resolveName,
    this.onLink,
    this.onPermalink,
    this.onCopyTarget,
    this.backend,
  });

  final ChatEntry entry;
  final TextStyle style;
  final AppPalette palette;
  final String? ownUserId;
  final NameResolver? resolveName;
  final LinkHandler? onLink;
  final PermalinkHandler? onPermalink;
  final void Function(MessageCopyTarget target)? onCopyTarget;

  /// Loads custom emoji (`<img data-mx-emoticon>`) images. Defaults to the
  /// signed-in backend known to the packs module; without one, emoticons
  /// show their `:shortcode:` alt text.
  final ChatBackend? backend;

  @override
  State<MessageContentView> createState() => _MessageContentViewState();
}

class _MessageContentViewState extends State<MessageContentView> {
  final _recognizers = <GestureRecognizer>[];
  final _revealed = <int>{};
  Object? _key;
  Widget? _built;

  GestureRecognizer _tap(VoidCallback onTap) {
    final recognizer = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(recognizer);
    return recognizer;
  }

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _reveal(int index) {
    if (!mounted) return;
    setState(() => _revealed.add(index));
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final key = (
      entry.id,
      entry.body,
      entry.formattedBody,
      entry.kind,
      entry.senderLabel,
      entry.mine,
      widget.style,
      widget.palette,
      widget.ownUserId,
      widget.backend,
      _revealed.length,
    );
    if (key != _key || _built == null) {
      _disposeRecognizers();
      _built = _build();
      _key = key;
    }
    return _built!;
  }

  Widget _build() {
    final entry = widget.entry;
    final palette = widget.palette;
    final muted = entry.mine
        ? palette.bubbleText.withValues(alpha: 0.78)
        : palette.muted;
    if (entry.redacted) {
      return _StatusLine(
        icon: Icons.delete_outline_rounded,
        text: 'Message removed',
        style: widget.style.copyWith(color: muted, fontStyle: FontStyle.italic),
      );
    }
    switch (entry.kind) {
      case EntryKind.redacted:
        return _StatusLine(
          icon: Icons.delete_outline_rounded,
          text: 'Message removed',
          style: widget.style.copyWith(
            color: muted,
            fontStyle: FontStyle.italic,
          ),
        );
      case EntryKind.undecryptable:
        return _UndecryptableView(style: widget.style, muted: muted);
      default:
        break;
    }
    final base = entry.kind == EntryKind.notice
        ? widget.style.copyWith(color: muted)
        : widget.style;
    final leading = entry.kind == EntryKind.emote
        ? <InlineSpan>[
            TextSpan(
              text: '* ${entry.senderLabel} ',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ]
        : const <InlineSpan>[];
    final renderer = _Renderer(
      base: base,
      palette: palette,
      mine: entry.mine,
      tap: _tap,
      ownUserId: widget.ownUserId,
      resolveName: widget.resolveName,
      onLink: (uri, text) => widget.onLink?.call(uri, text),
      onPermalink: (link) => widget.onPermalink?.call(link),
      onCopyTarget: widget.onCopyTarget,
      revealed: _revealed,
      reveal: _reveal,
      backend: widget.backend,
    );
    final formatted = entry.formattedBody;
    if (formatted != null &&
        formatted.trim().isNotEmpty &&
        formatted.length <= maxFormattedBodyLength) {
      final rendered = renderer.renderHtml(formatted, leading: leading);
      if (rendered != null) return rendered;
    }
    if (leading.isEmpty && isEmojiOnly(entry.body)) {
      return Text(
        entry.body.trim(),
        style: base.copyWith(fontSize: (base.fontSize ?? 15) * 2.2),
      );
    }
    return renderer.renderPlain(entry.body, leading: leading);
  }
}

// Unicode property escapes need `unicode: true` (the lint cannot see it).
const _emojiOnlySource =
    r'^(?:[\p{Extended_Pictographic}\p{Emoji_Modifier}\u{FE0F}\u{200D}\u{20E3}\u{1F1E6}-\u{1F1FF}]|\s)+$';
const _pictographicSource = r'\p{Extended_Pictographic}';
final _emojiOnly = RegExp(_emojiOnlySource, unicode: true);
final _pictographic = RegExp(_pictographicSource, unicode: true);

/// Short messages made only of emoji are shown larger, as in Element X.
bool isEmojiOnly(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty || trimmed.characters.length > 5) return false;
  return _emojiOnly.hasMatch(trimmed) && _pictographic.hasMatch(trimmed);
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({
    required this.icon,
    required this.text,
    required this.style,
  });
  final IconData icon;
  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 16, color: style.color),
      const SizedBox(width: 6),
      Flexible(child: Text(text, style: style)),
    ],
  );
}

class _UndecryptableView extends StatelessWidget {
  const _UndecryptableView({required this.style, required this.muted});
  final TextStyle style;
  final Color muted;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      _StatusLine(
        icon: Icons.hourglass_empty_rounded,
        text: 'Waiting for this message',
        style: style.copyWith(color: muted, fontStyle: FontStyle.italic),
      ),
      const SizedBox(height: 4),
      Text(
        'Unable to decrypt. This device doesn’t have the key yet — it can '
        'arrive from your other devices or key backup once this device is '
        'verified.',
        style: style.copyWith(color: muted, fontSize: 12, height: 1.3),
      ),
    ],
  );
}

/// Inline rendering context.
class _Ctx {
  const _Ctx({
    required this.style,
    this.recognizer,
    this.linkify = true,
    this.preserve = false,
  });
  final TextStyle style;
  final GestureRecognizer? recognizer;
  final bool linkify;
  final bool preserve;

  _Ctx copyWith({
    TextStyle? style,
    GestureRecognizer? recognizer,
    bool? linkify,
  }) => _Ctx(
    style: style ?? this.style,
    recognizer: recognizer ?? this.recognizer,
    linkify: linkify ?? this.linkify,
    preserve: preserve,
  );

  _Ctx merge(TextStyle extra) => copyWith(style: style.merge(extra));
}

class _Renderer {
  _Renderer({
    required this.base,
    required this.palette,
    required this.mine,
    required this.tap,
    required this.ownUserId,
    required this.resolveName,
    required this.onLink,
    required this.onPermalink,
    required this.onCopyTarget,
    required this.revealed,
    required this.reveal,
    this.backend,
  });

  final TextStyle base;
  final AppPalette palette;
  final bool mine;
  final GestureRecognizer Function(VoidCallback onTap) tap;
  final String? ownUserId;
  final NameResolver? resolveName;
  final LinkHandler onLink;
  final PermalinkHandler onPermalink;
  final void Function(MessageCopyTarget target)? onCopyTarget;
  String messageContext = '';
  final Set<int> revealed;
  final void Function(int index) reveal;
  final ChatBackend? backend;
  int _spoilers = 0;
  int _chars = 0;
  int _emoticons = 0;

  /// Emoticons render at text height, or larger when a message holds only a
  /// few of them (like emoji-only messages).
  double _emoticonSize = 0;

  bool get _exhausted => _chars > _maxRenderedChars;

  Color get _linkColour => mine ? palette.bubbleText : palette.secondary;
  Color get _codeBackground =>
      (mine ? palette.bubbleText : palette.foreground).withValues(alpha: 0.1);

  TextStyle get _mono => const TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['RobotoMono', 'Menlo', 'Courier'],
  );

  Widget renderPlain(String body, {List<InlineSpan> leading = const []}) {
    messageContext = body;
    final block = _BlockBuilder(this);
    for (final span in leading) {
      block.addSpan(span);
    }
    block.addText(body, _Ctx(style: base, preserve: true));
    return block.build(base);
  }

  Widget? renderHtml(String html, {List<InlineSpan> leading = const []}) {
    final dom.DocumentFragment fragment;
    try {
      fragment = html_parser.parseFragment(html);
    } catch (_) {
      return null;
    }
    messageContext = fragment.text ?? '';
    final fontSize = base.fontSize ?? 15;
    _emoticonSize = leading.isEmpty && _onlyEmoticons(fragment)
        ? (fontSize * 2.4).clamp(28.0, 48.0)
        : (fontSize * 1.45).clamp(14.0, 32.0);
    final block = _BlockBuilder(this);
    for (final span in leading) {
      block.addSpan(span);
    }
    _visitAll(fragment.nodes, block, _Ctx(style: base), 0);
    if (block.isEmpty) return null;
    return block.build(base);
  }

  /// A custom emoji image: `<img data-mx-emoticon>` with an `mxc://` source.
  /// Any other `<img>` (remote URLs, data URIs, plain mxc images) is never
  /// fetched and only contributes its alt text.
  static Uri? _emoticonSource(dom.Element node) =>
      node.attributes.containsKey('data-mx-emoticon')
      ? parseMxcUri(node.attributes['src'])
      : null;

  static bool _onlyEmoticons(dom.DocumentFragment fragment) {
    var count = 0;
    for (final node in fragment.nodes) {
      if (node is dom.Text && node.data.trim().isEmpty) continue;
      if (node is dom.Element &&
          node.localName == 'img' &&
          _emoticonSource(node) != null) {
        if (++count > 5) return false;
        continue;
      }
      return false;
    }
    return count > 0;
  }

  void _image(dom.Element node, _BlockBuilder block, _Ctx ctx) {
    final alt = (node.attributes['alt'] ?? node.attributes['title'] ?? '')
        .trim();
    final source = _emoticonSource(node);
    if (source == null || _emoticons >= _maxEmoticons || _exhausted) {
      if (alt.isNotEmpty) block.addText(alt, ctx);
      return;
    }
    _emoticons++;
    final label = alt.isEmpty ? ':emoji:' : alt;
    final bounded = label.length > 102 ? '${label.substring(0, 100)}…' : label;
    _chars += bounded.length;
    block.addSpan(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: EmoticonInline(
          url: source,
          alt: bounded,
          size: _emoticonSize > 0 ? _emoticonSize : 22,
          style: ctx.style,
          backend: backend,
        ),
      ),
    );
  }

  void _visitAll(
    Iterable<dom.Node> nodes,
    _BlockBuilder block,
    _Ctx ctx,
    int depth,
  ) {
    for (final node in nodes.toList()) {
      if (_exhausted) return;
      _visit(node, block, ctx, depth);
    }
  }

  void _visit(dom.Node node, _BlockBuilder block, _Ctx ctx, int depth) {
    if (depth > _maxDepth) return;
    if (node is dom.Text) {
      block.addText(node.data, ctx);
      return;
    }
    if (node is! dom.Element) return;
    final tag = (node.localName ?? '').toLowerCase();
    if (_droppedTags.contains(tag)) return;
    final next = depth + 1;
    switch (tag) {
      case 'br':
        block.addBreak();
      case 'p' || 'div' || 'caption' || 'li' || 'summary':
        block.flush();
        _visitAll(node.nodes, block, ctx, next);
        block.flush();
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final scale = switch (tag) {
          'h1' => 1.45,
          'h2' => 1.3,
          'h3' => 1.18,
          _ => 1.06,
        };
        block.flush();
        _visitAll(
          node.nodes,
          block,
          ctx.merge(
            TextStyle(
              fontSize: (base.fontSize ?? 15) * scale,
              fontWeight: FontWeight.w800,
            ),
          ),
          next,
        );
        block.flush();
      case 'hr':
        block.addBlock(
          Divider(
            height: 12,
            color: (ctx.style.color ?? palette.foreground).withValues(
              alpha: 0.3,
            ),
          ),
        );
      case 'pre':
        block.addBlock(_codeBlock(node.text));
      case 'blockquote':
        final inner = _BlockBuilder(this);
        _visitAll(node.nodes, inner, ctx, next);
        if (!inner.isEmpty) block.addBlock(_quote(inner.build(ctx.style)));
      case 'ul' || 'ol':
        block.addBlock(_list(node, ctx, next));
      case 'table':
        block.addBlock(_table(node, ctx, next));
      case 'details':
        block.addBlock(_details(node, ctx, next));
      case 'a':
        _link(node, block, ctx, next);
      case 'img':
        _image(node, block, ctx);
      case 'b' || 'strong':
        _visitAll(
          node.nodes,
          block,
          ctx.merge(const TextStyle(fontWeight: FontWeight.w700)),
          next,
        );
      case 'i' || 'em':
        _visitAll(
          node.nodes,
          block,
          ctx.merge(const TextStyle(fontStyle: FontStyle.italic)),
          next,
        );
      case 'u' || 'ins':
        _visitAll(
          node.nodes,
          block,
          ctx.merge(const TextStyle(decoration: TextDecoration.underline)),
          next,
        );
      case 's' || 'del' || 'strike':
        _visitAll(
          node.nodes,
          block,
          ctx.merge(const TextStyle(decoration: TextDecoration.lineThrough)),
          next,
        );
      case 'code':
        _visitAll(
          node.nodes,
          block,
          ctx
              .merge(_mono.copyWith(backgroundColor: _codeBackground))
              .copyWith(linkify: false),
          next,
        );
      case 'sup' || 'sub':
        _visitAll(
          node.nodes,
          block,
          ctx.merge(TextStyle(fontSize: (ctx.style.fontSize ?? 15) * 0.75)),
          next,
        );
      case 'span' || 'font':
        _styled(node, block, ctx, next);
      default:
        _visitAll(node.nodes, block, ctx, next);
    }
  }

  void _styled(dom.Element node, _BlockBuilder block, _Ctx ctx, int depth) {
    final attributes = node.attributes;
    if (attributes.containsKey('data-mx-spoiler')) {
      final index = _spoilers++;
      if (!revealed.contains(index)) {
        final hidden = (ctx.style.color ?? palette.foreground);
        _visitAll(
          node.nodes,
          block,
          ctx.copyWith(
            style: ctx.style.copyWith(color: hidden, backgroundColor: hidden),
            recognizer: tap(() => reveal(index)),
            linkify: false,
          ),
          depth,
        );
        return;
      }
    }
    final colour = parseMatrixColour(
      attributes['data-mx-color'] ??
          (node.localName == 'font' ? attributes['color'] : null),
    );
    final background = parseMatrixColour(attributes['data-mx-bg-color']);
    _visitAll(
      node.nodes,
      block,
      ctx.merge(TextStyle(color: colour, backgroundColor: background)),
      depth,
    );
  }

  void _link(dom.Element node, _BlockBuilder block, _Ctx ctx, int depth) {
    final href = node.attributes['href'] ?? '';
    final text = node.text;
    final permalink = MatrixPermalink.parse(href);
    if (permalink != null && permalink.kind != PermalinkKind.event) {
      block.addSpan(_pill(permalink, text));
      _chars += text.length;
      return;
    }
    final uri = permalink?.uri ?? safeLinkUri(href);
    if (uri == null) {
      _visitAll(node.nodes, block, ctx, depth);
      return;
    }
    final recognizer = tap(
      () => permalink != null ? onPermalink(permalink) : onLink(uri, text),
    );
    _visitAll(
      node.nodes,
      block,
      ctx.copyWith(
        style: ctx.style.merge(
          TextStyle(
            color: _linkColour,
            decoration: TextDecoration.underline,
            decorationColor: _linkColour,
          ),
        ),
        recognizer: recognizer,
        linkify: false,
      ),
      depth,
    );
  }

  /// Plain text runs with URLs, permalinks and @room converted.
  List<InlineSpan> linkified(String text, _Ctx ctx) {
    final spans = <InlineSpan>[];
    for (final token in tokenizeText(text)) {
      switch (token.kind) {
        case TextTokenKind.text:
          spans.addAll(_plainSpans(token.text, ctx));
        case TextTokenKind.link:
          final uri = token.href!;
          spans.add(
            TextSpan(
              text: token.text,
              style: ctx.style.merge(
                TextStyle(
                  color: _linkColour,
                  decoration: TextDecoration.underline,
                  decorationColor: _linkColour,
                ),
              ),
              recognizer: tap(() => onLink(uri, token.text)),
            ),
          );
        case TextTokenKind.permalink:
          final link = token.permalink!;
          if (link.kind == PermalinkKind.event) {
            spans.add(
              TextSpan(
                text: token.text,
                style: ctx.style.merge(
                  TextStyle(
                    color: _linkColour,
                    decoration: TextDecoration.underline,
                    decorationColor: _linkColour,
                  ),
                ),
                recognizer: tap(() => onPermalink(link)),
              ),
            );
          } else {
            spans.add(_pill(link, ''));
          }
        case TextTokenKind.roomMention:
          spans.add(_roomPill());
      }
    }
    return spans;
  }

  List<InlineSpan> _plainSpans(String text, _Ctx ctx) {
    final matches = _copyMatches(text);
    if (matches.isEmpty) {
      return [
        TextSpan(text: text, style: ctx.style, recognizer: ctx.recognizer),
      ];
    }
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in matches) {
      if (match.start < cursor || match.end > text.length) continue;
      if (match.start > cursor) {
        spans.add(
          TextSpan(
            text: text.substring(cursor, match.start),
            style: ctx.style,
            recognizer: ctx.recognizer,
          ),
        );
      }
      final target = match.target;
      spans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: ctx.style.merge(
            TextStyle(
              color: _linkColour,
              decoration: TextDecoration.underline,
              decorationColor: _linkColour,
            ),
          ),
          recognizer: tap(() => onCopyTarget?.call(target)),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(
        TextSpan(
          text: text.substring(cursor),
          style: ctx.style,
          recognizer: ctx.recognizer,
        ),
      );
    }
    return spans;
  }

  List<MessageCopyMatch> _copyMatches(String text) {
    if (onCopyTarget == null || text.isEmpty) return const [];
    final context = messageContext;
    if (context.isEmpty || context == text) return messageCopyMatches(text);
    return messageCopyMatches(
      text,
      context: context,
      contextOffset: context.indexOf(text),
    );
  }

  InlineSpan _pill(MatrixPermalink link, String text) {
    final visible = text.trim();
    String label;
    var highlighted = false;
    if (link.isUser) {
      final name = resolveName?.call(link.identifier);
      final fromText = visible.isNotEmpty && !visible.contains('://')
          ? visible
          : null;
      label = name ?? fromText ?? link.identifier;
      if (!label.startsWith('@')) label = '@$label';
      highlighted = link.identifier == ownUserId;
    } else {
      label = link.identifier.startsWith('#')
          ? link.identifier
          : (visible.isNotEmpty && !visible.contains('://') ? visible : 'Room');
    }
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: MentionPill(
        label: label,
        palette: palette,
        mine: mine,
        highlighted: highlighted,
        fontSize: (base.fontSize ?? 15) * 0.93,
        onTap: () => onPermalink(link),
      ),
    );
  }

  InlineSpan _roomPill() => WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: MentionPill(
      label: '@room',
      palette: palette,
      mine: mine,
      highlighted: true,
      fontSize: (base.fontSize ?? 15) * 0.93,
    ),
  );

  Widget _codeBlock(String code) {
    var text = code.replaceAll(RegExp(r'\n+$'), '');
    if (text.length > _maxCodeChars) {
      text = '${text.substring(0, _maxCodeChars)}\n…';
    }
    _chars += text.length;
    return Container(
      decoration: BoxDecoration(
        color: _codeBackground,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          text,
          softWrap: false,
          style: base.merge(_mono).copyWith(fontSize: 13, height: 1.35),
        ),
      ),
    );
  }

  Widget _quote(Widget child) => Container(
    padding: const EdgeInsets.only(left: 10),
    decoration: BoxDecoration(
      border: Border(
        left: BorderSide(
          color: (mine ? palette.bubbleText : palette.accent).withValues(
            alpha: 0.6,
          ),
          width: 3,
        ),
      ),
    ),
    child: child,
  );

  Widget _list(dom.Element node, _Ctx ctx, int depth) {
    final ordered = node.localName == 'ol';
    var number = int.tryParse(node.attributes['start'] ?? '') ?? 1;
    final items = <Widget>[];
    for (final child in node.children) {
      if (items.length >= _maxListItems || _exhausted) break;
      if (child.localName != 'li') continue;
      final inner = _BlockBuilder(this);
      _visitAll(child.nodes, inner, ctx, depth + 1);
      items.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: ordered ? 26 : 16,
              child: Text(ordered ? '${number++}.' : '•', style: ctx.style),
            ),
            Flexible(child: inner.build(ctx.style)),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: items,
    );
  }

  Widget _table(dom.Element node, _Ctx ctx, int depth) {
    final rows = <dom.Element>[];
    void collect(dom.Element element) {
      for (final child in element.children) {
        if (rows.length >= _maxTableRows) return;
        final name = child.localName;
        if (name == 'tr') {
          rows.add(child);
        } else if (name == 'thead' || name == 'tbody' || name == 'tfoot') {
          collect(child);
        }
      }
    }

    collect(node);
    final cells = <List<Widget>>[];
    var width = 0;
    for (final row in rows) {
      final rowCells = <Widget>[];
      for (final cell in row.children.where(
        (c) => c.localName == 'td' || c.localName == 'th',
      )) {
        if (rowCells.length >= _maxTableCells) break;
        final inner = _BlockBuilder(this);
        _visitAll(
          cell.nodes,
          inner,
          cell.localName == 'th'
              ? ctx.merge(const TextStyle(fontWeight: FontWeight.w700))
              : ctx,
          depth + 1,
        );
        rowCells.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: inner.build(ctx.style),
          ),
        );
      }
      if (rowCells.length > width) width = rowCells.length;
      cells.add(rowCells);
    }
    if (width == 0) return const SizedBox.shrink();
    final border = (ctx.style.color ?? palette.foreground).withValues(
      alpha: 0.25,
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder.all(color: border),
        children: [
          for (final row in cells)
            TableRow(
              children: [
                ...row,
                for (var i = row.length; i < width; i++)
                  const SizedBox.shrink(),
              ],
            ),
        ],
      ),
    );
  }

  Widget _details(dom.Element node, _Ctx ctx, int depth) {
    final summary = node.children
        .where((child) => child.localName == 'summary')
        .firstOrNull;
    final summaryBlock = _BlockBuilder(this);
    if (summary != null) {
      _visitAll(
        summary.nodes,
        summaryBlock,
        ctx.merge(const TextStyle(fontWeight: FontWeight.w700)),
        depth + 1,
      );
    } else {
      summaryBlock.addText('Details', ctx);
    }
    final body = _BlockBuilder(this);
    _visitAll(
      node.nodes.where((child) => child != summary),
      body,
      ctx,
      depth + 1,
    );
    return _DetailsBlock(
      summary: summaryBlock.build(ctx.style),
      body: body.isEmpty ? null : body.build(ctx.style),
      initiallyOpen: node.attributes.containsKey('open'),
      colour: ctx.style.color ?? palette.foreground,
    );
  }
}

/// Collects inline spans into paragraphs and block widgets.
class _BlockBuilder {
  _BlockBuilder(this.renderer);
  final _Renderer renderer;
  final _blocks = <Widget>[];
  var _spans = <InlineSpan>[];
  var _atLineStart = true;
  var _hasContent = false;

  bool get isEmpty => _blocks.isEmpty && !_hasContent;

  void addSpan(InlineSpan span) {
    _spans.add(span);
    _atLineStart = false;
    _hasContent = true;
  }

  void addBreak() {
    _spans.add(const TextSpan(text: '\n'));
    _atLineStart = true;
  }

  void addText(String raw, _Ctx ctx) {
    if (renderer._exhausted) return;
    var text = raw;
    if (!ctx.preserve) {
      text = text.replaceAll(RegExp(r'\s+'), ' ');
      if (_atLineStart) text = text.trimLeft();
    }
    if (text.isEmpty) return;
    final room = _maxRenderedChars - renderer._chars;
    if (text.length > room) {
      text = '${text.substring(0, room < 0 ? 0 : room)}…';
    }
    renderer._chars += text.length;
    final spans = ctx.linkify
        ? renderer.linkified(text, ctx)
        : [TextSpan(text: text, style: ctx.style, recognizer: ctx.recognizer)];
    _spans.addAll(spans);
    _atLineStart = text.endsWith('\n');
    _hasContent = true;
  }

  void flush() {
    while (_spans.isNotEmpty &&
        _spans.last is TextSpan &&
        ((_spans.last as TextSpan).text ?? '').trim().isEmpty &&
        (_spans.last as TextSpan).children == null) {
      _spans.removeLast();
    }
    if (_spans.isNotEmpty) {
      _blocks.add(Text.rich(TextSpan(children: _spans)));
    }
    _spans = <InlineSpan>[];
    _atLineStart = true;
  }

  void addBlock(Widget widget) {
    flush();
    _blocks.add(widget);
    _hasContent = true;
  }

  Widget build(TextStyle style) {
    flush();
    if (_blocks.isEmpty) return const SizedBox.shrink();
    if (_blocks.length == 1) {
      return DefaultTextStyle.merge(style: style, child: _blocks.single);
    }
    return DefaultTextStyle.merge(
      style: style,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _blocks.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            _blocks[i],
          ],
        ],
      ),
    );
  }
}

class _DetailsBlock extends StatefulWidget {
  const _DetailsBlock({
    required this.summary,
    required this.body,
    required this.initiallyOpen,
    required this.colour,
  });
  final Widget summary;
  final Widget? body;
  final bool initiallyOpen;
  final Color colour;

  @override
  State<_DetailsBlock> createState() => _DetailsBlockState();
}

class _DetailsBlockState extends State<_DetailsBlock> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      InkWell(
        onTap: widget.body == null
            ? null
            : () => setState(() => _open = !_open),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _open ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
              size: 18,
              color: widget.colour,
            ),
            Flexible(child: widget.summary),
          ],
        ),
      ),
      if (_open && widget.body != null)
        Padding(
          padding: const EdgeInsets.only(left: 18, top: 4),
          child: widget.body,
        ),
    ],
  );
}

/// A user, room or `@room` mention pill.
class MentionPill extends StatelessWidget {
  const MentionPill({
    super.key,
    required this.label,
    required this.palette,
    required this.mine,
    this.highlighted = false,
    this.fontSize = 14,
    this.onTap,
  });
  final String label;
  final AppPalette palette;
  final bool mine;
  final bool highlighted;
  final double fontSize;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final background = highlighted
        ? palette.accent.withValues(alpha: mine ? 0.45 : 0.28)
        : (mine ? palette.bubbleText : palette.secondary).withValues(
            alpha: 0.18,
          );
    final foreground = mine ? palette.bubbleText : palette.foreground;
    return Semantics(
      button: onTap != null,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: foreground,
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

/// Parses a Matrix `#RRGGBB` colour attribute.
Color? parseMatrixColour(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(value.trim());
  if (match == null) return null;
  return Color(0xFF000000 | int.parse(match[1]!, radix: 16));
}
