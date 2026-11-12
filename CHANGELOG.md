# Changelog

## Unreleased

### Faster, no more short freezes

- The room list no longer rebuilds every room after each sync (every message, and every 30 seconds when idle). On large accounts that rebuild re-read the whole direct-chat list and every push rule for each room and briefly froze the app. Now only the rooms a sync changed are updated.
- Photo galleries are resized in the background, and queued photos, videos and voice messages are saved without freezing the screen. Upload progress updates the screen about once per percent instead of every 64 KB.
- The chat list stays still while a room is open and catches up when you go back. Rows and message bubbles are kept when new messages move them, instead of being rebuilt with their pictures reloaded.
- Opening and closing the keyboard no longer makes every piece of text in the app redraw.
- After the app has been in the background, notifications are shown at most two at a time, in order per room.
- Device search reads each room's stored history once instead of on every launch, and writes in batches.
- More profile pictures and animated stickers stay cached, and room backgrounds are decoded at screen size.

### Chat pictures and app logos

- Long-press a chat → **Chat picture…** sets a picture only this phone shows for that chat. It's cropped to a 256 px square in the background and saved on the phone, so it appears at once and costs no network.
- Settings → Appearance → **App logos instead of letters** shows the app's logo (WhatsApp, Google Messages, Messenger, Instagram, Discord, LinkedIn, X, Xbox, Matrix) for chats with no picture. Detection uses bridge state, bridge bot names, bridged contact usernames, the room's canonical alias and its last sender; when there's no evidence the chat keeps its letter rather than a guessed Matrix logo.
- Long-press a chat → **Chat picture… → App logo…** overrides what was detected for that room, including "No logo". Both choices are saved on the phone.

### Link previews

- Links in messages show a small card with the page's title, description and image, under the message. Your homeserver fetches the preview, so your phone doesn't contact the site; tapping the card opens the link.
- Previews are remembered on the phone (newest 300 per account), so scrolling back over a link doesn't fetch it again, and are deleted on sign-out. A page that fails is retried after ten minutes rather than on every rebuild.
- In encrypted chats previews are off unless you turn on Settings → Media → **Preview links in encrypted chats**, because fetching one tells your homeserver which link was sent. Settings → Media → **Show link previews** turns them off everywhere.

### Message bubbles

- Bubbles are as wide as their message: a short message gets a short bubble, on the right for your own messages and after the sender's picture for others. Before, every bubble stretched to its widest because the time's right alignment took the full width.
- Your long messages stop about a quarter of the way in from the left, mirroring other people's bubbles on the right, and wrapped lines hug the longest line. On tablets bubbles are at most 520 points wide.

### Thumbnails saved on the device

- Chat and profile pictures and photo, sticker and video previews are now saved on the phone, so they show straight away after a restart and without a connection. Before, they were only kept in memory, and a picture that failed to load stayed as initials until the screen was rebuilt.
- Settings → Media → **Sync thumbnails** goes through every chat and saves its pictures and previews, with a progress bar, a Stop button and a summary of what was saved. It reads each chat's history stored on the device (about the last 100 events), skips invitations, runs four downloads at a time and can be run again to pick up failures.
- The same section shows how much space they use and can clear them. They're limited to 1 GB (oldest removed first), stay encrypted for encrypted chats, and are deleted when you sign out.

### Settings and home screen

