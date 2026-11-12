// Account-data models for Note to self, saved messages (bookmarks) and chat
// folders.
//
// Account data is NOT end-to-end encrypted, so these records hold only room
// IDs, event IDs, timestamps and user-chosen folder names — never message
// text. Unknown fields written by newer clients are preserved on every
// rewrite.
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../chat_backend.dart';

/// Account-data event types owned by this module.
abstract final class SavedAccountData {
  static const noteToSelf = 'net.samrusselltech.parallax.note_to_self';
  static const bookmarks = 'net.samrusselltech.parallax.bookmarks';
  static const folders = 'net.samrusselltech.parallax.folders';
}

/// Saved messages kept per account; the oldest are dropped beyond this.
const maxBookmarks = 500;

/// Folder limits. Account data travels in every initial sync, so each record
/// is kept well under the 64 KiB event size most homeservers enforce.
const maxFolders = 30;
const maxFolderNameLength = 40;
const maxFolderRooms = 300;
const maxAccountDataBytes = 60000;

/// Display title of the Note to self room.
const noteToSelfTitle = 'Note to self';

final _whitespace = RegExp(r'\s');

bool _validId(Object? value, String sigil) =>
    value is String &&
    value.length > 1 &&
    value.length <= 255 &&
    value.startsWith(sigil) &&
    !value.contains(_whitespace);

/// A plausible Matrix room ID (`!opaque` or `!opaque:server`).
bool isRoomIdLike(Object? value) => _validId(value, '!');

/// A plausible Matrix event ID (`$opaque`).
bool isEventIdLike(Object? value) => _validId(value, r'$');

Map<String, Object?> _extra(Map<String, Object?> json, Set<String> known) => {
  for (final entry in json.entries)
    if (!known.contains(entry.key)) entry.key: entry.value,
};

int _jsonBytes(Map<String, Object?> json) =>
    utf8.encode(jsonEncode(json)).length;

/// Thrown when a change would make an account-data record too large.
class SavedDataTooLarge implements Exception {
  const SavedDataTooLarge();
  @override
  String toString() => 'SavedDataTooLarge';
}

// --- Note to self ----------------------------------------------------------

/// `net.samrusselltech.parallax.note_to_self`: `{room_id}` plus whether the
/// inbox prompt was dismissed (synced so it stays dismissed on every device).
@immutable
class NoteToSelfRecord {
  const NoteToSelfRecord({
    this.roomId,
    this.promptDismissed = false,
    this.extra = const {},
  });

  factory NoteToSelfRecord.fromJson(Map<String, Object?>? json) {
    if (json == null) return const NoteToSelfRecord();
    final roomId = json['room_id'];
    return NoteToSelfRecord(
      roomId: isRoomIdLike(roomId) ? roomId as String : null,
      promptDismissed: json['prompt_dismissed'] == true,
      extra: Map.unmodifiable(_extra(json, _known)),
    );
  }

  static const _known = {'room_id', 'prompt_dismissed'};

  final String? roomId;
  final bool promptDismissed;

  /// Fields this version does not understand, kept verbatim.
  final Map<String, Object?> extra;

  NoteToSelfRecord copyWith({String? roomId, bool? promptDismissed}) =>
      NoteToSelfRecord(
        roomId: roomId ?? this.roomId,
        promptDismissed: promptDismissed ?? this.promptDismissed,
        extra: extra,
      );

  Map<String, Object?> toJson() => {
    ...extra,
    'room_id': ?roomId,
    if (promptDismissed) 'prompt_dismissed': true,
  };
}

// --- Bookmarks -------------------------------------------------------------

/// One saved message: identifiers and when it was saved, nothing else.
@immutable
class Bookmark {
  const Bookmark({
    required this.roomId,
    required this.eventId,
    required this.savedTs,
    this.extra = const {},
  });

