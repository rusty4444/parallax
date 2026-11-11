# Changelog

## Unreleased

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
