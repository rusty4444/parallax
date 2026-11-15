# Android notifications

Notifications are **on by default** after sign-in, with no opt-in
(`startDefaultNotifications` in `lib/features/platform/background_connection.dart`):

1. **UnifiedPush** when a distributor app such as ntfy is installed. Parallax
   registers with it automatically and finds the Matrix gateway on the
   distributor's server (ntfy has one), falling back to the UnifiedPush project's
   public gateway `matrix.gateway.unifiedpush.org` when the server has none, as
   Element X does. Your homeserver sends only room and event IDs; Parallax
   fetches and decrypts each message on the device.
2. Otherwise, or if UnifiedPush can't start (no endpoint, several distributors
   and none chosen, no gateway), the **built-in connection** below. A failed
   UnifiedPush start isn't retried until the next launch; installing a
   distributor later switches over the next time Parallax comes to the
   foreground.

Choosing *Built in* or *UnifiedPush* under Settings → Notifications → Enable
notifications on this device is remembered (`notifications.delivery`), as is turning notifications off
(`notifications.in_app_off`). Firebase stays manual and opt-in, and the
automatic choice leaves it alone.

Recommended setup: install **ntfy from Google Play** and open it once (allow its
notifications), keeping its default server `ntfy.sh`. ntfy.sh answers the Matrix
gateway discovery (`{"unifiedpush":{"gateway":"matrix"}}`) and relays the
homeserver's push body unchanged; a captured relay is pinned in
`test/platform_unified_push_test.dart`. ntfy then wakes the phone through
Google's Firebase, so there's no ongoing notification. Settings → Notifications →
Enable notifications on this device offers a "Get ntfy" link when no distributor is installed.

With a self-hosted ntfy server, the ntfy app keeps its own connection open (with
its own ongoing notification) and the server must be reachable over HTTPS from
your homeserver. With the Play Store ntfy app and `ntfy.sh`, ntfy wakes through
Google's Firebase instead.

## Built-in delivery

No Firebase project, push gateway or UnifiedPush distributor.
Parallax keeps its own Matrix sync running and turns events that the account's
push rules mark as notifying (`Client.onNotification`: not the initial sync, not
your own messages) into the same rich notifications described below. Live-location
beacons and call-membership events never notify.

How it stays running (`android/app/src/main/kotlin/.../BackgroundConnection.kt`,
`lib/features/platform/background_connection.dart`):

- The Flutter engine is cached for the whole process (`MainActivity.getCachedEngineId`),
  so the Matrix client outlives the activity instead of being torn down with it.
- `BackgroundConnectionService`, a `specialUse` foreground service with a
  minimum-priority “Parallax is connected” notification, keeps the process alive.
  It starts once notification permission is granted and stops on sign-out or when
  the user turns notifications off. When Android restarts the process it brings
  the engine back headless, and `BackgroundConnectionBootReceiver` restarts it after
  a reboot or an app update.
- Parallax asks once (while on screen) to be exempt from battery optimisation;
  Settings → Notifications → Enable notifications on this device shows the
  state and can ask again.
- Turning notifications off is remembered on the device
  (`notifications.in_app_off`). There is no pusher, so nothing is registered on
  the homeserver.

Trade-offs: a permanent low-priority notification (the channel can be hidden),
more battery use than FCM, and some phone makers stop background apps regardless.
Delivery has not yet been checked on a physical phone.

Your own Firebase project and gateway remain available under Settings →
Notifications → Enable notifications on this device → How notifications arrive, behind the consent
boundary below. UnifiedPush no longer needs opt-in (see the top of this page);
the consent rules below now apply to Firebase.

## Firebase: status and consent boundary

Push through your own Firebase project is **disabled by default**. No service credentials, Firebase project, gateway,
friend's service, or working push backend are bundled. The production Android
adapter exists, but **live delivery is unverified**. Tests use injected drivers and
pusher callbacks; they do not prove FCM, gateway or homeserver interoperability.

