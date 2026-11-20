import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart' as matrix;
import 'package:parallax/app_theme.dart';
import 'package:parallax/appearance_preferences.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/feature_settings_scope.dart';
import 'package:parallax/features/message_fonts/message_fonts.dart';
import 'package:parallax/features/rich_timeline/message_composition.dart';
import 'package:parallax/matrix_backend.dart';
import 'package:parallax/message_draft_store.dart';
import 'package:parallax/messaging_features.dart';
import 'package:parallax/rich_message_composer.dart';
import 'package:parallax/secure_store.dart';
import 'package:parallax/timeline/bubble_column.dart';
import 'package:parallax/timeline/message_bubble.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widget_test.dart' show FakeBackend;

const _fontKey = 'parallax.appearance.v1.message_font';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('catalogue', () {
    test('IDs are stable, unique and well formed', () {
      expect(messageFonts.map((font) => font.id), [
        'dmserif',
        'indieflower',
        'pacifico',
        'lobster',
        'comicneue',
        'spacemono',
        'pressstart2p',
        'bangers',
      ]);
      expect(messageFonts.map((font) => font.family).toSet(), hasLength(8));
      for (final font in messageFonts) {
        expect(isMessageFontId(font.id), isTrue, reason: font.id);
      }
    });

    test('lookup resolves known IDs and treats anything else as default', () {
      expect(messageFontById('pacifico')?.family, 'Pacifico');
      expect(messageFontById('pacifico')?.label, 'Pacifico');
      expect(messageFontById('pressstart2p')?.label, 'Press Start 2P');
      expect(messageFontById(null), isNull);
      expect(messageFontById('wingdings'), isNull);
      expect(messageFontById('Pacifico'), isNull);
      expect(messageFontById(''), isNull);

      expect(messageFontOf({messageFontContentKey: 'lobster'})?.id, 'lobster');
      expect(messageFontOf({messageFontContentKey: 'unknown'}), isNull);
      expect(messageFontOf({messageFontContentKey: 42}), isNull);
      expect(messageFontOf(const {'body': 'hi'}), isNull);
    });

    test('ID shape check', () {
      expect(isMessageFontId('a'), isTrue);
      expect(isMessageFontId('future_font-2'), isTrue);
      expect(isMessageFontId('a' * 32), isTrue);
      expect(isMessageFontId('a' * 33), isFalse);
      expect(isMessageFontId(''), isFalse);
      expect(isMessageFontId('Pacifico'), isFalse);
      expect(isMessageFontId('comic sans'), isFalse);
      expect(isMessageFontId('font!'), isFalse);
    });

    test('every font is bundled, declared and licensed', () async {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('- assets/fonts/licenses/'));
      for (final font in messageFonts) {
        expect(pubspec, contains('- family: ${font.family}\n'));
        final match = RegExp(
          '- family: ${font.family}\\n\\s+fonts:\\n\\s+- asset: (\\S+)',
        ).firstMatch(pubspec);
        expect(match, isNotNull, reason: font.family);
        final bytes = File(match!.group(1)!).readAsBytesSync();
        // A TrueType outline font starts with version 1.0 (00 01 00 00).
        expect(bytes.sublist(0, 4), [0, 1, 0, 0], reason: font.family);
        final licence = File(font.licenceAsset).readAsStringSync();
        expect(licence, contains('SIL OPEN FONT LICENSE Version 1.1'));
        expect(licence, contains('Copyright'));
      }
    });

    test('licence entries carry each family’s notice', () async {
      final entries = await messageFontLicences().toList();
      expect(entries, hasLength(messageFonts.length));
      for (final (index, font) in messageFonts.indexed) {
        expect(entries[index].packages, ['${font.label} font']);
        final text = entries[index].paragraphs.map((p) => p.text).join('\n');
        expect(text, contains('SIL OPEN FONT LICENSE Version 1.1'));
        expect(text, isNot(contains('\r')));
      }
      final dm = entries.first.paragraphs.map((p) => p.text).join('\n');
      expect(dm, contains('Copyright 2019 Google LLC'));
    });
  });

  group('outgoing content', () {
    test('a new message carries the font key only when one is chosen', () {
      final plain = composeTextMessage('hello');
      final styled = withMessageFont(plain, 'pacifico');
      expect(styled[messageFontContentKey], 'pacifico');
      expect(styled['body'], 'hello');
      expect(styled['msgtype'], 'm.text');
      expect(plain.containsKey(messageFontContentKey), isFalse);

      expect(identical(withMessageFont(plain, null), plain), isTrue);
      expect(identical(withMessageFont(plain, 'wingdings'), plain), isTrue);
    });

    test('an edit carries it at the top level and in m.new_content', () {
      final edit = composeTextMessage('*fixed*', editEventId: r'$orig');
      final styled = withMessageFont(edit, 'lobster');
      expect(styled[messageFontContentKey], 'lobster');
      final newContent = styled['m.new_content'] as Map;
      expect(newContent[messageFontContentKey], 'lobster');
      expect(newContent['body'], '*fixed*');
      expect(newContent['formatted_body'], isNotNull);
      expect(styled['m.relates_to'], {
        'rel_type': 'm.replace',
        'event_id': r'$orig',
      });
      // The input is not modified.
      expect(
        (edit['m.new_content'] as Map).containsKey(messageFontContentKey),
        isFalse,
      );

      final plainEdit = withMessageFont(edit, null);
      expect(plainEdit.containsKey(messageFontContentKey), isFalse);
      expect(
        (plainEdit['m.new_content'] as Map).containsKey(messageFontContentKey),
        isFalse,
      );
    });

    group('through the outbox to the room', () {
      Future<_Room> send(
        Future<void> Function(MatrixBackend backend, _Client client) queue,
      ) async {
        final client = _Client();
        final backend = MatrixBackend.withClient(
          client,
          localStorage: _Store(),
          undoSendDelay: () async => Duration.zero,
        );
        addTearDown(backend.dispose);
        await queue(backend, client);
        for (var i = 0; i < 50 && backend.pendingSends.isNotEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(
          backend.pendingSends,
          isEmpty,
          reason: backend.pendingSends.map((p) => p.error).join(', '),
        );
        return client.room;
      }

      test('a new message in a chosen font', () async {
        final room = await send(
          (backend, client) =>
              backend.queueMessage(client.room.id, 'Hello', font: 'pacifico'),
        );
        final content = room.sent.single;
        expect(content['body'], 'Hello');
        expect(content[messageFontContentKey], 'pacifico');
      });

      test('a thread reply in a chosen font', () async {
        final room = await send(
          (backend, client) => backend.queueMessage(
            client.room.id,
            'In the thread',
            threadRootId: r'$root',
            font: 'comicneue',
          ),
        );
        expect(room.sent.single[messageFontContentKey], 'comicneue');
        expect(room.threadRoots.single, r'$root');
      });

      test('an edit in a chosen font', () async {
        final room = await send(
          (backend, client) => backend.queueMessage(
            client.room.id,
            'Fixed it',
            editEventId: r'$orig',
            font: 'bangers',
          ),
        );
        final content = room.sent.single;
        expect(content[messageFontContentKey], 'bangers');
        final newContent = content['m.new_content'] as Map;
        expect(newContent['body'], 'Fixed it');
        expect(newContent[messageFontContentKey], 'bangers');
        expect((content['m.relates_to'] as Map)['rel_type'], 'm.replace');
      });

      test('the default font sends no key', () async {
        final room = await send(
          (backend, client) => backend.queueMessage(client.room.id, 'Plain'),
        );
        expect(room.sent.single.containsKey(messageFontContentKey), isFalse);
      });

      test('a default-font edit sends no key either', () async {
        final edit = await send(
          (backend, client) => backend.queueMessage(
            client.room.id,
            'Plain edit',
            editEventId: r'$orig',
          ),
        );
        final content = edit.sent.single;
        expect(content.containsKey(messageFontContentKey), isFalse);
        expect(
          (content['m.new_content'] as Map).containsKey(messageFontContentKey),
          isFalse,
        );
      });

      test('an unknown font is dropped, not sent', () async {
        final room = await send(
          (backend, client) =>
              backend.queueMessage(client.room.id, 'Hi', font: 'wingdings'),
        );
        expect(room.sent.single.containsKey(messageFontContentKey), isFalse);
      });
    });
  });

  group('timeline', () {
    final palette = paletteFor(VisualTheme.parallax);
    final backend = FakeBackend()..currentUserId = '@me:example.org';

    Future<void> pumpBubble(WidgetTester tester, ChatEntry entry) async {
      tester.view
        ..physicalSize = const Size(400, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: themeFor(VisualTheme.parallax),
          home: Scaffold(
            body: ListView(
              children: [
                MessageBubble(
                  entry: entry,
                  backend: backend,
                  roomId: '!r:example.org',
                  palette: palette,
                  group: false,
                  onHeart: () {},
                  onAction: () {},
                  onReaction: (_) {},
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    ChatEntry message(
      String body, {
      Object? font,
      String? formattedBody,
      bool mine = false,
    }) => ChatEntry(
      id: r'$e',
      sender: mine ? '@me:example.org' : '@bo:example.org',
      body: body,
      time: DateTime(2026, 11, 20, 9),
      mine: mine,
      formattedBody: formattedBody,
      content: {
        'msgtype': 'm.text',
        'body': body,
        if (formattedBody != null) ...{
          'format': 'org.matrix.custom.html',
          'formatted_body': formattedBody,
        },
        messageFontContentKey: ?font,
      },
    );

    testWidgets('a known font draws the body in that family', (tester) async {
      await pumpBubble(tester, message('Fancy hello', font: 'pacifico'));
      expect(_familyOf(tester, 'Fancy hello'), 'Pacifico');
    });

    testWidgets('own messages too', (tester) async {
      await pumpBubble(tester, message('Mine', font: 'spacemono', mine: true));
      expect(_familyOf(tester, 'Mine'), 'SpaceMono');
    });

    testWidgets('unknown, malformed or missing fonts change nothing', (
      tester,
    ) async {
      await pumpBubble(tester, message('No font'));
      final standard = _familyOf(tester, 'No font');
      expect(messageFonts.map((f) => f.family), isNot(contains(standard)));
      for (final font in <Object>['wingdings', 42, 'Pacifico']) {
        await pumpBubble(tester, message('No font', font: font));
        expect(_familyOf(tester, 'No font'), standard, reason: '$font');
      }
    });

    testWidgets('formatted messages use it too; code stays monospace', (
      tester,
    ) async {
      await pumpBubble(
        tester,
        message(
          'Bold and x = 1',
          font: 'lobster',
          formattedBody: '<b>Bold</b> and <code>x = 1</code>',
        ),
      );
      expect(_familyOf(tester, 'Bold'), 'Lobster');
      expect(_familyOf(tester, 'x = 1'), 'monospace');
    });

    testWidgets('an edit that changes the font redraws the message', (
      tester,
    ) async {
      await pumpBubble(tester, message('Same text', font: 'pacifico'));
      expect(_familyOf(tester, 'Same text'), 'Pacifico');
      await pumpBubble(tester, message('Same text', font: 'bangers'));
      expect(_familyOf(tester, 'Same text'), 'Bangers');
      await pumpBubble(tester, message('Same text'));
      expect(_familyOf(tester, 'Same text'), isNot('Bangers'));
    });
  });

  group('preferences', () {
    test('the font is sticky and validated', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final preferences = AppearancePreferences(prefs: prefs);
      addTearDown(preferences.dispose);
      expect(preferences.messageFont, isNull);
      await preferences.setMessageFont('indieflower');
      expect(preferences.messageFont, 'indieflower');
      expect(prefs.getString(_fontKey), 'indieflower');

      final restored = AppearancePreferences(prefs: prefs);
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.messageFont, 'indieflower');

      await expectLater(
        preferences.setMessageFont('wingdings'),
        throwsArgumentError,
      );
      expect(preferences.messageFont, 'indieflower');

      await preferences.setMessageFont(null);
      expect(preferences.messageFont, isNull);
      expect(prefs.containsKey(_fontKey), isFalse);
    });

    test('a stored font this version does not know loads as default', () async {
      SharedPreferences.setMockInitialValues({_fontKey: 'wingdings'});
      final preferences = AppearancePreferences(
        prefs: await SharedPreferences.getInstance(),
      );
      addTearDown(preferences.dispose);
      await preferences.load();
      expect(preferences.messageFont, isNull);
    });
  });

  group('composer', () {
    Future<AppearancePreferences> mount(
      WidgetTester tester, {
      required TextEditingController controller,
      Map<String, Object> stored = const {},
      bool scoped = true,
      MediaPicker? pickFile,
    }) async {
      // Tall enough for the whole font list.
      tester.view
        ..physicalSize = const Size(500, 1400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues(stored);
      final preferences = AppearancePreferences(
        prefs: await SharedPreferences.getInstance(),
      );
      await preferences.load();
      addTearDown(preferences.dispose);
      final composer = MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: RichMessageComposer(
              controller: controller,
              sending: false,
              onSend: (_, _) async {},
              pickFile: pickFile,
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        scoped
            ? FeatureSettingsScope(
                preferences: preferences,
                draftStore: MessageDraftStore(),
                child: composer,
              )
            : composer,
      );
      return preferences;
    }

    IconButton fontButton(WidgetTester tester) => tester.widget<IconButton>(
      find.byKey(const ValueKey('composer-message-font')),
    );

    String? fieldFamily(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).style?.fontFamily;

    testWidgets('the picker sets a sticky font shown while typing', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'Draft');
      addTearDown(controller.dispose);
      final preferences = await mount(tester, controller: controller);
      expect(fontButton(tester).isSelected, isFalse);
      expect(fieldFamily(tester), isNull);

      await tester.tap(find.byTooltip('Message font'));
      await tester.pumpAndSettle();
      expect(find.text('Message font'), findsWidgets);
      // Every option is drawn in its own face, the current one ticked.
      for (final font in messageFonts) {
        expect(
          tester.widget<Text>(find.text(font.label)).style?.fontFamily,
          font.family,
        );
      }
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('message-font-default')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('message-font-pacifico')));
      await tester.pumpAndSettle();

      expect(preferences.messageFont, 'pacifico');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_fontKey), 'pacifico');
      expect(fieldFamily(tester), 'Pacifico');
      expect(fontButton(tester).isSelected, isTrue);
      expect(controller.text, 'Draft');

      // Reopening ticks the chosen font; Default clears it.
      await tester.tap(find.byTooltip('Message font'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('message-font-pacifico')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('message-font-default')));
      await tester.pumpAndSettle();
      expect(preferences.messageFont, isNull);
      expect(prefs.containsKey(_fontKey), isFalse);
      expect(fieldFamily(tester), isNull);
      expect(fontButton(tester).isSelected, isFalse);
    });

    testWidgets('a saved font is restored with the preferences', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await mount(
        tester,
        controller: controller,
        stored: {_fontKey: 'lobster'},
      );
      expect(fieldFamily(tester), 'Lobster');
      expect(fontButton(tester).isSelected, isTrue);
    });

    testWidgets('dismissing the picker keeps the font', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final preferences = await mount(
        tester,
        controller: controller,
        stored: {_fontKey: 'bangers'},
      );
      await tester.tap(find.byTooltip('Message font'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(preferences.messageFont, 'bangers');
    });

    testWidgets('no font button for attachments or without preferences', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await mount(
        tester,
        controller: controller,
        stored: {_fontKey: 'pacifico'},
        pickFile: () async => MediaSelection(
          bytes: Uint8List(3),
          name: 'notes.pdf',
          mimeType: 'application/pdf',
        ),
      );
      expect(find.byTooltip('Message font'), findsOneWidget);
      await tester.tap(find.byTooltip('Attach media'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      expect(find.text('notes.pdf'), findsOneWidget);
      // Captions are not text messages: default font, no button.
      expect(find.byTooltip('Message font'), findsNothing);
      expect(fieldFamily(tester), isNull);
      await tester.tap(find.byTooltip('Remove attachment'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Message font'), findsOneWidget);
      expect(fieldFamily(tester), 'Pacifico');

      await mount(tester, controller: controller, scoped: false);
      expect(find.byTooltip('Message font'), findsNothing);
    });
  });
}

/// The font family the glyphs of [text] are drawn with: the closest span
/// style naming a family, from the [RichText] that contains it.
String? _familyOf(WidgetTester tester, String text) {
  for (final element
      in find
          .descendant(
            of: find.byType(BubbleColumn),
            matching: find.byType(RichText),
          )
          .evaluate()) {
    final found = _familyIn((element.widget as RichText).text, text, null);
    if (found != null) return found.$1;
  }
  fail('No text "$text" in the bubble');
}

(String?,)? _familyIn(InlineSpan span, String text, String? inherited) {
  final family = span.style?.fontFamily ?? inherited;
  if (span is TextSpan) {
    if (span.text?.contains(text) ?? false) return (family,);
    for (final child in span.children ?? const <InlineSpan>[]) {
      final found = _familyIn(child, text, family);
      if (found != null) return found;
    }
  }
  return null;
}

class _Database extends Fake implements matrix.DatabaseApi {}

class _Store implements SecureValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _Client extends matrix.Client {
  _Client()
    : super(
        'font-test',
        database: _Database(),
        httpClient: MockClient((_) async => http.Response('{}', 500)),
      ) {
    homeserver = Uri.parse('https://matrix.example');
    accessToken = 'test-token';
    onLoginStateChanged.add(matrix.LoginState.loggedIn);
  }
  late final room = _Room();
  @override
  String? get userID => '@sam:matrix.example';
  @override
  String? get deviceID => 'DEVICE';
  @override
  matrix.Room? getRoomById(String id) => room.id == id ? room : null;
  @override
  Future<void> dispose({bool closeDatabase = true}) async {}
}

class _Room extends Fake implements matrix.Room {
  final sent = <Map<String, Object?>>[];
  final threadRoots = <String?>[];
  @override
  String get id => '!room:matrix.example';
  @override
  bool get encrypted => false;
  @override
  matrix.Membership get membership => matrix.Membership.join;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #getEventById) {
      final id = invocation.positionalArguments.first as String;
      return Future<matrix.Event?>.value(
        matrix.Event(
          content: {'msgtype': 'm.text', 'body': 'Original'},
          type: matrix.EventTypes.Message,
          eventId: id,
          senderId: '@sam:matrix.example',
          originServerTs: DateTime(2026, 11, 20),
          room: this,
        ),
      );
    }
    if (invocation.memberName == #sendEvent) {
      sent.add(
        Map<String, Object?>.from(
          invocation.positionalArguments.first as Map<String, dynamic>,
        ),
      );
      threadRoots.add(invocation.namedArguments[#threadRootEventId] as String?);
      return Future<String?>.value(r'$sent');
    }
    return super.noSuchMethod(invocation);
  }
}
