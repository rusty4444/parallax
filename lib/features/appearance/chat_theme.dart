import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Color;
import 'package:matrix/matrix.dart' as matrix;
import 'package:shared_preferences/shared_preferences.dart';

import '../../room_background_store.dart';
import '../../room_events.dart';
import '../../timeline_kinds.dart' show chatThemeEventType;
import '../media/image_optimiser.dart' show ImagePreparer;
import 'bubble_colours.dart';
import 'theme_pictures.dart';

/// Kinds of chat theme change, for the timeline notice.
abstract final class ChatThemeChange {
  static const colours = 'colours';
  static const background = 'background';
  static const theme = 'theme';
  static const reset = 'reset';
}

/// "Sam changed the chat colours" / "You removed the chat theme". [sender]
/// is null when it was you.
String describeChatThemeChange(Object? change, {String? sender}) {
  final who = sender ?? 'You';
  if (change == ChatThemeChange.reset) return '$who removed the chat theme';
  final what = switch (change) {
    ChatThemeChange.colours => 'the chat colours',
    ChatThemeChange.background => 'the chat background',
    _ => 'the chat theme',
  };
  return '$who changed $what';
}

/// The bubble colours and background a Parallax user set for everyone in a
/// room: the newest `net.samrusselltech.parallax.chat_theme` event. In an
/// encrypted room the event, and so the background's key, is end-to-end
/// encrypted. Each event relates (`m.relates_to`, rel_type = the event type)
/// to the room's create event, so the newest can be found with the
/// relations API without scanning history.
@immutable
class ChatTheme {
  const ChatTheme({
    required this.eventId,
    required this.time,
    required this.sender,
    required this.change,
    required this.colours,
    this.background,
  });

  final String eventId;

  /// Server timestamp, ms since epoch.
  final int time;
  final String sender;
  final String change;
  final BubbleColours colours;

  /// `{file, info}`: the encrypted picture; null for no background.
  final Map<String, Object?>? background;

  bool get isEmpty => colours.isEmpty && background == null;

  /// `mxc://` address of the background, which identifies the picture.
  String? get backgroundUrl {
    final file = background?['file'];
    final url = file is Map ? file['url'] : null;
    return url is String ? url : null;
  }

  /// Newer than [other] (server time, then event ID).
  bool isNewerThan(ChatTheme? other) =>
      other == null ||
      time > other.time ||
      (time == other.time && eventId.compareTo(other.eventId) > 0);

  /// Reads an event's content; null when it is not a usable theme.
  static ChatTheme? fromContent({
    required String eventId,
    required int time,
    required String sender,
    required Map<String, Object?> content,
  }) {
    if (eventId.isEmpty) return null;
    final change = content['change'];
    final background = content['background'];
    Map<String, Object?>? picture;
    if (background is Map) {
      final file = background['file'];
      final info = background['info'];
      if (file is Map) {
        picture = {
          'file': Map<String, Object?>.from(file),
          if (info is Map) 'info': Map<String, Object?>.from(info),
        };
      }
    }
    return ChatTheme(
      eventId: eventId,
      time: time,
      sender: sender,
      change: change is String ? change : ChatThemeChange.theme,
      colours: sharedColours(BubbleColours.fromJson(content['bubbleColours'])),
      background: picture,
    );
  }

  static ChatTheme? fromEvent(matrix.Event event) {
    if (event.type != chatThemeEventType || event.redacted) return null;
    return fromContent(
      eventId: event.eventId,
      time: event.originServerTs.millisecondsSinceEpoch,
      sender: event.senderId,
      content: event.content,
    );
  }

  Map<String, Object?> toJson() => {
    'eventId': eventId,
    'time': time,
    'sender': sender,
    'change': change,
    'bubbleColours': colours.toJson(),
    'background': ?background,
  };

  static ChatTheme? fromJson(Object? json) {
    if (json is! Map) return null;
    final eventId = json['eventId'], time = json['time'];
    final sender = json['sender'];
    if (eventId is! String || time is! int || sender is! String) return null;
    return fromContent(
      eventId: eventId,
      time: time,
      sender: sender,
      content: Map<String, Object?>.from(json),
    );
  }
}

