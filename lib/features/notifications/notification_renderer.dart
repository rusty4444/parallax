// Builds Android notifications like Element X's NotificationCreator: one
// MessagingStyle conversation notification per room (sender Person with
// avatar, room title for groups, image previews via content URIs), grouped
// under a summary, plus call and invite notifications.
//
// Rendering is pure (testable); NotificationSurface performs the plugin I/O.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../message_copy_targets.dart';
import '../../push_notifications.dart';
import '../chat_lock/chat_lock_store.dart';
import 'notification_model.dart';

/// Notification group for message notifications (Element X: one group per
/// account with a summary).
const notificationGroupKey = 'net.samrussell.parallax.messages';

/// Summary notification ID (the generic notification uses 1001).
const notificationSummaryId = 1000;

/// Channel shared with the generic notification.
const messageChannelId = 'parallax_messages_v1';
const messageChannelName = 'Messages';

/// High-importance channel for ringing calls.
const callChannelId = 'parallax_calls_v1';
const callChannelName = 'Calls';

const _accent = Color(0xFFFF5A36);

/// Darwin (iOS/macOS) notification categories. iOS categories are registered
/// once at plugin initialisation, so the copy variants are separate
/// categories picked per notification (Android adds the action inline).
const darwinMessageCategory = 'parallax.message';
const darwinCopyCodeCategory = 'parallax.message.copy_code';
const darwinCopyPhoneCategory = 'parallax.message.copy_phone';
const darwinCallCategory = 'parallax.call';
const darwinInviteCategory = 'parallax.invite';
const darwinGenericMarkReadCategory = 'parallax.generic.mark_read';

final _darwinReplyAction = DarwinNotificationAction.text(
  pushReplyActionId,
  'Reply',
  buttonTitle: 'Send',
  placeholder: 'Message',
);

final _darwinMarkReadAction = DarwinNotificationAction.plain(
  pushMarkReadActionId,
  'Mark as read',
  options: {DarwinNotificationActionOption.foreground},
);

/// Register in [DarwinInitializationSettings.notificationCategories].
final darwinNotificationCategories = <DarwinNotificationCategory>[
  DarwinNotificationCategory(
    darwinMessageCategory,
    actions: [_darwinReplyAction, _darwinMarkReadAction],
    options: {DarwinNotificationCategoryOption.hiddenPreviewShowTitle},
  ),
  DarwinNotificationCategory(
    darwinCopyCodeCategory,
    actions: [
      DarwinNotificationAction.plain(pushCopyCodeActionId, 'Copy code'),
      _darwinReplyAction,
      _darwinMarkReadAction,
    ],
    options: {DarwinNotificationCategoryOption.hiddenPreviewShowTitle},
  ),
  DarwinNotificationCategory(
    darwinCopyPhoneCategory,
    actions: [
      DarwinNotificationAction.plain(pushCopyPhoneActionId, 'Copy number'),
      _darwinReplyAction,
      _darwinMarkReadAction,
    ],
    options: {DarwinNotificationCategoryOption.hiddenPreviewShowTitle},
  ),
  DarwinNotificationCategory(darwinCallCategory),
  DarwinNotificationCategory(darwinInviteCategory),
  DarwinNotificationCategory(
    darwinGenericMarkReadCategory,
    actions: [_darwinMarkReadAction],
  ),
];

int _fnv(String value) {
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(value)) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// Stable notification ID for a room's conversation notification.
int roomNotificationId(String roomId) =>
    0x10000000 | (_fnv(roomId) & 0x0fffffff);

/// Stable notification ID for a room's ringing call.
int callNotificationId(String roomId) =>
    0x20000000 | (_fnv('call:$roomId') & 0x0fffffff);

/// Stable notification ID for an invitation to a room.
int inviteNotificationId(String roomId) =>
    0x30000000 | (_fnv('invite:$roomId') & 0x0fffffff);

/// A notification ready to be posted.
@immutable
class RenderedNotification {
  const RenderedNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.details,
    this.payload,
  });
  final int id;
  final String? title;
  final String? body;
  final NotificationDetails details;
  final String? payload;
}

/// Where notifications are posted (the plugin in production, fakes in tests).
abstract interface class NotificationSurface {
  Future<void> show(RenderedNotification notification);
  Future<void> cancel(int id);
  Future<void> showGeneric(PushEnvelope envelope);

  /// Removes every notification Parallax has posted.
  Future<void> cancelAll();
}

