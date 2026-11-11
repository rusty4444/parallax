# Ideas from other messaging apps

Features that WhatsApp, Messenger, Instagram, Telegram, Signal, iMessage,
Discord and Slack have and that Element X does not. Each entry notes where it
comes from, how it would work on Matrix, and the rough effort. "Native" means
there is a Matrix spec or MSC, so other clients can understand it; "Parallax
only" means it works only between Parallax users or on this device.

## Strong candidates

| Idea | Seen in | Matrix fit | Effort |
|---|---|---|---|
| **Scheduled messages ("Send later")** | Telegram, iMessage, Gmail-style | Native: MSC4140 delayed events (already used by Element Call; SDK 14.1 has helpers). The server sends it, so the phone can be off. Needs homeserver support. | Small–medium |
| **Undo send** (5–10 s grace period) | Gmail, iMessage | Parallax only: hold the outbox item before transmission; cancel is local. | Small |
| **Disappearing messages** per chat | WhatsApp, Signal, Messenger vanish mode | Partly native: `m.room.retention` (MSC1763) for server purge plus client-side expiry; MSC2228 self-destructing events is still a proposal. Make the guarantee limits clear (other clients and screenshots). | Medium |
| **Live location sharing** | WhatsApp, Messenger, iMessage "Check In" | Native: MSC3488/MSC3489 beacons (Element Web and Element Classic render them). Builds on the static location work. | Medium |
| **Custom emoji and sticker packs** | Telegram, Discord, Slack | Native: MSC2545 image packs (FluffyChat, Cinny, Nheko support them). Room and personal packs, picker integration. | Medium |
| **Chat effects** (confetti, fireworks, hearts, snow) | iMessage, Messenger | Native-ish: Element Web's `nic.custom.*` effect msgtypes, so effects interoperate with Element Web. | Small |
| **Note to self / Saved messages** | Telegram, Signal, WhatsApp | Native: a DM room with only yourself, pinned at the top of the list. | Small |
| **Bookmarks / starred messages** | WhatsApp, Slack, Telegram | Native-ish: store event references in account data so they sync across your devices; one Saved screen. | Small |
| **Chat folders** (custom tabs such as Work and Family) | Telegram, WhatsApp lists | Native-ish: room tags in account data; a folder bar above the room list. | Small–medium |
| **Per-chat lock** (biometric to open a chat) | WhatsApp Chat Lock, Telegram | Parallax only: extends the app-lock PIN/biometric to individual rooms, and hides their previews. | Small |
| **Message requests** (unknown senders go to a separate inbox) | Instagram, Messenger, Signal | Parallax only: split invites from people you share no rooms with; preview safely with avatars hidden; accept, decline or block. | Small–medium |
| **On-device translation** | Telegram, Instagram | Parallax only: ML Kit on-device translation per message, so no text leaves the phone. | Medium |
| **Voice message transcription** | WhatsApp, iMessage, Telegram | Parallax only: on-device speech-to-text (Android SpeechRecognizer offline, or Whisper). | Medium |
| **Remind me about this message** | Slack, Gmail | Parallax only: local scheduled notification that opens the message. | Small |
| **Per-chat themes that sync** (colour, bubble style, background) | Messenger, Instagram, Telegram | Native-ish: extend Parallax's room backgrounds and store the choice in room account data so it follows you to other devices. | Small–medium |
| **Status / Notes** (short status line or emoji over your avatar) | Instagram Notes, WhatsApp About, Slack status | Native where the server supports Element X's new user status; otherwise profile fields. | Small |

## Worth considering

| Idea | Seen in | Matrix fit | Effort |
|---|---|---|---|
| Stories (24-hour photo and video updates) | WhatsApp Status, Instagram, Messenger | Parallax only (no spec): a private "stories" room per user with client-side expiry and retention. Big product decision. | Large |
| Broadcast channels (one-to-many, read-only) | WhatsApp Channels, Telegram channels | Native: rooms whose power levels let only admins post; channel styling in the list. | Small–medium |
| Persistent voice rooms ("drop in" audio) | Discord voice channels, Slack huddles | Native: an always-on Element Call session in a room. Builds on the call module. | Medium |
| Shareable call links | WhatsApp, Google Meet | Native: Element Call link to a dedicated room. | Small |
| GIF search (Tenor/Giphy) | Every major app | Third-party API; route requests through a privacy proxy or make it opt-in. | Small |
| Round video messages | Telegram | Native: `m.video` with a flag for circular rendering; record in-app. | Medium |
| Catch-up summaries of long unread chats | Slack AI, Messenger | Parallax only: on-device model only, strictly opt-in, never sent to a cloud service. | Large |
| Silent send (no notification) | Telegram | No spec. Could use MSC push hints, or a convention other clients ignore. | Small but non-interoperable |
| Screen sharing in calls | WhatsApp, Discord, Messenger | Element Call supports it on the web; Android WebView capture needs native work. | Large |
| Incognito keyboard and screen security | Signal | Parallax only: no-learning keyboard flag on composers, plus `FLAG_SECURE` for the whole app. | Small |
| Chat export (text/HTML/zip with media) | WhatsApp, Telegram | Parallax only: export decrypted history to a user-chosen file. Warn that the export is plaintext. | Medium |

## Suggested first batch

1. Scheduled messages and undo send. Both come out of the outbox and delayed-event work, and nothing else in the Matrix ecosystem does them well on mobile.
2. Note to self, bookmarks and chat folders. Small, popular and synced through account data.
3. Live location, custom emoji/sticker packs and chat effects. All three have Matrix interop with Element Web, FluffyChat and Cinny.
4. Per-chat lock and message requests. Both use the app-lock and decline-and-block work.
