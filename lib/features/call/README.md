# Element Call module

Voice and video calls in Parallax run [Element Call](https://github.com/element-hq/element-call)
in a WebView, driven by a Dart implementation of the Matrix widget API.
Reference: Element X Android v26.11.0 (`features/call`, matrix-rust-sdk
`widget` driver).

## Pieces

| File | Role |
|---|---|
| `call_widget_url.dart` | Builds the widget URL like the Rust SDK (`#?` fragment params, `intent`, `perParticipantE2EE`, `confineToRoom`, `appPrompt=false`, `preload=false`, `header=none`/`hideHeader`, `hideScreensharing`, `fontScale`). |
| `widget_capabilities.dart` | Element X's capability allow-list; grants the requested subset only. |
| `widget_driver.dart` | Widget API host: versions, capabilities, `content_loaded`, `get_openid`, `send_event` (incl. MSC4140 delayed state), `update_delayed_event`, `read_events`, `send_to_device`, live `send_event` / `update_state` / `send_to_device` pushes, Element join/hang-up/close actions. |
| `matrix_call_features.dart` | Matrix implementation over `MatrixSdkAccess` + `RoomEventFeatures`. |
| `call_web_host.dart` | WebView, injected `postMessage` listener (`elementX` channel), same-origin navigation, camera/mic permission gate. |
| `call_screen.dart` | Full-screen call, permission prompt, wake lock, hang-up grace. |
| `call_ui.dart` | Header button, ongoing-call banner, timeline items. |
| `incoming_call_overlay.dart`, `call_ringer.dart` | In-app ringing for MSC4075 DM rings. |
| `call_settings_section.dart` | Element Call URL override and MatrixRTC status. |

## Security notes

- Message-like events go through `RoomEventFeatures.sendRoomEvent` (trust
  approval, fail-closed encryption). Delayed *message* events are refused for
  that reason; only own call-membership **state** may be delayed.
- The widget can write only this device's own `call.member` state keys and
  read only call-related state and side-channel events, never messages.
- In encrypted rooms to-device call keys are always Olm-encrypted, and
  cleartext incoming to-device keys are dropped. Keys addressed to another
  room are dropped.
- Redactions are limited to the user's own events.
- The OpenID token is handed to the widget (Element Call needs it for its
  LiveKit JWT service) and never logged.

## Known gaps

- No background or push ringing (ringing only while Parallax is open), no
  Android telecom/ConnectionService integration and no picture-in-picture.
- No native audio routing (speaker/earpiece/Bluetooth); the WebView's
  default output is used.
- Screen sharing is hidden (Android WebView has no `getDisplayMedia`).
- MSC4039 file download, MSC4515 RTC transports and MSC4533 LiveKit token
  delegation are not offered; Element Call falls back to `.well-known` foci
  and OpenID.
- Element X bundles Element Call; Parallax loads the hosted build
  (`https://call.element.io` by default, overridable in Settings → Calls or
  by `.well-known` `io.element.call.url`).
- Live interoperability (two devices, LiveKit focus) has not been tested
  here.
