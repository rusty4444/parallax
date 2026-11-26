# Changelog

## 1.8.0

### Same settings on all devices

- Your settings now follow your Matrix account to every device, not just the theme and font. That covers chat settings (double-tap reaction, the quick reaction row, undo send, message font, chat effects, message requests, Stories), home screen and reading options, media and link previews (including previews in encrypted chats), privacy (read receipts, typing, invite avatars), what notifications show, the app language and call settings.
- Each setting syncs on its own: change one setting on your phone and another on your computer, and both changes reach every device. When the same setting changes in two places, the later change wins.
- The first time a device syncs settings it takes your account's values. It only adds the settings your account doesn't have yet and that you changed on that device.
- Text size, app lock, how notifications arrive, the background connection, the local search index and window layout stay on each device.
- One switch covers it all: Settings → Appearance → "Same settings on all devices" (on by default; it used to say "Same theme and font on all devices").

### Who reacted

- Hovering over a reaction on Windows or Mac now names who reacted, for example "You, Alex and 2 others reacted with 👍", instead of "React with 👍". Clicking it still adds or removes your reaction. Long-press still opens the full list.

### Voice notes on Windows

- Voice notes from Element, Element X, WhatsApp and Signal now play on Windows. They arrive as Ogg Opus, which Windows can decode but not open, so they never played. Parallax now repackages them as WebM just before playing; the audio itself is unchanged.

### Jumping to the message a reply quotes

- Clicking the quote in a reply now reaches older messages on desktop too. Jumping used to give up with "Couldn't jump to that message" when earlier messages were already loading, or when the message was more than about 2,000 events back. Desktop keeps less history on the device than a phone that syncs all day, so it hit those limits far more often.

### Transcribe voice notes

- Voice notes and audio files have a small Transcribe button beside the player. The transcript appears under the player in the same message and is saved on this device, so it's still there next time you open the chat. Long-press → Transcribe does the same.
- Transcription runs on your phone with Android's speech recogniser (Android 13 or later). Parallax reads the audio straight from the file, so nothing plays out loud, the microphone isn't used and nothing is uploaded. Before, Transcribe played the voice note through the speaker and listened with the microphone.
- Not yet on Windows, Mac or iPhone: the button only shows where transcription works.

### Google Messages voice notes

- Voice notes in Google Messages chats now play. The bridge first posts a "Waiting for attachment" notice and then edits the voice note into it; Parallax showed the edited message but downloaded from the notice, which has no file. It now plays the file the message shows (on every platform), and these bridge edits no longer show "(edited)".

## 1.7.0

### Chat themes for everyone

- Share your bubble colours and background with everyone in a chat: the chat's background menu → "Chat theme for everyone…". Other Parallax users in the chat see it, and the chat shows "Sam changed the chat colours", "… the chat background", "… the chat theme" or "… removed the chat theme". Sharing turns your own colours and background for the chat into the chat theme, so later changes by others show for you too.
- Your own colours or background for a chat still win over its chat theme. Settings → Appearance → "Show chat themes" turns other people's themes off.
- The theme travels as a hidden message, so anyone who can post can change it (bridged groups included). In encrypted chats it is end-to-end encrypted, picture key included. Other apps, and people on the far side of a bridge, don't see chat themes.
- Theme changes never notify. Parallax adds a push rule to your account so your homeserver doesn't count them as unread either; in encrypted chats, members using other apps may still see an unread count for a change.
- Text colours someone else picks are only used when they're readable on their bubble; otherwise Parallax picks the text colour.

### Backgrounds

- Choosing a new background for a chat that already had one now shows the new picture. Before, the chat kept showing the old picture until Parallax restarted, and removing a background and then choosing another brought the removed one back.
- "Background on this device only" in the background menu now has a checkbox.
- Removing your own background in a chat whose chat theme has a background now says that the chat theme's background shows instead.

## 1.6.1

### Portrait photos in the image editor

- Photos taken in portrait now open in the image editor upright and in their real shape. Before, the editor sized its canvas from the camera's stored landscape pixels, so the photo was squeezed into a wide box. The preview and the saved edit now match.

## 1.6.0

### Your look on every device

