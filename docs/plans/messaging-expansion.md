# MatriXpress messaging expansion implementation plan

> **For Hermes:** Use subagent-driven-development to implement this plan, with spec review before quality review and an integration review before publishing.

**Goal:** Implement every NeonMatrix-inspired feature proposed to Sam in MatriXpress, preserve its stronger encryption/trust invariants, and publish a verified GitHub Android preview release.

**Architecture:** Preserve ChatBackend and current Flutter/ChangeNotifier styling. Add a reviewed optional MessagingFeatures interface so existing test backends remain valid. Isolate platform services and fault-testable stores; parent owns integration. No donor source copying is required. Never replace the guarded crypto bootstrap with NeonMatrix's unsafe rotation code.

**Tech stack:** Flutter 3.44.0/Dart 3.12.0, matrix 14.1.0, flutter_vodozemac 0.8.1; existing HTTP, SQLite, image/file pickers; new secure_storage, video_player, audioplayers, record, web_auth, Firebase/local-notification packages resolved against this SDK.

## Prerequisites and fixed decisions

- Baseline commit cdcc119; main matches origin/main. Work on feat/neon-inspired-messaging. Baseline analysis and 78 tests passed.
- User explicitly approved opt-in push configuration only, disabled until their own Firebase project and Matrix gateway are supplied. No NeonMatrix service reuse and no live push claims.
- New contracts: lib/messaging_features.dart and lib/secure_store.dart, compiled and undergoing independent review before delegation.
- All app source edits use patch/write_file. No secrets read/printed. No push until verified; user has explicitly authorised GitHub release.
- Verification commands use absolute /opt/homebrew/bin/flutter and dart. Do not change global Flutter. SDK14.1 source at ~/.pub-cache/hosted/pub.dev/matrix-14.1.0/lib is authoritative.
- Each implementation begins with a focused failing regression test, implements the smallest real path, then runs its narrow tests. Parent coordinates Flutter test invocations to avoid dependency/compile races.

## Work packages and ownership

### 1. Encrypted drafts

Create lib/message_draft_store.dart and test/message_draft_store_test.dart. Use SecureValueStore read/write/delete. Public MessageDraftStore({SecureValueStore? storage}); Future<String> read(String accountKey,String roomId); Future<void> write(String accountKey,String roomId,String text); Future<void> clearAccount(String accountKey). Prefer independent scoped keys and serialize writes across instances addressing the same key. A failed read must never imply missing data; queued updates must not destroy unread drafts. Test account/room isolation, ordering, storage read/write failures and recreation. Parent integrates loading, debounce, flush and successful-send clearing in room_screen.dart; edit text is not persisted as a normal draft.

### 2. Full-screen media

Create lib/media_viewer.dart and test/media_viewer_test.dart. API Future<void> openMediaViewer(BuildContext context,{required ChatBackend backend,required String roomId,required String eventId}); download original via backend.loadAttachment (already bounded); inspect MIME. Images use zoomable InteractiveViewer; audio/video use local native player with play/pause/seek. Temporary media file has single ownership and cleanup after player disposal; pause on app background, cancel stale loading on route close/account replacement, never leave plaintext temporary file after successful cleanup. Inject loaders/player/file ownership for tests. Parent connects taps in MessageImage and attachment rows.

### 3. Composer and voice

Create lib/rich_message_composer.dart and test/rich_message_composer_test.dart. A reusable widget receives TextEditingController, sending flag, Future<void> Function(String text, MediaSelection? media) onSend, VoidCallback? onCancel, and ValueChanged<String>? onChanged. Support staged image/file/camera selection with 20MB check before bytes; caption uses the existing controller; remove/replace; built-in emoji sheet; Android ContentInsertionConfiguration supported image MIME with actual-byte bounds. Voice recording must be permission-triggered, show duration and preview, stop/discard and clean temp file on close/background. Single-flight selection/send; keep state on rejected future and clear only after successful acknowledgement, never erase newer typing/selection. Dependencies present; don't edit room_screen.dart or backend. Parent handles captured reply/thread and secure drafts.

### 4. Durable outbox

Create lib/message_outbox.dart and test/message_outbox_test.dart. Public OutboxRecord includes stable transaction ID/accountKey/roomId/body or MediaSelection/caption/reply/edit/thread IDs/timestamp/state/progress/error. MessageOutbox with injected SecureValueStore, account ownership callback and send callback; restore(account), enqueue text/media, retry, discard, cancel, read records, onChanged. Persist before attempting network and preserve same txid across retries/restart. Never auto-replay key shares outside existing trust/send guards. Retryable work requires current session; stale completion cannot write into another account. Bound payloads and total queue; validate corrupt entries fail visibly, don't replace unread store on read error. Keep failed items until explicit successful acknowledgement/discard. Inject cancellation ownership. Parent backend adapter performs actual guarded sending and exposes PendingSend.

### 5. Authentication

