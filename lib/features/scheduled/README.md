# Scheduled messages and Undo send

Round-2 module: **Send later** (MSC4140 delayed events) and **Undo send**.

## Send later

- **Entry point:** long-press the composer's send button → "Send later…"
  (`scheduledSendOptions`). The composer workstream renders the menu from
  `composerSendOptionsFor`.
- **Picker** (`send_later_sheet.dart`): In 30 minutes, Tonight 6 pm (until
  5:55 pm), Tomorrow 9 am, Monday 9 am (skipped when Monday is tomorrow),
  or a custom date and time. Calendar presets use local date fields, never
  24-hour additions, so they keep their wall-clock time across daylight
  saving. Presets beyond the homeserver's advertised maximum are disabled.
- **Composition:** the draft is trimmed and composed exactly like a normal
  send — `composeTextMessage` (markdown, `/me`, mentions) then
  `transformOutgoingText` — plus an `m.in_reply_to` or `m.thread` relation.
  Reply fallbacks are omitted (removed from the spec by MSC2781). Edits
  can't be scheduled.
- **Sending:** `MatrixBackend.sendRoomEventDelayed` (next to
  `sendRoomEvent`) applies the same session ownership, recipient trust
  approval, fail-closed encryption and final HTTP guard. Encrypted rooms are
  encrypted **now** with `encryptGroupMessagePayload` inside the protected
  send zone; anything other than a Megolm payload fails closed before any
  request. The request is
  `PUT /_matrix/client/v3/rooms/{roomId}/send/{type}/{txnId}?org.matrix.msc4140.delay=<ms>`
  and returns a `delay_id`. People who join after scheduling never receive
  the room key, so they can't read it — the picker and list say so.
- **Capability:** `m.delayed_events` / `org.matrix.msc4140.delayed_events`
  capability (`max_delay_ms`, `max_scheduled`; an explicit 0 disables), then
  `/versions` `unstable_features["org.matrix.msc4140"]` (Synapse < 1.157).
  Unsupported → "Your homeserver doesn't support scheduled messages."
  Delay-too-large errors are recognised in all known shapes
  (`M_DELAY_TOO_LARGE`, `ORG.MATRIX.MSC4140_DELAY_TOO_LARGE`,
  `M_MAX_DELAY_EXCEEDED`, `M_UNKNOWN` + `org.matrix.msc4140.errcode`), with
  `max_delay` when given. A server that ignores the delay and returns an
  `event_id` is reported as sent, not retried.
- **List:** the room banner "1 scheduled message" opens a sheet with Send
  now, Reschedule and Cancel. Management uses the SDK's
  `manageDelayedEvent`. Reschedule schedules the new copy first, then
  cancels the original (no data loss); if the original was already sent it
  withdraws the copy instead of sending twice.
- **Local records:** the server list only holds ciphertext for encrypted
  rooms, so the plaintext content, room and time are kept in platform
  secure storage, keyed by account (homeserver + user, SHA-256 in the key)
  and `delay_id` (`scheduled_store.dart`). They are reconciled with the
  server list: records the server no longer has are dropped only when the
  list was complete; a failed or capped list never deletes. State delayed
  events (for example Element Call's) and non-message types are never shown.

### Not shown: encrypted delayed events without a local record

Encrypted server entries with no local record (scheduled on another
device, or after reinstalling) are hidden. Their inner type is unknown, and
decrypting them locally with SDK 14.1 would record the Megolm message index
against a synthetic event ID, after which the real event fails to decrypt
("channel corrupted"). They still send at their time.

## Undo send

- **Setting:** Settings → Chats → Sending → Undo send: Off / 5 s / 10 s / 20 s
  (default 5 s), in shared preferences (`UndoSendPreferences`).
- **Outbox:** `MessageOutbox` holds newly queued main-timeline text and
  media (queued, with an in-memory deadline) before transmission. `undo`
  withdraws a held record durably and returns it; the room's pending panel
  shows "Sending in N s · Undo" and puts the text (or caption) back in the
  composer, restoring the reply when its target is loaded. Edits, retries
  and thread replies (the thread screen has no undo surface) skip the hold.
- **Leaving the room** doesn't affect held sends: the outbox belongs to the
  backend, so they send at their deadline.
- **Backgrounding:** held sends are released **immediately** when the app is
  hidden, paused or detached (`watchAppBackground`), because Android may
  freeze or kill a background process before the grace period ends.
- **Restart:** holds are process-local. A record held when the process died
  is restored like any interrupted send — "Not sent. Retry or discard." with
  the same transaction ID — never replayed automatically.
- Queued transmissions are serialised (`MatrixBackend._transmitQueued`), so
  several held sends falling due together go out one after another instead
  of failing as "another secure operation is running".

## Verification limits

Request shapes, guards, error mapping, reconciliation, presets and widgets
are covered by tests with fakes (`test/scheduled_*`). Live MSC4140
behaviour (Synapse/MAS limits, delivery at the scheduled time, decryption
by other members) needs a real homeserver and a second client.