  static Bookmark? tryParse(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, Object?>();
    final roomId = map['room_id'];
    final eventId = map['event_id'];
    final savedTs = map['saved_ts'];
    if (!isRoomIdLike(roomId) || !isEventIdLike(eventId)) return null;
    return Bookmark(
      roomId: roomId as String,
      eventId: eventId as String,
      savedTs: savedTs is num && savedTs.isFinite && savedTs >= 0
          ? savedTs.toInt()
          : 0,
      extra: Map.unmodifiable(_extra(map, _known)),
    );
  }

  static const _known = {'room_id', 'event_id', 'saved_ts'};

  final String roomId;
  final String eventId;

  /// Milliseconds since the epoch.
  final int savedTs;
  final Map<String, Object?> extra;

  DateTime get savedAt => DateTime.fromMillisecondsSinceEpoch(savedTs);

  bool matches(String roomId, String eventId) =>
      this.roomId == roomId && this.eventId == eventId;

  Map<String, Object?> toJson() => {
    ...extra,
    'room_id': roomId,
    'event_id': eventId,
    'saved_ts': savedTs,
  };
}

/// `net.samrusselltech.parallax.bookmarks`: `{"bookmarks": [...]}`, newest
/// first, de-duplicated and capped at [maxBookmarks].
@immutable
class BookmarkList {
  const BookmarkList({this.bookmarks = const [], this.extra = const {}});

  static const empty = BookmarkList();

  factory BookmarkList.fromJson(Map<String, Object?>? json) {
    if (json == null) return empty;
    final raw = json['bookmarks'];
    final parsed = <Bookmark>[
      if (raw is List)
        for (final item in raw.take(maxBookmarks * 2)) ?Bookmark.tryParse(item),
    ];
    // Stable newest-first order: other clients may have appended.
    final indexed = parsed.indexed.toList()
      ..sort((a, b) {
        final byTime = b.$2.savedTs.compareTo(a.$2.savedTs);
        return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
      });
    final seen = <String>{};
    final bookmarks = [
      for (final (_, bookmark) in indexed)
        if (seen.add('${bookmark.roomId}\n${bookmark.eventId}')) bookmark,
    ];
    return BookmarkList(
      bookmarks: List.unmodifiable(bookmarks.take(maxBookmarks)),
      extra: Map.unmodifiable(_extra(json, const {'bookmarks'})),
    );
  }

  final List<Bookmark> bookmarks;
  final Map<String, Object?> extra;

  int get length => bookmarks.length;
  bool get isEmpty => bookmarks.isEmpty;

  bool contains(String roomId, String eventId) =>
      bookmarks.any((bookmark) => bookmark.matches(roomId, eventId));

  /// Rooms with saved messages, in order of their newest bookmark.
  List<String> get roomIds => [
    ...{for (final bookmark in bookmarks) bookmark.roomId},
  ];

  /// Saves (or re-saves) a message at the front of the list, dropping the
  /// oldest bookmarks beyond the count and size caps.
  BookmarkList withAdded(
    String roomId,
    String eventId, {
    required int savedTs,
  }) {
    if (!isRoomIdLike(roomId) || !isEventIdLike(eventId)) {
      throw ArgumentError('Invalid room or event ID');
    }
    final next = [
      Bookmark(roomId: roomId, eventId: eventId, savedTs: savedTs),
      ...bookmarks.where((bookmark) => !bookmark.matches(roomId, eventId)),
    ];
    // Keep [savedTs] ordering for explicit restores (undo) too.
    next.sort((a, b) => b.savedTs.compareTo(a.savedTs));
    var capped = next.take(maxBookmarks).toList();
    while (capped.length > 1 &&
        _jsonBytes(BookmarkList(bookmarks: capped, extra: extra).toJson()) >
            maxAccountDataBytes) {
      capped = capped.sublist(0, capped.length - 1);
    }
    return BookmarkList(bookmarks: List.unmodifiable(capped), extra: extra);
  }

