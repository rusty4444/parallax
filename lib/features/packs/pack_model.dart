import 'package:flutter/foundation.dart';

/// MSC2545 image packs: the de-facto format shared by FluffyChat, Cinny,
/// Nheko and Element Web's emote support.
///
/// * Room packs: state `im.ponies.room_emotes`, state key = pack id.
/// * Personal pack: account data `im.ponies.user_emotes`.
/// * Room packs enabled everywhere: account data `im.ponies.emote_rooms`,
///   `{rooms: {roomId: {stateKey: {}}}}`.
///
/// Parsing is lenient (malformed entries are skipped, never thrown) and
/// preserves unknown keys so that writes do not destroy other clients' data.
const roomPackEventType = 'im.ponies.room_emotes';
const userPackEventType = 'im.ponies.user_emotes';
const emoteRoomsEventType = 'im.ponies.emote_rooms';

/// Upper bounds for untrusted pack content.
const maxPackImages = 1000;
const maxShortcodeLength = 100;
const maxCreatedShortcodeLength = 64;
const maxEmoteRooms = 50;
const maxAvailablePacks = 100;

enum PackUsage { emoticon, sticker }

const _usageNames = {
  PackUsage.emoticon: 'emoticon',
  PackUsage.sticker: 'sticker',
};

final _mxcPattern = RegExp(
  r'^mxc://(?:[A-Za-z0-9.\-]+|\[[0-9A-Fa-f:.]+\])(?::\d{1,5})?/[A-Za-z0-9_\-]+$',
);

/// A well-formed `mxc://server/mediaId` URI, or null. Anything else (http,
/// data:, relative, oversized, odd characters) is rejected.
Uri? parseMxcUri(Object? value) {
  if (value is! String || value.length > 255 || !_mxcPattern.hasMatch(value)) {
    return null;
  }
  return Uri.tryParse(value);
}

final _invalidShortcodeChars = RegExp(r'[\s:]');

/// Whether [code] can be addressed as `:code:` (pack content from any client).
bool isValidShortcode(String code) =>
    code.isNotEmpty &&
    code.length <= maxShortcodeLength &&
    !_invalidShortcodeChars.hasMatch(code);

final _creatableShortcode = RegExp(r'^[A-Za-z0-9_+\-.]+$');

/// Whether Parallax lets a user save [code] as a new shortcode. Stricter than
/// [isValidShortcode] so the code survives HTML escaping and markdown.
bool isCreatableShortcode(String code) =>
    code.isNotEmpty &&
    code.length <= maxCreatedShortcodeLength &&
    _creatableShortcode.hasMatch(code);

/// Turns user input or a file name into a creatable shortcode ('' if nothing
/// usable remains).
String normaliseShortcode(String input) {
  var code = input.trim();
  while (code.startsWith(':')) {
    code = code.substring(1);
  }
  while (code.endsWith(':')) {
    code = code.substring(0, code.length - 1);
  }
  code = code
      .replaceAll(RegExp(r'\s+'), '_')
      .replaceAll(RegExp(r'[^A-Za-z0-9_+\-.]'), '');
  if (code.length > maxCreatedShortcodeLength) {
    code = code.substring(0, maxCreatedShortcodeLength);
  }
  return code;
}

/// Lower-case `[a-z0-9_-]` identifier for `:slug~code:` (empty → 'pack').
String packSlug(String input) {
  var slug = input
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9_-]+'), '-')
      .replaceAll(RegExp(r'-+'), '-');
  while (slug.startsWith('-')) {
    slug = slug.substring(1);
  }
  while (slug.endsWith('-')) {
    slug = slug.substring(0, slug.length - 1);
  }
  if (slug.length > 32) slug = slug.substring(0, 32);
  return slug.isEmpty ? 'pack' : slug;
}

List<String>? _usageList(Object? value) {
  if (value is! List) return null;
  return List.unmodifiable([
    for (final item in value.take(8))
      if (item is String && item.length <= 64) item,
  ]);
}

/// Known usages in a raw `usage` list. Absent or empty means every usage
/// (MSC2545); a list holding only unknown values means none we support.
Set<PackUsage>? _knownUsage(List<String>? raw) {
  if (raw == null || raw.isEmpty) return null;
  return {
    for (final entry in _usageNames.entries)
      if (raw.contains(entry.value)) entry.key,
  };
}