/// flutter_local_notifications. The plugin must already be initialised in
/// this isolate (drivers do this on enable; background entries call
/// [initializePushLocalNotifications]).
class PluginNotificationSurface implements NotificationSurface {
  PluginNotificationSurface([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();
  final FlutterLocalNotificationsPlugin _plugin;

  @override
  Future<void> show(RenderedNotification notification) => _plugin.show(
    id: notification.id,
    title: notification.title,
    body: notification.body,
    notificationDetails: notification.details,
    payload: notification.payload,
  );

  @override
  Future<void> cancel(int id) => _plugin.cancel(id: id);

  @override
  Future<void> cancelAll() => _plugin.cancelAll();

  @override
  Future<void> showGeneric(PushEnvelope envelope) =>
      showGenericPushNotification(_plugin, envelope);
}

/// Routing data in a rich notification's private payload. The registration
/// nonce lets taps and "Mark as read" be verified exactly like the generic
/// notification. A copy action also carries its exact target, already visible
/// in the notification; the full message body is not added to the payload.
/// Nothing here is logged.
///
/// The account and device let a quick reply typed on an older notification
/// be matched to the signed-in session after push was re-registered.
Map<String, Object?> notificationPayload({
  required String registrationId,
  required String roomId,
  String? eventId,
  String? userId,
  String? deviceId,
  String? copyValue,
}) => {
  'registration_id': registrationId,
  'room_id': roomId,
  'event_id': ?eventId,
  'user_id': ?userId,
  'device_id': ?deviceId,
  'copy_value': ?copyValue,
};

AndroidBitmap<Object>? _bitmap(String? path) =>
    path == null ? null : FilePathAndroidBitmap(path);

AndroidIcon<Object>? _icon(String? path) =>
    path == null ? null : BitmapFilePathAndroidIcon(path);

/// Existing-file check, injectable for tests.
typedef FileExists = bool Function(String path);

bool _fileExists(String path) {
  try {
    return File(path).existsSync();
  } catch (_) {
    return false;
  }
}

/// Windows toast for a room's conversation: the newest message with a reply
/// box, plus the same copy and Mark as read actions as Android. Windows hands
/// a button press only that button's arguments, so each one carries the
/// toast's routing [payload] (see [windowsActionArguments]).
@visibleForTesting
WindowsNotificationDetails windowsRoomDetails({
  required String payload,
  required bool alert,
  bool reply = true,
  bool canMarkRead = false,
  MessageCopyTarget? copyTarget,
  String? avatarPath,
  String? imagePath,
  DateTime? timestamp,
  FileExists fileExists = _fileExists,
}) => WindowsNotificationDetails(
  inputs: [
    if (reply)
      const WindowsTextInput(
        id: windowsReplyInputId,
        placeHolderContent: 'Message',
      ),
  ],
  actions: [
    if (reply)
      WindowsAction(
        content: 'Reply',
        arguments: windowsActionArguments(pushReplyActionId, payload),
        inputId: windowsReplyInputId,
      ),
    if (copyTarget != null)
      WindowsAction(
        content: copyTarget.label,
        arguments: windowsActionArguments(
          copyTarget.kind == MessageCopyKind.oneTimeCode
              ? pushCopyCodeActionId
              : pushCopyPhoneActionId,
          payload,
        ),
      ),
    if (canMarkRead)
      WindowsAction(
        content: 'Mark as read',
        arguments: windowsActionArguments(pushMarkReadActionId, payload),
      ),
  ],
  images: [
    if (avatarPath != null && fileExists(avatarPath))
      WindowsImage(
        Uri.file(avatarPath, windows: true),
        altText: '',
        placement: WindowsImagePlacement.appLogoOverride,
        crop: WindowsImageCrop.circle,
      ),
    if (imagePath != null && fileExists(imagePath))
      WindowsImage(Uri.file(imagePath, windows: true), altText: ''),
  ],
  audio: alert ? null : WindowsNotificationAudio.silent(),
  timestamp: timestamp,
);

List<AndroidNotificationAction> _roomActions({
  required bool canMarkRead,
  MessageCopyTarget? copyTarget,
}) => [
  const AndroidNotificationAction(
    pushReplyActionId,
    'Reply',
    inputs: [AndroidNotificationActionInput(label: 'Message')],
    showsUserInterface: false,
    cancelNotification: false,
    allowGeneratedReplies: true,
    semanticAction: SemanticAction.reply,
  ),
  if (copyTarget != null)
    AndroidNotificationAction(
      copyTarget.kind == MessageCopyKind.oneTimeCode
          ? pushCopyCodeActionId
          : pushCopyPhoneActionId,
      copyTarget.label,
      showsUserInterface: false,
      cancelNotification: false,
    ),
  // Runs in the background (Android Auto rejects a Mark as read that opens
  // the app): the action isolate hands it to the running client, or keeps
  // it until Parallax runs (handleBackgroundNotificationAction).
  if (canMarkRead)
    const AndroidNotificationAction(
      pushMarkReadActionId,
      'Mark as read',
      showsUserInterface: false,
      cancelNotification: true,
      semanticAction: SemanticAction.markAsRead,
    ),
];

/// Renders a room's conversation notification from its accumulated lines.
///
/// [contentUriFor] maps a preview file to the `content://` URI Android reads
/// (null when previews are off). [alert] is false when the update must not
/// buzz again (for example after a quick reply). [carProjecting] keeps every
/// message in MessagingStyle, the only style Android Auto reads aloud.
RenderedNotification renderRoomThread(
  RoomNotificationThread thread, {
  required String myUserId,
  required String registrationId,
  String? myDeviceId,
  String? Function(String path)? contentUriFor,
  bool alert = true,
  String? statusLine,
  bool carProjecting = false,
  FileExists fileExists = _fileExists,
}) {
  // Locked chats never reveal sender, body or media in a notification.
  if (ChatLockStore.shared.isLocked(thread.roomId)) {
    return RenderedNotification(
      id: roomNotificationId(thread.roomId),
      title: thread.roomName,
      body: 'Locked chat',
      details: NotificationDetails(
        windows: WindowsNotificationDetails(
          audio: alert ? null : WindowsNotificationAudio.silent(),
        ),
        android: AndroidNotificationDetails(
          messageChannelId,
          messageChannelName,
          channelDescription: 'Messages and mentions',
          importance: Importance.high,
          priority: Priority.high,
          visibility: NotificationVisibility.secret,
          category: AndroidNotificationCategory.message,
          color: _accent,
          groupKey: notificationGroupKey,
          onlyAlertOnce: !alert,
          silent: !alert,
        ),
        iOS: DarwinNotificationDetails(
          threadIdentifier: thread.roomId,
          presentSound: alert,
        ),
        macOS: DarwinNotificationDetails(
          threadIdentifier: thread.roomId,
          presentSound: alert,
        ),
      ),
      payload: jsonEncode(
        notificationPayload(
          registrationId: registrationId,
          roomId: thread.roomId,
          eventId: thread.latestEventId,
          userId: myUserId,
          deviceId: myDeviceId,
        ),
      ),
    );
  }
  final me = Person(name: 'Me', key: myUserId);
  final people = <String, Person>{};
  Person personFor(NotificationLine line) => line.fromMe
      ? me
      : people.putIfAbsent(
          line.senderId,
          () => Person(
            name: line.senderName,
            key: line.senderId,
            icon:
                line.senderAvatarPath != null &&
                    fileExists(line.senderAvatarPath!)
                ? _icon(line.senderAvatarPath)
                : null,
          ),
        );
  final messages = <Message>[
    for (final line in thread.lines)
      _message(line, personFor(line), contentUriFor, fileExists),
    if (statusLine != null) Message(statusLine, DateTime.now(), me),
  ];
  final latest = thread.lines.last;
  final copyTarget = statusLine == null ? messageCopyTarget(latest.text) : null;
  final highlight = thread.lines.any((line) => line.highlight && !line.fromMe);
  final roomAvatar = thread.roomAvatarPath ?? latest.senderAvatarPath;
  final largeAvatarExists = roomAvatar != null && fileExists(roomAvatar);
  // Android hides largeIcon on a collapsed MessagingStyle notification. For a
  // single text-only group message with avatar art, BigTextStyle keeps the
  // collapsed row's avatar visible. Media previews, direct chats and
  // multi-message threads retain MessagingStyle so inline/animated media
  // and sender Person icons render. Android Auto ignores BigTextStyle, so
  // while the phone is connected to a car every room uses MessagingStyle.
  final hasMediaPreview = messages.any((message) => message.dataUri != null);
  final singleGroupWithAvatar =
      !carProjecting &&
      !thread.isDirect &&
      thread.lines.length == 1 &&
      statusLine == null &&
      largeAvatarExists &&
      !hasMediaPreview;
  final StyleInformation style = singleGroupWithAvatar
      ? BigTextStyleInformation(
          latest.fromMe ? latest.text : '${latest.senderName}: ${latest.text}',
          contentTitle: thread.roomName,
        )
      : MessagingStyleInformation(
          me,
          conversationTitle: thread.isDirect ? null : thread.roomName,
          groupConversation: !thread.isDirect,
          messages: messages,
        );
  final details = AndroidNotificationDetails(
    messageChannelId,
    messageChannelName,
    channelDescription: 'Messages and mentions',
    importance: Importance.high,
    priority: highlight ? Priority.max : Priority.high,
    visibility: NotificationVisibility.private,
    category: AndroidNotificationCategory.message,
    color: _accent,
    styleInformation: style,
    groupKey: notificationGroupKey,
    onlyAlertOnce: !alert,
    silent: !alert,
    when: latest.timestamp.millisecondsSinceEpoch,
    // MessagingStyle already places the sender Person icon beside their name.
    // A second large bitmap on a direct notification can instead be rendered
    // beside the message body (the misplaced avatar in the screenshot). Keep
    // direct avatars on Person only. Group notifications still need a large
    // icon for their collapsed row; use room art, or the latest sender when a
    // bridged group has no room-level avatar of its own.
    largeIcon: !thread.isDirect && largeAvatarExists
        ? _bitmap(roomAvatar)
        : null,
    actions: _roomActions(
      canMarkRead: thread.latestEventId != null,
      copyTarget: copyTarget,
    ),
  );
  final darwinCategory = copyTarget == null
      ? darwinMessageCategory
      : copyTarget.kind == MessageCopyKind.oneTimeCode
      ? darwinCopyCodeCategory
      : darwinCopyPhoneCategory;
  final previewImage = latest.imagePath;
  final darwin = DarwinNotificationDetails(
    threadIdentifier: thread.roomId,
    categoryIdentifier: darwinCategory,
    interruptionLevel: highlight
        ? InterruptionLevel.timeSensitive
        : InterruptionLevel.active,
    presentSound: alert,
    attachments: [
      if (previewImage != null && fileExists(previewImage))
        DarwinNotificationAttachment(previewImage),
    ],
  );
  final payload = jsonEncode(
    notificationPayload(
      registrationId: registrationId,
      roomId: thread.roomId,
      eventId: thread.latestEventId,
      userId: myUserId,
      deviceId: myDeviceId,
      copyValue: copyTarget?.value,
    ),
  );
  final windows = windowsRoomDetails(
    payload: payload,
    alert: alert,
    canMarkRead: thread.latestEventId != null,
    copyTarget: copyTarget,
    avatarPath: thread.isDirect ? latest.senderAvatarPath : roomAvatar,
    imagePath: previewImage,
    timestamp: latest.timestamp,
    fileExists: fileExists,
  );
  return RenderedNotification(
    id: roomNotificationId(thread.roomId),
    title: thread.isDirect ? latest.senderName : thread.roomName,
    body: latest.fromMe ? latest.text : '${latest.senderName}: ${latest.text}',
    details: NotificationDetails(
      android: details,
      iOS: darwin,
      macOS: darwin,
      windows: windows,
    ),
    payload: payload,
  );
}

Message _message(
  NotificationLine line,
  Person person,
  String? Function(String path)? contentUriFor,
  FileExists fileExists,
) {
  // Highlights raise priority only. Keep the complete message visible rather
  // than spending its limited notification space on a "Mentioned you" label.
  final text = line.text;
  final image = line.imagePath;
  final uri = image != null && contentUriFor != null && fileExists(image)
      ? contentUriFor(image)
      : null;
  return uri == null
      ? Message(text, line.timestamp, person)
      : Message(
          text,
          line.timestamp,
          person,
          dataMimeType: notificationPreviewMimeType(image!),
          dataUri: uri,
        );
}

/// MIME type reported to Android `MessagingStyle.Message.setData` for a cached
/// preview file.
String notificationPreviewMimeType(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.png')) return 'image/png';
  return 'image/jpeg';
}

/// A quick-reply status for a room without notification history.
RenderedNotification renderReplyStatus(
  String roomId,
  String status, {
  required String registrationId,
}) => RenderedNotification(
  id: roomNotificationId(roomId),
  title: 'Quick reply',
  body: status,
  details: NotificationDetails(
    windows: WindowsNotificationDetails(
      audio: WindowsNotificationAudio.silent(),
    ),
    android: const AndroidNotificationDetails(
      messageChannelId,
      messageChannelName,
      channelDescription: 'Messages and mentions',
      importance: Importance.high,
      priority: Priority.high,
      visibility: NotificationVisibility.private,
      category: AndroidNotificationCategory.message,
      color: _accent,
      onlyAlertOnce: true,
      silent: true,
    ),
    iOS: const DarwinNotificationDetails(
      categoryIdentifier: darwinMessageCategory,
      presentSound: false,
    ),
    macOS: const DarwinNotificationDetails(
      categoryIdentifier: darwinMessageCategory,
      presentSound: false,
    ),
  ),
  payload: jsonEncode(
    notificationPayload(registrationId: registrationId, roomId: roomId),
  ),
);

/// The group summary (shown on older Android versions and when collapsed).
RenderedNotification renderSummary(
  List<RoomNotificationThread> threads, {
  FileExists fileExists = _fileExists,
}) {
  final count = threads.fold<int>(0, (sum, t) => sum + t.lines.length);
  final title = count == 1 ? '1 notification' : '$count notifications';
  final lines = [
    for (final thread in threads.take(6))
      '${thread.roomName}: ${thread.lines.last.text}',
  ];
  final latestThread = threads.isEmpty
      ? null
      : threads.reduce((a, b) => a.updatedAt.isAfter(b.updatedAt) ? a : b);
  final avatar = latestThread == null
      ? null
      : latestThread.roomAvatarPath ?? latestThread.lines.last.senderAvatarPath;
  return RenderedNotification(
    id: notificationSummaryId,
    title: title,
    body: threads.map((t) => t.roomName).take(4).join(', '),
    details: NotificationDetails(
      windows: WindowsNotificationDetails(
        audio: WindowsNotificationAudio.silent(),
      ),
      android: AndroidNotificationDetails(
        messageChannelId,
        messageChannelName,
        channelDescription: 'Messages and mentions',
        importance: Importance.high,
        priority: Priority.high,
        visibility: NotificationVisibility.private,
        category: AndroidNotificationCategory.message,
        color: _accent,
        largeIcon: avatar != null && fileExists(avatar)
            ? _bitmap(avatar)
            : null,
        groupKey: notificationGroupKey,
        setAsGroupSummary: true,
        groupAlertBehavior: GroupAlertBehavior.children,
        onlyAlertOnce: true,
        silent: true,
        styleInformation: InboxStyleInformation(
          lines,
          contentTitle: title,
          summaryText: 'Parallax',
        ),
      ),
      iOS: const DarwinNotificationDetails(
        threadIdentifier: 'parallax.summary',
        presentSound: false,
      ),
      macOS: const DarwinNotificationDetails(
        threadIdentifier: 'parallax.summary',
        presentSound: false,
      ),
    ),
  );
}

/// A ringing call: high priority, call category, opens the room on tap.
RenderedNotification renderCall(
  ResolvedPushEvent event, {
  required String registrationId,
}) => RenderedNotification(
  id: callNotificationId(event.roomId),
  title: event.isDirect ? event.line.senderName : event.roomName,
  body: event.isDirect
      ? event.line.text
      : '${event.line.senderName}: ${event.line.text}',
  details: NotificationDetails(
    windows: const WindowsNotificationDetails(
      duration: WindowsNotificationDuration.long,
    ),
    android: AndroidNotificationDetails(
      callChannelId,
      callChannelName,
      channelDescription: 'Incoming calls',
      importance: Importance.max,
      priority: Priority.max,
      visibility: NotificationVisibility.private,
      category: AndroidNotificationCategory.call,
      color: _accent,
      timeoutAfter: 90 * 1000,
      largeIcon: _bitmap(event.line.senderAvatarPath),
      audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
    ),
    iOS: const DarwinNotificationDetails(
      categoryIdentifier: darwinCallCategory,
      interruptionLevel: InterruptionLevel.timeSensitive,
    ),
    macOS: const DarwinNotificationDetails(
      categoryIdentifier: darwinCallCategory,
      interruptionLevel: InterruptionLevel.timeSensitive,
    ),
  ),
  payload: jsonEncode(
    notificationPayload(registrationId: registrationId, roomId: event.roomId),
  ),
);

/// "Name invited you to Room": opens Parallax on tap.
RenderedNotification renderInvite(
  ResolvedPushEvent event, {
  required String registrationId,
}) => RenderedNotification(
  id: inviteNotificationId(event.roomId),
  title: event.isDirect ? event.line.senderName : event.roomName,
  body: event.line.text,
  details: NotificationDetails(
    windows: const WindowsNotificationDetails(),
    android: AndroidNotificationDetails(
      messageChannelId,
      messageChannelName,
      channelDescription: 'Messages and mentions',
      importance: Importance.high,
      priority: Priority.high,
      visibility: NotificationVisibility.private,
      category: AndroidNotificationCategory.social,
      color: _accent,
      largeIcon: _bitmap(event.line.senderAvatarPath ?? event.roomAvatarPath),
    ),
    iOS: const DarwinNotificationDetails(
      categoryIdentifier: darwinInviteCategory,
    ),
    macOS: const DarwinNotificationDetails(
      categoryIdentifier: darwinInviteCategory,
    ),
  ),
  payload: jsonEncode(
    notificationPayload(registrationId: registrationId, roomId: event.roomId),
  ),
);