Create lib/matrix_auth_service.dart and test/matrix_auth_service_test.dart; modify only lib/login_screen.dart for provider discovery/browser UI. MatrixAuthService is passed the real Client and ownership checks; expose discovery(String)->ProviderDiscovery, browserLogin(discovery,{oidc}), refresh and password reauth. Use validated HTTPS discovery, app callback net.samrussell.matrixpress://auth, cryptographic SSO state, SDK OIDC PKCE/state. Inject browser callback for tests. Validate effective homeserver/token endpoints before credentials; pin account/device/generation through awaits. Failures in metadata/network must not surface as destructive MatrixException to SDK. Preserve device via reauth rather than Client.login wiping old state. Parent backend delegates through service and registers onSoftLogout, login methods and lifecycle. Do not modify Android manifest (parent owns). Failed refresh must not poison initialization. Existing password login form/tests must remain functional.

### 6. Directory, threads, Spaces, receipt/favourite service and screens

Create lib/matrix_room_features.dart and targeted tests; lib/user_directory_screen.dart, lib/space_browser_screen.dart, lib/thread_screen.dart with widget tests. Service accepts Client, current ownership callback and event mapper supplied by parent so ChatEntry conversion remains one source. Implement user directory search, Space hierarchy pagination, thread aggregation/history, read-receipt names/times, favourites through SDK account data. UI takes ChatBackend that implements MessagingFeatures. Generations invalidate search and hierarchy pages on refresh/clear; old success/error/finally can't overwrite new state. Thread sends call queueMessage(threadRootId: root); no main-timeline relation-only duplication. Parent integrates navigation and adapters in backend/inbox/room screens.

### 7. Owned, opt-in push

Create lib/push_notifications.dart, lib/push_settings_screen.dart and tests. Default disabled. Build/runtime config requires own HTTPS Matrix gateway and matching FirebaseOptions/app ID. Store preference only after explicit user choice; no contacts/registration/FCM auto-init until enabled AND fully configured. Register event_id_only pushers, remove/deactivate on disable/logout and token change. Tie notification payload/navigation to account/device registration generation; stale payloads are discarded. Missing config shows actionable setup fields/docs, not a successful state. Inject Firebase/pusher drivers for tests; native options must not be required for a clean build. Parent integrates app startup, background entrypoint, navigation, settings and manifest/desugaring. User accepted no live push gate until infrastructure supplied.

### 8. Parent-owned integration

Modify lib/chat_backend.dart only as needed without breaking default fakes, lib/matrix_backend.dart to implement MessagingFeatures and service adapters, lib/encrypted_media.dart to pass stable txid/caption/reply/thread and cancellation/progress while preserving pre-encryption and final guard. Add feature metadata to ChatEntry through optional fields; retain current reply/edit/redaction behaviour. Own room_screen.dart, inbox_screen.dart, message_image.dart, settings_screen.dart, main.dart, Android config and manifests, pubspec/lock/docs. Implement appearance controls in separate lib/appearance_preferences.dart (persist text scale, compact layout, preview preference, receipts preference) and settings. Use secure draft integration and one send owner. Show pending states/progress with Retry/Cancel/Discard; failed rooms remain visible. Favourite room ordering must keep invites explicit and stable. Reset authenticated navigator and route owners on hard logout/account replacement. Protect soft logout/recovery setup from competing account replacement. Existing security generation/send guard/trust and bootstrap verification must remain in force for every new text/thread/media/retry path.

## Acceptance ledger (nothing silently omitted)

- [ ] Account/room encrypted drafts survive route/process recreation; failed reads do not destroy stored drafts.
- [ ] Image zoom and audio/video playback work through actual routes; resources/temp files cleaned and background paused.
- [ ] Stage/remove/replace/caption image/file/camera attachments; correct reply/thread relations; retain on failure.
- [ ] Voice permission/record/preview/discard/send and lifecycle cleanup.
- [ ] Emoji picker and keyboard-inserted images/GIF/stickers with bounds.
- [ ] Durable delivery state/outbox with txid-safe explicit retries/discard; progress and real cancellation.
- [ ] User directory with race-safe results; favourite ordering; persistent appearance controls.
- [ ] Thread view/send/history with exact relations; Spaces hierarchy/join/refresh/paging.
- [ ] Password/discovery/SSO/OIDC UI and safe refresh/reauth; callbacks configured; transient errors preserve keys.
- [ ] Push opt-in config and guarded registration/UI; disabled by default without user's config; live delivery explicitly pending.
- [ ] Read-receipt detail UI, not just mark-on-open.
- [ ] Encryption, recipient trust, logout/account/async ownership invariants across every new feature; no automatic destructive recovery reset/rotation.
- [ ] Spec review PASS then quality review approved; fault/interleaving tests; full formatter/analyzer/tests; native APK and emulator smoke/logcat.
- [ ] README/security/privacy/release notes accurately identify live acceptance not exercised and optional external services.
- [ ] Versioned preview on GitHub at exact committed SHA, CI certificate/native library/version-code verified, release asset read back.

## Release procedure

Choose next semver after reading existing remote releases (0.3.0 preview proposed; current pubspec0.2.2+4). Keep existing signing certificate and increasing versionCode. Commit reviewed changes, push feature/base safely without history rewrite, use existing main workflow for verified APK. Read back exact remote SHA/run result and asset; publish versioned prerelease referencing that same SHA with feature list, limitations and checksum. No production-security claims or source visibility change. Missing infrastructure/live accounts are explicit acceptance limitations, not fabricated results.