/// Raw usage list for [usage], keeping [previous]' unknown values.
List<String> usageToJson(Set<PackUsage> usage, List<String>? previous) {
  final known = _usageNames.values.toSet();
  return [
    for (final value in previous ?? const <String>[])
      if (!known.contains(value)) value,
    for (final entry in _usageNames.entries)
      if (usage.contains(entry.key)) entry.value,
  ];
}

Map<String, Object?>? _stringMap(Object? value) {
  if (value is! Map) return null;
  return {
    for (final entry in value.entries)
      if (entry.key is String) entry.key as String: entry.value,
  };
}

/// One image of a pack.
@immutable
class PackImage {
  const PackImage({
    required this.shortcode,
    required this.url,
    this.body,
    this.info,
    this.usage,
    this.extra = const {},
  });

  final String shortcode;

  /// Validated `mxc://` URI.
  final Uri url;
  final String? body;

  /// `ImageInfo` (`w`, `h`, `mimetype`, `size` …) as stored.
  final Map<String, Object?>? info;

  /// Raw `usage` list, null to inherit the pack's.
  final List<String>? usage;

  /// Unknown keys, preserved on write.
  final Map<String, Object?> extra;

  /// Parses one `images` entry; null when malformed.
  static PackImage? fromJson(String shortcode, Object? json) {
    if (!isValidShortcode(shortcode)) return null;
    final map = _stringMap(json);
    if (map == null) return null;
    final url = parseMxcUri(map['url']);
    if (url == null) return null;
    final body = map['body'];
    return PackImage(
      shortcode: shortcode,
      url: url,
      body: body is String && body.trim().isNotEmpty
          ? (body.length > 500 ? body.substring(0, 500) : body)
          : null,
      info: _stringMap(map['info']),
      usage: _usageList(map['usage']),
      extra: Map.unmodifiable({
        for (final entry in map.entries)
          if (!const {'url', 'body', 'info', 'usage'}.contains(entry.key))
            entry.key: entry.value,
      }),
    );
  }

  Map<String, Object?> toJson() => {
    ...extra,
    'url': url.toString(),
    if (body != null) 'body': body,
    if (info != null) 'info': info,
    if (usage != null) 'usage': usage,
  };

  int? _positiveInt(String key, int max) {
    final value = info?[key];
    return value is int && value > 0 && value <= max ? value : null;
  }

  int? get width => _positiveInt('w', 1 << 16);
  int? get height => _positiveInt('h', 1 << 16);
  int? get size => _positiveInt('size', 1 << 30);
  String? get mimetype {
    final value = info?['mimetype'];
    return value is String && value.startsWith('image/') && value.length < 64
        ? value
        : null;
  }

  /// Human description: the body, else the shortcode.
  String get description => body ?? shortcode;

  PackImage copyWith({
    String? shortcode,
    String? body,
    bool clearBody = false,
    List<String>? usage,
    bool inheritUsage = false,
  }) => PackImage(
    shortcode: shortcode ?? this.shortcode,
    url: url,
    body: clearBody ? null : (body ?? this.body),
    info: info,
    usage: inheritUsage ? null : (usage ?? this.usage),
    extra: extra,
  );
}

/// One pack: images in their stored order plus pack metadata.
@immutable
class ImagePack {
  const ImagePack({
    this.images = const {},
    this.displayName,
    this.avatarUrl,
    this.usage,
    this.attribution,
    this.extra = const {},
    this.packExtra = const {},
    this.invalidImages = const {},
  });

  static const empty = ImagePack();

  final Map<String, PackImage> images;
  final String? displayName;
  final Uri? avatarUrl;

  /// Raw pack-level `usage`; null or empty means emoticons and stickers.
  final List<String>? usage;
  final String? attribution;

  /// Unknown top-level keys, preserved on write.
  final Map<String, Object?> extra;

  /// Unknown keys of the `pack` object, preserved on write.
  final Map<String, Object?> packExtra;

  /// Entries we could not parse (another client's format), preserved as-is.
  final Map<String, Object?> invalidImages;

  bool get isEmpty => images.isEmpty;

