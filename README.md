# Parallax

![Parallax](assets/parallax_icon.png)

Parallax is an Android messaging app for [Matrix](https://matrix.org), written in Flutter and separate from the Element X fork. It was previously called MatriXpress.

The logo shows three message bubbles offset like layers, in crimson, vermilion and amber, to suggest the parallax effect. The default **Parallax** theme uses those colours on a dark ink background. **Parallax Day** is the light version, and the older Ultraviolet, Afterglow and Daybreak palettes are still available. Settings can switch between the two Parallax themes automatically to follow the system's light or dark mode.

## 0.4 preview: Element X parity

Parallax covers the features Element X Android v26.11.0 turns on by default, plus its own extras. [docs/element-x-parity.md](docs/element-x-parity.md) is the row-by-row record of what is built, partial or missing.

- **Signing in:** choose matrix.org or another homeserver, then sign in with a password, OIDC/MAS or SSO. After signing in, confirm your identity with another device or your recovery key.
- **Security:** emoji verification, warnings when someone's identity changes, key storage, recovery key set-up and change, identity reset, and a PIN or biometric app lock.
- **Chat list:** filters for unread, people, rooms, favourites, low priority and invites. Mention badges, a long-press menu (read/unread, favourite, low priority, mute, copy link, leave), a Spaces switcher, and "decline and block" for invites.
- **Timeline:** formatted messages, links and mention pills; sender avatars, day separators, readable room changes, read receipts and typing notifications.
- **Reacting and sharing messages:** reactions in encrypted rooms with a full emoji picker, forwarding, pinned messages, polls, static location sharing, threads with a thread list, and jumping to a specific message.
- **Media:** voice messages with waveforms, inline audio and video, stickers, animated GIF/WebP, a swipeable media viewer, a per-room media gallery and optimised image uploads.
- **Rooms:** start a chat; create private, ask-to-join or public rooms; join by address. Room info covers editing, per-room notifications, security and privacy, roles and permissions, members, join requests, reporting and leaving. User profiles let you message, verify, block and moderate.
- **Calls:** Element Call embedded in the app, with a call button, an ongoing-call banner, call items in the timeline and ringing while the app is open.
- **Notifications and links:** notifications on by default with no opt-in, through UnifiedPush when a distributor such as ntfy is installed or Parallax's own background connection otherwise (no Google needed), optional Firebase delivery, and global notification settings. Share into Parallax from other apps, and open matrix.to or `matrix:` links in Parallax.
- **Search:** an on-device search index of your encrypted history alongside server search.
- **Account and settings:** profile, sessions, blocked users, account management, sign out (warns if key backup isn't on) and account deactivation.
- **Parallax extras:** room backgrounds, photo-grid bubbles, avatar collages, double-tap heart, a durable outbox with retry, a choice of palettes, and encrypted drafts.

Ideas from other messaging apps for after parity are in [docs/feature-ideas.md](docs/feature-ideas.md).

## What hasn't been verified

Every feature above has automated tests (1,098 passing). **None has been tested against a live homeserver, a second Matrix client or a physical phone yet.** That includes sign-in providers, encrypted reactions as Element X sees them, Element Call (which needs a homeserver with MatrixRTC/LiveKit) and push delivery.

Known gaps:

- **Calls:** no ringing while the app is in the background, and no picture-in-picture.
- **Notifications:** they never show the sender or message text, by design.
- **Missing features:** QR-code sign-in, Space administration and exporting room keys.

Don't move your main account to Parallax, or rely on it for important encrypted conversations, until the acceptance tests in the parity ledger have passed.

The SDK database relies on Android's app sandbox and device encryption, with app backup disabled; there's no SQLCipher layer on top. The on-device search index is stored the same way, is deleted when you sign out, and can be turned off in Settings. See [security and privacy](docs/security-and-privacy.md).

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

## Licences

The bundled Space Grotesk font is licensed under the SIL Open Font License 1.1 (`assets/fonts/OFL.txt`). The `matrix` Dart SDK is AGPL-3.0-or-later; check its distribution obligations before shipping any build. Map tiles are © OpenStreetMap contributors.

Parallax was built with AI-assisted implementation and review. Automated tests and an installable APK are engineering checks, not a security certification or proof that it works with other Matrix clients.
