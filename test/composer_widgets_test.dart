import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/features/composer/markdown_styling.dart';
import 'package:parallax/hooks/hook_types.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/rich_message_composer.dart';

Future<void> mount(
  WidgetTester tester, {
  required TextEditingController controller,
  Future<void> Function(String, MediaSelection?)? onSend,
  List<ComposerSendOption>? sendOptions,
  List<ComposerSuggestionSource>? suggestionSources,
  ValueChanged<bool>? onAcknowledged,
  String? replyToId,
  bool editing = false,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: RichMessageComposer(
          controller: controller,
          sending: false,
          onSend: onSend ?? (_, _) async {},
          sendOptions: sendOptions,
          suggestionSources: suggestionSources,
          onAcknowledged: onAcknowledged,
          replyToId: replyToId,
          editing: editing,
        ),
      ),
    ),
  ),
);

ComposerSendOption option(
  Future<bool> Function(BuildContext, ComposerDraft) onSelected,
) => ComposerSendOption(
  id: 'later',
  icon: Icons.schedule_rounded,
  label: 'Send later',
  onSelected: onSelected,
);

IconButton iconButton(WidgetTester tester, String tooltip) =>
    tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == tooltip,
      ),
    );

void main() {
  group('long-press send options', () {
    testWidgets('a consuming option clears the draft like a send', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      ComposerDraft? received;
      var sends = 0;
      final acks = <bool>[];
      await mount(
        tester,
        controller: controller,
        replyToId: r'$reply',
        onSend: (_, _) async => sends++,
        onAcknowledged: acks.add,
        sendOptions: [
          option((context, draft) async {
            received = draft;
            return true;
          }),
        ],
      );
      await tester.enterText(find.byType(TextField), 'see you tomorrow');
      await tester.pump();
      await tester.longPress(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      expect(find.text('Send options'), findsOneWidget);
      await tester.tap(find.text('Send later'));
      await tester.pumpAndSettle();
      expect(received!.text, 'see you tomorrow');
      expect(received!.replyToId, r'$reply');
      expect(received!.editing, isFalse);
      expect(controller.text, isEmpty);
      expect(acks, [true]);
      expect(sends, 0);
    });

    testWidgets('a declined or failed option keeps the draft', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var result = false;
      final acks = <bool>[];
      await mount(
        tester,
        controller: controller,
        onAcknowledged: acks.add,
        sendOptions: [
          option((context, draft) async {
            if (result) throw StateError('server refused');
            return false;
          }),
        ],
      );
      await tester.enterText(find.byType(TextField), 'keep me');
      await tester.pump();
      await tester.longPress(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send later'));
      await tester.pumpAndSettle();
      expect(controller.text, 'keep me');
      expect(acks, isEmpty);

      result = true;
      await tester.longPress(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send later'));
      await tester.pumpAndSettle();
      expect(controller.text, 'keep me');
      expect(find.textContaining('server refused'), findsOneWidget);
      expect(acks, isEmpty);
    });

    testWidgets('typing during the option keeps the newer text', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final gate = Completer<bool>();
      final acks = <bool>[];
      await mount(
        tester,
        controller: controller,
        onAcknowledged: acks.add,
        sendOptions: [option((context, draft) => gate.future)],
      );
      await tester.enterText(find.byType(TextField), 'first');
      await tester.pump();
      await tester.longPress(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send later'));
      await tester.pump();
      controller.text = 'newer';
      gate.complete(true);
      await tester.pumpAndSettle();
      expect(controller.text, 'newer');
      expect(acks, [false]);
    });

    testWidgets('tap still sends; no options means no menu', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final sent = <String>[];
      await mount(
        tester,
        controller: controller,
        onSend: (text, _) async => sent.add(text),
        sendOptions: [option((context, draft) async => true)],
      );
      await tester.enterText(find.byType(TextField), 'tap send');
      await tester.pump();
      await tester.tap(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      expect(sent, ['tap send']);
      expect(controller.text, isEmpty);

      await mount(
        tester,
        controller: controller,
        onSend: (text, _) async => sent.add(text),
        sendOptions: const [],
      );
      await tester.enterText(find.byType(TextField), 'no menu');
      await tester.pump();
      await tester.longPress(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      expect(find.text('Send options'), findsNothing);
    });

    testWidgets('an empty draft offers no options', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await mount(
        tester,
        controller: controller,
        sendOptions: [option((context, draft) async => true)],
      );
      await tester.longPress(find.byTooltip('Send message'));
      await tester.pumpAndSettle();
      expect(find.text('Send options'), findsNothing);
    });
  });

  group('autocomplete', () {
    final emoji = ComposerSuggestionSource(
      id: 'test.emoji',
      trigger: ':',
      minQueryLength: 2,
      search: (query) => [
        if ('party'.startsWith(query))
          const ComposerSuggestion(
            id: 'party',
            label: ':party:',
            subtitle: 'Party parrot',
            insertText: ':party: ',
          ),
      ],
    );

    testWidgets('slash commands at the start of a message', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await mount(tester, controller: controller);
      await tester.enterText(find.byType(TextField), '/con');
      await tester.pump();
      expect(find.text('/confetti <message>'), findsOneWidget);
      expect(
        find.text('Sends the given message with confetti'),
        findsOneWidget,
      );
      await tester.tap(find.text('/confetti <message>'));
      await tester.pump();
      expect(controller.text, '/confetti ');
      expect(find.byKey(const ValueKey('composer-suggestions')), findsNothing);

      await tester.enterText(find.byType(TextField), '/');
      await tester.pump();
      expect(find.text('/shrug <message>'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'and /con');
      await tester.pump();
      expect(find.text('/confetti <message>'), findsNothing);
    });

    testWidgets('no commands while editing', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await mount(tester, controller: controller, editing: true);
      await tester.enterText(find.byType(TextField), '/con');
      await tester.pump();
      expect(find.text('/confetti <message>'), findsNothing);
    });

    testWidgets('feature sources by trigger character', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await mount(tester, controller: controller, suggestionSources: [emoji]);
      await tester.enterText(find.byType(TextField), 'hi :p');
      await tester.pump();
      expect(find.text(':party:'), findsNothing); // Below minQueryLength.
      await tester.enterText(find.byType(TextField), 'hi :pa');
      await tester.pump();
      expect(find.text(':party:'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('suggestion-test.emoji-party')),
        findsOneWidget,
      );
      await tester.tap(find.text(':party:'));
      await tester.pump();
      expect(controller.text, 'hi :party: ');
      expect(controller.selection.baseOffset, controller.text.length);
      await tester.enterText(find.byType(TextField), 'hi:pa');
      await tester.pump();
      expect(find.text(':party:'), findsNothing); // Needs a word boundary.
    });

    testWidgets('a throwing source is ignored', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await mount(
        tester,
        controller: controller,
        suggestionSources: [
          ComposerSuggestionSource(
            id: 'broken',
            trigger: ':',
            search: (_) => throw StateError('boom'),
          ),
          emoji,
        ],
      );
      await tester.enterText(find.byType(TextField), ':pa');
      await tester.pump();
      expect(find.text(':party:'), findsOneWidget);
    });
  });

  testWidgets('unknown commands are refused before sending', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final sent = <String>[];
    await mount(
      tester,
      controller: controller,
      onSend: (text, _) async => sent.add(text),
    );
    await tester.enterText(find.byType(TextField), '/frobnicate now');
    await tester.pump();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pump();
    expect(sent, isEmpty);
    expect(
      find.textContaining('Unrecognised command: /frobnicate'),
      findsOneWidget,
    );
    expect(controller.text, '/frobnicate now');

    await tester.enterText(find.byType(TextField), '//frobnicate now');
    await tester.pump();
    await tester.tap(find.byTooltip('Send message'));
    await tester.pumpAndSettle();
    expect(sent, ['//frobnicate now']);
  });

  group('formatting toolbar', () {
    testWidgets('toggles, formats the selection and shows active state', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await mount(tester, controller: controller);
      expect(
        find.byKey(const ValueKey('composer-formatting-toolbar')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('Text formatting'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('composer-formatting-toolbar')),
        findsOneWidget,
      );
      // Element X replaces "add attachment" while formatting.
      expect(find.byTooltip('Attach media'), findsNothing);
      expect(find.byTooltip('Close text formatting'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'hello world');
      await tester.pump();
      controller.selection = const TextSelection(
        baseOffset: 6,
        extentOffset: 11,
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Apply bold format'));
      await tester.pump();
      expect(controller.text, 'hello **world**');
      expect(
        controller.selection,
        const TextSelection(baseOffset: 8, extentOffset: 13),
      );
      expect(iconButton(tester, 'Apply bold format').isSelected, isTrue);
      expect(iconButton(tester, 'Apply italic format').isSelected, isFalse);
      // Indent needs a list.
      expect(iconButton(tester, 'Indent').onPressed, isNull);

      await tester.tap(find.byTooltip('Toggle bullet list'));
      await tester.pump();
      expect(controller.text, '- hello **world**');
      expect(iconButton(tester, 'Toggle bullet list').isSelected, isTrue);

      await tester.tap(find.byTooltip('Close text formatting'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('composer-formatting-toolbar')),
        findsNothing,
      );
      expect(find.byTooltip('Attach media'), findsOneWidget);
    });

    testWidgets('link dialog validates and inserts a link', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await mount(tester, controller: controller);
      await tester.tap(find.byTooltip('Text formatting'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'read the docs');
      await tester.pump();
      controller.selection = const TextSelection(
        baseOffset: 9,
        extentOffset: 13,
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Set link'));
      await tester.pumpAndSettle();
      expect(find.text('Create a link'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('composer-link-url')),
        'javascript:alert(1)',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(find.textContaining('Enter a valid link'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('composer-link-url')),
        'example.com/docs',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(controller.text, 'read the [docs](https://example.com/docs)');

      // Editing the link offers removal.
      controller.selection = const TextSelection.collapsed(offset: 11);
      await tester.pump();
      await tester.tap(find.byTooltip('Set link'));
      await tester.pumpAndSettle();
      expect(find.text('Edit link'), findsOneWidget);
      await tester.tap(find.text('Remove link'));
      await tester.pumpAndSettle();
      expect(controller.text, 'read the docs');
    });

    testWidgets('lists continue on Enter while formatting', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await mount(tester, controller: controller);
      await tester.tap(find.byTooltip('Text formatting'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '- one');
      await tester.pump();
      await tester.enterText(find.byType(TextField), '- one\n');
      await tester.pump();
      expect(controller.text, '- one\n- ');
    });

    testWidgets('hidden for captions', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RichMessageComposer(
              controller: controller,
              sending: false,
              onSend: (_, _) async {},
              pickFile: () async => MediaSelection(
                bytes: Uint8List(3),
                name: 'a.pdf',
                mimeType: 'application/pdf',
              ),
            ),
          ),
        ),
      );
      expect(find.byTooltip('Text formatting'), findsOneWidget);
      await tester.tap(find.byTooltip('Attach media'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      expect(find.text('a.pdf'), findsOneWidget);
      expect(find.byTooltip('Text formatting'), findsNothing);
    });
  });

  group('live styling', () {
    testWidgets('the field styles markdown while the caller keeps text', (
      tester,
    ) async {
      final controller = TextEditingController(text: '**bold** and ~~gone~~');
      addTearDown(controller.dispose);
      await mount(tester, controller: controller);
      final field = tester.widget<TextField>(find.byType(TextField));
      final styled = field.controller! as ComposerTextController;
      expect(styled.text, controller.text);
      final span = styled.buildTextSpan(
        context: tester.element(find.byType(TextField)),
        withComposing: false,
      );
      expect(span.toPlainText(), controller.text);
      final bold = span.children!.cast<TextSpan>().firstWhere(
        (child) => child.text == 'bold',
      );
      expect(bold.style!.fontWeight, FontWeight.w700);
      final marker = span.children!.cast<TextSpan>().first;
      expect(marker.text, '**');
      expect(marker.style!.color, isNotNull);

      // Typing reaches the caller; caller edits reach the field.
      await tester.enterText(find.byType(TextField), 'typed');
      expect(controller.text, 'typed');
      controller.text = 'restored';
      await tester.pump();
      expect(styled.text, 'restored');
      expect(find.text('restored'), findsOneWidget);
    });

    test('spans keep the exact text and combine styles', () {
      const colours = MarkdownStyleColours(
        marker: Color(0xFF888888),
        accent: Color(0xFFFF5A36),
        quote: Color(0xFF777777),
        codeBackground: Color(0x22000000),
        spoilerBackground: Color(0x44000000),
      );
      const text =
          '> quote\n- item with <u>**both**</u>\n`code` [link](https://x.org)\n```\nblock\n```';
      final span = buildMarkdownTextSpan(text, colours: colours);
      expect(span.toPlainText(), text);
      TextStyle? styleOf(String fragment) {
        for (final child in span.children!.cast<TextSpan>()) {
          if (child.text == fragment) return child.style;
        }
        return null;
      }

      expect(styleOf('> ')!.color, colours.marker);
      expect(styleOf('quote')!.fontStyle, FontStyle.italic);
      expect(styleOf('- ')!.color, colours.accent);
      final both = styleOf('both')!;
      expect(both.fontWeight, FontWeight.w700);
      expect(both.decoration!.contains(TextDecoration.underline), isTrue);
      expect(styleOf('code')!.fontFamily, 'monospace');
      expect(styleOf('link')!.color, colours.accent);
      expect(styleOf('](https://x.org)')!.color, colours.marker);
      expect(styleOf('block')!.fontFamily, 'monospace');

      final composing = buildMarkdownTextSpan(
        'abc',
        colours: colours,
        composing: const TextRange(start: 1, end: 3),
      );
      expect(composing.toPlainText(), 'abc');
      expect(
        (composing.children![1] as TextSpan).style!.decoration,
        TextDecoration.underline,
      );
    });
  });
}