/// Colours someone else chose can't be trusted to be readable: a text colour
/// is kept only with its bubble colour and at 4.5:1 contrast; otherwise the
/// text colour is picked automatically.
BubbleColours sharedColours(BubbleColours colours) {
  Color? ink(Color? bubble, Color? text) =>
      bubble != null && text != null && contrastRatio(bubble, text) >= 4.5
      ? text
      : null;
  return BubbleColours(
    mine: colours.mine,
    mineText: ink(colours.mine, colours.mineText),
    theirs: colours.theirs,
    theirsText: ink(colours.theirs, colours.theirsText),
  );
}

/// The ID of [room]'s create event, which every chat theme event relates
/// to. Room version 12 IDs are the create event's hash (`!x` → `$x`).
String? createEventId(matrix.Room room) {
  final create = room.getState(matrix.EventTypes.RoomCreate);
  if (create is matrix.Event && create.eventId.startsWith(r'$')) {
    return create.eventId;
  }
  final id = room.id;
  return id.startsWith('!') && !id.contains(':') && id.length > 1
      ? r'$' + id.substring(1)
      : null;
}

/// Each room's current chat theme on this device, and its background
/// picture once downloaded.
class ChatThemeStore extends ChangeNotifier {
  ChatThemeStore({
    SharedPreferences? preferences,
    RoomBackgroundStore? pictures,
  }) : _prefs = preferences,
       pictures =
           pictures ?? RoomBackgroundStore(folder: 'chat_theme_backgrounds');

  final RoomBackgroundStore pictures;
  SharedPreferences? _prefs;
  final _themes = <String, ChatTheme?>{};
  final _pictureUrls = <String, String?>{};

  static String keyFor(String roomId) =>
      'parallax.chat_theme.v1.${sha256.convert(utf8.encode(roomId))}';

  Future<SharedPreferences> _preferences() async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// Already loaded theme (no I/O); null when none or not loaded.
  ChatTheme? cached(String roomId) => _themes[roomId];

  Future<ChatTheme?> load(String roomId) async {
    if (_themes.containsKey(roomId)) return _themes[roomId];
    ChatTheme? theme;
    String? pictureUrl;
    try {
      final raw = (await _preferences()).getString(keyFor(roomId));
      if (raw != null) {
        final json = jsonDecode(raw);
        theme = ChatTheme.fromJson(json is Map ? json['theme'] : null);
        final url = json is Map ? json['pictureUrl'] : null;
        pictureUrl = url is String ? url : null;
      }
    } catch (_) {
      // Unreadable: no theme until the next lookup.
    }
    if (_themes.containsKey(roomId)) return _themes[roomId];
    _pictureUrls[roomId] = pictureUrl;
    return _themes[roomId] = theme;
  }

  /// Keeps [theme] when it is newer than [roomId]'s current one. True when
  /// it replaced it.
  Future<bool> offer(String roomId, ChatTheme theme) async {
    final current = await load(roomId);
    if (!theme.isNewerThan(current)) return false;
    _themes[roomId] = theme;
    await _save(roomId);
    notifyListeners();
    return true;
  }

  /// The downloaded background of [roomId]'s current theme, or null (no
  /// background, or not downloaded yet).
  Future<File?> pictureFile(String roomId) async {
    final theme = await load(roomId);
    final url = theme?.backgroundUrl;
    if (url == null || _pictureUrls[roomId] != url) return null;
    return pictures.fileFor(roomId);
  }

  /// Whether [roomId]'s current background still has to be downloaded.
  Future<bool> needsPicture(String roomId) async {
    final url = (await load(roomId))?.backgroundUrl;
    if (url == null) return false;
    return _pictureUrls[roomId] != url ||
        await pictures.fileFor(roomId) == null;
  }

  /// Stores the picture for the background at [url].
  Future<void> storePicture(String roomId, String url, Uint8List bytes) async {
    await load(roomId);
    await pictures.replaceBytes(roomId, bytes);
    _pictureUrls[roomId] = url;
    await _save(roomId);
    notifyListeners();
  }

  Future<void> _save(String roomId) async {
    final prefs = await _preferences();
    final saved = await prefs.setString(
      keyFor(roomId),
      jsonEncode({
        'theme': _themes[roomId]?.toJson(),
        'pictureUrl': _pictureUrls[roomId],
      }),
    );
    if (!saved) throw StateError('Could not save the chat theme');
  }

