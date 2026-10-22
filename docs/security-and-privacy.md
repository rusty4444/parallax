# Security, privacy and preview limitations

MatriXpress is an independently built Android Matrix client. This is a personal test preview, not a security certification or a claim of Element X parity. Automated transport, storage and widget tests do not establish live end-to-end encryption interoperability.

## Local data

- The Matrix SDK stores session, timeline and encryption state in SQLite inside Android's app sandbox. Device storage encryption and sandbox access controls apply; the database does **not** have an additional SQLCipher layer.
- Message drafts and the durable outbox use OS-backed secure storage, with no plaintext storage fallback. Missing values are distinct from read errors. Automatic Android secure-storage reset on errors is explicitly disabled so a failed read cannot silently erase saved work.
- Appearance preferences are not sensitive message data and use local preferences. Room backgrounds are private app files, not encrypted secure-storage entries.
- Android application backup and device-transfer backup are disabled. This does not protect a compromised/rooted device or a running, unlocked app.
- A native media player needs a decrypted temporary file for audio/video playback. Cleanup joins the work and disposes the player before removing its source. A native operation that never finishes, failed player disposal or process death can prevent cleanup; temporary files are not an encrypted media vault. Explicitly saved attachments belong to the destination the user chooses and are outside this cleanup policy.
- Voice recording requests microphone permission only for a user-initiated recording. Recording and preview are local operations; sending is a separate action. Do not record sensitive material on an untrusted device.
- Signing certificates must match to update an existing preview. Uninstalling to bypass an update error removes the Matrix session and local encryption keys. Keep a verified recovery credential before changing installations.

## Network and encrypted sends

- Entered, discovered and restored Matrix homeserver URLs must use HTTPS without embedded credentials. Passwords and bearer tokens must not be sent to an insecure discovered URL.
- Encrypted-room text, thread replies, media and retries retain the app's recipient-trust checks and final HTTP send guard. Losing encryption or session ownership is an error, not permission to fall back to plaintext.
- Encrypted attachments are encrypted before upload. The queued upload route sends to the configured HTTPS homeserver without automatic redirects, bounds the response, and has an aborting overall deadline. A progress indicator measures bytes handed to the transport, not server acknowledgement.
- A durable outbox entry is saved before transmission. Queued acceptance is not delivery: sending/failed state and explicit retry/discard remain visible. Interrupted entries are not automatically replayed after restart. A cancelled or timed-out request may already have reached the server; cancellation cannot retract a delivered event. Stable transaction IDs reduce duplicate event delivery when retrying within the same Matrix transaction scope.
- The legacy multi-photo batch remains sequential and non-atomic. Some photos can be delivered before a later photo fails. It is not a single transactional message.
- Typing notifications and relation-only reactions remain disabled in encrypted rooms because the resolved SDK can expose relation metadata or prepare key sharing before recipient approval.
- Read-receipt preferences control automatic room-open receipts. A Matrix homeserver can still observe connections, memberships, encrypted traffic, event sizes and timing. Encryption does not conceal all metadata.

## Authentication and recovery

Browser sign-in uses the configured homeserver/identity provider and the app's dedicated callback. The callback, state/nonce and account ownership are validated before accepting authentication results. OIDC compatibility depends on the provider's supported registration and authorisation flow; an automated callback test is not a real-provider acceptance test.

Transient refresh/network failures must not erase the existing device or encryption identity. Soft-logout re-authentication is distinct from replacing an account. New-account setup and partial repair retain the existing conservative checks: no automatic destructive reset or recovery-key rotation, no inferred absence of keys after an incomplete server response, and no account replacement during an in-flight crypto setup. Save the displayed recovery credential before server writes. Do not run setup for the same account simultaneously on another client.

Android blocks screenshots and recent-app previews while recovery credentials are displayed. Other message and media screens are not represented as screenshot-proof.

## Optional push service

Push is disabled by default and requires the user's own Firebase project and Matrix-compatible HTTPS push gateway. No borrowed gateway, service account or Firebase project credentials are bundled. Configuration alone does not demonstrate live delivery. Notification permission, token creation and pusher registration require complete configuration and explicit opt-in; disabling push or signing out must retire that account's registration.

Enabling push introduces Google Firebase Cloud Messaging and the configured gateway as external services. They can receive device registration and routing metadata. Notifications should contain generic text rather than decrypted message bodies. Notification navigation must be bound to the active account/device, not merely a room ID from an old payload. See [push setup](push-notifications.md) for the actual configuration contract and limitations.

## Required live acceptance checks

Use disposable accounts before trusting this preview with important messages:

- Two-client text/media/thread encryption, first-use trust, identity changes and rejected trust.
- Verification in both directions, mismatch/cancel, recovery and guarded partial repair.
- Password, SSO and OIDC sign-in against the actual provider; expired-token refresh and soft logout without changing device identity.
- Gallery/document/keyboard media, voice recording, audio/video playback and lifecycle interruption on a physical Android device.
- Directory, thread pagination, Spaces hierarchy/join, favourites and receipts against the actual homeserver.
- Opted-in push delivery, token rotation, disable/logout and stale-notification rejection using the user's own infrastructure.

Calls/Element Call interoperability, production signing and a complete independent security audit are outside this preview. Consult release notes for the exact automated checks and device smoke tests actually executed; an unchecked live test must not be treated as passed.
