import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:parallax/app_theme.dart';
import 'package:parallax/chat_backend.dart';
import 'package:parallax/features/bridged_messages/bridged_message_features.dart';
import 'package:parallax/features/bridged_messages/bridged_message_models.dart';
import 'package:parallax/features/bridged_messages/new_bridged_message_screen.dart';
import 'package:parallax/room_creation_request.dart';

import 'widget_test.dart' show FakeBackend;

const _capabilities = BridgeCapabilities(
  canListContacts: false,
  canSearchRecipients: false,
  canResolvePhoneNumber: false,
  canResolveUsername: false,
  canUseAnyPhoneNumber: true,
  canCreateDirectConversation: true,
  supportedIdentifierTypes: {BridgeIdentifierType.phoneNumber},
);
const _metaCapabilities = BridgeCapabilities(
  canListContacts: false,
  canSearchRecipients: true,
  canResolvePhoneNumber: false,
  canResolveUsername: false,
  canUseAnyPhoneNumber: false,
  canCreateDirectConversation: true,
  supportedIdentifierTypes: {BridgeIdentifierType.remoteId},
);
const _account = BridgeAccount(
  service: BridgedService.googleMessages,
  accountId: 'login-1',
  displayName: 'Personal',
  capabilities: _capabilities,
  availability: BridgeAccountAvailability.connected,
);
const _instagramAccount = BridgeAccount(
  service: BridgedService.instagram,
  accountId: 'ig-login-1',
  displayName: '@sam',
  capabilities: _metaCapabilities,
  availability: BridgeAccountAvailability.connected,
);
const _messengerAccount = BridgeAccount(
  service: BridgedService.messenger,
  accountId: 'fb-login-1',
  displayName: 'Sam',
  capabilities: _metaCapabilities,
  availability: BridgeAccountAvailability.connected,
);
const _roomId = '!bridged:example.org';
const _room = ChatRoom(
  id: _roomId,
  name: 'Recipient',
  preview: '',
  lastActivity: null,
  isDirect: true,
);

class _FakeFeatures implements BridgedMessageFeatures {
  List<BridgeAccount> accounts = [_account];
  List<String> warnings = const [];
  List<BridgeRecipient> searchResponse = const [];
  Object? loadError;
  Object? searchError;
  Object? createError;
  Completer<BridgeConversation>? createCompleter;
  Completer<BridgeRecipient>? resolveCompleter;
  Completer<List<BridgeRecipient>>? searchCompleter;
  int resolveCalls = 0;
  int searchCalls = 0;
  int createCalls = 0;
  String? lastSearchQuery;
  BridgeAccount? lastCreateAccount;
  BridgeRecipient? lastCreateRecipient;

  @override
  String? get defaultPhoneRegion => 'AU';

  @override
  List<String> get serviceWarnings => warnings;

  @override
  Future<List<BridgeAccount>> loadAccounts() async {
    if (loadError case final error?) throw error;
    return accounts;
  }

  @override
  Future<List<BridgeRecipient>> searchRecipients(
    BridgeAccount account,
    String query,
  ) async {
    searchCalls++;
    lastSearchQuery = query;
    if (searchError case final error?) throw error;
    if (searchCompleter case final completer?) return completer.future;
    return searchResponse;
  }

  @override
  Future<BridgeRecipient> resolveRecipient(
    BridgeAccount account,
    String identifier,
  ) async {
    resolveCalls++;
    final phone = normalizePhoneNumber(identifier, defaultRegion: 'AU');
    final recipient = BridgeRecipient(
      service: account.service,
      accountId: account.accountId,
      identifierType: BridgeIdentifierType.phoneNumber,
      canonicalIdentifier: phone,
      remoteUserId: phone,
    );
    if (resolveCompleter case final completer?) return completer.future;
    return recipient;
  }

