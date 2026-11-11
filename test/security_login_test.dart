import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/login_screen.dart';

class _LoginBackend extends ChatBackend {
  final logins = <(String, String)>[];

  @override
  SessionStatus get connection => SessionStatus.signedOut;
  @override
  String? get userId => null;

  @override
  Future<void> login({
    required String homeserver,
    required String username,
    required String password,
  }) async {
    logins.add((homeserver, username));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_LoginBackend> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
  final backend = _LoginBackend();
  await tester.pumpWidget(
    MaterialApp(
      theme: themeFor(VisualTheme.parallax),
      home: LoginScreen(
        backend: backend,
        palette: paletteFor(VisualTheme.parallax),
      ),
    ),
  );
  return backend;
}

TextField _server(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).first);

Future<void> _submit(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Enter the matrix'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Enter the matrix'));
  await tester.pump();
}

void main() {
  testWidgets('matrix.org is the default, fixed account provider', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('matrix.org'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
    expect(find.text('You’re about to sign in to matrix.org'), findsOneWidget);
    expect(_server(tester).readOnly, isTrue);
    expect(_server(tester).controller!.text, 'https://matrix.org');
  });

  testWidgets('Other lets the user enter their own provider', (tester) async {
    final backend = await _pump(tester);
    await tester.tap(find.text('Other'));
    await tester.pump();
    expect(_server(tester).readOnly, isFalse);
    expect(_server(tester).controller!.text, isEmpty);
    expect(find.textContaining('example: companyname.com'), findsOneWidget);
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'https://chat.example.org',
    );
    await tester.pump();
    expect(
      find.text('You’re about to sign in to chat.example.org'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextFormField).at(1), 'sam');
    await tester.enterText(find.byType(TextFormField).at(2), 'secret');
    await _submit(tester);
    expect(backend.logins, [('https://chat.example.org', 'sam')]);

    // Switching back restores matrix.org.
    await tester.ensureVisible(find.text('matrix.org'));
    await tester.tap(find.text('matrix.org'));
    await tester.pump();
    expect(_server(tester).controller!.text, 'https://matrix.org');
    expect(_server(tester).readOnly, isTrue);
  });

  testWidgets('a Matrix ID on another server is caught before sign-in', (
    tester,
  ) async {
    final backend = await _pump(tester);
    await tester.enterText(
      find.byType(TextFormField).at(1),
      '@sam:example.org',
    );
    await tester.enterText(find.byType(TextFormField).at(2), 'secret');
    await _submit(tester);
    expect(backend.logins, isEmpty);
    expect(
      find.textContaining('This Matrix ID belongs to example.org'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextFormField).at(1), '@sam:matrix.org');
    await _submit(tester);
    expect(backend.logins, [('https://matrix.org', '@sam:matrix.org')]);
  });
}
