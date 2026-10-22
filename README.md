# MatriXpress

A new Android Matrix messenger, built independently of the Element X fork. Its name is a Matrix/express pun; its interface uses Space Grotesk, vivid gradients and three contrast-conscious palettes: Ultraviolet, Afterglow and Daybreak.

## 0.3 preview

- HTTPS provider discovery, password login, legacy browser SSO and native OIDC/PKCE flows; persistent local session and SDK sync. Refresh and soft-logout re-authentication preserve the existing device and encryption identity. Browser/provider interoperability still needs live testing.
- Room inbox with joined rooms and invitations, search, unread-count badges and manually-unread indicators. Invites can be accepted or declined; long-press a joined room to mark it manually unread or leave after confirmation.
- Room details fetch current server state for name, topic and member list. Permitted members can edit name/topic, invite by Matrix ID and kick, ban or unban after confirmation; the backend rechecks power levels before each write. These controls need live cross-client testing.
- Room timelines with older-message loading, text messages, read-on-open markers and double-tap ❤️ reactions in **unencrypted rooms**. Long-press a message to reply, choose a reaction in an unencrypted room, or edit/delete your own message. Encrypted-room reactions and typing sends are disabled because this SDK can send reaction metadata in plaintext or share room keys before recipient approval. Reply fallbacks are stripped from visible text; redactions no longer expose the original body.
- Up to ten gallery photos in one selection, previewed before sequential upload; encrypted media is encrypted **before** upload and the SDK decrypts the thumbnail or original preview in visible message bubbles. The batch is not atomic.
- Consecutive photos from one sender form two-, three- or four-image grids without a server change.
- Per-room background photos are copied into private app storage and survive restart; the old background remains if replacement fails.
- Avatar collages use up to four cached Matrix room heroes when no room avatar is set. Only visible rows download thumbnails, with a bounded cache and concurrent-download cap.
- Public room directory search/join and paginated server message search for joined rooms. Encrypted message plaintext is not indexed by the server; selecting a hit opens its room, not that historical event.
- Send files, audio and video up to 20 MB from the Android document picker; download and decrypt attachments and save them through a user-selected document destination. The picker may first copy a large source into its cache before the app rejects it.
- A rich composer stages gallery/camera/file attachments with removal, replacement and captions; emoji selection and Android keyboard image/GIF/sticker insertion are supported. Voice messages include permission-on-record, duration, local preview, discard and send. Physical camera/microphone and keyboard-provider testing remains pending.
- Full-screen image zoom and local audio/video playback with play/pause/seek. Downloads remain bounded; backgrounding pauses playback. Temporary sources are removed only after their native player has stopped and disposed. Images currently show the first animation frame.
- Encrypted account/room-scoped drafts, restored after reopening the room. Secure-storage failures are surfaced rather than treated as empty drafts.
- A durable composer/thread outbox with queued/sending/failed state, upload progress and explicit retry/cancel/discard. Saved work precedes transmission; interrupted sends do not automatically replay on restart. Transaction IDs and outbox ownership are pinned to the Matrix device, separately from account-scoped drafts.
- Search the user directory or enter a full Matrix ID to start/reopen a direct conversation. Favourite rooms sort ahead of ordinary joined rooms without hiding invitations.
- Thread root/reply views with relation-aware sending and paginated history, nested Spaces browsing/joining, and per-message receipt details. Receipts show exact latest read pointers, not an exhaustive list of everyone who has ever read a message.
- Light/dark themes, bundled font, custom launcher icon and persistent text-size, compact-layout, automatic media-preview and automatic read-receipt preferences.
- Opt-in push setup for **your own** Firebase project and HTTPS Matrix push gateway. Push is off until configured and explicitly enabled, and requires fresh consent after foreground restart. No borrowed gateway or service credentials are bundled. The gateway must support data-only delivery and echo this app's registration binding; see [push setup](docs/push-notifications.md). **Live delivery has not been tested.**
- Matrix Dart SDK encryption initialised via Vodozemac. Settings distinguish a new account from an existing or partial identity. A single-device new account can create secret storage, cross-signing and key backup after saving a generated recovery phrase; the SDK also returns a recovery key. Existing complete identities can be restored. Partial repair unlocks the existing storage key, compares derived signing/backup public keys with the server keys, and verifies retained subkeys are signed by the current master before creating only missing components; an orphaned storage key can be adopted with the existing credential before any new keys are made. Missing or mismatched private keys and stale default-storage pointers are **blocked**, not rotated. Logout and account switching cannot begin while setup is running. Setup rechecks server state and disables destructive wipes, but Matrix has no atomic cross-device setup lock; do not set up the same account simultaneously on another client. Android blocks screenshots and recent-app previews while recovery credentials are displayed. Settings can initiate verification with another device; encrypted-room message actions can initiate verification with a sender. Incoming/outgoing SAS requests show seven emoji (or three decimal numbers), require an explicit match/mismatch decision, and offer recovery-key unlocking if cross-signing needs it. Encrypted sends warn before trusting unverified recipient master keys on first use; missing keys are never recorded as trusted. **These flows have automated tests, but no live two-device setup, verification or recovery test yet.**