  @override
  Future<BridgeConversation> ensureDirectConversation(
    BridgeAccount account,
    BridgeRecipient recipient,
  ) async {
    createCalls++;
    lastCreateAccount = account;
    lastCreateRecipient = recipient;
    if (createError case final error?) throw error;
    if (createCompleter case final completer?) return completer.future;
    return BridgeConversation(
      roomId: _roomId,
      accountId: account.accountId,
      service: account.service,
      createdOrExisting: ConversationCreationState.unknown,
      portalCreated: true,
    );
  }
}

Future<FakeBackend> _mount(WidgetTester tester, _FakeFeatures features) async {
  final backend = FakeBackend()..currentUserId = '@me:example.org';
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => FilledButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => NewBridgedMessageScreen(
                backend: backend,
                palette: paletteFor(VisualTheme.parallax),
                features: features,
              ),
            ),
          ),
          child: const Text('Host screen'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Host screen'));
  await tester.pumpAndSettle();
  return backend;
}

Future<void> _review(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('bridged.recipient')),
    '0412 345 678',
  );
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('bridged.review')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('typing and reviewing never create a conversation', (
    tester,
  ) async {
    final features = _FakeFeatures();
    await _mount(tester, features);
    expect(find.text('+61412345678'), findsNothing);
    await _review(tester);
    expect(features.resolveCalls, 1);
    expect(features.createCalls, 0);
    expect(find.text('+61412345678'), findsOneWidget);
    expect(find.text('Open conversation'), findsOneWidget);
    expect(find.textContaining('No message will be sent'), findsOneWidget);
    expect(find.textContaining('Name search is not supported'), findsOneWidget);
    expect(
      tester
          .widget<Semantics>(
            find.byKey(const ValueKey('bridged.confirmation_semantics')),
          )
          .properties
          .liveRegion,
      isTrue,
    );
  });

  testWidgets('invalid input shows a safe error without a bridge call', (
    tester,
  ) async {
    final features = _FakeFeatures();
    await _mount(tester, features);
    await tester.enterText(
      find.byKey(const ValueKey('bridged.recipient')),
      'not a phone number',
    );
    await tester.tap(find.byKey(const ValueKey('bridged.review')));
    await tester.pump();
    expect(features.resolveCalls, 0);
    expect(features.createCalls, 0);
    expect(find.textContaining('valid phone number'), findsOneWidget);
    expect(
      tester
          .widget<Semantics>(
            find.byKey(const ValueKey('bridged.operation_error')),
          )
          .properties
          .liveRegion,
      isTrue,
    );
  });

  testWidgets('account loading failures are recoverable', (tester) async {
    final features = _FakeFeatures()
      ..loadError = const BridgedMessageException(
        BridgedMessageErrorKind.bridgeUnavailable,
        'Bridge unavailable for test',
      );
    await _mount(tester, features);
    expect(find.text('Bridge unavailable for test'), findsOneWidget);
    features.loadError = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bridged.recipient')), findsOneWidget);
  });

  testWidgets('disconnected account cannot review or create', (tester) async {
    final features = _FakeFeatures()
      ..accounts = const [
        BridgeAccount(
          service: BridgedService.googleMessages,
          accountId: 'login-1',
          displayName: 'Personal',
          capabilities: _capabilities,
          availability: BridgeAccountAvailability.disconnected,
        ),
      ];
    await _mount(tester, features);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('bridged.review')),
    );
    expect(button.onPressed, isNull);
    expect(find.textContaining('account is disconnected'), findsOneWidget);
    expect(features.resolveCalls, 0);
    expect(features.createCalls, 0);
  });

  testWidgets('unsupported creation explains the unavailable action', (
    tester,
  ) async {
    final features = _FakeFeatures()
      ..accounts = const [
        BridgeAccount(
          service: BridgedService.googleMessages,
          accountId: 'login-1',
          displayName: 'Personal',
          capabilities: BridgeCapabilities(
            canListContacts: false,
            canSearchRecipients: false,
            canResolvePhoneNumber: false,
            canResolveUsername: false,
            canUseAnyPhoneNumber: true,
            canCreateDirectConversation: false,
            supportedIdentifierTypes: {BridgeIdentifierType.phoneNumber},
          ),
          availability: BridgeAccountAvailability.connected,
        ),
      ];
    await _mount(tester, features);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('bridged.review')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('bridged.recipient')))
          .enabled,
      isFalse,
    );
    expect(
      find.textContaining('Starting conversations is unavailable'),
      findsOneWidget,
    );
  });

  testWidgets('stale recipient resolution cannot install an old confirmation', (
    tester,
  ) async {
    final features = _FakeFeatures();
    final completer = Completer<BridgeRecipient>();
    features.resolveCompleter = completer;
    await _mount(tester, features);
    await tester.enterText(
      find.byKey(const ValueKey('bridged.recipient')),
      '0412 345 678',
    );
    await tester.tap(find.byKey(const ValueKey('bridged.review')));
    await tester.pump();
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('bridged.recipient')),
    );
    field.controller!.text = '0499 999 999';
    field.onChanged?.call(field.controller!.text);
    await tester.pump();
    final stalePhone = normalizePhoneNumber(
      '0412 345 678',
      defaultRegion: 'AU',
    );
    completer.complete(
      BridgeRecipient(
        service: _account.service,
        accountId: _account.accountId,
        identifierType: BridgeIdentifierType.phoneNumber,
        canonicalIdentifier: stalePhone,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bridged.open')), findsNothing);
    expect(find.text(stalePhone), findsNothing);
    expect(features.resolveCalls, 1);
    expect(features.createCalls, 0);
  });

  testWidgets('double submission and late acknowledgement use one create', (
    tester,
  ) async {
    final features = _FakeFeatures();
    final backend = await _mount(tester, features);
    await _review(tester);
    final completer = Completer<BridgeConversation>();
    features.createCompleter = completer;
    addTearDown(() {
      if (!completer.isCompleted) {
        completer.complete(
          const BridgeConversation(
            roomId: _roomId,
            accountId: 'login-1',
            service: BridgedService.googleMessages,
            createdOrExisting: ConversationCreationState.unknown,
            portalCreated: true,
          ),
        );
      }
    });
    await tester.tap(find.byKey(const ValueKey('bridged.open')));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('bridged.open')),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(seconds: 11));
    expect(features.createCalls, 1);
    expect(find.text('CONFIRMATION DELAYED'), findsOneWidget);
    expect(
      tester
          .widget<Semantics>(
            find.byKey(const ValueKey('bridged.creation_pending_semantics')),
          )
          .properties
          .liveRegion,
      isTrue,
    );
    completer.complete(
      const BridgeConversation(
        roomId: _roomId,
        accountId: 'login-1',
        service: BridgedService.googleMessages,
        createdOrExisting: ConversationCreationState.unknown,
        portalCreated: true,
      ),
    );
    await tester.pump();
    backend.roomList = [_room];
    backend.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Host screen'), findsOneWidget);
    expect(features.createCalls, 1);
    expect(RoomCreationRequest.forBackend(backend).active, isFalse);
  });

  testWidgets('route disposal and reopening recover the acknowledged room', (
    tester,
  ) async {
    final features = _FakeFeatures();
    final backend = await _mount(tester, features);
    await _review(tester);
    final completer = Completer<BridgeConversation>();
    features.createCompleter = completer;
    await tester.tap(find.byKey(const ValueKey('bridged.open')));
    await tester.pump();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Host screen'), findsOneWidget);
    completer.complete(
      const BridgeConversation(
        roomId: _roomId,
        accountId: 'login-1',
        service: BridgedService.googleMessages,
        createdOrExisting: ConversationCreationState.unknown,
        portalCreated: true,
      ),
    );
    await tester.pump();
    backend.roomList = [_room];
    backend.notifyListeners();
    final request = RoomCreationRequest.forBackend(backend);
    expect(request.roomId, _roomId);
    expect(request.active, isTrue);
    await tester.tap(find.text('Host screen'));
    await tester.pumpAndSettle();
    expect(find.text('Host screen'), findsOneWidget);
    expect(features.createCalls, 1);
    expect(request.active, isFalse);
  });

  testWidgets('delayed Matrix readiness retries only the room wait', (
    tester,
  ) async {
    final features = _FakeFeatures();
    final backend = await _mount(tester, features);
    await _review(tester);
    await tester.tap(find.byKey(const ValueKey('bridged.open')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    expect(features.createCalls, 1);
    expect(find.text('Check room again'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('bridged.recipient')))
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('bridged.review')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<Semantics>(
            find.byKey(const ValueKey('bridged.room_wait_semantics')),
          )
          .properties
          .liveRegion,
      isTrue,
    );
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('bridged.recipient')),
    );
    field.controller!.text = '0499 999 999';
    field.onChanged?.call(field.controller!.text);
    await tester.tap(
      find.byKey(const ValueKey('bridged.review')),
      warnIfMissed: false,
    );
    await tester.pump();
    expect(features.resolveCalls, 1);
    expect(find.byKey(const ValueKey('bridged.open')), findsNothing);
    backend.roomList = [_room];
    backend.notifyListeners();
    await tester.tap(find.byKey(const ValueKey('bridged.retry_room')));
    await tester.pumpAndSettle();
    expect(find.text('Host screen'), findsOneWidget);
    expect(features.createCalls, 1);
  });

  testWidgets('uncertain creation failure stays locked against another POST', (
    tester,
  ) async {
    final features = _FakeFeatures()
      ..createError = const BridgedMessageException(
        BridgedMessageErrorKind.uncertainOutcome,
        'Uncertain creation failure',
        definiteNonCreation: false,
      );
    final backend = await _mount(tester, features);
    await _review(tester);
    await tester.tap(find.byKey(const ValueKey('bridged.open')));
    await tester.pump();
    await tester.pump();
    expect(find.text('CONFIRMATION DELAYED'), findsOneWidget);
    expect(RoomCreationRequest.forBackend(backend).active, isTrue);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('bridged.open')))
          .onPressed,
      isNull,
    );
    await tester.tap(
      find.byKey(const ValueKey('bridged.open')),
      warnIfMissed: false,
    );
    await tester.pump(const Duration(seconds: 11));
    expect(features.createCalls, 1);
  });

  testWidgets('definite creation failure is safe and retryable', (
    tester,
  ) async {
    final features = _FakeFeatures()
      ..createError = const BridgedMessageException(
        BridgedMessageErrorKind.permissionDenied,
        'Safe creation failure',
      );
    final backend = await _mount(tester, features);
    await _review(tester);
    await tester.tap(find.byKey(const ValueKey('bridged.open')));
    await tester.pumpAndSettle();
    expect(find.text('Safe creation failure'), findsOneWidget);
    expect(find.textContaining('private'), findsNothing);
    expect(RoomCreationRequest.forBackend(backend).active, isFalse);
    expect(features.createCalls, 1);
  });

  group('Meta search and disclosure flow', () {
    testWidgets(
      'Instagram uses explicit search, keeps numeric ID internal, shows text-first disclosure and opens room',
      (tester) async {
        const candidate = BridgeRecipient(
          service: BridgedService.instagram,
          accountId: 'ig-login-1',
          identifierType: BridgeIdentifierType.remoteId,
          canonicalIdentifier: '17841400000000001',
          remoteUserId: '17841400000000001',
          displayName: 'Alice Example',
          identifiers: ['instagram:alice.example'],
          verifiedRemoteIdentity: true,
        );
        final features = _FakeFeatures()
          ..accounts = const [_instagramAccount]
          ..searchResponse = const [candidate];
        final backend = await _mount(tester, features);

        // Typing never searches as-you-type.
        await tester.enterText(
          find.byKey(const ValueKey('bridged.recipient')),
          '@alice.example',
        );
        await tester.pump(const Duration(seconds: 1));
        expect(features.searchCalls, 0);
        expect(features.createCalls, 0);

        // Explicit search submits normalized handle.
        await tester.tap(find.byKey(const ValueKey('bridged.search')));
        await tester.pumpAndSettle();
        expect(features.searchCalls, 1);
        expect(features.lastSearchQuery, 'alice.example');
        expect(features.createCalls, 0);
        expect(find.text('Alice Example'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('bridged.result.17841400000000001')),
            matching: find.text('@alice.example'),
          ),
          findsOneWidget,
        );
        expect(find.text('17841400000000001'), findsNothing);

        // Selecting a person shows confirmation + Instagram caveats without creating.
        await tester.tap(
          find.byKey(const ValueKey('bridged.result.17841400000000001')),
        );
        await tester.pumpAndSettle();
        expect(features.createCalls, 0);
        expect(find.textContaining('first text message'), findsOneWidget);
        expect(
          find.textContaining('Send text before sending photos'),
          findsOneWidget,
        );

        // Explicit Open conversation calls create_dm with numeric ID and waits for Matrix.
        backend.roomList = [_room];
        await tester.tap(find.byKey(const ValueKey('bridged.open')));
        await tester.pumpAndSettle();
        expect(features.createCalls, 1);
        expect(features.lastCreateAccount?.key, 'instagram:ig-login-1');
        expect(
          features.lastCreateRecipient?.canonicalIdentifier,
          '17841400000000001',
        );
        expect(find.text('Host screen'), findsOneWidget);
      },
    );

    testWidgets(
      'Messenger shows remote setup caveat and invalidates stale search on query edit',
      (tester) async {
        final searchCompleter = Completer<List<BridgeRecipient>>();
        final features = _FakeFeatures()
          ..accounts = const [_messengerAccount]
          ..searchCompleter = searchCompleter;
        await _mount(tester, features);

        await tester.enterText(
          find.byKey(const ValueKey('bridged.recipient')),
          'Bob',
        );
        await tester.tap(find.byKey(const ValueKey('bridged.search')));
        await tester.pump();

        final field = tester.widget<TextField>(
          find.byKey(const ValueKey('bridged.recipient')),
        );
        field.controller!.text = 'Charlie';
        field.onChanged?.call('Charlie');
        await tester.pump();
        searchCompleter.complete(const [
          BridgeRecipient(
            service: BridgedService.messenger,
            accountId: 'fb-login-1',
            identifierType: BridgeIdentifierType.remoteId,
            canonicalIdentifier: '100001234567890',
            displayName: 'Bob Stale',
            verifiedRemoteIdentity: true,
          ),
        ]);
        await tester.pumpAndSettle();
        expect(find.text('Bob Stale'), findsNothing);

        features.searchCompleter = null;
        features.searchResponse = const [
          BridgeRecipient(
            service: BridgedService.messenger,
            accountId: 'fb-login-1',
            identifierType: BridgeIdentifierType.remoteId,
            canonicalIdentifier: '100009876543210',
            displayName: 'Charlie Messenger',
            verifiedRemoteIdentity: true,
          ),
        ];
        await tester.tap(find.byKey(const ValueKey('bridged.search')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('bridged.result.100009876543210')),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('does not guarantee Messenger accepted'),
          findsOneWidget,
        );
        expect(features.createCalls, 0);
      },
    );

    testWidgets(
      'shows partial bridge warnings and empty search state cleanly',
      (tester) async {
        final features = _FakeFeatures()
          ..accounts = const [_instagramAccount, _account]
          ..warnings = const [
            'Couldn’t reach Messenger. Check the connection and try again.',
          ]
          ..searchResponse = const [];
        await _mount(tester, features);
        expect(
          find.byKey(const ValueKey('bridged.service_warnings')),
          findsOneWidget,
        );
        expect(find.textContaining('Couldn’t reach Messenger'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('bridged.account')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Instagram · @sam').last);
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const ValueKey('bridged.recipient')),
          'nobody_matches',
        );
        await tester.tap(find.byKey(const ValueKey('bridged.search')));
        await tester.pumpAndSettle();
        expect(find.text('No matching people found'), findsOneWidget);
      },
    );
  });
}