Construction, configuration and session binding do not initialize Firebase, ask
permission, create tokens, or register Matrix pushers. Only `enable(consent: true)`
with a complete configuration and authenticated `PushSession` can do that. Denied
Android notification permission prevents token creation/pusher registration.
`active` means a token's pusher callback completed and its background binding was
stored, not confirmed end-to-end delivery. The UI calls this “registered — delivery
unverified.” Failed/missing configuration must never claim active.

The foreground process does not restore consent automatically. Call `initialize()`
once at foreground startup; it only clears the previous background routing binding.
A process restart and each account/session replacement require fresh opt-in. An
already opted-in registration can show background notifications while the app is
terminated, until the next foreground startup or explicit disable/logout. Old
notification launch payloads are deliberately discarded, not reassigned to a newly
signed-in account.

## Exact integration API

`lib/push_notifications.dart` exports:

```dart
PushNotifications({
  PushConfiguration? configuration, // defaults to compile-time configuration
  PushDriver? driver,               // defaults to FirebasePushDriver
  PushStateStore? store,            // defaults to secure platform storage
});

Future<void> initialize(); // local storage only; once before session binding
Future<void> configure(PushConfiguration configuration); // disables first
Future<void> setSession(PushSession? session); // invalidates synchronously, joins cleanup
Future<void> enable({required bool consent});
Future<void> disable(); // invalidates synchronously, joins all old work and cleanup
Future<void> logout();  // clears session then disables/joins
Future<void> shutdown(); // await at app-owner teardown; then disposes notifier
Future<void> settle(); // joins already queued work, useful in deterministic tests

// ChangeNotifier getters:
PushConfiguration configuration;
List<String> configurationIssues;
PushStatus status;
String message;
bool enabled, active, busy, hasSession;
int consentRevision; // snapshot around consent dialogs; reject changed revisions
```

Create the shared owner once. Call `await push.initialize()` at foreground startup,
without any Firebase initialization or background-handler registration in `main`.
Put `PushSettingsScreen(notifications: push)` in the settings navigation. The screen
does not own/dispose the shared notifier.

For each restored/login SDK session create ONE `PushSession`, after `userID` and
`deviceID` exist. Capture the exact authenticated SDK client, not a mutable backend
getter. Reuse that session object until the login changes, including re-login to
the same account (which must get a new session object).

```dart
final accountClient = client; // exact client/account ownership
await push.setSession(PushSession(
  userId: accountClient.userID!,
  deviceId: accountClient.deviceID!,
  registerPusher: (registration) => accountClient.postPusher(
    registration.pusher,
    append: false, // explicit: do not preserve other-account token associations
  ),
  removePusher: (registration) => accountClient.deletePusher(registration.pusherId),
  onNavigate: (request) async {
    if (!request.isCurrent) return;
    // Resolve only within this captured account; reject non-member/unknown rooms.
    // await any needed room lookup here, then recheck request.isCurrent.
    // Every async backend/UI mutation MUST itself be generation-safe.
    if (!request.isCurrent) return;
    // Open the authenticated room only while still current. Never trust payload
    // room/event IDs as authorization or as message content.
  },
));
```

`PushRegistration` exposes `configuration`, `userId`, `deviceId`, `token`,
`registrationId`, `matrix.Pusher pusher`, `matrix.PusherId pusherId`. It intentionally
contains no access token. The pusher has kind `http`, `data.format: event_id_only`,
your exact gateway URL and a fresh 192-bit `data.registration_id` nonce. That nonce
changes per account/device/token registration generation.

`PushNavigationRequest` exposes `userId`, `deviceId`, `roomId`, `eventId`, `envelope`,
and the live cancellation predicate `isCurrent`. The navigation callback MUST
check this predicate after **every** await and immediately before each navigation
or backend mutation. Controller jobs are serialized, and logout invalidates the
predicate synchronously and waits for the callback to settle. A Dart Future cannot
be forcibly cancelled; a callback that ignores cancellation or never returns can
block logout. Do not return `Navigator.push()`'s route-lifetime Future from this
callback: complete once the route is safely dispatched, not after the user leaves
it. Logout cannot safely join a permanently outstanding route Future.