The room list and timeline use lazy builders; only one room timeline is subscribed at a time. No speed benchmark or device-startup measurement has been performed yet. For safety, failed encrypted to-device requests are not persisted for later replay without their approved recipient snapshot; verification or key sharing may need to be retried after a network failure.

## Limitations and remaining work

This is **not** a full Element X replacement. Calls/Element Call, polls, location sharing, room creation, Space administration, per-room push policies and precise search-result jump-to-event remain missing or limited. Threads and Spaces do not imply complete unread/notification parity with Element X. New-account encryption setup, verification, recovery, authentication providers and messaging features require live cross-client acceptance tests before they can be relied on. Do not migrate your main account or use this for critical encrypted conversations yet.

The local SDK SQLite store uses Android's app sandbox and device storage encryption, with application backup disabled; there is no additional SQLCipher layer. Draft/outbox storage uses OS-backed secure storage. Native media playback requires temporary plaintext files, and process death or failed native disposal can prevent their cleanup. Read the [security/privacy boundaries and live-test checklist](docs/security-and-privacy.md), [parity ledger](docs/element-x-parity.md) and release notes for the actual verification performed.

## Automatic APKs

Every normal commit pushed to `main` runs analysis and tests, builds an arm64 APK, and publishes an immutable per-commit prerelease at [GitHub Releases](https://github.com/rusty4444/matrixpress/releases). The repository is private; sign in to GitHub to download it. Local edits do not trigger a build until committed and pushed. The same APK is retained as a GitHub Actions artifact for 30 days. Commits marked `[skip ci]` do not build.

Pushes to `feat/**` and `fix/**` run the same checks and retain a signed candidate APK as an Actions artifact **without publishing a release**. This allows install/update testing before promoting the exact source commit to `main`.

CI restores the existing personal debug signing key from the `MATRIXPRESS_DEBUG_KEYSTORE_BASE64` GitHub Actions secret and verifies its public certificate fingerprint before publishing. This preserves update compatibility with the v0.2.1 preview; an incorrect or missing key fails the build instead of releasing an APK that would require uninstalling. CI uses an increasing Android version code. These are **test builds**, not production-signed releases; the signing key must never be committed to Git.

## Build

CI pins Flutter 3.44.0, JDK 17 and Android SDK 36/NDK 28.2.13676358. Rust (`rustup` with Android targets) is required for the encryption plugin. Keep the committed lockfile; a clean build does not need Firebase service configuration while push is disabled.

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export PATH="$JAVA_HOME/bin:$HOME/.cargo/bin:$PATH"
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

The resulting `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` is **arm64 only, release-optimised but signed with this machine's debug certificate** by the generated Gradle configuration; it is for device testing, not production distribution. Install with `adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` only when its version code is higher than the installed APK and its signing certificate matches. CI uses a higher, increasing version code; a default local build may be rejected as a downgrade. Other machines' debug certificates will not match: uninstalling first removes local session and encryption keys. A future production-signed APK also cannot update this debug-signed installation in place. The package ID is `net.samrussell.matrixpress`, separate from official Element X and the fork. No credentials are bundled into the APK.

The bundled Space Grotesk font is licensed under SIL Open Font License 1.1 (`assets/fonts/OFL.txt`). The `matrix` Dart SDK is AGPL-3.0-or-later; review its distribution obligations before shipping any build.

Development includes AI-assisted implementation and review. Automated tests and an installable APK are engineering checks, not independent security certification or proof of Matrix interoperability.