  BookmarkList withRemoved(String roomId, String eventId) => BookmarkList(
    bookmarks: List.unmodifiable(
      bookmarks.where((bookmark) => !bookmark.matches(roomId, eventId)),
    ),
    extra: extra,
  );

  Map<String, Object?> toJson() => {
    ...extra,
    'bookmarks': [for (final bookmark in bookmarks) bookmark.toJson()],
  };
}

// --- Chat folders ----------------------------------------------------------

/// Chat types a folder includes automatically.
@immutable
class FolderIncludes {
  const FolderIncludes({
    this.unread = false,
    this.people = false,
    this.groups = false,
    this.favourites = false,
    this.invites = false,
    this.extra = const {},
  });

  factory FolderIncludes.fromJson(Object? json) {
    if (json is! Map) return const FolderIncludes();
    final map = json.cast<String, Object?>();
    return FolderIncludes(
      unread: map['unread'] == true,
      people: map['people'] == true,
      groups: map['groups'] == true,
      favourites: map['favourites'] == true,
      invites: map['invites'] == true,
      extra: Map.unmodifiable(_extra(map, _known)),
    );
  }

  static const _known = {'unread', 'people', 'groups', 'favourites', 'invites'};

  final bool unread;
  final bool people;

  /// Rooms that are not direct chats ("Rooms" in Element X wording).
  final bool groups;
  final bool favourites;
  final bool invites;
  final Map<String, Object?> extra;

  bool get any => unread || people || groups || favourites || invites;

  FolderIncludes copyWith({
    bool? unread,
    bool? people,
    bool? groups,
    bool? favourites,
    bool? invites,
  }) => FolderIncludes(
    unread: unread ?? this.unread,
    people: people ?? this.people,
    groups: groups ?? this.groups,
    favourites: favourites ?? this.favourites,
    invites: invites ?? this.invites,
    extra: extra,
  );

  Map<String, Object?> toJson() => {
    ...extra,
    'unread': unread,
    'people': people,
    'groups': groups,
    'favourites': favourites,
    'invites': invites,
  };
}

String _truncate(String value, int maxRunes) {
  final runes = value.runes;
  return runes.length <= maxRunes
      ? value
      : String.fromCharCodes(runes.take(maxRunes));
}

List<String> _roomList(Object? raw) {
  if (raw is! List) return const [];
  final seen = <String>{};
  return List.unmodifiable(
    [
      for (final id in raw.take(maxFolderRooms * 2))
        if (isRoomIdLike(id) && seen.add(id as String)) id,
    ].take(maxFolderRooms),
  );
}

/// Sanitises a user-chosen folder name: single line, trimmed, bounded.
String cleanFolderName(String name) => _truncate(
  name.replaceAll(RegExp(r'[\u0000-\u001f\u007f\u2028\u2029]'), ' ').trim(),
  maxFolderNameLength,
).trim();

/// A short emoji icon, or null. Rejects anything that is plain text.
String? cleanFolderIcon(Object? icon) {
  if (icon is! String) return null;
  final value = icon.trim();
  if (value.isEmpty || value.runes.length > 8) return null;
  if (RegExp(r'[A-Za-z0-9\s<>&"]').hasMatch(value)) return null;
  return value;
}

/// One chat folder. [includeRooms] are always shown and [excludeRooms] never
/// are; other chats are shown when they match [include].
@immutable
class ChatFolder {
  const ChatFolder({
    required this.id,
    required this.name,
    this.icon,
    this.includeRooms = const [],
    this.excludeRooms = const [],
    this.include = const FolderIncludes(),
    this.extra = const {},
  });

  static ChatFolder? tryParse(Object? json) {
    if (json is! Map) return null;
    final map = json.cast<String, Object?>();
    final id = map['id'];
    final name = map['name'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 64 ||
        id.contains(_whitespace) ||
        name is! String) {
      return null;
    }
    final cleanName = cleanFolderName(name);
    if (cleanName.isEmpty) return null;
    final exclude = _roomList(map['exclude_rooms']);
    return ChatFolder(
      id: id,
      name: cleanName,
      icon: cleanFolderIcon(map['icon']),
      // Exclusion wins; drop contradictory inclusions.
      includeRooms: List.unmodifiable(
        _roomList(map['include_rooms']).where((id) => !exclude.contains(id)),
      ),
      excludeRooms: exclude,
      include: FolderIncludes.fromJson(map['include']),
      extra: Map.unmodifiable(_extra(map, _known)),
    );
  }

