// Background push handling for when Parallax's main isolate is not running
// (FCM background handler, UnifiedPush headless service, notification
// actions).
//
// Order of preference:
//  1. Hand the push to the main isolate (it owns the client and database).
//  2. Otherwise open a short-lived, READ-ONLY client on the same database:
//     no Client.init, no sync loop, no key upload, no to-device processing and
//     no database writes. Fetch the one event over HTTP, decrypt it with the
//     stored Megolm session, render, close.
//  3. On any failure or timeout: the generic notification.
//
// Residual risk: the app can start while a background client has the database
// open. The background connection is read-only, so it cannot corrupt
// crypto state; MatrixBackend.initialize also waits (bounded) for the
// background lock file so startup migrations do not race the read.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vodozemac;
import 'package:http/http.dart' as http;
import 'package:matrix/encryption.dart' as encryption;
import 'package:matrix/matrix.dart' as matrix;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqlite;
import 'package:vodozemac/vodozemac.dart' as vod;

import '../../homeserver_security.dart';
import '../../message_copy_targets.dart';
import '../../push_notifications.dart';
import 'matrix_push_projection.dart';
import 'notification_media.dart';
import 'notification_model.dart';
import 'notification_renderer.dart';
import 'notification_store.dart';
import 'push_handoff.dart';
import 'rich_push_handler.dart';

/// Matrix SDK client and database names used by MatrixBackend.
const _clientName = 'Parallax';
const _databaseName = 'parallax';
const _databaseFile = 'parallax.db';

/// Total time a background isolate spends resolving one push.
const backgroundResolveTimeout = Duration(seconds: 15);

/// Largest event JSON accepted from `/rooms/{roomId}/event/{eventId}`.
const _maxEventBytes = 256 * 1024;

// --- Lock --------------------------------------------------------------------

/// Marks a running background client so the main isolate can wait for it.
class BackgroundClientLock {
  BackgroundClientLock._(this._file);

  static const fileName = 'push_background_client.lock';

  /// A lock older than this belongs to a killed isolate.
  static const staleAfter = Duration(seconds: 40);

  final File _file;

  static File fileIn(String directory) => File(p.join(directory, fileName));