`PushBackgroundBinding.parse(String?)` is a pure fail-closed validator for the
durable background approval; `binding.envelope(data)` rejects unmatched nonces.
Its `configuration`, `userId`, `deviceId` and `registrationId` are read-only.

**Before** SDK logout, credential clearing, session replacement, or client disposal:

```dart
await push.logout(); // cancels/joins registration + navigation, deletes exact pushers
await accountClient.logout();
```

Also call `push.logout()` on remote session invalidation and handle its error. A
cleanup failure throws `PushCleanupException` after local invalidation. The owner
retains failed pusher removals and retries them on disable; token deletion and
local-notification cancellation are attempted even when server deletion fails.
Surface the cleanup failure rather than claiming removal succeeded; if credentials
are already invalid, server-side removal may require the user's homeserver device
settings. Never switch a mutable SDK client's account before joined cleanup ends.
Use `await push.shutdown()` for final teardown; synchronous `dispose()` invalidates
immediately but can only schedule best-effort joined cleanup.

## Configuration

Runtime:

```dart
await push.configure(PushConfiguration(
  gatewayUrl: Uri.parse('https://YOUR-HOST/_matrix/push/v1/notify'),
  appId: 'YOUR.REVERSE.DNS.APP',
  firebaseOptions: yourOwnFirebaseOptions,
)); // remains disabled; settings consent + enable are still required
```

Or compile-time `--dart-define` values:

- `MATRIX_PUSH_GATEWAY`: full HTTPS Matrix notify endpoint, optionally behind a path prefix
- `MATRIX_PUSH_APP_ID`: reverse-DNS pusher app ID, at most 64 characters, configured on your gateway
- `FIREBASE_API_KEY`: Firebase **client** API key, not a service-account key
- `FIREBASE_APP_ID`: Android Firebase app ID (`1:SENDER_ID:android:HEX_IDENTIFIER`)
- `FIREBASE_MESSAGING_SENDER_ID`: numeric project/sender number matching that app ID
- `FIREBASE_PROJECT_ID`: your Firebase project identifier

No values have usable service defaults. Runtime settings permit the same fields.
Runtime configuration remains in memory except for the validated client options
needed by an explicitly enabled background binding, stored in platform secure
storage. Consent is not automatically restored in the foreground. The URL rejects
HTTP, embedded credentials, query and fragment. This client validates the supplied
app/sender pairing and verifies an already initialized Firebase default app matches
all supplied identifiers; it cannot attest that a remote gateway actually belongs
to you or uses those server-side Firebase credentials. That is an operator setup
and live-test obligation. Do not use any friend's/third party's service implicitly.

The production driver currently supports Android only, and fails visibly elsewhere.
The Firebase Android app must have been registered for this build's Android
application ID and signing setup. Keep Firebase Messaging native auto-init disabled
in the Android manifest, request `POST_NOTIFICATIONS`, and exclude app state from
backup/device transfer. Do not add unconditional Firebase initialization or native
service config with a different project. Do not put Firebase Admin credentials,
service-account JSON, signing keys, bearer tokens or a gateway admin password in
Dart defines, runtime settings, APK assets or this repository. Gateway secrets live
on your gateway, never in the client.

## Required gateway contract and privacy

Use your own Matrix-compatible HTTPS push gateway. Configure its Matrix app ID and
Firebase service account for the **same Firebase project** as the Android client.
The gateway receives Matrix `event_id_only` notifications. It must forward **data-only
FCM** messages and copy the target device's `data.registration_id` into each message's
string data fields:

```text
registration_id = the exact nonce from that target Matrix pusher's data
room_id          = the Matrix room ID
event_id         = optional Matrix event ID
```