- Settings is now a short menu. Every setting lives on one of these pages:
  - **Account:** profile and password (or your provider's account page), devices, link a new device, delete account.
  - **Notifications:** notifications on this device, message content and media previews, and the rules for direct chats, group chats, @room, invitations and calls.
  - **Appearance:** theme, text size, compact layout and the home screen.
  - **Chats:** double-tap reaction, haptic feedback, undo send, chat effects, custom emoji and stickers, note to self, saved messages and chat folders.
  - **Media:** when chats show media, and upload quality.
  - **Privacy:** screen lock, read receipts, typing notifications, invite avatars, blocked users and device search.
  - **Security:** your encryption identity, verifying with another device, key storage, recovery, room keys and reset. The menu row says when this device needs recovery or setup.
  - **Advanced:** the Element Call service and opening a Matrix link.
  - **About & help:** version, licences and reporting a problem.
- Sign out stays at the bottom of the main Settings screen.
- The other-devices list under Security is collapsed until you open it.
- Settings → Appearance → Home screen: choose the chat row style (Cards, List or Compact) and how much message preview to show (None, Small or Long).

### Notifications without Google or a push service

- Notifications are on by default after sign-in, with no opt-in. Parallax keeps its own connection to your homeserver in the background (a foreground service with a small “Parallax is connected” notification) and shows new messages itself, so no Firebase project, push gateway or UnifiedPush app is needed. It restarts after a reboot or an update.
- Settings → Notifications on this device can turn them off (remembered on the device) and asks Android to let Parallax run in the background.
- UnifiedPush is used automatically, with no opt-in, whenever a distributor app such as ntfy is installed, and the choice survives restarts. If the distributor's server has no Matrix gateway, Parallax uses the UnifiedPush project's public one, as Element X does. If UnifiedPush can't start, the built-in connection takes over. Your own Firebase project remains optional.

## 0.5.0 — Round 2

- Rich notifications, QR sign-in, Space admin, room key export/import, formatting toolbar, send later and undo send, saved messages, folders and note to self, live location, emoji and sticker packs, slash commands and chat effects. See `docs/element-x-parity.md`.

## 0.4.0 — Parallax

### Renamed and rethemed

- MatriXpress is now **Parallax**, with a new logo: three offset message bubbles in crimson, vermilion and amber, used for the launcher, adaptive and themed icons, splash screen and notification icon.
- The new default **Parallax** theme is red and orange on dark ink, with a light **Parallax Day** version. The theme can follow the system's light/dark setting.
- The app ID is now `net.samrussell.parallax`, so it installs as a separate app from the MatriXpress preview.
- OIDC sign-in now uses a redirect URI and client URI that matching authentication servers (MAS) accept.

### Element X v26.11.0 parity

Each area is built as its own feature module on a shared set of extension points ([architecture](docs/parity/architecture.md)):

- **Timeline:** formatted messages, pills, avatars and sender names, day separators, room-change summaries, read receipts, and @-mentions in the composer.
- **Reactions and message actions:** reactions work in encrypted rooms, with a full emoji picker, a "who reacted" view, forwarding, pinned messages, content reporting and moderator removal.
- **Polls and location:** polls (create, vote, end, edit, history) and static location sharing.
- **Element Call:** embedded calls, banners, call items in the timeline and in-app ringing.
- **Room administration:** start chat, create and join rooms, room info, per-room notifications, security and privacy, roles and permissions, members, join requests, and user profiles.
- **Home and settings:** room list filters and menu, a Spaces switcher, profile, notification settings, sessions, blocked users, app lock, and sign-out/deactivation.
- **Platform:** sharing into Parallax, matrix.to and `matrix:` links, UnifiedPush, and a "Mark as read" notification action.
- **Media:** voice waveforms, audio and video bubbles, stickers, animated images, the viewer and gallery, and optimised image uploads.
- **Threads and search:** a thread list and summaries, jumping to a specific message, and on-device search of encrypted history.
- **Security:** a post-sign-in identity check, identity-change warnings, key storage, recovery key change and identity reset.

### Other changes

- The repository moved to private Gitea; CI is now a Gitea Actions workflow.
- This preview has not been tested live. See the parity ledger for the acceptance tests still needed.

## 0.3.1 — room creation, search and Spaces fixes (folded in from PRs #12–#14)

- Private room creation with an explicit encryption choice, enabled by default.
- Definite pre-dispatch failures and recognised Matrix rejection codes release room-creation admission and show an accurate retriable error. Unknown/server/transport errors and post-create session changes retain the original uncertain request; no automatic retry or encryption downgrade occurs.
- Bounded visible acknowledgement and sync waits. A missing acknowledgement becomes uncertain after ten seconds without cancelling or replacing the original request. Session-owned request/room-ID retention survives inbox disposal; late acknowledgement cannot navigate an expired session. Ambiguous transport failures keep creation blocked rather than risking duplicate POSTs. This ownership is not persisted across process restart; use ordinary sync to check for a room before creating again.
- Deterministic SDK transport/widget coverage holds response headers, releases late acknowledgements, and exercises route disposal, account replacement and same-account logout/login. These are not live Android/two-client interoperability results.
- Isolate public-directory pagination by query generation. Query changes retire the old page guard/cursor immediately; stale success, error and cleanup cannot affect current results or admit duplicate page requests. Controlled widget regressions cover held obsolete requests, repeated terms/cursors, retry, debounce and route disposal; this is not live server or device acceptance.
- Bound Space child-room and directory join waits to 30 seconds with explicit stop/check-again controls, session-owned acknowledgement retention and processed-membership recovery. Cancelling a wait does not undo a server join; uncertain requests are not automatically repeated in the same session. Records do not survive process restart.
- This is one prerequisite for issue #5, not Space graph administration or live Element X acceptance. Invitation acceptance remains a separate SDK flow.

## 0.3.0 — messaging expansion preview

### Added

- OS-backed encrypted drafts scoped to the Matrix account and room, with ordered writes and visible storage failures.
- Rich attachment composition: gallery/camera/document staging, captions, removal/replacement, emoji selection and bounded Android keyboard images/GIFs/stickers.
- Permission-triggered voice recording with duration, local preview, discard/send and joined lifecycle cleanup.
- Full-screen image zoom and native audio/video playback, including background pause and player-before-file disposal.
- Durable composer/thread delivery states, stable device-scoped transaction IDs, explicit retry/discard, upload progress and cancellation. Interrupted work is not automatically resent after restart.
- User-directory search, favourite-room ordering and persistent appearance/media/read-receipt preferences.
- Thread root/reply views with decrypted paginated history and relation-aware sending.
- Nested Spaces browsing, refresh/pagination and room joins.
- Per-message receipt details showing exact latest read pointers.
- HTTPS provider discovery, legacy browser SSO and OIDC/PKCE, with session-preserving refresh and soft-logout re-authentication.
- Explicitly opted-in push configuration for an owned Firebase project and compatible HTTPS Matrix gateway. Push remains disabled without configuration and consent.

### Safety and reliability

- Preserved encrypted-send recipient approval and final HTTP encryption guards across queued text, thread and media paths.
- Fenced legacy plaintext media sends and final transport requests against logout/account replacement; actual streamed media bytes are capped.
- Kept fresh password discovery inside the validated authentication boundary and serialized session commits against logout.
- Distinguished missing secure-storage values from read failures; disabled automatic destructive storage reset.
- Retired acknowledged outbox payloads after durable removal and reserved lifecycle metadata space, so successful usage cannot exhaust pending capacity and near-limit saved work remains recoverable/discardable.
- Guarded startup, route ownership, deferred Spaces refreshes and stale async success/error/finally paths.
- Kept recovery setup conservative: no automatic destructive reset or recovery-key rotation.

### Preview boundaries

This is not a production-security or Element X parity release. Live two-client encryption, verification/recovery, provider sign-in, hardware media and push delivery remain acceptance work. Push requires the user's own infrastructure, including data-only FCM and registration binding support; no third-party gateway or service credentials are bundled. Calls, polls, location sharing, Space administration and precise search jump-to-event remain missing or limited.

Android previews retain the existing personal debug signing identity and increasing CI version codes. Do not uninstall an older preview to bypass an update error: that removes local session and encryption keys. See the README, parity ledger and security/privacy document for detailed limitations.