  static const _known = {
    'id',
    'name',
    'icon',
    'include_rooms',
    'exclude_rooms',
    'include',
  };

  final String id;
  final String name;
  final String? icon;
  final List<String> includeRooms;
  final List<String> excludeRooms;
  final FolderIncludes include;
  final Map<String, Object?> extra;

  /// Tab label: icon and name.
  String get label => icon == null ? name : '$icon $name';

  /// Whether the folder can show anything at all.
  bool get hasContent => includeRooms.isNotEmpty || include.any;

  ChatFolder copyWith({
    String? name,
    String? icon,
    bool clearIcon = false,
    List<String>? includeRooms,
    List<String>? excludeRooms,
    FolderIncludes? include,
  }) => ChatFolder(
    id: id,
    name: name ?? this.name,
    icon: clearIcon ? null : icon ?? this.icon,
    includeRooms: includeRooms ?? this.includeRooms,
    excludeRooms: excludeRooms ?? this.excludeRooms,
    include: include ?? this.include,
    extra: extra,
  );

  /// Adds [roomId] to the folder ([member] true) or takes it out. A chat that
  /// still matches the folder's chat types is excluded explicitly.
  ChatFolder withRoomMembership(
    String roomId, {
    required bool member,
    required bool matchesTypes,
  }) {
    if (!isRoomIdLike(roomId)) throw ArgumentError.value(roomId, 'roomId');
    final include = includeRooms.where((id) => id != roomId).toList();
    final exclude = excludeRooms.where((id) => id != roomId).toList();
    if (member) {
      include.add(roomId);
    } else if (matchesTypes) {
      exclude.add(roomId);
    }
    if (include.length > maxFolderRooms || exclude.length > maxFolderRooms) {
      throw const SavedDataTooLarge();
    }
    return copyWith(
      includeRooms: List.unmodifiable(include),
      excludeRooms: List.unmodifiable(exclude),
    );
  }

  Map<String, Object?> toJson() => {
    ...extra,
    'id': id,
    'name': name,
    'icon': ?icon,
    'include_rooms': includeRooms,
    'exclude_rooms': excludeRooms,
    'include': include.toJson(),
  };
}

/// `net.samrusselltech.parallax.folders`: ordered folders.
@immutable
class ChatFolders {
  const ChatFolders({this.folders = const [], this.extra = const {}});

  static const empty = ChatFolders();

  factory ChatFolders.fromJson(Map<String, Object?>? json) {
    if (json == null) return empty;
    final raw = json['folders'];
    final seen = <String>{};
    final folders = <ChatFolder>[
      if (raw is List)
        for (final item in raw.take(maxFolders * 2))
          if (ChatFolder.tryParse(item) case final folder?
              when seen.add(folder.id))
            folder,
    ];
    return ChatFolders(
      folders: List.unmodifiable(folders.take(maxFolders)),
      extra: Map.unmodifiable(_extra(json, const {'folders'})),
    );
  }

  final List<ChatFolder> folders;
  final Map<String, Object?> extra;

  bool get isEmpty => folders.isEmpty;

  ChatFolder? byId(String? id) =>
      id == null ? null : folders.where((f) => f.id == id).firstOrNull;

  ChatFolders _with(List<ChatFolder> folders) {
    if (folders.length > maxFolders) throw const SavedDataTooLarge();
    final next = ChatFolders(folders: List.unmodifiable(folders), extra: extra);
    if (_jsonBytes(next.toJson()) > maxAccountDataBytes) {
      throw const SavedDataTooLarge();
    }
    return next;
  }