  /// Null when another background client is running.
  static Future<BackgroundClientLock?> acquire(String directory) async {
    final file = fileIn(directory);
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await file.create(exclusive: true);
        return BackgroundClientLock._(file);
      } on FileSystemException {
        if (!await _isStale(file)) return null;
        try {
          await file.delete();
        } on FileSystemException {
          return null;
        }
      }
    }
    return null;
  }

  static Future<bool> _isStale(File file) async {
    try {
      return DateTime.now().difference(await file.lastModified()) > staleAfter;
    } on FileSystemException {
      return true;
    }
  }

  Future<void> release() async {
    try {
      await _file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}

/// Called by the main isolate before opening the database: waits (bounded)
/// until a background push client has closed its read-only connection.
Future<void> waitForBackgroundPushClient(
  String supportDirectory, {
  Duration maxWait = const Duration(seconds: 8),
  Duration poll = const Duration(milliseconds: 150),
}) async {
  final file = BackgroundClientLock.fileIn(supportDirectory);
  final deadline = DateTime.now().add(maxWait);
  try {
    while (await file.exists()) {
      if (await BackgroundClientLock._isStale(file)) {
        try {
          await file.delete();
        } on FileSystemException {
          // Raced with its owner.
        }
        return;
      }
      if (DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(poll);
    }
  } catch (_) {
    // Never block startup on the lock.
  }
}

// --- Short-lived read-only client --------------------------------------------

/// A Client that is never initialised: credentials, account data and push
/// rules are read from the database and nothing is written back.
class _BackgroundClient extends matrix.Client {
  _BackgroundClient({
    required matrix.DatabaseApi database,
    required String userId,
    required String deviceId,
    required Uri homeserver,
    required String accessToken,
    required Map<String, matrix.BasicEvent> accountData,
    required http.Client httpClient,
  }) : _user = userId,
       _device = deviceId,
       _account = accountData,
       super(_clientName, database: database, httpClient: httpClient) {
    this.homeserver = homeserver;
    this.accessToken = accessToken;
    final rules = accountData[matrix.EventTypes.PushRules]?.content;
    try {
      _rules = rules == null
          ? null
          : matrix.PushruleEvaluator.fromRuleset(
              matrix.PushRuleSet.fromJson(Map<String, Object?>.from(rules)),
            );
    } catch (_) {
      _rules = null;
    }
  }

  final String _user;
  final String _device;
  final Map<String, matrix.BasicEvent> _account;
  matrix.PushruleEvaluator? _rules;

  @override
  String? get userID => _user;

  @override
  String? get deviceID => _device;

  @override
  Map<String, matrix.BasicEvent> get accountData => _account;

  @override
  Map<String, List<String>> get directChats {
    final content = _account['m.direct']?.content ?? const {};
    return {
      for (final entry in content.entries)
        entry.key: entry.value is List
            ? (entry.value as List).whereType<String>().toList()
            : const <String>[],
    };
  }

  @override
  matrix.PushruleEvaluator get pushruleEvaluator =>
      _rules ?? super.pushruleEvaluator;
}

/// Fetches one event with the stored access token (bounded, no redirects).
@visibleForTesting
Future<Map<String, Object?>> fetchPushEvent({
  required http.Client httpClient,
  required Uri homeserver,
  required String accessToken,
  required String roomId,
  required String eventId,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final prefix = homeserver.pathSegments.where((s) => s.isNotEmpty);
  final uri = homeserver.replace(
    pathSegments: [
      ...prefix,
      '_matrix',
      'client',
      'v3',
      'rooms',
      roomId,
      'event',
      eventId,
    ],
    query: null,
    fragment: null,
  );
  final request = http.Request('GET', uri)
    ..followRedirects = false
    ..headers['authorization'] = 'Bearer $accessToken'
    ..headers['accept'] = 'application/json';
  final response = await httpClient.send(request).timeout(timeout);
  final body = BytesBuilder(copy: false);
  await response.stream
      .forEach((chunk) {
        if (body.length + chunk.length > _maxEventBytes) {
          throw StateError('Event is too large');
        }
        body.add(chunk);
      })
      .timeout(timeout);
  if (response.statusCode != 200) {
    throw StateError('Event unavailable (${response.statusCode})');
  }
  final json = jsonDecode(utf8.decode(body.takeBytes()));
  if (json is! Map ||
      json['event_id'] != eventId ||
      (json['room_id'] != null && json['room_id'] != roomId)) {
    throw StateError('Unexpected event');
  }
  return Map<String, Object?>.from(json)..['room_id'] = roomId;
}

/// Resolves a push without a running main isolate.
class BackgroundPushResolver {
  BackgroundPushResolver({
    required this.binding,
    required this.supportDirectory,
    required this.cacheRoot,
  });

  final PushBackgroundBinding binding;
  final String supportDirectory;
  final Directory cacheRoot;

  Future<ResolvedPushEvent?> resolve(
    PushEnvelope envelope,
    NotificationPreferences preferences,
  ) async {
    final eventId = envelope.eventId;
    if (eventId == null) throw const UndescribablePushEvent();
    final path = p.join(supportDirectory, _databaseFile);
    if (!await File(path).exists()) throw StateError('No session database');
    if (!vod.isInitialized()) await vodozemac.init();
    final lock = await BackgroundClientLock.acquire(supportDirectory);
    if (lock == null) throw StateError('Another background client is open');
    sqlite.Database? database;
    _BackgroundClient? client;
    final httpClient = http.Client();
    try {
      // Read-only and NOT the shared single instance: closing it can never
      // close a connection the main isolate is using.
      database = await sqlite.openDatabase(
        path,
        readOnly: true,
        singleInstance: false,
      );
      final store = matrix.MatrixSdkDatabase.buildWithoutOpen(
        _databaseName,
        database: database,
      );
      await store.open();
      final account = await store.getClient(_clientName);
      final homeserverUrl = account?['homeserver_url'];
      final token = account?['token'];
      final homeserver = homeserverUrl is String
          ? Uri.tryParse(homeserverUrl)
          : null;
      if (account == null ||
          account['user_id'] != binding.userId ||
          account['device_id'] != binding.deviceId ||
          token is! String ||
          token.isEmpty ||
          homeserver == null ||
          !isSecureHomeserver(homeserver)) {
        throw StateError('Stored session does not match the push binding');
      }
      client = _BackgroundClient(
        database: store,
        userId: binding.userId,
        deviceId: binding.deviceId,
        homeserver: homeserver,
        accessToken: token,
        accountData: await store.getAccountData(),
        httpClient: httpClient,
      );
      final room = await store.getSingleRoom(client, envelope.roomId);
      if (room == null) throw StateError('Room not stored yet');
      final media = preferences.showContent
          ? NotificationMediaLoader(
              httpClient: httpClient,
              homeserver: homeserver,
              accessToken: token,
              cacheRoot: cacheRoot,
            )
          : null;
      Future<void> loadMember(String userId) async {
        final user = await store.getUser(userId, room);
        if (user != null) room.setState(user);
      }

      await loadMember(binding.userId);
      if (room.membership == matrix.Membership.invite) {
        final me = room.getState(matrix.EventTypes.RoomMember, binding.userId);
        if (me != null) await loadMember(me.senderId);
        return await projectInvite(
          room: room,
          myUserId: binding.userId,
          eventId: eventId,
          media: media,
        );
      }
      final json = await fetchPushEvent(
        httpClient: httpClient,
        homeserver: homeserver,
        accessToken: token,
        roomId: envelope.roomId,
        eventId: eventId,
      );
      var event = matrix.Event.fromJson(json, room);
      if (event.type == matrix.EventTypes.Encrypted) {
        final sessionId = event.content['session_id'];
        if (sessionId is! String) throw const UndescribablePushEvent();
        // Constructing Encryption is inert (no init, no key upload); only the
        // stored inbound session is unpickled.
        final crypto = encryption.Encryption(client: client);
        await crypto.keyManager.loadInboundGroupSession(room.id, sessionId);
        event = crypto.decryptRoomEventSync(event);
        if (event.type == matrix.EventTypes.Encrypted) {
          throw const UndescribablePushEvent();
        }
      }
      if (await _alreadyRead(store, room, event)) return null;
      await loadMember(event.senderId);
      for (final hero in (room.summary.mHeroes ?? const <String>[]).take(5)) {
        await loadMember(hero);
      }
      final isDirect = client.directChats.values.any(
        (rooms) => rooms.contains(room.id),
      );
      return await projectPushEvent(
        event: event,
        room: room,
        myUserId: binding.userId,
        isDirect: isDirect,
        highlight: pushEventHighlights(client.pushruleEvaluator, event),
        media: media,
        loadMediaPreview: preferences.mediaEnabled,
      );
    } finally {
      try {
        await client?.dispose(closeDatabase: false);
      } catch (_) {
        // Best effort.
      }
      try {
        await database?.close();
      } catch (_) {
        // Best effort.
      }
      httpClient.close();
      await lock.release();
    }
  }

  /// Mirrors Client.getEventByPushNotification's read-marker check.
  Future<bool> _alreadyRead(
    matrix.DatabaseApi store,
    matrix.Room room,
    matrix.Event event,
  ) async {
    final fullyRead = room.fullyRead;
    if (fullyRead.isEmpty) return false;
    if (fullyRead == event.eventId) return true;
    try {
      final marker = await store.getEventById(fullyRead, room);
      return marker != null &&
          marker.originServerTs.isAfter(event.originServerTs);
    } catch (_) {
      return false;
    }
  }
}

// --- Entry flow ----------------------------------------------------------------

/// Injectable dependencies of the background flow (tests use fakes).
class BackgroundPushEnvironment {
  const BackgroundPushEnvironment({
    required this.handOff,
    required this.surface,
    required this.store,
    required this.resolver,
    required this.contentUriFor,
  });

  factory BackgroundPushEnvironment.production() => BackgroundPushEnvironment(
    handOff: (kind, payload) => handOffToMainIsolate(kind, payload),
    surface: () async {
      final plugin = FlutterLocalNotificationsPlugin();
      await initializePushLocalNotifications(plugin);
      return PluginNotificationSurface(plugin);
    },
    store: NotificationStore.open,
    resolver: (binding) async {
      final support = await getApplicationSupportDirectory();
      final cache = await getTemporaryDirectory();
      return BackgroundPushResolver(
        binding: binding,
        supportDirectory: support.path,
        cacheRoot: cache,
      ).resolve;
    },
    contentUriFor: () async {
      final cache = await getTemporaryDirectory();
      return (path) => notificationContentUri(path, cache.path);
    },
  );

  final Future<HandoffResult> Function(
    String kind,
    Map<String, Object?> payload,
  )
  handOff;
  final Future<NotificationSurface> Function() surface;
  final Future<NotificationStore> Function() store;
  final Future<PushEventResolver> Function(PushBackgroundBinding binding)
  resolver;
  final Future<String? Function(String path)> Function() contentUriFor;
}

/// Shows a verified push from a background isolate. [stillBound] re-reads
/// the stored binding right before anything is posted.
Future<RichPushOutcome?> handleBackgroundPushEnvelope({
  required PushBackgroundBinding binding,
  required PushEnvelope envelope,
  required Future<bool> Function() stillBound,
  BackgroundPushEnvironment? environment,
}) async {
  final env = environment ?? BackgroundPushEnvironment.production();
  final handoff = await env.handOff(handoffKindPush, envelope.toJson());
  if (handoff != HandoffResult.unavailable) return null;
  final surface = await env.surface();
  NotificationStore? store;
  try {
    store = await env.store();
  } catch (_) {
    store = null;
  }
  String? Function(String)? contentUriFor;
  try {
    contentUriFor = await env.contentUriFor();
  } catch (_) {
    contentUriFor = null;
  }
  PushEventResolver resolve;
  try {
    resolve = await env.resolver(binding);
  } catch (_) {
    resolve = (_, _) => Future.error(StateError('No background client'));
  }
  final handler = RichPushHandler(
    store: store,
    surface: surface,
    resolve: resolve,
    userId: binding.userId,
    deviceId: binding.deviceId,
    contentUriFor: contentUriFor,
    resolveTimeout: backgroundResolveTimeout,
    confirm: stillBound,
  );
  return handler.handle(envelope);
}

// --- Notification actions ----------------------------------------------------

Future<void> _copyNotificationValue(String value) =>
    Clipboard.setData(ClipboardData(text: value));

/// flutter_local_notifications runs actions that do not open the app here, in
/// a background isolate. Copy actions use the platform clipboard directly.
/// Inline replies are handed to the main isolate, which sends them through the
/// guarded send path. With no main isolate a reply is kept privately and sent
/// when Parallax is next opened; it is never sent from a background isolate.
@pragma('vm:entry-point')
Future<void> parallaxNotificationActionBackground(
  NotificationResponse response,
) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    await handleBackgroundNotificationAction(response);
  } catch (_) {
    // Never log payloads or message text.
  }
}

/// Testable body of [parallaxNotificationActionBackground].
Future<void> handleBackgroundNotificationAction(
  NotificationResponse response, {
  BackgroundPushEnvironment? environment,
  PushStateStore bindingStore = const SecurePushStateStore(),
  DateTime Function() clock = DateTime.now,
  Future<void> Function(String)? clipboardWriter,
}) async {
  final copyKind = switch (response.actionId) {
    pushCopyCodeActionId => MessageCopyKind.oneTimeCode,
    pushCopyPhoneActionId => MessageCopyKind.phoneNumber,
    _ => null,
  };
  if (copyKind != null) {
    final data = decodeNotificationPayload(response.payload);
    final value = data?['copy_value'];
    if (value is! String || !validMessageCopyValue(copyKind, value)) return;
    await (clipboardWriter ?? _copyNotificationValue)(value);
    return;
  }
  if (response.actionId != pushReplyActionId) return;
  final data = decodeNotificationPayload(response.payload);
  final text = response.input?.trim();
  if (data == null ||
      text == null ||
      text.isEmpty ||
      text.length > PendingReply.maxLength) {
    return;
  }
  final roomId = data['room_id'];
  final registrationId = data['registration_id'];
  if (roomId is! String || registrationId is! String) return;
  final env = environment ?? BackgroundPushEnvironment.production();
  final handoff = await env.handOff(handoffKindReply, {...data, 'text': text});
  if (handoff == HandoffResult.accepted) return;

  final binding = PushBackgroundBinding.parse(await bindingStore.read());
  final surface = await env.surface();
  NotificationStore? store;
  try {
    store = await env.store();
  } catch (_) {
    store = null;
  }
  final handler = RichPushHandler(
    store: store,
    surface: surface,
    resolve: (_, _) => Future.value(),
    userId: binding?.userId ?? '',
    deviceId: binding?.deviceId ?? '',
  );
  final eventId = data['event_id'];
  if (handoff == HandoffResult.rejected ||
      binding == null ||
      binding.registrationId != registrationId ||
      store == null) {
    await handler.showReplyResult(
      roomId,
      text,
      registrationId: registrationId,
      appendReply: false,
      statusLine: quickReplyFailedLine,
    );
    return;
  }
  await store.addPendingReply(
    PendingReply(
      userId: binding.userId,
      deviceId: binding.deviceId,
      roomId: roomId,
      eventId: eventId is String ? eventId : null,
      text: text,
      createdAt: clock(),
    ),
  );
  await handler.showReplyResult(
    roomId,
    text,
    registrationId: registrationId,
    statusLine: quickReplyPendingLine,
  );
}
