import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/messaging_features.dart';

import 'gif_preview_test.dart' show pngBytes;
import 'rich_message_composer_test.dart' show mount;
import 'windows_desktop_ux_test.dart' show platformTestWidgets;

void main() {
  platformTestWidgets(
    'macOS Enter sends and Shift+Enter does not send',
    TargetPlatform.macOS,
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final sent = <String>[];
      await mount(
        tester,
        controller: controller,
        onSend: (text, media) async {
          sent.add(text);
        },
      );
      await tester.enterText(find.byType(TextField), 'hello matrix');
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(sent, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent, ['hello matrix']);
    },
  );

  platformTestWidgets(
    'macOS Cmd+V stages the native PNG for sending',
    TargetPlatform.macOS,
    (tester) async {
      const channel = MethodChannel('parallax/clipboard');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var reads = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'readImage');
        reads++;
        return pngBytes;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      MediaSelection? sent;
      await mount(
        tester,
        controller: controller,
        onSend: (text, media) async {
          sent = media;
        },
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(reads, 1);
      expect(find.text('pasted-image.png'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent, isNotNull);
      expect(sent!.name, 'pasted-image.png');
      expect(sent!.mimeType, 'image/png');
      expect(sent!.bytes, orderedEquals(pngBytes));
    },
  );

  platformTestWidgets(
    'macOS Cmd+V falls back to text at the selection',
    TargetPlatform.macOS,
    (tester) async {
      const channel = MethodChannel('parallax/clipboard');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': 'pasted text'};
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(channel, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await mount(tester, controller: controller, onSend: (_, _) async {});
      await tester.enterText(find.byType(TextField), 'before after');
      await tester.tap(find.byType(TextField));
      await tester.pump();
      controller.selection = const TextSelection.collapsed(offset: 7);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(controller.text, 'before pasted textafter');
      expect(find.text('pasted-image.png'), findsNothing);
    },
  );
}