- Bubble colours chosen for a chat now reach your other devices even when those devices had already chosen colours for that chat. Before, a device kept its own colours when it opened the chat, so a change made on your phone only showed on your computer if the chat happened to be open at the time. A change made offline is uploaded when you're back online, and a newer change from another device wins over it.
- Chat backgrounds sync too. The picture is shrunk, encrypted on your device and stored on your homeserver; your other devices download it when you open the chat. Removing a background removes it everywhere. "Background on this device only" (in the chat's background menu) keeps a picture to one device, for example a portrait photo on your phone and a wide one on your computer.
- The app theme and font follow your account: pick a theme on one device and the others change to match. Turn this off with Settings → Appearance → "Same theme and font on all devices". Turning it back on takes the theme and font from your other devices.
- These settings are stored as Matrix account data, which isn't end-to-end encrypted: your homeserver can read the colours, the theme and the key to a synced background.

### Android Auto

- Message notifications now work in Android Auto: the car reads new messages aloud, and you can reply by voice or mark the chat as read. Mark as read no longer opens Parallax on the phone; it works in the background like Reply.
- While the phone is connected to a car, Parallax keeps its connection open so voice replies and Mark as read are sent straight away. Ones made while Parallax wasn't running are sent when it next starts (a late Mark as read only covers the message it was pressed on).
- Parallax on the car screen (test builds and Play test tracks): your recent chats, with an Unread filter, to listen to, answer by voice and mark as read. Locked chats never appear in the car, and if the app lock is on and Parallax is locked, the car says so instead of showing chats.

## 1.5.4

### Notifications from newer rooms

- Messages in rooms created as room version 12 (the default on current homeservers, so most new chats and bridged conversations) now notify. Their room IDs have no `:server` part, and the notification check rejected them, so they were silently dropped on every platform.

### Windows and Mac notifications

- Windows: message notifications now show the sender, the message and their picture, with a Reply box, Copy code and Mark as read. Clicking one opens the chat, bringing the window back from the tray. Previously a click did nothing and Mark as read lost track of the chat. There is no extra "1 notification" summary toast after each message.
- Windows: the tray icon is always there while Parallax runs, and unread messages show as a red count on the taskbar button and a dot on the tray icon.
- Mac: closing the window keeps Parallax running in the Dock so notifications keep arriving; click the Dock icon to bring it back, or press Cmd-Q to quit. The unread count shows on the Dock icon, Reply and Copy code work from the notification, and the extra summary notification is gone.

## 1.5.3

### Dependency and security updates

- Android build tooling: Android Gradle Plugin 9.5.2, Gradle 9.9.2, Kotlin 2.4.21, androidx appcompat 1.8.0, desugar_jdk_libs 2.1.5.

## 1.5.2

### Copy a code from the chat list

- Tapping "Copy ‘123456’" on a chat's row now marks that chat as read as well as copying the code, so the unread badge and the button clear without opening the chat. This follows the Send read receipts setting, the same as "Mark as read". If the code can't be copied, the chat stays unread.

## 1.5.1

### Message search, back in the inbox

- Typing in the inbox search bar now returns message matches inline, alongside matching chats — no extra tap into a separate search screen.
- Encrypted rooms are searched in the on-device index in parallel with unencrypted rooms on the homeserver, with a searching animation while results load. Matching chats cap at three (expand with "Show all chats") so message hits stay in view.
- "Load more messages" pages older results, and errors offer retry. Device-search setting changes in Settings → Privacy take effect immediately.

## 1.5.0

### Several accounts

- Settings → Account → Switch or add account signs in to another Matrix account. Each account has its own chats, encryption and database. The account you already use stays on its original storage. Back on the add-account screen returns to the previous account, and the original account cannot be removed.

### A chat of your own

- Two or more messages removed in a row fold into one line: "You removed N messages", or the name of the person who removed them.
- A new room can be a broadcast channel. A badge marks it in the list, and only admins can post.
- Bubble colours sync to your other devices. A photo wallpaper stays on the phone that chose it.
- Room details → Disappearing messages offers 1 hour, 24 hours, 7 days or a custom lifetime. Other clients can still keep a copy.

### Privacy in the inbox

- Lock one chat with the app PIN or biometrics. Until you open it, the inbox and its notifications say "Locked chat". Set up an app lock PIN in Settings → Security first.
- Invitations from people you share no room with wait under Message requests. Their name stays hidden until you choose to look, then you can accept, decline, or decline and block.
- Settings → Account → Status sets a note, an emoji and an expiry.
- Settings → Chats → Stories posts text or a photo to an encrypted story room that keeps it for 24 hours.

### On this phone

- Long-press a message → Remind me. Pending reminders are listed in Settings → Chats.
- Room details → Export chat saves text, HTML or a ZIP with media, and warns that the file is unencrypted plain text.
- A room with 10 or more unread messages offers a catch-up summary made on the phone: mentions, questions, threads, polls, media and who has been talking.
- On Android, long-press a message to translate it on the device, or transcribe a voice message with the phone's speech recognizer. The first translation downloads a language model. Transcription depends on a recognizer being installed.
- The composer can record a round video note, up to 60 seconds. Other Matrix apps show it as a normal video.

### When something is wrong

- Settings → Notifications → Troubleshoot notifications checks permission, background sync, battery optimisation and homeserver pushers, and can send a test notification.
- Settings → Advanced → Report a problem shares a description plus a log with tokens, passwords and keys removed. Shake to report is optional.
- Settings → Appearance → Language switches the settings menus among English, Spanish, French, German, Portuguese, Italian, Dutch, Japanese, Simplified Chinese and Russian. System default follows the phone. Message text is not translated by this setting.

### Calls and widgets

- A call can move the audio output, shrink to picture-in-picture, and share a link. On Android 12 and later, leaving the app during a call enters picture-in-picture, and an incoming call can ring on the lock screen.
- A new room can be a voice room, with a Drop in button for an audio call.
- Room details → Apps & widgets opens an HTTPS page in a sandbox. It starts with no access, and asks before it uses capabilities or an OpenID token. Addresses that are not plain HTTPS are refused.

## 1.4.0

### App font

- Settings → Appearance → Font changes the font on every screen: the chat list, chats, the compose box, settings, sheets and menus. There are 17 choices, each shown in its own face in the picker: Space Grotesk (the default), your device's own font, Figtree, Outfit, Manrope, Karla, Nunito, Quicksand, Josefin Sans, Atkinson Hyperlegible, Lexend, Lora, Libre Baskerville, Bitter, JetBrains Mono, Comic Neue and Caveat.
- The fonts ship with the app, so nothing is downloaded and the choice works offline. Messages sent in a message font keep that font, and code stays monospaced.
- Comic Neue now has a real bold weight, which also improves bold text in Comic Neue messages.

### About

- About has a Source code link to github.com/rusty4444/parallax and shows the AGPL licence notice.
- Report a problem now opens an email to sam@samrusselltech.net with the app version filled in, instead of a private issue tracker that only worked at home. If no email app is installed, Parallax shows the address instead.

## 1.3.0

### Open source

- Parallax is free software under the GNU AGPL-3.0-or-later, covering every version, with the source for each release public at https://github.com/rusty4444/parallax.

### One version for every device

- Android, iPhone, iPad, Mac and Windows now build from the same code and history, so every fix and feature reaches all of them at once. Android picks up the shared parts of the 1.2.0 desktop work: a draggable divider between the chat list and the chat on tablets and foldables, video players released only after they leave the screen, the wider sign-in layout on large screens and the reworked invitation buttons in the chat list.

### Messages pop out when you press them

- Long-pressing a message (or right-clicking it on a computer) now lifts it off the screen like Messenger: the chat dims and blurs, and the message grows slightly with a soft shadow while its actions are open. If the action sheet would cover it, it moves up to stay in view, and it settles back when the sheet closes. Photos in a gallery, stickers and thread replies lift the same way; thread replies also open their actions on right-click.
- Choosing Reply keeps the message popped out over the dimmed chat while you write, so you can see what you're answering; the compose box stays bright and usable. It settles back when you send, cancel the reply or start an edit, or when it scrolls off screen.
- Swipe to reply flows into the same pop-out: the message slides away, then springs back lifted with its shadow and stays up while you reply.

### Message fonts

- A Message font button in the compose box offers eight fonts (DM Serif Display, Indie Flower, Pacifico, Lobster, Comic Neue, Space Mono, Press Start 2P and Bangers), each shown in its own face. The draft shows the chosen font as you type, and the choice stays until you pick another.
- Other Parallax users see your message in that font, including replies in threads and edits. Other Matrix apps show the message in their usual font.

### Unpin Note to self

- Long-press Note to self in the chat list for Unpin from top. It then sorts with your other chats and loses its pin; Pin to top puts it back. The choice syncs to your other devices.

### Paste several images

- Pasting another image while one is waiting to send now adds it instead of replacing the first, up to ten. Each thumbnail has its own remove button. They send in order, with anything you typed following as its own message.

### Keyboard space on Android

- Switching away from Parallax while the keyboard was opening or closing could leave a black band the height of the keyboard when you came back. Parallax now asks Android for the real keyboard size when it returns and after every keyboard animation.

## 1.2.0

### Parallax on Mac, iPhone and iPad

- Parallax now runs on Apple Silicon Macs (macOS 13+), iPhone, iPad and iPhone Fold from the same codebase, with the same chats, encryption and Parallax extras as Android.
- Tablets, foldables and wide windows show the chat list and the open chat side by side; the divider can be dragged and resizing keeps the open chat.

### Desktop windows feel native

- A quick-action bar appears when you hover a message on Mac and Windows: react, reply, open the thread, edit your own text, pin and more. It flips below the message near the top of the chat. Right-click still opens the full action sheet.
- Drag-select message text and copy it with Ctrl+C / Cmd+C. Enter sends and Shift+Enter adds a new line; pasting a copied image attaches it.
- The title bar blends into the theme, the chat list and room headers sit flush in it, and the window can be dragged from any empty part of the top bar, including when maximised.

### Videos play reliably on desktop

- Playing a video no longer crashes Windows PCs with an older Microsoft C++ runtime installed. Parallax now ships the runtime it was built with, and its plugins also work with older runtimes.
- On Mac, videos that showed "Couldn't play this video" now play: the temporary folder they open from is created first. Voice recording, sharing and preparing videos to send use the same folder.
- Video players are released only after the picture has left the screen, which removes a crash when closing the full-screen viewer or scrolling away from a playing video.
- GIF and WebP previews keep their own shape.

## 1.1.1

### Tablets and foldables show the chat list beside the conversation

- On a tablet, a foldable opened out, or any window at least 600dp wide, Parallax keeps your chat list in a pane on the left and the open conversation on the right, so you can move between chats without leaving the list.
- It switches back to the phone layout when the window gets narrow, including straight away when you fold a foldable closed. Phones look and work exactly as before.
- This is the same app on every device: one purchase covers your phone, tablet and foldable, and Google Play installs the right download for each.

## 1.1.0

### Tap a reply's quote to see the original

- Tapping or clicking the quote at the top of a reply takes you to the message it answers. Parallax loads the conversation back as far as that message, scrolls up to it and marks it "Jumped to this message". Everything newer stays below it in order, so you can scroll back down or use the jump-to-bottom button. Tapping the same quote again scrolls back to it.
- Quotes inside a thread work the same way: the original scrolls into view when it's in the thread, otherwise the room opens at it.
- Search results, message links and pinned messages use the same jump, so they no longer swap the timeline for a slice that ends at the message.

### Text stays readable on any bubble colour

- Sender names, links, reply quotes, times and the jump marker inside a message bubble now adjust to the room's bubble colour, so none of them disappear on a light or bright bubble. They keep the theme's colour where it already reads clearly.
- Automatic bubble text keeps white on strong colours only while it reads clearly, and switches to near-black otherwise.

## 1.0.0

### Edited messages preview their new text

- The chat list shows an edited message's new text instead of the "* …" fallback meant for old clients, including edits that bridges cut short. Edited replies no longer carry the quoted fallback text, and an edit without usable new content drops the "* " marker. A literal asterisk message that isn't an edit keeps its text.

### Portrait videos play upright

- A portrait recording played squashed flat into a landscape box, in the message bubble, the full-screen viewer and linked videos. The player now lays the video out at the size the video plugin reports instead of swapping it again, so a phone recording with a rotation flag plays in a portrait box.

### Mention pills keep display names

- Outgoing mentions keep the contact's display name on bridges that use the pill's text as the remote mention's visible name (such as Teams), instead of showing the raw bridged account ID. The message body and mention metadata still carry the IDs.

### Windows desktop port

- Parallax now runs on Windows 10/11 x64 from the same codebase: sign-in (password, SSO, OIDC), encrypted chat, threads, reactions, polls, spaces, media, document and PDF previews, voice messages, Element Call (WebView2), search, settings and the Parallax extras.
- The background connection is a tray keep-alive: closing the window hides it to the notification area and notifications keep arriving; the tray icon's Quit stops the app. Windows toasts include the Mark as read action.
- Sharing in works by dragging files onto the window or opening files with Parallax; recent chats appear in the taskbar jump list under the same PIN/sign-out rules as Android's share suggestions. matrix: links open Parallax (per-user protocol registration).
- Video compression, poster frames and animated previews use bundled FFmpeg helpers; PDF previews use PDFium. Recovery-secret windows are excluded from screen capture.
- Desktop gaps: no camera QR scanning or camera capture (file pickers instead), no UnifiedPush/Firebase delivery (built-in connection only). See docs/windows-port.md.
- Android behaviour is unchanged; the full test suite stays green and the Windows platform layer adds 28 tests.

### Copy a code from the chat list

- When the latest message in an unread chat has a one-time code, the chat's row on the home screen shows a "Copy ‘123456’" button under the preview, as Google Messages does. Tapping it copies the code and says "Code copied". The chat isn't opened and stays unread.
- The button uses the same code detection as tapping a code inside a message and the Copy button on a notification. It goes once the chat is read. It isn't offered for your own messages, for phone numbers, or for messages longer than 1,000 characters.

### Links in captions can be tapped

- A link in the caption of a photo, video, audio message or file opens when you tap it. Before, captions were plain text. The usual case is a Facebook post shared in Messenger: the bridge sends the post's picture with the post's link as its caption, so the picture appeared but the link under it did nothing.
- Captions are drawn like message text, so mentions, formatting and tap-to-copy on codes and phone numbers work in them too. An emoji-only caption keeps its normal size.

### Zoomed pictures use the whole screen

- Pinching a picture in the viewer zooms it across the whole page, down to the bottom edge of the screen. Before, the zoomed picture stayed inside the frame it had at rest, so a landscape photo on a portrait phone only ever used a strip across the middle.
- While the zoomed picture is still smaller than the screen in one direction, it stays centred in that direction. Once it fills the screen you can drag it as far as its own edge; the black bars can't be dragged into view.
- Long, thin pictures (panoramas, tall screenshots) can zoom further than before, far enough to fill the screen.

### Recent chats in Android's share menu

- When you share from another app, Android's share menu suggests your most recent Parallax chats, with their pictures, as it does for Element. The suggestions are the top of your chat list, up to eight chats, without invitations, Spaces or chats marked low priority. Android decides how many it shows, usually three per app.
- Tapping a suggested chat opens Parallax on "Send to" that chat, showing what you're sharing and a Send button, so nothing goes out until you confirm. The other rooms are listed underneath in case you picked the wrong one.
- The same chats appear when you long-press the Parallax icon on the home screen. Tapping one opens that chat.
- Android keeps these names and pictures outside Parallax's screen lock, so none are offered while a screen lock PIN is set (Element X does the same). They are removed when you sign out.

### Document previews

- Word (.docx), Excel (.xlsx), PowerPoint (.pptx), Markdown, CSV/TSV and text files (logs, JSON, code) open in the viewer instead of the "can't be previewed" card. Word and Markdown keep headings, bold and italic, lists and tables. A spreadsheet is a scrollable grid with column letters, row numbers and a tab per sheet; tapping a cell shows all of its text with a Copy button. A presentation shows each slide's text. Share, Save and File info stay in the top bar.
- In the timeline, a document shows its first lines (or first cells) under the file card. Like photo previews this follows Settings → Media → In chats, and it only fetches files up to 4 MB. Tap the preview to open the viewer.
- PDF files open as pages you scroll through, with a page counter. Pinch or double-tap to zoom; the pages in view are drawn again at a higher resolution so small print stays sharp. In the timeline a PDF shows the top of its first page. A password-protected PDF says so, and a damaged one keeps the file card; both can still be saved or shared.
- Files are read in memory on a background worker and aren't written to the phone. Reading is bounded: a very large file shows its start and says so, and a damaged or mislabelled file keeps the plain file card.
- PDFs are drawn by Android's own PDF renderer in a separate, isolated process that has no access to your messages, keys, files or the network, because a PDF from someone else is untrusted input. If a file crashes or hangs the renderer, only that preview fails.
- Not previewed yet: the older .doc/.xls/.ppt formats, and pictures or charts inside Office documents. PDF pages are pictures: their text can't be selected or searched, links in them can't be tapped, and there is no password prompt. Excel dates and times are formatted; currency and percentage formats show the stored number.

### Signing in no longer starts five-minute renewals

- Parallax asked the homeserver for a refresh token whenever you signed in with a password or SSO. On Synapse that request is what makes access tokens expire after five minutes, so the app had to renew its sign-in every five minutes for as long as it stayed signed in. Other clients, such as Element, don't ask and get a token that lasts until you sign out. Parallax no longer asks, so a new sign-in is not renewed at all.
- A session that was signed in with an earlier version keeps renewing until you sign in again. Homeservers that sign in through OIDC (Matrix Authentication Service) always use short-lived tokens; those sessions renew as before.
- When a session is signed in again in place (after "Sign in again to reconnect"), the refresh token from the earlier sign-in is dropped instead of being kept after the server has cancelled it.

### Messages no longer fail while the app reconnects

- A message sent while Parallax was renewing its sign-in failed at once with "Send belongs to an unavailable session". Access tokens last a few minutes, so the renewal runs every few minutes and whenever the app comes back from the background, which is why it mostly happened just after opening a chat. If a renewal failed (no network yet), every send kept failing until the next attempt up to 30 seconds later.
- Messages, photos, files, reactions, polls and locations now wait for the renewal, for up to a minute, and then send. A send also starts the renewal itself when the token has run out, instead of waiting for the next sync.
- If a renewal starts while a queued message is on its way, the message is sent again with the same transaction ID, so it can't arrive twice.
- If the account still can't reconnect after a minute, the message reads "Not sent: still reconnecting to your account" and Retry works once you're back online.

### Animated notification previews

- Sent videos, GIFs and animated WebP images or stickers play as looping previews inside rich Android notifications, including encrypted rooms and background sync, and fall back to the static thumbnail if sampling fails.

### Timeline and composer fixes

- The swipe-to-reply strip fades out at the top and bottom so the accent tint blends into the room instead of cutting a hard line.
- Swiping a message to reply, or choosing Reply from the long-press menu, puts the cursor in the compose box so you can type straight away. Quote in reply does the same in a thread.
- Photo galleries line up with the other bubbles: they reserve the sender's picture column and use the same width cap, so a run of photos no longer sticks out past the text and single-image messages.
- "Send a photo gallery" moved into the composer's **+** menu (**Photo gallery**), keeping the timeline clear.
- Tapping your own reaction removes it on the first tap, even when the SDK has not indexed the reaction yet; it no longer takes a second reaction to make the first one removable.
- **Edit message** (for your own text messages) and **Copy text** sit directly in the long-press menu below **Forward** and above **More**.

### Faster, no more short freezes

- The room list no longer rebuilds every room after each sync (every message, and every 30 seconds when idle). On large accounts that rebuild re-read the whole direct-chat list and every push rule for each room and briefly froze the app. Now only the rooms a sync changed are updated.
- Photo galleries are resized in the background, and queued photos, videos and voice messages are saved without freezing the screen. Upload progress updates the screen about once per percent instead of every 64 KB.
- The chat list stays still while a room is open and catches up when you go back. Rows and message bubbles are kept when new messages move them, instead of being rebuilt with their pictures reloaded.
- Opening and closing the keyboard no longer makes every piece of text in the app redraw.
- After the app has been in the background, notifications are shown at most two at a time, in order per room.
- Device search reads each room's stored history once instead of on every launch, and writes in batches.
- More profile pictures and animated stickers stay cached, and room backgrounds are decoded at screen size.

### Chat pictures and app logos

- Long-press a chat → **Chat picture…** sets a picture only this phone shows for that chat. It's cropped to a 256 px square in the background and saved on the phone, so it appears at once and costs no network.
- Settings → Appearance → **App logos instead of letters** shows the app's logo (WhatsApp, Google Messages, Messenger, Instagram, Discord, LinkedIn, X, Xbox, Matrix) for chats with no picture. Detection uses bridge state, bridge bot names, bridged contact usernames, the room's canonical alias and its last sender; when there's no evidence the chat keeps its letter rather than a guessed Matrix logo.
- Long-press a chat → **Chat picture… → App logo…** overrides what was detected for that room, including "No logo". Both choices are saved on the phone.

### Link previews

- Links in messages show a small card with the page's title, description and image, under the message. Your homeserver fetches the preview, so your phone doesn't contact the site; tapping the card opens the link.
- Previews are remembered on the phone (newest 300 per account), so scrolling back over a link doesn't fetch it again, and are deleted on sign-out. A page that fails is retried after ten minutes rather than on every rebuild.
- In encrypted chats previews are off unless you turn on Settings → Media → **Preview links in encrypted chats**, because fetching one tells your homeserver which link was sent. Settings → Media → **Show link previews** turns them off everywhere.

### Message bubbles

- Bubbles are as wide as their message: a short message gets a short bubble, on the right for your own messages and after the sender's picture for others. Before, every bubble stretched to its widest because the time's right alignment took the full width.
- Your long messages stop about a quarter of the way in from the left, mirroring other people's bubbles on the right, and wrapped lines hug the longest line. On tablets bubbles are at most 520 points wide.

### Copy codes and phone numbers

- A one-time code, phone number or IP address in a message is tappable. The popup offers **Copy**, and a phone number also offers **Call**. **Copy text** in the long-press menu still copies the whole message. This works in the timeline and in threads.
- Rich Android notifications show **Copy code** or **Copy phone number** when the latest message contains one. The action copies the exact value without opening Parallax or dismissing the notification. Generic alerts with message content hidden are unchanged.

### Thumbnails saved on the device

- Chat and profile pictures and photo, sticker and video previews are now saved on the phone, so they show straight away after a restart and without a connection. Before, they were only kept in memory, and a picture that failed to load stayed as initials until the screen was rebuilt.
- Settings → Media → **Sync thumbnails** goes through every chat and saves its pictures and previews, with a progress bar, a Stop button and a summary of what was saved. It reads each chat's history stored on the device (about the last 100 events), skips invitations, runs four downloads at a time and can be run again to pick up failures.
- The same section shows how much space they use and can clear them. They're limited to 1 GB (oldest removed first), stay encrypted for encrypted chats, and are deleted when you sign out.

### Settings and home screen

- Settings is now a short menu. Every setting lives on one of these pages:
  - **Account:** profile and password (or your provider's account page), devices, link a new device, delete account.
  - **Notifications:** notifications on this device, message content and media previews, and the rules for direct chats, group chats, @room, invitations and calls.
  - **Appearance:** theme, text size, compact layout and the home screen.
  - **Chats:** double-tap reaction, haptic feedback, undo send, chat effects, custom emoji and stickers, note to self, saved messages and chat folders.
  - **Media:** when chats show media, and upload quality.
  - **Privacy:** screen lock, read receipts, typing notifications, invite avatars, blocked users and device search.
  - **Security:** your encryption identity, verifying with another device, key storage, recovery, room keys and reset. The menu row says when this device needs recovery or setup.
  - **Advanced:** the Element Call service, opening a Matrix link, and the public server/bridge setup guide for optional advanced media features.
  - **About & help:** version, licences and reporting a problem.
- Settings → Advanced → **Required for advanced features** links to the public setup repository, including the Synapse video-thumbnail module, compatibility requirements and installation instructions.
- Sign out stays at the bottom of the main Settings screen.
- The other-devices list under Security is collapsed until you open it.
- Settings → Appearance → Home screen: choose the chat row style (Cards, List or Compact) and how much message preview to show (None, Small or Long).
- Pulling down in a chat while **Load earlier messages** is visible loads older history automatically; tapping the button still works.
- Back now dismisses conversation search and clears its query instead of closing the app. Pressing Back again retains the normal app-exit behaviour.
- Message search results show sender display names instead of Matrix IDs, with the ID retained only when no usable display name is available.
- Mentions in the chat list, notifications and search snippets use the person's display name. The Matrix ID stays only when no usable display name is loaded.
- Group avatar collages from joined members and full room state remain included, including bridged groups marked as direct chats and rooms with sparse membership summaries.

### Notifications without Google or a push service

- Notifications are on by default after sign-in, with no opt-in. Parallax keeps its own connection to your homeserver in the background (a foreground service with a small “Parallax is connected” notification) and shows new messages itself, so no Firebase project, push gateway or UnifiedPush app is needed. It restarts after a reboot or an update.
- Settings → Notifications on this device can turn them off (remembered on the device) and asks Android to let Parallax run in the background.
- UnifiedPush is used automatically, with no opt-in, whenever a distributor app such as ntfy is installed, and the choice survives restarts. If the distributor's server has no Matrix gateway, Parallax uses the UnifiedPush project's public one, as Element X does. If UnifiedPush can't start, the built-in connection takes over. Your own Firebase project remains optional.

## 0.5.0 — Round 2

- Rich notifications, QR sign-in, Space admin, room key export/import, formatting toolbar, send later and undo send, saved messages, folders and note to self, live location, emoji and sticker packs, slash commands and chat effects. See `docs/element-x-parity.md`.

## 0.4.0 — Parallax

### Renamed and rethemed

- MatriXpress is now **Parallax**, with a new logo: three offset message bubbles in crimson, vermilion and amber, used for the launcher, adaptive and themed icons, splash screen and notification icon.
- The new default **Parallax** theme is red and orange on dark ink, with a light **Parallax Day** version. The theme can follow the system's light/dark setting.
- The app ID is now `net.samrussell.parallax`, so it installs as a separate app from the MatriXpress preview.
- OIDC sign-in now uses a redirect URI and client URI that matching authentication servers (MAS) accept.

### Element X v26.11.0 parity

Each area is built as its own feature module on a shared set of extension points ([architecture](docs/parity/architecture.md)):

- **Timeline:** formatted messages, pills, avatars and sender names, day separators, room-change summaries, read receipts, and @-mentions in the composer.
- **Reactions and message actions:** reactions work in encrypted rooms, with a full emoji picker, a "who reacted" view, forwarding, pinned messages, content reporting and moderator removal.
- **Polls and location:** polls (create, vote, end, edit, history) and static location sharing.
- **Element Call:** embedded calls, banners, call items in the timeline and in-app ringing.
- **Room administration:** start chat, create and join rooms, room info, per-room notifications, security and privacy, roles and permissions, members, join requests, and user profiles.
- **Home and settings:** room list filters and menu, a Spaces switcher, profile, notification settings, sessions, blocked users, app lock, and sign-out/deactivation.
- **Platform:** sharing into Parallax, matrix.to and `matrix:` links, UnifiedPush, and a "Mark as read" notification action.
- **Media:** voice waveforms, audio and video bubbles, stickers, animated images, the viewer and gallery, and optimised image uploads.
- **Threads and search:** a thread list and summaries, jumping to a specific message, and on-device search of encrypted history.
- **Security:** a post-sign-in identity check, identity-change warnings, key storage, recovery key change and identity reset.

### Other changes

- The repository moved to private Gitea; CI is now a Gitea Actions workflow.
- This preview has not been tested live. See the parity ledger for the acceptance tests still needed.

## 0.3.1 — room creation, search and Spaces fixes (folded in from PRs #12–#14)

- Private room creation with an explicit encryption choice, enabled by default.
- Definite pre-dispatch failures and recognised Matrix rejection codes release room-creation admission and show an accurate retriable error. Unknown/server/transport errors and post-create session changes retain the original uncertain request; no automatic retry or encryption downgrade occurs.
- Bounded visible acknowledgement and sync waits. A missing acknowledgement becomes uncertain after ten seconds without cancelling or replacing the original request. Session-owned request/room-ID retention survives inbox disposal; late acknowledgement cannot navigate an expired session. Ambiguous transport failures keep creation blocked rather than risking duplicate POSTs. This ownership is not persisted across process restart; use ordinary sync to check for a room before creating again.
- Deterministic SDK transport/widget coverage holds response headers, releases late acknowledgements, and exercises route disposal, account replacement and same-account logout/login. These are not live Android/two-client interoperability results.
- Isolate public-directory pagination by query generation. Query changes retire the old page guard/cursor immediately; stale success, error and cleanup cannot affect current results or admit duplicate page requests. Controlled widget regressions cover held obsolete requests, repeated terms/cursors, retry, debounce and route disposal; this is not live server or device acceptance.
- Bound Space child-room and directory join waits to 30 seconds with explicit stop/check-again controls, session-owned acknowledgement retention and processed-membership recovery. Cancelling a wait does not undo a server join; uncertain requests are not automatically repeated in the same session. Records do not survive process restart.
- This is one prerequisite for issue #5, not Space graph administration or live Element X acceptance. Invitation acceptance remains a separate SDK flow.

## 0.3.0 — messaging expansion preview

### Added

- OS-backed encrypted drafts scoped to the Matrix account and room, with ordered writes and visible storage failures.
- Rich attachment composition: gallery/camera/document staging, captions, removal/replacement, emoji selection and bounded Android keyboard images/GIFs/stickers.
- Permission-triggered voice recording with duration, local preview, discard/send and joined lifecycle cleanup.
- Full-screen image zoom and native audio/video playback, including background pause and player-before-file disposal.
- Durable composer/thread delivery states, stable device-scoped transaction IDs, explicit retry/discard, upload progress and cancellation. Interrupted work is not automatically resent after restart.
- User-directory search, favourite-room ordering and persistent appearance/media/read-receipt preferences.
- Thread root/reply views with decrypted paginated history and relation-aware sending.
- Nested Spaces browsing, refresh/pagination and room joins.
- Per-message receipt details showing exact latest read pointers.
- HTTPS provider discovery, legacy browser SSO and OIDC/PKCE, with session-preserving refresh and soft-logout re-authentication.
- Explicitly opted-in push configuration for an owned Firebase project and compatible HTTPS Matrix gateway. Push remains disabled without configuration and consent.

### Safety and reliability

- Preserved encrypted-send recipient approval and final HTTP encryption guards across queued text, thread and media paths.
- Fenced legacy plaintext media sends and final transport requests against logout/account replacement; actual streamed media bytes are capped.
- Kept fresh password discovery inside the validated authentication boundary and serialized session commits against logout.
- Distinguished missing secure-storage values from read failures; disabled automatic destructive storage reset.
- Retired acknowledged outbox payloads after durable removal and reserved lifecycle metadata space, so successful usage cannot exhaust pending capacity and near-limit saved work remains recoverable/discardable.
- Guarded startup, route ownership, deferred Spaces refreshes and stale async success/error/finally paths.
- Kept recovery setup conservative: no automatic destructive reset or recovery-key rotation.

### Preview boundaries

This is not a production-security or Element X parity release. Live two-client encryption, verification/recovery, provider sign-in, hardware media and push delivery remain acceptance work. Push requires the user's own infrastructure, including data-only FCM and registration binding support; no third-party gateway or service credentials are bundled. Calls, polls, location sharing, Space administration and precise search jump-to-event remain missing or limited.

Android previews retain the existing personal debug signing identity and increasing CI version codes. Do not uninstall an older preview to bypass an update error: that removes local session and encryption keys. See the README, parity ledger and security/privacy document for detailed limitations.
