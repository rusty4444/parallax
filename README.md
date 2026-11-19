# Parallax

![Parallax](assets/parallax_icon.png)

Parallax is a messaging app for [Matrix](https://matrix.org), written in Flutter and separate from the Element X fork. It was previously called MatriXpress. It ships for Android, Windows, iPhone, iPad and Mac from one codebase; the [Windows port](docs/windows-port.md) documents the desktop feature mapping and build.

The logo shows three message bubbles offset like layers, in crimson, vermilion and amber, to suggest the parallax effect. The default **Parallax** theme uses those colours on a dark ink background. **Parallax Day** is the light version, and the older Ultraviolet, Afterglow and Daybreak palettes are still available. Settings can switch between the two Parallax themes automatically to follow the system's light or dark mode.

## 0.4 preview: Element X parity

Parallax covers the features Element X Android v26.11.0 turns on by default, plus its own extras. [docs/element-x-parity.md](docs/element-x-parity.md) is the row-by-row record of what is built, partial or missing.

- **Signing in:** choose matrix.org or another homeserver, then sign in with a password, OIDC/MAS or SSO. After signing in, confirm your identity with another device or your recovery key.
- **Security:** emoji verification, warnings when someone's identity changes, key storage, recovery key set-up and change, identity reset, and a PIN or biometric app lock.
- **Chat list:** filters for unread, people, rooms, favourites, low priority and invites. Mention badges, a long-press menu (read/unread, favourite, low priority, mute, copy link, leave), a Spaces switcher, and "decline and block" for invites.
- **Timeline:** formatted messages, links and mention pills; sender avatars, day separators, readable room changes, read receipts and typing notifications.
- **Reacting and sharing messages:** reactions in encrypted rooms with a full emoji picker, forwarding, pinned messages, polls, static location sharing, threads with a thread list, and jumping to a specific message.
- **Media:** voice messages with waveforms, inline audio and video, stickers, animated GIF/WebP, a swipeable media viewer, a per-room media gallery, optimised image uploads, and sending or recording videos (compressed to 720p on the phone when they're over 20 MB, with a poster frame). PDF, Word, Excel, PowerPoint, Markdown, CSV and text files open in a built-in viewer and show their first lines (for a PDF, the top of its first page) in the timeline.
- **Rooms:** start a chat; create private, ask-to-join or public rooms; join by address. Room info covers editing, per-room notifications, security and privacy, roles and permissions, members, join requests, reporting and leaving. User profiles let you message, verify, block and moderate.
- **Calls:** Element Call embedded in the app, with a call button, an ongoing-call banner, call items in the timeline and ringing while the app is open.
- **Notifications and links:** notifications on by default with no opt-in, through UnifiedPush when a distributor such as ntfy is installed or Parallax's own background connection otherwise (no Google needed), optional Firebase delivery, and global notification settings. Share into Parallax from other apps, with your recent chats suggested in Android's share menu, and open matrix.to or `matrix:` links in Parallax.
- **Search:** an on-device search index of your encrypted history alongside server search.
- **Account and settings:** profile, sessions, blocked users, account management, sign out (warns if key backup isn't on) and account deactivation.
- **Parallax extras:** room backgrounds, per-room bubble colours (yours and theirs, with automatic or custom text colour), Messenger-style reactions on the bubble's bottom edge, photo-grid bubbles, avatar collages, double-tap heart, a durable outbox with retry, a choice of palettes, and encrypted drafts.

Ideas from other messaging apps after parity are in [docs/feature-ideas.md](docs/feature-ideas.md).

## Apple platforms (iPhone, iPad, iPhone Fold, Mac)

The same Dart codebase runs on iOS, iPadOS and macOS (`feat/apple-port`). The Android app is unchanged.

- **Adaptive layout.** The shared tablet/foldable two-pane layout (`lib/two_pane.dart`): windows at least 600 pt wide and 480 pt tall — iPad landscape, the iPhone Fold unfolded, and Mac windows — show the room list beside the open chat, with a drag-resizable divider (persisted width, double-click resets) and hinge-aware splitting on foldables. Folding/unfolding or resizing keeps the open chat on screen, moving it between the detail pane and a full-screen route. iPhone and the Fold's outer screen keep the phone flow.
- **Desktop UX on Mac.** The native title bar is hidden and blended into the theme gradient (traffic lights kept), with a drag strip and double-click zoom; the inbox and room headers sit flush at the top. Right-click opens the message action menu, message text is drag-selectable (Cmd+C copies), Enter sends (Shift+Enter newline) and Cmd+V pastes clipboard images — the same desktop behaviour as the Windows port.
- **Feature parity.** Sign-in (password/OIDC/SSO), verification and recovery, E2EE (vodozemac builds for iOS and macOS), the timeline, reactions, threads, polls, spaces, media, voice messages, Element Call (WKWebView on both platforms), file previews and the on-device search index all run from the shared code. PDF previews use PDFium through `pdfx` instead of Android's isolated PdfRenderer process, with the same timeouts and pixel caps. Video probing/compression uses AVFoundation behind the same `parallax/video` channel.
- **Notifications.** The built-in delivery shows notifications fetched and decrypted on the device while Parallax is running, with Reply / Mark as read / copy actions. iOS and macOS do not allow Android's persistent foreground-service connection, and UnifiedPush/Firebase delivery are Android-only for now, so notifications do not arrive while the app is fully closed. This is stated in Settings → Notifications on the device.
- **Secure window.** While a recovery secret is shown, iOS covers the app-switcher snapshot with an overlay (screenshots while active cannot be blocked on iOS); macOS excludes the window from screen capture and sharing.
- **Database.** iOS uses sqflite; macOS uses sqlite3 via FFI (`sqflite_common_ffi` + `sqlite3_flutter_libs`). The SDK database is inside the app sandbox (macOS App Sandbox enabled) with no SQLCipher layer, as on Android.

**Nothing on the Apple platforms has been tested against a live homeserver, a second Matrix client or a physical device yet** — the same acceptance gate as the Android parity ledger applies.

## What hasn't been verified

Every feature above has automated tests (1,098 passing). **None has been tested against a live homeserver, a second Matrix client or a physical phone yet.** That includes sign-in providers, encrypted reactions as Element X sees them, Element Call (which needs a homeserver with MatrixRTC/LiveKit) and push delivery.

Known gaps:

- **Calls:** no ringing while the app is in the background, and no picture-in-picture.
- **Notifications:** they never show the sender or message text, by design.
- **Missing features:** QR-code sign-in, Space administration and exporting room keys.

Don't move your main account to Parallax, or rely on it for important encrypted conversations, until the acceptance tests in the parity ledger have passed.

The SDK database relies on Android's app sandbox and device encryption, with app backup disabled; there's no SQLCipher layer on top. The on-device search index is stored the same way, is deleted when you sign out, and can be turned off in Settings. Saved thumbnails stay encrypted for encrypted chats and are deleted when you sign out. See [security and privacy](docs/security-and-privacy.md).

## Code layout

Core screens (room, timeline, room info, settings and the app shell) expose extension points. Each feature lives in its own module under `lib/features/`. Feature modules send timeline events through one guarded path, which applies the encryption and recipient-trust checks. See [docs/parity/architecture.md](docs/parity/architecture.md).

## Source and APKs

The code is hosted on private Gitea at `http://192.168.68.247:3300/rusty4444/parallax` (git.samprim.net). The issues, pull requests and releases were migrated from the old GitHub repository, which has been deleted.

`.gitea/workflows/android-apk.yml` checks and builds each push. Pushes to `main` also publish a per-commit prerelease APK (`build-<12-character SHA>`). It runs on Sam's Mac as the self-hosted Gitea Actions runner `sam-mac-parallax` (label `parallax-android`, LaunchAgent `ai.hermes.gitea-runner`), so the Mac needs to be awake for builds to run.

The app ID is **`net.samrussell.parallax`**. It installs as a new app alongside the old MatriXpress preview (`net.samrussell.matrixpress`), so sign in again and confirm your identity. Builds are signed with the same personal debug certificate as before (SHA-256 `2E:1C:94:…:EF:F7`), so later Parallax test builds update in place. They are **test builds**, not production-signed releases.

## Build

Requirements: Flutter 3.44.0, JDK 17, Android SDK 36 / NDK 28.2.13676358, and `rustup` with the Android targets (for the encryption plugin).

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export PATH="$JAVA_HOME/bin:$HOME/.cargo/bin:$PATH"
flutter pub get
flutter analyze
flutter test
flutter build apk --release --target-platform android-arm64 --split-per-abi --build-number=30010
```

For a visual check without a device, run `PARALLAX_SCREENSHOT_DIR=/tmp/shots flutter test test/visual`. It renders the login, inbox and room screens in both Parallax themes.

To regenerate the launcher and notification icons, run `python3 tools/generate_icon.py` (requires Pillow).

### iOS / macOS

Requirements: Xcode (with the iOS SDK), CocoaPods, and `rustup` with the Apple targets (for the encryption plugin):

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin
flutter pub get
(cd ios && pod install)
flutter build ios --release --no-codesign   # device build; sign in Xcode to install
flutter build ios --simulator               # simulator build
flutter build macos --release
```

The bundle ID is `net.samrussell.parallax` on both platforms. The OIDC redirect scheme `net.samrusselltech.parallax` and the `matrix:` link scheme are registered in the runners; native Swift handlers for video tools, permissions, the secure window and link intents live in `apple/ParallaxApple.swift`.

Verified with Xcode 27.2 / Flutter 3.44: the macOS release build runs (login screen, Matrix client and local storage initialise); the iOS simulator build installs and launches. Two toolchain workarounds are committed: iOS/macOS builds are arm64-only (`ARCHS = arm64` in the runners' xcconfigs) because Xcode 27's `lipo` rejects Flutter 3.44's multi-arch `-verify_arch` call, and the Podfiles raise pod deployment targets to the runners' floors (iOS 15 / macOS 13). Flutter 3.44 integrates the plugins through Swift Package Manager; CocoaPods carries only the engine pod. macOS secure storage uses the login keychain for ad-hoc local builds (see the security doc).

### Windows

On a Windows machine with Visual Studio 2022 (Desktop development with C++ workload), Flutter 3.44.0, Git and Rust (MSVC):

```powershell
flutter pub get
flutter build windows --release
```

The portable app is `build\windows\x64\runner\Release\`. Video compression needs `ffmpeg.exe`/`ffprobe.exe` next to the executable. See [docs/windows-port.md](docs/windows-port.md) for the feature mapping, runtime layout and known gaps.

## Licences

The bundled Space Grotesk font is licensed under the SIL Open Font License 1.1 (`assets/fonts/OFL.txt`). The `matrix` Dart SDK is AGPL-3.0-or-later; check its distribution obligations before shipping any build. Map tiles are © OpenStreetMap contributors.

Parallax was built with AI-assisted implementation and review. Automated tests and an installable APK are engineering checks, not a security certification or proof that it works with other Matrix clients.