  /// Parses pack content; never throws. Accepts the legacy `emoticons` and
  /// `short` layouts when `images` is absent.
  factory ImagePack.fromJson(Object? json) {
    final map = _stringMap(json);
    if (map == null) return empty;
    final images = <String, PackImage>{};
    final invalid = <String, Object?>{};
    void addImage(String key, Object? value) {
      if (images.length >= maxPackImages) return;
      final image = PackImage.fromJson(key, value);
      if (image != null) {
        images.putIfAbsent(key, () => image);
      } else if (invalid.length < maxPackImages) {
        invalid[key] = value;
      }
    }

    String stripColons(String key) =>
        key.length > 2 && key.startsWith(':') && key.endsWith(':')
        ? key.substring(1, key.length - 1)
        : key;

    final rawImages = _stringMap(map['images']);
    if (rawImages != null) {
      rawImages.forEach(addImage);
    } else if (_stringMap(map['emoticons']) case final legacy?) {
      legacy.forEach((key, value) => addImage(stripColons(key), value));
    } else if (_stringMap(map['short']) case final short?) {
      short.forEach((key, value) => addImage(stripColons(key), {'url': value}));
    }
    final pack = _stringMap(map['pack']) ?? const <String, Object?>{};
    final name = pack['display_name'];
    final attribution = pack['attribution'];
    return ImagePack(
      images: Map.unmodifiable(images),
      displayName: name is String && name.trim().isNotEmpty
          ? (name.length > 200 ? name.substring(0, 200) : name)
          : null,
      avatarUrl: parseMxcUri(pack['avatar_url']),
      usage: _usageList(pack['usage']),
      attribution: attribution is String && attribution.trim().isNotEmpty
          ? attribution
          : null,
      extra: Map.unmodifiable({
        for (final entry in map.entries)
          if (!const {
            'images',
            'pack',
            'emoticons',
            'short',
          }.contains(entry.key))
            entry.key: entry.value,
      }),
      packExtra: Map.unmodifiable({
        for (final entry in pack.entries)
          if (!const {
            'display_name',
            'avatar_url',
            'usage',
            'attribution',
          }.contains(entry.key))
            entry.key: entry.value,
      }),
      invalidImages: Map.unmodifiable(invalid),
    );
  }

  Map<String, Object?> toJson() => {
    ...extra,
    'images': {
      ...invalidImages,
      for (final image in images.values) image.shortcode: image.toJson(),
    },
    'pack': {
      ...packExtra,
      if (displayName != null) 'display_name': displayName,
      if (avatarUrl != null) 'avatar_url': avatarUrl.toString(),
      if (usage != null) 'usage': usage,
      if (attribution != null) 'attribution': attribution,
    },
  };

  /// Effective usage of [image] (image usage, else pack usage, else both).
  Set<PackUsage> usageOf(PackImage image) =>
      _knownUsage(image.usage) ??
      _knownUsage(usage) ??
      const {PackUsage.emoticon, PackUsage.sticker};

  Iterable<PackImage> imagesFor(PackUsage use) =>
      images.values.where((image) => usageOf(image).contains(use));

  bool supports(PackUsage use) => imagesFor(use).isNotEmpty;

  ImagePack copyWith({
    Map<String, PackImage>? images,
    String? displayName,
    bool clearDisplayName = false,
    Uri? avatarUrl,
    bool clearAvatar = false,
  }) => ImagePack(
    images: images ?? this.images,
    displayName: clearDisplayName ? null : (displayName ?? this.displayName),
    avatarUrl: clearAvatar ? null : (avatarUrl ?? this.avatarUrl),
    usage: usage,
    attribution: attribution,
    extra: extra,
    packExtra: packExtra,
    invalidImages: invalidImages,
  );

  /// Adds [image], or replaces the image named [replacing] in place (so a
  /// rename keeps its position). Throws [ArgumentError] on a duplicate code.
  ImagePack withImage(PackImage image, {String? replacing}) {
    final next = <String, PackImage>{};
    var placed = false;
    if (image.shortcode != replacing &&
        (images.containsKey(image.shortcode) ||
            invalidImages.containsKey(image.shortcode))) {
      throw ArgumentError.value(image.shortcode, 'shortcode', 'Already used');
    }
    for (final entry in images.entries) {
      if (entry.key == replacing) {
        next[image.shortcode] = image;
        placed = true;
      } else {
        next[entry.key] = entry.value;
      }
    }
    if (!placed) {
      if (next.length >= maxPackImages) {
        throw StateError('This pack is full');
      }
      next[image.shortcode] = image;
    }
    return copyWith(images: Map.unmodifiable(next));
  }

