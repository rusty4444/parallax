# Custom emoji and sticker packs (MSC2545)

Interoperable with FluffyChat, Cinny, Nheko and Element Web's emote support.

| Data | Where |
|---|---|
| Room packs | state `im.ponies.room_emotes`, state key = pack id |
| Personal pack | account data `im.ponies.user_emotes` |
| Room packs used in every room | account data `im.ponies.emote_rooms` (`{rooms: {roomId: {stateKey: {}}}}`) |

Packs usable in a room, in priority order: personal pack, the room's own
packs (by state key), then packs enabled for all rooms. `:code:` resolves to
the first pack providing it; `:slug~code:` (the SDK's syntax) selects a
specific pack when a code is shadowed. Images without `usage` (and packs
without `usage`) count as both emoji and sticker.

## Files

- `pack_model.dart` – lenient parsing (unknown keys preserved on write,
  bounded), availability merge, `emote_rooms` helpers. Pure Dart.
- `emoticon_transform.dart` – outgoing `:code:` → `<img data-mx-emoticon>` in
  `formatted_body` (body keeps the codes; code, pre, links and reply
  fallbacks are skipped; edits convert `m.new_content` too).
- `pack_features.dart` / `matrix_packs.dart` – module interface and the SDK
  implementation (local state reads, fresh server read before every write,
  serialised writes, session checks after awaits, bounded thumbnail cache).
- `pack_image.dart`, `custom_reactions.dart` – image widgets, inline
  emoticons, MSC4027 reaction keys (`mxc://` key +
  `com.beeper.reaction.shortcode`).
- `packs_picker.dart` – emoji picker tabs, `:` suggestions, sticker picker.
- `pack_management.dart`, `pack_upload.dart` – room/personal pack screens and
  upload validation (PNG, GIF, WebP, JPEG by magic bytes; ≤ 2 MB;
  ≤ 4096 px, header-only decode).

## Where users find it

- Messages: custom emoji render inline; reactions with custom emoji show the
  image on the chip.
- Composer: emoji button → pack tabs; attachment menu → **Sticker**.
- Long-press a message → more reactions → pack tabs.
- Room details → **Emoji & stickers** (create/edit packs, "Use in all rooms").
- Settings → **Emoji & stickers** (personal pack, packs used everywhere).

Pack images are uploaded unencrypted (MSC2545 has no encrypted packs), so
every member's client can show them; stickers sent into encrypted rooms are
encrypted events that reference that unencrypted media, as in other clients.
