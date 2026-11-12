# Saved module: Note to self, saved messages and chat folders

Telegram/WhatsApp-style personal organisation, synced across devices through
Matrix **account data**. Account data is not end-to-end encrypted, so these
records only ever hold room IDs, event IDs, timestamps and user-chosen folder
names — never message text.

| File | Purpose |
|---|---|
| `saved_hooks.dart` | Message action **Save / Remove from saved**; Settings → Saved section |
| `saved_models.dart` | Account-data models, caps, folder membership rules |
| `saved_features.dart` | `SavedFeatures` interface and `savedFeaturesOf` resolver |
| `matrix_saved_features.dart` | Matrix implementation (account data, room creation, event loading) |
| `note_to_self.dart` | Pinned Note to self row, "Start your note to self" prompt, open helper |
| `saved_messages_screen.dart` | Saved messages list (lazy loading, jump to message, swipe to remove, room filter) |
| `folder_tabs.dart` | Inbox folder tabs, tab options, **Add to folder…** sheet |
| `folder_editor_screen.dart` | New/Edit folder and the chat picker |
| `folders_screen.dart` | Settings → Saved → Chat folders (reorder, edit, delete) |
| `saved_settings_section.dart` | Settings → Saved |

## Account data

`net.samrusselltech.parallax.note_to_self`

```json
{"room_id": "!abc:example.org", "prompt_dismissed": true}
```

`net.samrusselltech.parallax.bookmarks` — newest first, at most 500 entries
and about 60 KB (the oldest are dropped).

```json
{"bookmarks": [{"room_id": "!abc:example.org", "event_id": "$ev", "saved_ts": 1762900000000}]}
```

`net.samrusselltech.parallax.folders` — ordered, at most 30 folders and
300 included/excluded chats per list.

```json
{"folders": [{"id": "f_x1y2", "name": "Work", "icon": "💼",
  "include_rooms": ["!a:example.org"], "exclude_rooms": [],
  "include": {"unread": false, "people": false, "groups": true,
              "favourites": false, "invites": false}}]}
```

Unknown fields (top level, per bookmark, per folder and inside `include`) are
preserved on every rewrite. Every write re-reads the server's current value
(`GET …/account_data/{type}`), applies the change and writes it back,
serialised per type on this device. Matrix has no compare-and-swap for
account data, so a simultaneous write on another device can still win.

## Note to self

On first use Parallax creates a room with `preset: private_chat`, the name
"Note to self", an `m.room.encryption` (Megolm) initial state and **no
invitees**, records it in the note-to-self account data and adds it under the
user's own ID in `m.direct` so other clients show it as a DM with yourself.
Creation fails closed when encryption is unavailable on the device. Opening is
single-flight per session; a recorded room that another device created is
adopted (`GET /joined_rooms`), and an earlier self-only DM is recovered before
another room is ever created. The room is pinned at the top of the chat list
with its own avatar and appears under the People filter.

## Folder membership

Spaces are never shown. A chat in `exclude_rooms` is never shown; a chat in
`include_rooms` always is; otherwise it is shown when it matches any selected
chat type (`people` = direct chats, `groups` = other rooms, `favourites`,
`unread`, `invites` — invitations appear only through `invites` or an explicit
inclusion). Taking a chat that matches a type out of a folder excludes it
explicitly. Folder tabs combine with the Element X filters and the Space
switcher. Each tab's badge counts unread chats and invitations in it.

## Limits

- Saved messages are loaded on demand (four at a time) from the open
  timeline, the local database or `GET /rooms/{id}/event/{id}` and decrypted
  by the SDK; previews of messages outside the open room do not apply later
  edits. Messages in rooms you have left cannot be shown (the room's keys and
  state are gone), only removed.
- Verified with unit, mock-homeserver and widget tests; not yet against a live
  homeserver or a second client.
