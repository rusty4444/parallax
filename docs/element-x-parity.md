# Parallax / Element X parity ledger

Baseline: [Element X Android v26.11.0](https://github.com/element-hq/element-x-android/releases/tag/v26.11.0) (6 November 2026). I checked it against that release's source tree and against the features its `FeatureFlags.kt` turns on by default. Parallax is an independent Flutter client built on Matrix Dart SDK 14.1.0, not a port of Element X.

**Status key**
- **Built:** implemented in Parallax with automated tests.
- **Partial:** some of Element X's behaviour is there; the gap is noted in the row.
- **Missing:** not implemented.
- **Off in Element X:** behind a flag that is off by default in v26.11.0, so not needed for parity.

**Nothing below has been checked against a live homeserver, a second Matrix client or a physical phone.** Every row still needs that acceptance test before you rely on it, so read "Built" as "ready to test". The module boundaries are described in [parity/architecture.md](parity/architecture.md).

## Sign-in and security

| Area | Status | Notes |
|---|---|---|
| Account provider choice, password, OIDC/MAS, legacy SSO | Built | `lib/login_screen.dart`, `lib/matrix_auth_service.dart`. The OIDC redirect is now `net.samrusselltech.parallax:/auth` with an `https://samrusselltech.net/` client URI. The old redirect had a host part, which MAS refuses. |
| Confirm identity after sign-in (another device, recovery key, reset) | Built | `lib/features/security/security_gate.dart`. Element X has no skip; Parallax offers "Later", with a warning, for one app session. |
| SAS emoji verification, both directions | Built | `lib/security_overlay.dart` |
| Identity-change warnings (reset, verified-user violation) | Partial | Only resets this device has observed are detected. Anything else falls back to the existing prompt before sending. |
| Key storage on/off, recovery setup and change, reset identity | Built | Changing the recovery key needs the current key, because SDK 14.1.0 doesn't keep the master key on the device. Turning key storage off keeps recovery. |
| Export/import room keys | Built | Settings → Security → Room keys. Pure-Dart codec in the Element file format; Element Web's test vectors decrypt. |
| Sign in by scanning a QR code (MSC4108) | Built | `lib/features/qr_login/`. The secure channel matches vodozemac 0.11.2 test vectors. Full key import needs secret storage on the account. Parallax can also show a QR to link a new device (Settings → Account → Devices); that side is off in Element X. |
| App lock (PIN, biometrics) | Built | `lib/features/home/app_lock/`. Also covers incoming verification prompts. |
| Multiple accounts | Off in Element X | |

## Room list and Spaces

| Area | Status | Notes |
|---|---|---|
| Filters: unread, people, rooms, favourites, low priority, invites | Built | `lib/features/home/room_list_filters.dart` |
| Unread and mention badges, muted indicator, sender in the preview | Built | |
| Room menu: read/unread, favourite, low priority, mute, copy link, leave | Built | `room_list_menu.dart` |
| Invites: accept, decline, decline and block (with optional report) | Built | |
| Spaces filter and browser, join and leave | Built | `space_switcher.dart`, `lib/space_browser_screen.dart` |
| Space administration (add rooms, space settings) | Built | `lib/features/spaces_admin/`: create Spaces, add/remove/order rooms, Space settings, leave with room choice. Reordering is move up/down, not drag and drop. |
| Message search (on-device index of encrypted history) | Built | `lib/features/threads/`. An FTS5 index kept in app storage and deleted on sign-out. Unencrypted rooms are searched on the server. |

## Timeline and composer

| Area | Status | Notes |
|---|---|---|
| Formatted HTML, links, user/room pills, emotes, notices | Built | `lib/features/rich_timeline/`. The HTML renderer uses an allow-list. |
| Sender avatars and names, day separators, readable room changes | Built | Room changes collapse into "N room changes", as in Element X. |
| Read receipts under messages; typing indicators | Built | In encrypted rooms only the typing notification is sent, without starting the key sharing the SDK normally does. |
| Reactions (including encrypted rooms), emoji picker, who reacted | Built | SDK 14.1.0 sends reactions unencrypted. Parallax adds a marker so they go through the guarded encrypted path. Not yet tested with Element X. |
| Replies, edits, deleting, moderator removal with a reason | Built | |
| Threads: list, summaries, thread view | Built | Element X's thread timeline is **off by default**; Parallax has it. A new thread's summary count only updates when the room reloads. |
| Forwarding, including choosing several messages | Built | Up to 10 rooms (Element X allows 5). |
| Pinned messages: banner, list, pin/unpin | Built | Opening a pinned message shows it in a sheet instead of scrolling to it. |
| Polls: create, vote, end, edit, history | Built | `lib/features/polls/` |
| Sharing and viewing a static location | Built | OpenStreetMap tiles. |
| Voice messages with waveforms; audio, video, files, stickers, captions | Built | `lib/features/media/`. If the app restarts before a voice message sends, the waveform is lost. |
| Media viewer (swipe, share, save, info) and room media gallery | Built | |
| Optimised image uploads | Built | Videos over 20 MB or above 1080p are compressed to 720p on the device (Media3 Transformer) and sent with a poster frame, size and duration. Per-upload quality is **off in Element X**. |
| Copy text, copy link, view source, report content | Built | |
| Jump to a message (search results, permalinks) | Partial | The room opens on the message and marks it, but doesn't scroll or animate to it. |
| @-mention suggestions, markdown, `/me` | Built | |
| Rich-text (WYSIWYG) editor | Partial | Element X's formatting toolbar with live markdown styling in the field (`lib/features/composer/`); not a true WYSIWYG editor. |
| Drafts, and an outbox with retry | Built | Parallax extra. |
| Jump to first unread, slash commands, multi-image gallery messages | Off in Element X | |

## Room details and administration

| Area | Status | Notes |
|---|---|---|
| Start chat; create a room (private, ask to join or public); join by address; request to join | Built | `lib/features/rooms_admin/` |
| Room info: edit name, topic and avatar; share; favourite | Built | |
| Per-room notifications (all, mentions, mute) | Built | Stored as push rules, the way Element X does it. |
| Security and privacy: join rule, address, directory listing, encryption, history visibility | Built | Includes the authorised-Spaces list for restricted rooms. |
| Roles and permissions, members, bans, join requests | Built | |
| Report room; leave room (with a last-admin warning) | Built | |
| User profile: message, verify, block/unblock, moderation | Built | |

## Calls

| Area | Status | Notes |
|---|---|---|
| Element Call (embedded widget): start/join, banners, timeline items | Built | `lib/features/call/`. Loads the hosted call.element.io, where Element X bundles its own copy; the URL can be overridden. **Needs a MatrixRTC/LiveKit homeserver and a live two-device test.** |
| Ringing for direct-chat calls | Built | Only rings while Parallax is open. |
| Background ringing, Android call integration, picture-in-picture, audio routing | Missing | |
| Native MatrixRTC calls | Off in Element X | |

## Notifications and platform

| Area | Status | Notes |
|---|---|---|
| Notifications with the app closed | Built | On by default with no opt-in: UnifiedPush when a distributor such as ntfy is installed (gateway discovery with the public-gateway fallback, as in Element X's F-Droid build), otherwise Parallax's own sync in a foreground service. Element X's Play build uses Element's Firebase project and push gateway instead. Your own Firebase project stays optional and opt-in. Not yet tested on a physical phone. |
| Global notification settings (direct chats, groups, @room, invites, calls) | Built | |
| Sender and message text in notifications; inline reply | Built | `lib/features/notifications/`: fetched and decrypted on the device, so the push provider sees only IDs. Can be turned off in Settings. A reply sent while the app is closed waits until it next opens. |
| Notification troubleshooting screen | Missing | |
| Sharing into Parallax; matrix.to and `matrix:` links | Built | Recent chats are suggested in Android's share menu (`lib/features/platform/share_shortcuts.dart`), except while a screen lock PIN is set, as in Element X. Element X publishes a chat when you send to it; Parallax mirrors the top of the chat list. Checked on an Android 15 emulator, not yet on a Samsung phone. |

## Account and settings

| Area | Status | Notes |
|---|---|---|
| Profile, devices and sessions, blocked users, manage account / change password | Built | Uses the MAS account page when the homeserver advertises one. |
| Sign out with a backup warning; deactivate account | Built | |
| Theme (match system, light, dark), media previews, read receipts, typing | Built | Parallax palettes, red and orange by default. |
| About, licences, report a problem | Partial | Reporting a problem opens a Gitea issue; there's no in-app bug report with logs (rageshake). |
| User status | Missing | Element X shows it only when the server supports it. |
| Analytics opt-in | Not applicable | Parallax has no analytics. |

## Parallax extras (not in Element X)

Room backgrounds, photo-grid bubbles, avatar collages, double-tap heart, a durable outbox with retry/cancel, server message search, a choice of palettes, and "Ask to join" room creation plus the thread timeline (both off by default in Element X).

Round 2 added, from other messaging apps: send later (MSC4140 delayed events; needs homeserver support) and undo send; Note to self, saved messages and chat folders (account data); live location sharing (MSC3672 beacons); custom emoji and sticker packs (MSC2545); slash commands and Element Web chat effects.

Document previews: PDF, Word, Excel, PowerPoint, Markdown, CSV and text files open in the media viewer and show their first lines (for a PDF, the top of its first page) in the timeline (`lib/features/file_preview/`). PDF pages are drawn by Android's `PdfRenderer` in an isolated process (`PdfRenderService.kt`, checked on a device by `integration_test/pdf_tools_test.dart` and `pdf_preview_test.dart`). Element X shows a file card and hands the file to another app.

## Room-creation failure contract

Only app-owned `RoomCreationFailure` outcomes release create admission:

- `notSubmitted`: the backend rejects an empty/overlong name, missing/unavailable/signed-out session, logout/disposal, or unavailable requested encryption **before** calling the SDK create operation. The user may correct the choice and submit again; encryption never changes automatically.
- `rejected`: the SDK create operation returns a recognised refusal code: `M_FORBIDDEN`, `M_UNAUTHORIZED`, `M_UNKNOWN_TOKEN`, `M_MISSING_TOKEN`, `M_USER_DEACTIVATED`, `M_GUEST_ACCESS_FORBIDDEN`, `M_LIMIT_EXCEEDED`, `M_RESOURCE_LIMIT_EXCEEDED`, `M_BAD_JSON`, `M_NOT_JSON`, `M_MISSING_PARAM`, `M_INVALID_PARAM`, `M_UNSUPPORTED_ROOM_VERSION`, `M_ROOM_IN_USE`, or `M_EXCLUSIVE`. Show a sanitised error and permit another explicit submission, never automatic resend. The SDK does not preserve HTTP status on generated API exceptions, so other codes are deliberately not assumed safe.
- Every other error, including arbitrary `StateError`/`ArgumentError`, `M_UNKNOWN`, generic server errors, malformed acknowledgements and transport loss, retains the original future and admission lock as uncertain. In particular, the session-change check **after** a successful create is not evidence of rejection. A pending-header deadline is presentation only, not cancellation or permission to resend.

## Apple platforms (iPhone, iPad, iPhone Fold, Mac)

The `feat/apple-port` branch runs the same Dart codebase on iOS, iPadOS and macOS. Every "Built" row above applies to the Apple platforms too unless listed here; **none of it has been checked against a live homeserver, a second client or a physical Apple device yet.** The Android rows remain the reference.

| Area | Status on Apple | Notes |
|---|---|---|
| Adaptive layout (iPad, unfolded iPhone Fold, Mac) | Built | Master-detail above 600 pt shortest side; fold/unfold and Split View transitions keep the open chat (`lib/features/home/adaptive_layout.dart`, `test/adaptive_layout_test.dart`). iPhone and the Fold's outer screen keep the phone flow. |
| E2EE (vodozemac) | Built, unverified | `flutter_vodozemac` is an FFI plugin for iOS and macOS; Rust targets `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-apple-darwin`. Needs a two-device live test. |
| Database | Built | sqflite on iOS; sqlite3 via FFI on macOS (`apple_bootstrap.dart`). Same `SafeMatrixDatabase` guards. |
| PDF previews | Built | PDFium through `pdfx` in-process (`pdfx_pdf_tools.dart`), same timeouts/pixel caps as Android; no isolated process (see security doc). |
| Video probe/compress/frames | Built, unverified | AVFoundation behind the same `parallax/video` channel (`apple/ParallaxApple.swift`); 720p-class compression with the caller's bitrate. |
| Element Call | Built, unverified | WKWebView on iOS and macOS (`webview_flutter_wkwebview`), inline media without a user gesture, camera/mic permission requests mapped to the same grant checks. |
| Notifications | Partial | Built-in delivery while the app runs, with Reply/Mark as read/copy actions and image attachments (`notification_renderer.dart` Darwin details). No persistent background connection, no APNs/Firebase or UnifiedPush delivery yet: nothing arrives while fully closed. |
| Secure window | Partial | iOS app-switcher overlay; macOS window capture/sharing exclusion. iOS cannot block screenshots while active. |
| Share into Parallax | Partial | iOS share extension hands items to the app (same caps, explicit Send). Android Direct Share suggestions have no iOS equivalent; macOS has no share-in. |
| Links / OIDC callback | Built, unverified | `matrix:` scheme and `net.samrusselltech.parallax:/auth` registered in both runners; same Dart validation. Universal links need a hosted `apple-app-site-association` (not set up). |
| Runtime permissions | Built | Camera/microphone via AVCaptureDevice behind the same `parallax/permissions` channel; location/photos/Face ID through the plugins' own prompts. |
| QR sign-in, app lock, voice, location, packs, threads, polls, spaces, search | Built | Shared code; `mobile_scanner`, `local_auth`, `record`, `geolocator` all support iOS/macOS. Device acceptance still required. |

## Acceptance tests before claiming parity

1. On disposable accounts, with Parallax and Element X side by side, test:
   - sign-in by password, OIDC/MAS and SSO;
   - confirming identity on a new device, recovery and reset;
   - encrypted messages, reactions, polls, location, voice and media;
   - pins, threads, forwarding and search.
2. Element Call against a MatrixRTC homeserver: 1:1 and group calls, with ringing in both directions (Parallax to Element X and back).
3. UnifiedPush through ntfy with the app killed, and Firebase push.
4. Install, update and cold start on a physical arm64 phone.