  /// Replaces the folder with the same ID in place, or appends it.
  ChatFolders withUpserted(ChatFolder folder) {
    final index = folders.indexWhere((f) => f.id == folder.id);
    return _with(
      index < 0
          ? [...folders, folder]
          : [...folders.take(index), folder, ...folders.skip(index + 1)],
    );
  }

  ChatFolders withRemoved(String id) =>
      _with(folders.where((f) => f.id != id).toList());

  /// Moves folder [id] to [index] (clamped).
  ChatFolders withMoved(String id, int index) {
    final folder = byId(id);
    if (folder == null) return this;
    final rest = folders.where((f) => f.id != id).toList();
    rest.insert(index.clamp(0, rest.length), folder);
    return _with(rest);
  }

  /// Applies an order of folder IDs; unknown IDs are ignored and folders not
  /// listed (for example added on another device meanwhile) keep their
  /// relative order at the end.
  ChatFolders withOrder(List<String> ids) {
    final ordered = [for (final id in ids) ?byId(id)];
    final seen = {for (final f in ordered) f.id};
    return _with([...ordered, ...folders.where((f) => !seen.contains(f.id))]);
  }

  Map<String, Object?> toJson() => {
    ...extra,
    'folders': [for (final folder in folders) folder.toJson()],
  };
}

/// A new, practically unique folder ID.
String newFolderId([Random? random]) {
  final source = random ?? Random.secure();
  final suffix = List.generate(
    10,
    (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[source.nextInt(36)],
  ).join();
  return 'f_$suffix';
}

/// Facts about a room that do not live on [ChatRoom] itself.
typedef FolderRoomFacts = ({bool favourite, bool unread});

/// Whether [room] matches [folder]'s chat types (ignoring explicit lists).
bool folderMatchesTypes(
  ChatFolder folder,
  ChatRoom room,
  FolderRoomFacts facts,
) {
  if (room.isSpace) return false;
  final include = folder.include;
  if (room.invited) return include.invites;
  return (include.people && room.isDirect) ||
      (include.groups && !room.isDirect) ||
      (include.favourites && (room.favourite || facts.favourite)) ||
      (include.unread && facts.unread);
}

/// Folder membership: Spaces never; excluded chats never; included chats
/// always; otherwise any matching chat type.
bool folderContainsRoom(
  ChatFolder folder,
  ChatRoom room,
  FolderRoomFacts facts,
) {
  if (room.isSpace) return false;
  if (folder.excludeRooms.contains(room.id)) return false;
  if (folder.includeRooms.contains(room.id)) return true;
  return folderMatchesTypes(folder, room, facts);
}

/// Unread chats (and pending invites) in [folder], for its tab badge.
int folderUnreadCount(
  ChatFolder folder,
  Iterable<ChatRoom> rooms,
  FolderRoomFacts Function(ChatRoom room) facts,
) {
  var count = 0;
  for (final room in rooms) {
    final roomFacts = facts(room);
    if ((room.invited || roomFacts.unread) &&
        folderContainsRoom(folder, room, roomFacts)) {
      count++;
    }
  }
  return count;
}

/// The Note to self room as the inbox presents it: titled "Note to self" and
/// treated as a direct chat (People filter), whatever its stored name.
ChatRoom presentNoteToSelf(ChatRoom room) => ChatRoom(
  id: room.id,
  name: noteToSelfTitle,
  preview: room.preview,
  lastActivity: room.lastActivity,
  unread: room.unread,
  encrypted: room.encrypted,
  isDirect: true,
  manuallyUnread: room.manuallyUnread,
  invited: room.invited,
  highlightCount: room.highlightCount,
  favourite: room.favourite,
  lowPriority: room.lowPriority,
  tags: room.tags,
  notificationMode: room.notificationMode,
  isSpace: false,
  isPublic: room.isPublic,
  canonicalAlias: room.canonicalAlias,
);
