# Configurable Android push notifications

## Status and consent boundary

Push is **disabled by default**. No service credentials, Firebase project, gateway,
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
already opted-in registration can show generic background alerts while the app is
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

All app-rendered alerts use fixed text: “New message” / “Open MatriXpress to read your
messages.” Only the registration nonce, room ID and optional event ID survive
payload parsing. Notifications never render untrusted private message contents.
The background top-level `matrixPushBackgroundHandler` is registered **only** after
valid configuration and explicit enable. It verifies persisted consent, complete
configuration, nonempty account/device identity, and the current registration nonce;
it never initializes Firebase or contacts Matrix. Locked/unavailable secure storage
fails closed. It rechecks its binding before showing a generic local alert.

On disable, rotation, logout or account replacement the foreground owner invalidates
routing immediately, cancels listeners, removes exact old pushers, clears background
state and deactivates/deletes the FCM token. Native/isolate/OS delivery is not an
atomic transaction with foreground logout: an already dispatched generic alert can
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
and default settings state. Still required: APK/native integration and a real
opted-in account/device test against your own gateway/Firebase, including background,
terminated, token rotation, permission denial, offline cleanup and logout races.