  ImagePack withoutImage(String shortcode) => copyWith(
    images: Map.unmodifiable({
      for (final entry in images.entries)
        if (entry.key != shortcode) entry.key: entry.value,
    }),
  );
}

/// Where a pack lives.
@immutable
class PackRef {
  const PackRef.personal() : roomId = null, stateKey = '';
  const PackRef.room(String this.roomId, this.stateKey);

  /// Null for the personal pack.
  final String? roomId;
  final String stateKey;

  bool get personal => roomId == null;

  @override
  bool operator ==(Object other) =>
      other is PackRef && other.roomId == roomId && other.stateKey == stateKey;

  @override
  int get hashCode => Object.hash(roomId, stateKey);

  @override
  String toString() => personal ? 'personal' : '$roomId/$stateKey';
}

/// A room pack as read from local state.
@immutable
class RoomPackState {
  const RoomPackState({
    required this.ref,
    required this.pack,
    required this.roomName,
  });
  final PackRef ref;
  final ImagePack pack;
  final String roomName;

  /// Display name: the pack's own, else the room name (default pack) or id.
  String get name =>
      pack.displayName ??
      (ref.stateKey.isEmpty ? roomName : '${ref.stateKey} · $roomName');
}

enum PackScope { personal, room, global }

/// A pack available in one room.
@immutable
class AvailablePack {
  const AvailablePack({
    required this.ref,
    required this.scope,
    required this.pack,
    required this.slug,
    required this.name,
  });
  final PackRef ref;
  final PackScope scope;
  final ImagePack pack;

  /// Unique within its [AvailablePacks]; addresses `:slug~code:`.
  final String slug;
  final String name;
}

/// An image together with the pack that provides it.
typedef PackEntry = ({AvailablePack pack, PackImage image});

/// The packs usable in a room, in priority order: personal pack, the room's
/// own packs (by state key), then room packs enabled for all rooms.
/// `:code:` resolves to the first pack providing it.
class AvailablePacks {
  AvailablePacks(List<AvailablePack> packs) : packs = List.unmodifiable(packs);

  static final empty = AvailablePacks(const []);

  final List<AvailablePack> packs;

  bool get isEmpty => packs.isEmpty;

  bool supports(PackUsage usage) => packs.any((p) => p.pack.supports(usage));

  /// Resolves `code` or `slug~code` for [usage].
  PackEntry? resolve(String code, {PackUsage usage = PackUsage.emoticon}) {
    final tilde = code.indexOf('~');
    if (tilde > 0 && tilde < code.length - 1) {
      final slug = code.substring(0, tilde);
      final name = code.substring(tilde + 1);
      for (final pack in packs) {
        if (pack.slug != slug) continue;
        final image = pack.pack.images[name];
        if (image != null && pack.pack.usageOf(image).contains(usage)) {
          return (pack: pack, image: image);
        }
      }
    }
    for (final pack in packs) {
      final image = pack.pack.images[code];
      if (image != null && pack.pack.usageOf(image).contains(usage)) {
        return (pack: pack, image: image);
      }
    }
    return null;
  }

  /// The first pack image with [url].
  PackEntry? findByUrl(Uri url) {
    for (final pack in packs) {
      for (final image in pack.pack.images.values) {
        if (image.url == url) return (pack: pack, image: image);
      }
    }
    return null;
  }

  /// Text that resolves back to exactly this image: `:code:`, or
  /// `:slug~code:` when a higher-priority pack shadows the shortcode.
  String insertCode(AvailablePack pack, PackImage image) {
    final plain = resolve(image.shortcode);
    return plain != null && plain.image.url == image.url
        ? ':${image.shortcode}:'
        : ':${pack.slug}~${image.shortcode}:';
  }

  /// Images for [usage], grouped by pack, each URL once (first pack wins).
  List<({AvailablePack pack, List<PackImage> images})> grouped(
    PackUsage usage,
  ) {
    final seen = <Uri>{};
    return [
      for (final pack in packs)
        if ([
              for (final image in pack.pack.imagesFor(usage))
                if (seen.add(image.url)) image,
            ]
            case final images when images.isNotEmpty)
          (pack: pack, images: images),
    ];
  }

