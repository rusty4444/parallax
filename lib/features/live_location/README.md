# Live location module

Live location sharing (MSC3488 location, MSC3489 live sharing, MSC3672
`beacon_info` as state), interoperable with Element Web, Element Classic and
Element X.

| File | Purpose |
|---|---|
| `live_location_hooks.dart` | Hook implementations wired by `lib/hooks/registry.dart` |
| `live_location_model.dart` | Pure parsing, content builders, liveness and latest-beacon aggregation |
| `beacon_throttle.dart` | When to send the next beacon (pure, clock-free) |
| `live_location_sharer.dart` | This device's shares: start/stop/expiry/resume/sign-out state machine |
| `live_location_features.dart` | `LiveLocationFeatures` / `LiveLocationLifecycle` interfaces and resolvers |
| `matrix_live_location.dart` | Matrix implementation (room state, `/relations`, guarded sends) |
| `position_source.dart` | geolocator wrapper, Android foreground service |
| `live_share_store.dart` | Per-account record of this device's active shares (SharedPreferences) |
| `live_location_view.dart` | Timeline body, full-screen live map |
| `live_location_banner.dart` | Room banner |
| `start_live_location.dart` | “Share live location” flow (permission, duration) |
| `live_location_scope.dart` | Signed-in wrapper: resume after restart, sign-out |

## Where users find it

* Composer attachments → **Share live location** → location permission (asked
  only now) → 15 minutes / 1 hour / 8 hours (with Element X’s disclaimer).
* Room banner: “You’re sharing your live location” with **Stop**, or
  “N people are sharing live location”; tap for the live map.
* Timeline: each share is a map preview of the sharer’s latest position with
  “Live location · ends 3:45 pm” (or “Live location ended”) and Stop on your
  own live share; tap for the live map with every sharer, their last update
  time and **Open in maps**.

## Wire format

Sent as Element sends today (unstable types); stable and unstable forms are
both read.

* Start: state `org.matrix.msc3672.beacon_info`, state key = own user ID,
  content `{description: "Live location", live: true, timeout: ms,
  "org.matrix.msc3488.ts": start ms, "org.matrix.msc3488.asset": {type:
  "m.self"}}`.
* Updates: `org.matrix.msc3672.beacon` with `m.relates_to` `{rel_type:
  m.reference, event_id: <beacon_info event>}`,
  `"org.matrix.msc3488.location": {uri: "geo:lat,lon;u=accuracy"}` and
  `"org.matrix.msc3488.ts"` (send time, as Element does, so it is on the same
  clock as the start).
* Stop: the same `beacon_info` content with `live: false`.

## Rules

* **Live** = `live: true`, now inside `[ts − 6 min, ts + timeout)` (the six
  minutes are matrix-js-sdk’s leniency for a sharer clock ahead of ours) and
  not replaced by a later `beacon_info` for the same state key (stable and
  unstable types compared by server time).
* A `beacon_info` whose state key the sender does not own (their user ID, or
  `@user:server_suffix` per MSC3757) is ignored.
* A beacon counts only if its sender is the sharer, it references the share
  with `m.reference`, its location is a valid WGS84 `geo:` URI, its
  timestamp lies inside the share’s period (later beacons are ignored), and
  it is newer than the current latest.

## Encryption

`beacon_info` is a state event and therefore cleartext in every room, as in
Element (it holds no position). Beacons go through
`RoomEventFeatures.sendRoomEvent` (session ownership, recipient trust,
fail-closed encryption, final HTTP guard). Matrix SDK 14.1’s
`encryptGroupMessagePayload` only skips encryption for relation-only
payloads (round 1 found this for reactions); a beacon also carries the
location and timestamp, so it is encrypted to `m.room.encrypted` with only
`m.relates_to` in the cleartext envelope, as the Matrix spec requires.
`test/live_location_matrix_test.dart` pins this, and that the final send
guard refuses a plaintext beacon in an encrypted room. The module also fails
closed itself (an encrypted room without working encryption ends the share
before any beacon is sent).

## Sharing engine

* One device position stream serves every room. Per room: at most one beacon
  in flight (newer fixes replace the pending one); the first fix goes out at
  once, then at most one beacon per 5 s for movement of at least 10 m beyond
  the fix’s accuracy radius, otherwise a 30 s heartbeat. Failed sends back
  off 5 s → 2 min. A refused recipient-trust prompt, losing the room, losing
  encryption or a `M_FORBIDDEN` ends the share instead of retrying (and
  re-prompting).
* `RoomEventFeatures.setRoomState` does not return the event ID, so a new
  share waits (up to 30 s) for its own `beacon_info` to arrive through sync
  before sending beacons, as Element X waits for the remote echo. If it never
  arrives the share is ended again.
* Expiry: a timer at the share’s end writes `live: false`.
* Another device replacing or stopping the own share (seen through sync)
  stops local updates without writing.

## Background (Android)

geolocator’s `AndroidSettings.foregroundNotificationConfig` runs the
plugin’s `GeolocatorLocationService` as a `location` foreground service with
an ongoing “Parallax is sharing your live location” notification and a
partial wake lock while any share is active. The manifest adds
`FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION` and `WAKE_LOCK` and
restates the service’s `foregroundServiceType="location"`. The service is
only started from the foreground with while-in-use permission, which Android
allows without `ACCESS_BACKGROUND_LOCATION`, so that permission is not
requested. geolocator’s notification has no action buttons, so there is no
Stop action in it; tapping it opens Parallax, where the banner has Stop.
Without notification permission (Android 13+) the service still runs but
the notification is hidden.

## Resume and sign-out

* Resume (chosen behaviour): shares **this device** started are recorded per
  account and device. After a restart, while Parallax is in the foreground,
  each record that has not expired and is still the live `beacon_info` on the
  server resumes automatically without prompting (as Element X does).
  Expired records are ended on the server; records stopped/replaced
  elsewhere are dropped; if location permission was revoked the share is
  ended rather than prompting. Shares started on other devices are left to
  them (the banner still offers Stop).
* Sign-out: `liveLocationBeforeLogout(backend)` ends every own share while
  the session can still write; it must run from the backend’s pre-logout
  hook (see the coordinator note in the round-2 report). Without that wiring,
  sign-out still stops local sharing and clears the records, and the
  homeserver ends the share at its timeout.

## Not verified here

Needs a device and a live homeserver: geolocator’s foreground service and
wake lock on Android 14+, background delivery with the screen off, Element
Web/Classic/X rendering Parallax shares (and vice versa), and real Megolm
encryption of beacons (tests pin the SDK decision point, not native crypto).