The extra nonce forwarding is an explicit gateway requirement; a stock gateway that
does not echo custom pusher data must be adapted. No registration nonce means the
client drops the notification. Use high-priority Android data delivery where
appropriate; OS throttling/force-stop still prevents guaranteed delivery. Never
send an FCM `notification` block, sender,
plaintext body, room name, or private previews. Android/Google can display an FCM
`notification` block before Dart is invoked, so client-side filtering cannot make
a misconfigured gateway safe. Event/room IDs, device tokens, timing and your IP are
still metadata visible to the homeserver, your gateway and/or Google; this is not
zero-metadata delivery. The nonce binds routing to a locally authenticated
account/device generation; it is not a cryptographic signature from the homeserver
and does not authorize access to a room.

Only the registration nonce, room ID and optional event ID survive payload parsing:
**no message content ever comes from the push**. The background top-level
`matrixPushBackgroundHandler` is registered **only** after valid configuration and
explicit enable. It verifies persisted consent, complete configuration, nonempty
account/device identity, and the current registration nonce; it never initializes
Firebase. Locked/unavailable secure storage fails closed. It rechecks its binding
before posting anything.

## What notifications show (rich notifications)

Like Element X, a verified push is turned into a real notification **on the
device**: Parallax fetches the notified event from your homeserver with the signed-in
session and decrypts it with the keys already on the phone. Your gateway, Google FCM
or UnifiedPush distributor only ever see event and room IDs.

- **One conversation per room** (Android MessagingStyle, ID derived from the room
  ID): sender name and avatar as the person icon, the room name as the title of
  group rooms, and the last few messages of that room. The room thumbnail is the
  large icon for direct and group chats; a direct chat without its own artwork
  falls back to the other person's avatar. Notifications are grouped under a summary.
- **Message text per type:** text and notices; emotes as “\* Name waves”; images,
  videos and stickers (“Image”, “Video”, “Sticker” or the caption); files as
  “📎 name”; “Voice message”; “📍 Location”; polls as “Poll: question”; reactions;
  live location. Mentions and keyword highlights (push rule `highlight`) are raised
  in priority without adding labels that obscure the message text.
- **Media previews:** decrypted static images/stickers, animated GIF/WebP images
  and video clips, downloaded with strict size caps (3 MB for static originals,
  10 MB for animated GIF/WebP originals, 20 MB for videos, and server-scaled
  thumbnails for static plaintext media with automatic thumbnail fallback when an
  animated or video download fails or exceeds its cap), decoded with pixel/frame
  bounds and re-encoded in the app's private cache (`cache/notification_media/`)
  as a small JPEG or looping GIF (for animated GIFs/WebPs and frames sampled from
  the opening seconds of a video). Android's system UI reads each preview through
  a non-exported FileProvider (`${applicationId}.notifications.fileprovider`)
  using only the URI attached to the posted notification. Android 12+ animates
  looping GIF previews inline like camera alerts; Android 9–11 shows a static
  frame; older versions show text.
- **Invites:** “Alice invited you to Book club” (or “… invited you to chat”).
- **Calls:** an MSC4075 `m.rtc.notification` ring (or legacy `m.call.invite`) in a
  DM becomes a high-priority, call-category notification on the “Calls” channel
  that opens the room. Expired rings show “Missed call”.
- **Actions:** tap opens the room with Back returning to the message list (without
  restoring a previously open room), “Mark as read” (as before) and an inline
  **Reply**. Notifications of a room are cleared when you open it in Parallax or it
  becomes read (for example on another device), and already-read events are not
  shown.
- **Settings → Notifications → This device:** “Show message content” (on by default; off
  restores the generic “New message” alert and removes existing rich
  notifications) and “Show media previews in notifications” (on by default).
  Lock-screen visibility stays *private*: Android hides content on a secure lock
  screen when you choose to hide sensitive notifications.

If the event cannot be fetched or decrypted within the time limit (15 s), or
anything else fails, the previous generic alert (“New message” / “Open Parallax to
read your messages.”) is shown instead; a push is never silently dropped because
rendering failed.

