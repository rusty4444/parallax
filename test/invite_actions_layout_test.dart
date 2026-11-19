import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/home/room_list_tile.dart';

import 'home_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'SpaceGrotesk',
    )..addFont(rootBundle.load('assets/fonts/SpaceGrotesk.ttf'))).load();
  });

  for (final width in [248.0, 268.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('invite labels fit a ${width}dp card at $scale text scale', (
        tester,
      ) async {
        var accepted = 0;
        var declined = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: themeFor(VisualTheme.parallax),
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: RoomListTile(
                      room: const ChatRoom(
                        id: '!invite:example.org',
                        name: 'Design review',
                        preview: '',
                        lastActivity: null,
                        invited: true,
                      ),
                      backend: HomeFakeBackend(),
                      palette: paletteFor(VisualTheme.parallax),
                      onTap: () {},
                      onAccept: () => accepted++,
                      onDecline: () => declined++,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final label in ['Accept', 'Decline']) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.text(label),
              matching: find.byType(RichText),
            ),
          );
          expect(
            paragraph.getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: label.length),
            ),
            hasLength(1),
            reason: '$label must stay on one line',
          );
          expect(find.text(label).hitTestable(), findsOneWidget);
          await tester.tap(find.text(label));
          await tester.pump();
        }
        expect(accepted, 1);
        expect(declined, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