  @visibleForTesting
  void clearMemory() {
    _themes.clear();
    _pictureUrls.clear();
  }
}

/// Follows, looks up and sends chat themes for one signed-in backend.
class ChatThemeSync {
  ChatThemeSync(
    Object backend, {
    ChatThemeStore? store,
    int Function()? now,
    ImagePreparer? prepareImage,
    MxcDownloader? download,
    FileEncrypter? encrypt,
    FileDecrypter? decrypt,
  }) : _access = backend is MatrixSdkAccess ? backend : null,
       _events = backend is RoomEventFeatures ? backend : null,
       store = store ?? ChatThemeStore(),
       _now = now ?? _wallClock,
       _pictures = ThemePictures(
         prepareImage: prepareImage,
         download: download,
         encrypt: encrypt,
         decrypt: decrypt,
       );

  static final _byBackend = Expando<ChatThemeSync>('ChatThemeSync');

  /// The one instance for [backend] (shared by the app and every room).
  static ChatThemeSync of(Object backend) =>
      _byBackend[backend] ??= ChatThemeSync(backend);

  /// Server-side push rule that keeps chat theme events from notifying or
  /// counting as unread (the relation is readable in encrypted rooms).
  static const pushRuleId = 'net.samrusselltech.parallax.chat_theme';

  final MatrixSdkAccess? _access;
  final RoomEventFeatures? _events;
  final ChatThemeStore store;
  final int Function() _now;
  final ThemePictures _pictures;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  matrix.Client? _attached;
  StreamSubscription<matrix.Event>? _timeline, _history;
  final _lookedUp = <String>{};
  final _downloading = <String, Future<void>>{};
  bool _pushRuleChecked = false;

  /// Whether this backend can send chat themes.
  bool get canShare => _client != null && _events != null;

  matrix.Client? get _client {
    final client = _access?.sdkClient;
    return client == null || client.userID == null ? null : client;
  }

  bool _current(matrix.Client client) =>
      _access?.isSessionCurrent(client) ?? false;

  /// Follows chat themes arriving through sync for the current session.
  /// Cheap to call repeatedly.
  void attach() {
    final client = _client;
    if (identical(client, _attached)) return;
    unawaited(_timeline?.cancel());
    unawaited(_history?.cancel());
    _timeline = _history = null;
    _lookedUp.clear();
    _pushRuleChecked = false;
    _attached = client;
    if (client == null) return;
    _timeline = client.onTimelineEvent.stream.listen(_received);
    _history = client.onHistoryEvent.stream.listen(_received);
  }

  void _received(matrix.Event event) {
    if (event.type != chatThemeEventType) return;
    final theme = ChatTheme.fromEvent(event);
    if (theme == null) return;
    unawaited(_take(event.room.id, theme).catchError((Object _) {}));
  }

  Future<void> _take(String roomId, ChatTheme theme) async {
    if (await store.offer(roomId, theme)) await ensurePicture(roomId);
  }

  /// Looks up [roomId]'s newest chat theme on the server (once a session per
  /// room unless [force]), then makes sure its picture is here.
  Future<void> refresh(String roomId, {bool force = false}) async {
    final client = _client;
    if (client == null) return;
    await store.load(roomId);
    if (force || _lookedUp.add(roomId)) {
      try {
        await _lookUp(client, roomId);
      } catch (_) {
        _lookedUp.remove(roomId); // Offline: try again next time.
      }
    }
    await ensurePicture(roomId);
  }

  Future<void> _lookUp(matrix.Client client, String roomId) async {
    final room = client.getRoomById(roomId);
    final createId = room == null ? null : createEventId(room);
    if (room == null || createId == null) return;
    final response = await client.getRelatingEventsWithRelType(
      roomId,
      createId,
      chatThemeEventType,
      limit: 5,
      dir: matrix.Direction.b,
    );
    if (!_current(client)) return;
    // Newest first; an undecryptable newest one falls back to the next.
    for (final raw in response.chunk) {
      var event = matrix.Event.fromMatrixEvent(raw, room);
      final encryption = client.encryption;
      if (event.type == matrix.EventTypes.Encrypted && encryption != null) {
        event = await encryption.decryptRoomEvent(event);
      }
      if (!_current(client)) return;
      final theme = ChatTheme.fromEvent(event);
      if (theme != null) {
        await store.offer(roomId, theme);
        return;
      }
    }
  }