  /// Autocomplete: prefix matches first, then substring matches; each URL
  /// once; case-insensitive.
  List<PackEntry> search(
    String query, {
    PackUsage usage = PackUsage.emoticon,
    int limit = 20,
  }) {
    final needle = query.toLowerCase();
    final prefix = <PackEntry>[];
    final contains = <PackEntry>[];
    final seen = <Uri>{};
    for (final pack in packs) {
      for (final image in pack.pack.imagesFor(usage)) {
        final code = image.shortcode.toLowerCase();
        final bucket = code.startsWith(needle)
            ? prefix
            : code.contains(needle)
            ? contains
            : null;
        if (bucket == null || !seen.add(image.url)) continue;
        bucket.add((pack: pack, image: image));
      }
    }
    return [...prefix, ...contains].take(limit).toList();
  }
}

/// Merges personal, room and globally enabled packs (see [AvailablePacks]).
AvailablePacks mergeAvailablePacks({
  ImagePack? personal,
  List<RoomPackState> roomPacks = const [],
  List<RoomPackState> globalPacks = const [],
}) {
  final result = <AvailablePack>[];
  final seenRefs = <PackRef>{};
  final slugs = <String>{};
  String uniqueSlug(String base) {
    var slug = base;
    for (var n = 2; !slugs.add(slug); n++) {
      slug = '$base-$n';
    }
    return slug;
  }

  if (personal != null && !personal.isEmpty) {
    result.add(
      AvailablePack(
        ref: const PackRef.personal(),
        scope: PackScope.personal,
        pack: personal,
        slug: uniqueSlug('user'),
        name: personal.displayName ?? 'Your emoji',
      ),
    );
  }
  final sortedRoom = [...roomPacks]
    ..sort((a, b) => a.ref.stateKey.compareTo(b.ref.stateKey));
  for (final (scope, list) in [
    (PackScope.room, sortedRoom),
    (PackScope.global, globalPacks),
  ]) {
    for (final state in list) {
      if (result.length >= maxAvailablePacks) break;
      if (state.pack.isEmpty || !seenRefs.add(state.ref)) continue;
      final key = state.ref.stateKey;
      result.add(
        AvailablePack(
          ref: state.ref,
          scope: scope,
          pack: state.pack,
          slug: uniqueSlug(
            packSlug(
              key.isNotEmpty
                  ? key
                  : scope == PackScope.room
                  ? 'room'
                  : state.roomName,
            ),
          ),
          name: state.name,
        ),
      );
    }
  }
  return AvailablePacks(result);
}

/// Enabled-everywhere packs from `im.ponies.emote_rooms`: room ID → state
/// keys, in stored order, bounded.
Map<String, List<String>> parseEmoteRooms(Object? content) {
  final rooms = _stringMap(_stringMap(content)?['rooms']);
  if (rooms == null) return const {};
  final result = <String, List<String>>{};
  for (final entry in rooms.entries) {
    if (result.length >= maxEmoteRooms) break;
    final roomId = entry.key;
    final keys = _stringMap(entry.value);
    if (!roomId.startsWith('!') || roomId.length > 255 || keys == null) {
      continue;
    }
    final stateKeys = [
      for (final key in keys.keys.take(20))
        if (key.length <= 255) key,
    ];
    if (stateKeys.isNotEmpty) result[roomId] = stateKeys;
  }
  return result;
}

/// Returns `im.ponies.emote_rooms` content with [ref] enabled or disabled,
/// keeping unknown keys and other rooms untouched.
Map<String, Object?> setEmoteRoom(
  Object? content,
  PackRef ref, {
  required bool enabled,
}) {
  final roomId = ref.roomId;
  if (roomId == null) throw ArgumentError('Only room packs can be enabled');
  final map = {...?_stringMap(content)};
  final rooms = {...?_stringMap(map['rooms'])};
  final keys = {...?_stringMap(rooms[roomId])};
  if (enabled) {
    keys[ref.stateKey] = _stringMap(keys[ref.stateKey]) ?? <String, Object?>{};
  } else {
    keys.remove(ref.stateKey);
  }
  if (keys.isEmpty) {
    rooms.remove(roomId);
  } else {
    rooms[roomId] = keys;
  }
  map['rooms'] = rooms;
  return map;
}
