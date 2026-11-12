# Parallax feature-module architecture

Parallax reaches Element X parity through independent feature modules. Core
screens expose extension points; each module implements them in its own files.
Reference baseline: Element X Android **v26.11.0** (released 2026-11-06).

## Extension points

`lib/hooks/hook_types.dart` defines the contexts and action types;
`lib/hooks/registry.dart` aggregates every module's hooks in a fixed order.
Core screens only call the registry:

| Core location | Registry call | Typical module use |
|---|---|---|
| `lib/timeline/message_bubble.dart` | `entryBodyFor`, `entryFootersFor` | poll/location/call/media bodies, thread summaries |
| `lib/room_screen.dart` header | `roomHeaderActionsFor` | call button, thread list |
| `lib/room_screen.dart` under header | `roomBannersFor` | pinned messages, ongoing call, identity warnings, knock requests |
| `lib/room_screen.dart` long-press sheet | `messageActionsFor` | forward, pin, copy link, view source, report, end poll |
| `lib/rich_message_composer.dart` attach sheet | `composerAttachmentsFor` | poll, location |
| `lib/room_details_screen.dart` | `roomDetailsSectionsFor` | pinned list, media gallery, poll history, threads |
| Settings category pages (`lib/settings_pages.dart`, `lib/security_settings_page.dart`, notification settings) | `accountDeviceSettingsRowsFor`, `notificationSettingsRowsFor`, `chatSettingsSectionsFor`, `mediaSettingsSectionsFor`, `privacySettingsSectionsFor`, `securitySettingsSectionsFor`, `advancedSettingsSectionsFor` | link new device, notification content, undo send, chat effects, emoji packs, saved, upload quality, device search, key storage, Element Call, Matrix links |
| `lib/main.dart` signed-in shell | `wrapSignedInApp` | app lock, verification gate, call overlay, share/deep links |

Each module's hook file is `lib/features/<module>/<module>_hooks.dart`. Keep
the existing function signatures; return `const []`/`null` when a hook does
not apply. Do not edit `registry.dart` or `hook_types.dart` from a module; if a
module needs a new extension point, add the function to its own hook file and
report it so the coordinator can wire it.

## Backend access for modules

Modules must not grow `ChatBackend`. Instead:

- Define a module interface (for example `PollFeatures`) in the module folder.
- Implement it with a class that wraps the live backend through
  `MatrixSdkAccess` and `RoomEventFeatures` (`lib/room_events.dart`), resolved
  with an `Expando` cache, e.g. `PollFeatures? pollFeaturesOf(ChatBackend b)`.
  Test fakes implement the module interface directly.
- **Timeline sends go through `RoomEventFeatures.sendRoomEvent`.** It applies
  session ownership, recipient-trust approval, fail-closed encryption and the
  final HTTP guard. Never call `Room.sendEvent`/`sendTextEvent` directly.
- Re-check `MatrixSdkAccess.isSessionCurrent(client)` after every await before
  touching caches or UI state.
- `ChatEntry` carries `kind`, `eventType`, `msgtype`, `content` (decrypted,
  edits applied), `formattedBody` (untrusted HTML), `senderName`,
  `senderAvatar`, `stateKey`, thread summary, `pinned` and `highlight`.

## Rules

- Untrusted content: sanitise HTML (allow-list the Matrix spec subset), only
  open `https`, `http`, `mailto`, `geo` and `matrix.to`/`matrix:` links, cap
  sizes of anything downloaded or decoded.
- Encrypted rooms keep fail-closed behaviour. Relation metadata (`m.relates_to`)
  is cleartext by Matrix spec, as in Element X; document that where it applies.
- Use `AppPalette` colours (`lib/app_theme.dart`); the default theme is the red
  and orange Parallax palette. Inherit the Space Grotesk font from the theme.
- Tests: focused unit/widget tests per module under `test/`; `dart format`,
  `flutter analyze` (no issues) and the full `flutter test` suite must pass.
- Visual QA: `PARALLAX_SCREENSHOT_DIR=… flutter test test/visual` renders key
  screens without a device.