  /// Downloads the background of [roomId]'s current theme if it isn't here.
  Future<void> ensurePicture(String roomId) {
    // Block body: returning the removed future would make whenComplete
    // wait for itself.
    return _downloading[roomId] ??= _ensurePicture(roomId).whenComplete(() {
      _downloading.remove(roomId);
    });
  }

  Future<void> _ensurePicture(String roomId) async {
    final client = _client;
    if (client == null || !await store.needsPicture(roomId)) return;
    final theme = store.cached(roomId);
    final file = theme?.background?['file'];
    final url = theme?.backgroundUrl;
    if (file is! Map || url == null) return;
    final bytes = await _pictures.download(
      client,
      Map<String, Object?>.from(file),
      isCurrent: () => _current(client),
    );
    if (bytes == null || !_current(client)) return;
    // A newer theme may have arrived during the download.
    if (store.cached(roomId)?.backgroundUrl != url) return;
    await store.storePicture(roomId, url, bytes);
  }

  /// Sets [roomId]'s chat theme for everyone: new [colours] and/or a new
  /// [background] picture (the other part stays as it is), or [reset] to
  /// remove the theme. Throws when it can't be sent (no permission,
  /// offline, recipients not approved).
  Future<void> share(
    String roomId, {
    BubbleColours? colours,
    Uint8List? background,
    bool reset = false,
  }) async {
    final client = _client;
    final events = _events;
    if (client == null || events == null) {
      throw StateError('Chat themes are unavailable');
    }
    if (!reset && colours == null && background == null) {
      throw ArgumentError('Nothing to share');
    }
    final current = await store.load(roomId);
    Map<String, Object?>? picture;
    if (background != null) {
      picture = await _pictures.upload(
        client,
        background,
        isCurrent: () => _current(client),
      );
      if (picture == null) throw StateError('Session changed');
    }
    final change = reset
        ? ChatThemeChange.reset
        : colours != null && background != null
        ? ChatThemeChange.theme
        : colours != null
        ? ChatThemeChange.colours
        : ChatThemeChange.background;
    final room = client.getRoomById(roomId);
    final createId = room == null ? null : createEventId(room);
    final keptBackground = reset ? null : picture ?? current?.background;
    final content = <String, Object?>{
      'version': 1,
      'change': change,
      'bubbleColours': reset
          ? <String, String>{}
          : (colours ?? current?.colours ?? BubbleColours.none).toJson(),
      'background': ?keptBackground,
      if (createId != null)
        'm.relates_to': {'rel_type': chatThemeEventType, 'event_id': createId},
    };
    final eventId = await events.sendRoomEvent(
      roomId,
      chatThemeEventType,
      content,
    );
    if (!_current(client)) return;
    final sent = ChatTheme.fromContent(
      eventId: eventId,
      time: _now(),
      sender: client.userID!,
      content: content,
    );
    if (sent == null) return;
    await store.offer(roomId, sent);
    final url = sent.backgroundUrl;
    if (background != null && url != null) {
      // Show the picture here without downloading it again.
      await store.storePicture(roomId, url, background);
    }
  }

  /// Adds the push rule that keeps chat theme events from notifying, once
  /// per session. Best effort.
  Future<void> ensurePushRule() async {
    final client = _client;
    if (client == null || _pushRuleChecked) return;
    _pushRuleChecked = true;
    final existing = client.globalPushRules?.override ?? const [];
    if (existing.any((rule) => rule.ruleId == pushRuleId)) return;
    try {
      await client.setPushRule(
        matrix.PushRuleKind.override,
        pushRuleId,
        const [],
        conditions: [
          matrix.PushCondition(
            kind: 'event_match',
            key: r'content.m\.relates_to.rel_type',
            pattern: chatThemeEventType,
          ),
        ],
      );
    } catch (_) {
      _pushRuleChecked = false; // Tried again next session start.
    }
  }

  @visibleForTesting
  Future<void> detach() async {
    await _timeline?.cancel();
    await _history?.cancel();
    _timeline = _history = null;
    _attached = null;
  }
}
