# Windows desktop port

Parallax runs on Windows 10/11 x64 as a native desktop app, built from the
same codebase as the Android app. Every feature with a desktop counterpart
is ported; the differences are listed below. Like the Android preview, this
is a personal test build, not a security certification or a live-verified
Element X replacement.

## Feature mapping

| Android | Windows |
| --- | --- |
| SQLite in the app sandbox (sqflite) | SQLite via FFI in `%APPDATA%\parallax` (`sqflite_common_ffi`, bundled `sqlite3.dll`); same database, no SQLCipher layer |
| Rust encryption (flutter_vodozemac) | Same crate, compiled for Windows MSVC and bundled as a DLL |
| Secure storage (Android Keystore) | `flutter_secure_storage_windows` (DPAPI) |
| Password / SSO / OIDC sign-in | Same flows; the browser round-trip uses a local loopback server (`flutter_web_auth_2`) |
| App lock PIN / biometrics | PIN unchanged; Windows Hello via `local_auth_windows` when enrolled |
| FLAG_SECURE for recovery secrets | `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` — the window is excluded from screen capture |
| Foreground service background connection | Tray keep-alive: closing the window hides it to the notification area and sync keeps running; the tray icon's **Quit** stops the app |
| UnifiedPush / Firebase delivery | Not applicable (Android concepts). The built-in connection is the only delivery; the settings page shows only **Built in** |
| Local notifications | Windows toasts (`flutter_local_notifications_windows`), including the **Mark as read** action; content rules identical |
| Share into Parallax (ACTION_SEND) | Drag files onto the window, or open files with Parallax; a second launch forwards its command line to the running window |
| Direct Share suggestions | Taskbar jump list ("Recent chats"), same rooms, same PIN/sign-out rules; requires the app pinned to the taskbar |
| matrix.to / `matrix:` links | `matrix:` protocol registered per-user (`HKCU\Software\Classes\matrix`); matrix.to links via the in-app dialog and browser |
| Chat shortcuts under the launcher icon | Jump-list entries launch `--room=<id>`, routed like Android's OpenRoomIntent |
| Media3 video compression / poster frames | Bundled `ffmpeg.exe` / `ffprobe.exe` helpers: same 720p/20 MB rules, poster frames and animated notification previews |
| Inline video (video_player) | `video_player_win` (Media Foundation) |
| Voice messages (record) | `record_windows` (Media Foundation, AAC-LC) |
| PDF previews (isolated PdfRenderer process) | PDFium via `pdfx`, **in-process** (see security notes), same timeouts and pixel caps |
| Office/Markdown/CSV/text previews | Unchanged (pure Dart) |
| Element Call (Android WebView) | WebView2 (`webview_windows`), same widget-API bridge and origin policy |
| Camera capture / gallery picker | File pickers (no camera capture on desktop); video "record" picks an existing file |
| QR sign-in camera scan | Not available yet — the scan step explains the gap; password/recovery sign-in works |
| Haptics | No-op (no vibration hardware) |
| Location sharing | `geolocator_windows` (Windows location service) |

## Known gaps on Windows

- **QR camera scanning** (sign-in and verification): `mobile_scanner` has no
  Windows implementation. Emoji/number verification still works both ways.
- **Camera capture**: photos/videos are picked from disk, not shot in-app.
- **Windows Share UI contract**: receiving shares uses drag-and-drop and
  "Open with" instead of the system share pane (that contract requires MSIX
  package identity). Sending out uses `share_plus`' Windows implementation.
- **PDF renderer isolation**: PDFium runs in-process on Windows, unlike
  Android's isolated renderer process. See
  [security and privacy](security-and-privacy.md).
- **Calls, push delivery and live interoperability** are unverified, exactly
  as on Android — no live homeserver acceptance tests have run on either
  platform.

## Build

Requirements: Windows 10/11 x64, Visual Studio 2022 with the **Desktop
development with C++** workload (MSVC + Windows SDK + C++ CMake tools),
Flutter 3.44.0 (same as Android), Git, and Rust (MSVC toolchain) for the
encryption plugin. `ffmpeg.exe`/`ffprobe.exe` are needed at runtime for video
compression; place them next to `parallax.exe` (or in a `ffmpeg` subfolder,
or on PATH).

```powershell
flutter pub get
flutter analyze
flutter test
flutter build windows --release
```

The output is `build\windows\x64\runner\Release\` — a portable folder
(`parallax.exe` + DLLs + `data\`). Zip the whole folder to distribute; no
installer is required. The app registers the `matrix:` protocol per-user at
first run and enforces a single instance per user.

### Installer (direct distribution)

With [Inno Setup 6](https://jrsoftware.org/isinfo.php) installed:

```powershell
ISCC.exe windows\installer\parallax.iss
```

Produces `build\windows\installer\Parallax-0.5.0-windows-x64-setup.exe` — a
per-user installer (no admin), Start-menu shortcut, optional desktop icon,
`matrix:` protocol registration, and an uninstaller that keeps the Matrix
session and keys in `%APPDATA%\parallax`. The installer is unsigned test
ware: Windows SmartScreen will warn until it is code-signed.

### Microsoft Store (MSIX)

Store distribution — and **selling** the app, which requires Store commerce
— uses an MSIX package with identity, not the Inno installer. The `msix`
dev dependency is configured in `pubspec.yaml` (`msix_config`), including
the `matrix:` protocol activation and internet/microphone/webcam
capabilities. On Windows, after the release build:

```powershell
dart run msix:create            # MSIX (sign_msix: false → unsigned)
dart run msix:create --store    # .msixupload for Partner Center
```

Before a real submission:

- Reserve "Parallax" in [Partner Center](https://partner.microsoft.com)
  (one-time developer account fee) and set `identity_name` and `publisher`
  to the reserved values — the publisher must be the account's
  `CN=<PublisherID>`, not a plain name.
- The runner detects package identity (`GetCurrentPackageFullName`) and
  skips its per-user protocol/AUMID registration when packaged; the
  manifest supplies both.
- Provide a privacy policy URL and support contact (required for chat
  apps), complete the age rating, and pass the Store's certification
  checks.
- **Licensing:** the matrix Dart SDK is AGPL-3.0-or-later and the bundled
  FFmpeg build is GPL-3.0. Selling/distributing combined builds carries
  source-offer obligations for those components — review them (and the
  Store agreement) before charging money.
- Live acceptance tests (see the parity ledger) must pass before selling;
  this is still a test preview.

The Android CI workflow (`.gitea/workflows/android-apk.yml`) is unchanged;
there is no Windows CI runner yet.

## licences

The bundled FFmpeg build (BtbN win64-gpl) is GPL-3.0; the matrix Dart SDK is
AGPL-3.0-or-later. Check distribution obligations before shipping builds
beyond personal testing. PDFium is BSD-style licensed; WebView2 uses the
Microsoft Edge WebView2 Runtime (evergreen, installed with Windows 11).