# Android Auto

Parallax works in Android Auto in two ways.

## Car notifications (every build)

New messages appear in the car as conversation notifications. Android Auto reads them aloud and offers **Reply** (voice) and **Mark as read**. Locked chats never show their sender or text, in the car or on the phone.

- `res/xml/automotive_app_desc.xml` declares `<uses name="notification"/>`; the manifest points `com.google.android.gms.car.application` at it.
- Room notifications are `MessagingStyle` with a Reply action (`SemanticAction.reply`, one text input) and a Mark as read action (`SemanticAction.markAsRead`). Both run without opening the app, as Android Auto requires (`lib/features/notifications/notification_renderer.dart`).
- On the phone, a lone group message with a room picture uses `BigTextStyle` so the collapsed row keeps the picture. Android Auto ignores that style, so while the phone is projecting every room notification is `MessagingStyle` (`androidAutoProjecting()` in `lib/features/android_auto/android_auto_platform.dart`, answered by `AndroidAuto.kt` from `CarConnection`).
- Reply and Mark as read run in the notification-action isolate. They're handed to the running client (`push_handoff.dart`, kinds `reply` and `mark_read`). With no client running they're kept privately (`pending_replies.json`, `pending_reads.json`) and sent when the client next starts. A delayed Mark as read only marks up to the message it was pressed on, and nothing at all if the chat was read elsewhere since.
- While the phone is projecting to a car, Parallax keeps its Matrix client running (`AndroidAuto.start`, from `ParallaxApplication`), so voice replies and Mark as read go out straight away even when notifications come through UnifiedPush or Firebase rather than the built-in connection.

## Car screen (CI and local APKs; Play only on test tracks)

Parallax also appears in the car's app launcher. It shows your recent chats (newest first, with an **Unread** filter) as Android Auto conversations: the car reads messages aloud, takes voice replies and marks chats read. Everything comes from the signed-in client on the phone; nothing is stored for the car.

- Service: `ParallaxCarAppService` (category `androidx.car.app.category.MESSAGING`, Car App API level 7 for `ConversationItem`) in `android/app/src/carApp/AndroidManifest.xml`. Release builds accept only Android Auto's signing certificates (`hosts_allowlist_sample`); debuggable builds accept any host so the desktop head unit works.
- Screen: `ConversationListScreen` in `ParallaxCarApp.kt`. It asks the Dart host (`lib/features/android_auto/android_auto_host.dart`) over `parallax/android_auto` for conversations, replies and read receipts. The host pushes an update when the chat list changes while the car screen is showing.
- Privacy: locked chats are never sent to the car. If the app lock would show on the phone, the car only says that Parallax is locked; unlock Parallax on the phone before driving. Replies use the same guarded send path as notification quick replies.
- Starting the car screen starts the client if Parallax wasn't running. Until it has signed in and loaded the chat list, the car shows a loading list, then "Sign in to Parallax on your phone" if no account is signed in.

### Google Play

Google accepts templated messaging apps on **internal and closed testing tracks only** and rejects them on open testing and production. So the car screen is built into an APK or AAB only when `PARALLAX_CAR_TEMPLATES=true` (or `-Pparallax.carTemplates=true`), which is the default for every build except Play builds (`PARALLAX_PLAY_BUILD=true`). A production Play build has car notifications but no car screen. To test the car screen through Play, build the AAB with both `PARALLAX_PLAY_BUILD=true` and `PARALLAX_CAR_TEMPLATES=true` and upload it to a closed or internal track only.

Shipping car notifications on Play needs the Android Auto form factor turned on in Play Console (Release → Advanced settings → Form factors), which sends the app through Google's car review.

## Testing

Unit and widget tests cover the conversation projection, the host (privacy, updates, replies, read receipts) and the notification actions: `test/android_auto_test.dart`, `test/notifications_*_test.dart`. The car screen itself runs against the real Car App Library templates under Robolectric (`android/app/src/test/.../CarScreenTest.kt`): `cd android && ./gradlew :app:testDebugUnitTest`. CI runs both, and checks that its APK declares the car screen.

On a real car or the desktop head unit (DHU):

1. Install an APK built with car templates (any CI or local APK).
2. On the phone, open Android Auto settings, tap the version number ten times to unlock developer settings, and turn on **Unknown sources** (needed for apps not installed from Play) and **Start head unit server**.
3. DHU on the Mac: `sdkmanager "extras;google;auto"`, connect the phone by USB, `adb forward tcp:5277 tcp:5277`, then run `$ANDROID_HOME/extras/google/auto/desktop-head-unit`.
4. Check: a message notification is read aloud and a voice reply arrives in the chat; Mark as read clears it on the phone; the Parallax launcher entry lists chats, plays them, replies and marks read; a locked chat never appears; with the app lock on and Parallax locked, the car says it's locked.