### Which process does the work

The main isolate owns the Matrix client and database.

1. **App running (foreground or background):** foreground FCM/UnifiedPush messages
   are rendered by the main isolate with the live client
   (`Client.getEventByPushNotification(storeInDatabase: false)`). FCM background
   messages arrive in a separate background isolate; it hands the push to the main
   isolate through an `IsolateNameServer` port registered by
   `wrapWithNotifications` and waits up to 2 s for an acknowledgement. The main
   isolate re-verifies the envelope against its live registration exactly like a
   foreground message.
2. **No main isolate (app closed):** the background isolate opens a short-lived
   **read-only** client on the same database (separate, read-only SQLite
   connection): no `Client.init`, no sync loop, no key upload, no to-device
   processing, no token refresh and no database writes. It reads the stored session
   (which must match the push binding's account and device), fetches the one event
   over HTTPS, decrypts it with the stored Megolm session and closes everything.
   A lock file (`push_background_client.lock`) marks the client; at most one runs.
3. **Residual risk:** Parallax can be launched while a background client is open.
   The background connection cannot write, so it cannot corrupt crypto state; the
   main isolate additionally waits (bounded, 8 s) for the lock before opening the
   database so startup migrations do not race the read. A port left behind by a dead
   isolate is detected by the missing acknowledgement and removed.

### Quick reply

The Reply action never opens the app and is never sent from a background isolate.
flutter_local_notifications delivers it to its (non-exported) action receiver in a
background isolate, which hands it to the main isolate; the main isolate verifies
the payload against the live registration and sends it through the normal guarded
send path (recipient trust, fail-closed encryption, final HTTP guard), then shows it
as “Me” in the conversation (or “Couldn’t send your reply…”). When Parallax is not
running, the reply is kept in the app's private storage and the notification says
“Reply not sent yet. Open Parallax to send it.”; the next time Parallax is opened
by that account and device it is sent through the same guarded path. Replies older
than 30 minutes are not sent.

### Local notification data

The last few messages per room (needed to rebuild MessagingStyle across isolates),
the two preferences and pending quick replies are kept in
`parallax_notifications/` in the app's private support directory (excluded from
backup, like the Matrix database, which already stores decrypted history). It is
scoped to one account and device, pruned after three days, and deleted with the
cached previews on sign-out.

On disable, rotation, logout or account replacement the foreground owner invalidates
routing immediately, cancels listeners, removes exact old pushers, clears background
state and deactivates/deletes the FCM token. Native/isolate/OS delivery is not an
atomic transaction with foreground logout: an already dispatched alert can
race revocation, although its tap is discarded after generation invalidation. OS
force-stop, crashes, app deletion or already-invalid credentials can prevent remote
pusher removal. Clean transitions are covered by joined cleanup; no claim of
server-side crash cleanup or guaranteed delivery is made.

## Verification

Run without dependency resolution:

```sh
flutter test --no-pub test/push_notifications_test.dart
flutter analyze --no-pub lib/push_notifications.dart lib/push_settings_screen.dart test/push_notifications_test.dart
```

The tests cover missing config/no contact, consent, denied permission/no token,
`event_id_only`, exact token rotation/removal, generic payloads, stale account/tap
rejection, registration and navigation logout joins, cancellation during permission
and default settings state. `test/notifications_*_test.dart` cover the rich
notification wording per event type, sender/room naming, media decisions and
bounded preview processing, the MessagingStyle history store, fallback paths
(content off, fetch failure, timeout, plugin failure, stale binding), isolate
hand-off with fake port directories, quick replies and the settings toggles.

Still required (not verifiable without a device, homeserver and second client):
APK/native integration and a real opted-in account/device test against your own
gateway/Firebase or distributor, including background, terminated, token rotation,
permission denial, offline cleanup and logout races; decryption by the background
read-only client (vodozemac and sqflite in a headless engine); MessagingStyle image
display through the FileProvider; the inline Reply round trip through the action
isolate; and ringing-call presentation.
