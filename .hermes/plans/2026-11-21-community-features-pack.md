# Community Most-Wanted Features Pack — Implementation Plan

Branch: `feat/community-features` (off `origin/main` `6f8e1d9`).
Rule: **Do NOT merge to `main`, push to `main`, tag, or publish to Play.** Deliver a verified arm64 test APK signed with the personal test key and a comprehensive testing checklist.

## Scope (All 22 features from the list)

### Phase 1 — Core Timeline & Room Polish
1. **Group sequential deleted messages**: Collapse ≥2 consecutive redacted messages (`minRemovedRun = 2`, Element Web parity) with sender attribution when uniform (`"You removed N messages"` / `"<Sender> removed N messages"`, else `"N removed messages"`), expandable on tap.
2. **Broadcast channels**: Room creation preset ("Broadcast channel — admins post, members read", `events_default: 50`), channel badge in room list/header, read-only composer banner when current user lacks permission to send messages.
3. **Per-chat themes that sync**: Sync per-room `BubbleColours` + built-in chat background preset/tint via Matrix room account data (`net.samrusselltech.parallax.room_theme`), seamlessly falling back to local custom photo files.
4. **Disappearing messages (`lib/features/retention/`)**: Read/write `m.room.retention` (`max_lifetime` ms) via `RoomEventFeatures`, Room Details UI + room timer banner, client-side timeline filtering of expired messages + optional own-expired redaction, explicit Matrix federation/screenshot limit disclosure.

### Phase 2 — Inbox & Privacy Features
5. **Per-chat biometric/PIN lock (`lib/features/chat_lock/`)**: Per-room lock state in `SecureValueStore` backed by `AppLockController`; hides message previews in Inbox & notifications (`"Locked chat"`), requires biometric/PIN unlock before opening.
6. **Message requests inbox (`lib/features/message_requests/`)**: Splits invites from unknown senders (no shared joined rooms) into a dedicated Message Requests pill & screen with safe avatar/media hiding, Accept, Decline, and Decline & Block.
7. **User status / Notes (`lib/features/user_status/`)**: Set/clear emoji + status line + optional expiry (`im.vector.user_status` / `org.matrix.msc3061` + presence `status_msg`), shown on Profile card, Inbox status chip, DM room headers, and User Profile screen.
8. **Stories / 24h status updates (`lib/features/stories/`)**: Opt-in Matrix-native Stories bar above Inbox backed by 24h-retention encrypted story rooms (`net.samrusselltech.parallax.story_room`), post text/photo stories, full-screen tap-through viewer with 24h client+retention expiry.

### Phase 3 — Message Actions & On-Device Intelligence
9. **Remind me about this message (`lib/features/reminders/`)**: Message action ("Remind me…") with presets & custom time, persisted per account, local notification + Settings → Chats → Reminders manager that jumps to the message.
10. **Chat export (`lib/features/chat_export/`)**: Room Details → Export chat (`.txt`, `.html`, `.zip` with media via pure-Dart ZIP builder), plaintext warning dialog, share/save.
11. **On-device catch-up summaries (`lib/features/catch_up/`)**: Strictly local extractive summary sheet/banner for unread bursts (mentions/questions, threads, polls, links/media, sender highlights) — zero network calls.
12. **On-device translation (`lib/features/translation/` + `TranslationTools.kt`)**: Google ML Kit On-Device Translation (`com.google.mlkit:translate` + `language-id`) via `parallax/translation` channel; explicit model-download consent; inline translated footer under message bubbles.
13. **Voice message transcription (`lib/features/transcription/` + `SpeechTools.kt`)**: Strictly offline on-device `SpeechRecognizer` / PCM pipe via `parallax/speech` channel; "Transcribe" button under voice/audio bubbles + cached local transcript.
14. **Round video messages (`lib/features/media/video_note.dart`)**: Record & send circular video notes (`net.samrusselltech.parallax.video_note: true` on standard `m.video`), circular inline video bubble with tap-to-play/mute.

### Phase 4 — Diagnostics, Support & Localisation
15. **Notification troubleshooting screen (`lib/features/notifications/notification_troubleshoot_screen.dart`)**: Live checklist (OS permission, delivery mode, UnifiedPush distributor & gateway, homeserver pushers, background sync & battery optimisation, test notification button).
16. **Rageshake / bug report with logs (`lib/features/bug_report/` + `ShakeDetector.kt`)**: Sanitised in-memory ring buffer (`DiagnosticLogBuffer`), shake-to-report toggle, in-app report composer with log preview & `.zip` diagnostic bundle export/share.
17. **App localisation (`lib/l10n/`)**: `flutter_localizations` + `ParallaxLocalizations` supporting System default + 10 languages (`en`, `es`, `fr`, `de`, `pt`, `it`, `nl`, `ja`, `zh`, `ru`), language selector in Settings → Appearance.

### Phase 5 — Calls & Widgets
18–21. **Full call integration (`lib/features/call/` + `CallIntegration.kt`)**:
   - Background/locked full-screen incoming call notification (`CallStyle` / Answer & Decline actions).
   - Android self-managed `ConnectionService` (`ParallaxConnectionService`) for system call state & Bluetooth buttons.
   - Picture-in-Picture (`enterPictureInPictureMode` + auto-PiP when leaving `CallScreen` mid-call).
   - Native audio routing picker (Speaker, Earpiece, Bluetooth, Wired headset) in `CallScreen`.
   - Shareable call links + Screen sharing support where platform WebView supports `getDisplayMedia`.
   - Persistent voice rooms ("Drop-in audio" rooms with live participant banner & one-tap audio join).
22. **Widgets / Integrations / Matrix Apps (`lib/features/widgets_host/`)**:
   - Read/add/remove room state widgets (`im.vector.modular.widgets` / `m.widget`) and personal account-data widgets (`m.widgets`).
   - Interactive sandboxed WebView Widget API host with explicit capability & OpenID consent per widget origin.

### Phase 6 — Multiple Accounts
23. **Multiple accounts (`lib/features/accounts/`)**:
   - Multi-account slot registry (`default` preserves `parallax.db` / `'Parallax'`; added accounts get `parallax_acct_<id>.db` / `'Parallax:<id>'`).
   - Account switcher sheet (Inbox header & Settings → Account), add-account flow with cancel-back-to-previous-account, switch active session, sign out / remove individual account.
