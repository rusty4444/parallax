# MatriXpress

A new Android Matrix messenger, built independently of the Element X fork. Its name is a Matrix/express pun; its interface uses Space Grotesk, vivid gradients and three contrast-conscious palettes: Ultraviolet, Afterglow and Daybreak.

## Current build

- Password login to an HTTPS Matrix homeserver; persistent local session and SDK sync.
- Room inbox with joined rooms and invitations, search, unread-count badges and manually-unread indicators. Invites can be accepted or declined.
- Room timelines with older-message loading, text messages, read-on-open markers and double-tap ❤️ reactions.
- Up to ten gallery photos in one selection, previewed before sequential upload; SDK-backed encrypted thumbnail download in visible message bubbles. The batch is not atomic.
- Consecutive photos from one sender form two-, three- or four-image grids without a server change.
- Per-room background photos are copied into private app storage and survive restart; the old background remains if replacement fails.
- Avatar collages use up to four cached Matrix room heroes when no room avatar is set. Only visible rows download thumbnails, with a bounded cache and concurrent-download cap.
- Public room directory search/join and paginated server message search for joined rooms. Encrypted message plaintext is not indexed by the server; selecting a hit opens its room, not that historical event.
- Send files, audio and video up to 20 MB from the Android document picker; download and decrypt attachments and save them through a user-selected document destination. The picker may first copy a large source into its cache before the app rejects it.
- Start or reopen a direct conversation by full Matrix ID.
- Light/dark themes, bundled font, custom launcher icon and local theme preference.
- Matrix Dart SDK encryption initialised via Vodozemac. Settings can inspect the existing crypto identity, restore it with an existing recovery key/passphrase, and then explicitly load backed-up room keys. This path never invokes the SDK’s destructive identity initialiser. **No live recovery or cross-device verification has been validated yet.**

The room list and timeline use lazy builders; only one room timeline is subscribed at a time. No speed benchmark or device-startup measurement has been performed yet.

## Not yet implemented

This is **not** a full Element X replacement. SSO/OIDC, push notifications, threads, calls and cross-device verification remain to be built. Recovery, image uploads, media saves and directory joins still need testing against a live account and device. Do not migrate your main account or rely on this for critical encrypted conversations yet. The local SDK SQLite store is protected by Android's app sandbox and device storage encryption, but has no additional SQLCipher layer.

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

The resulting `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` is **arm64 only, release-optimised but signed with the local debug certificate** by the generated Gradle configuration; it is for device testing, not production distribution. Install with `adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`. A future production-signed APK cannot update this debug-signed installation in place. The package ID is `net.samrussell.matrixpress`, separate from official Element X and the fork. No credentials are bundled into the APK.

The bundled Space Grotesk font is licensed under SIL Open Font License 1.1 (`assets/fonts/OFL.txt`). The `matrix` Dart SDK is AGPL-3.0-or-later; review its distribution obligations before shipping any build.
