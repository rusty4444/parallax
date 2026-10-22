# MatriXpress

A new Android Matrix messenger, built independently of the Element X fork. Its name is a Matrix/express pun; its interface uses Space Grotesk, vivid gradients and three contrast-conscious palettes: Ultraviolet, Afterglow and Daybreak.

## Current build

- Password login to an HTTPS Matrix homeserver; persistent local session and SDK sync.
- Room inbox with joined rooms and invitations, search, unread-count badges and manually-unread indicators. Invites can be accepted or declined; long-press a joined room to mark it manually unread or leave after confirmation.
- Room details fetch current server state for name, topic and member list. Permitted members can edit name/topic, invite by Matrix ID and kick, ban or unban after confirmation; the backend rechecks power levels before each write. These controls need live cross-client testing.
- Room timelines with older-message loading, text messages, read-on-open markers and double-tap ❤️ reactions in **unencrypted rooms**. Long-press a message to reply, choose a reaction in an unencrypted room, or edit/delete your own message. Encrypted-room reactions and typing sends are disabled because this SDK can send reaction metadata in plaintext or share room keys before recipient approval. Reply fallbacks are stripped from visible text; redactions no longer expose the original body.
- Up to ten gallery photos in one selection, previewed before sequential upload; encrypted media is encrypted **before** upload and the SDK decrypts the thumbnail or original preview in visible message bubbles. The batch is not atomic.
- Consecutive photos from one sender form two-, three- or four-image grids without a server change.
- Per-room background photos are copied into private app storage and survive restart; the old background remains if replacement fails.
- Avatar collages use up to four cached Matrix room heroes when no room avatar is set. Only visible rows download thumbnails, with a bounded cache and concurrent-download cap.
- Public room directory search/join and paginated server message search for joined rooms. Encrypted message plaintext is not indexed by the server; selecting a hit opens its room, not that historical event.
- Send files, audio and video up to 20 MB from the Android document picker; download and decrypt attachments and save them through a user-selected document destination. The picker may first copy a large source into its cache before the app rejects it.
- Start or reopen a direct conversation by full Matrix ID.
- Light/dark themes, bundled font, custom launcher icon and local theme preference.
- Matrix Dart SDK encryption initialised via Vodozemac. Settings distinguish a new account from an existing or partial identity. A single-device new account can create secret storage, cross-signing and key backup after saving a generated recovery phrase; the SDK also returns a recovery key. Existing complete identities can be restored. Partial repair unlocks the existing storage key, compares derived signing/backup public keys with the server keys, and verifies retained subkeys are signed by the current master before creating only missing components; an orphaned storage key can be adopted with the existing credential before any new keys are made. Missing or mismatched private keys and stale default-storage pointers are **blocked**, not rotated. Logout and account switching cannot begin while setup is running. Setup rechecks server state and disables destructive wipes, but Matrix has no atomic cross-device setup lock; do not set up the same account simultaneously on another client. Android blocks screenshots and recent-app previews while recovery credentials are displayed. Settings can initiate verification with another device; encrypted-room message actions can initiate verification with a sender. Incoming/outgoing SAS requests show seven emoji (or three decimal numbers), require an explicit match/mismatch decision, and offer recovery-key unlocking if cross-signing needs it. Encrypted sends warn before trusting unverified recipient master keys on first use; missing keys are never recorded as trusted. **These flows have automated tests, but no live two-device setup, verification or recovery test yet.**

The room list and timeline use lazy builders; only one room timeline is subscribed at a time. No speed benchmark or device-startup measurement has been performed yet. For safety, failed encrypted to-device requests are not persisted for later replay without their approved recipient snapshot; verification or key sharing may need to be retried after a network failure.

## Not yet implemented

This is **not** a full Element X replacement. SSO/OIDC, push notifications, threads and calls remain to be built. New-account encryption setup and verification UI must be tested against real clients before they can be trusted. Room management, spaces, moderation, notification settings and rich-media viewing also lag Element X. Recovery, room sync, replies/edits/redactions, image uploads, media saves and directory joins still need testing against a live account and device. Do not migrate your main account or rely on this for critical encrypted conversations yet. The local SDK SQLite store is protected by Android's app sandbox and device storage encryption, and Android backup is disabled, but there is no additional SQLCipher layer.

## Automatic APKs

Every normal commit pushed to `main` runs analysis and tests, builds an arm64 APK, and publishes an immutable per-commit prerelease at [GitHub Releases](https://github.com/rusty4444/matrixpress/releases). The repository is private; sign in to GitHub to download it. Local edits do not trigger a build until committed and pushed. The same APK is retained as a GitHub Actions artifact for 30 days. Commits marked `[skip ci]` do not build.

CI restores the existing personal debug signing key from the `MATRIXPRESS_DEBUG_KEYSTORE_BASE64` GitHub Actions secret and verifies its public certificate fingerprint before publishing. This preserves update compatibility with the v0.2.1 preview; an incorrect or missing key fails the build instead of releasing an APK that would require uninstalling. CI uses an increasing Android version code. These are **test builds**, not production-signed releases; the signing key must never be committed to Git.

## Build

Requires Flutter 3.44+, JDK 17, Android SDK/NDK and Rust (`rustup` with Android targets) for the encryption plugin.

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
