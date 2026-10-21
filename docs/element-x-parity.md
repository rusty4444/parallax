# MatriXpress / Element X parity ledger

MatriXpress is an independent Flutter client, not a port of the Element X Rust-SDK application. This ledger tracks user-visible parity without treating SDK API availability as a completed feature. Behaviour marked “implemented” has Flutter tests and static analysis, but not necessarily live two-device validation.

| Area | Status | Evidence / acceptance gate |
|---|---|---|
| Password login, persistent SDK session, room sync | Implemented; live sync unresolved | `lib/matrix_backend.dart`, `lib/room_sync_panel.dart`; install the APK over the prior build and verify a real account reaches joined rooms rather than SYNCING/SYNC ERROR/0 ROOMS. |
| Joined rooms, invites, directory, DM-by-ID | Implemented; live join/invite pending | `lib/inbox_screen.dart`, `lib/directory_screen.dart`. |
| Mark manually unread, leave a joined room | Implemented; live server confirmation pending | Long-press inbox row; backend calls SDK `Room.markUnread` and `Room.leave(waitForSync: true)`. |
| Timeline, pagination, replies, text edits, redactions, reactions and typing | Implemented; live encrypted-room round trip pending | `lib/room_screen.dart`, `lib/matrix_backend.dart`; widget and pure-model tests. Verify both sides see the same reply/edit/reaction/redaction and that typing expires. |
| Photo gallery, file/audio/video send and download | Partial | Photos are separate events; an interrupted batch can partially send. Test encrypted uploads and SAF save on a real device. Element X uses an atomic gallery send. |
| Recovery of an existing crypto identity and backed-up history | Implemented API/UI; unverified live | `lib/settings_screen.dart`; do not reset identity. Validate with a disposable two-device account. |
| Native OIDC / legacy SSO | Missing | Requires browser callback, PKCE/state/nonce validation, token refresh and a verified Android redirect. Prefer a claimed HTTPS App Link on an owned domain and stable release signing before accepting legacy SSO tokens. |
| Cross-device verification | Missing | Matrix SDK has SAS methods, but the client currently advertises no verification methods. Build and test the full incoming/outgoing state machine on two devices before using it for key trust. |
| Background push | Missing | Needs push provider and a secure push gateway; foreground sync alone is not a substitute. |
| Threads, in-room history navigation, polls, voice/video calls | Missing | SDK support is not equivalent to UI, lifecycle, notifications and media/VoIP interoperability. Element Call integration is a separate project. |
| Spaces, room/member moderation, notification preferences | Missing or limited | Need dedicated settings and server-authoritative state; avoid UI-only toggles. |

## Release gates

1. Build a release APK from the final source tree, inspect package/signature/ABI and cold-launch it on an emulator. This proves packaging, not authenticated sync.
2. On a disposable Matrix account: check a fresh and restarted inbox, invitation/join/leave, encrypted two-device text and media, recovery and history, and a server-side retry after network loss. Do not enter a recovery key or access token into an automation log.
3. Do not call this an Element X replacement or migrate a critical account until authentication, verification, push and calls are implemented and tested on supported devices.
