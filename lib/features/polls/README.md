# Polls and location module

Polls (MSC3381) and static location sharing (MSC3488) at Element X Android
v26.11.0 parity.

| File | Purpose |
|---|---|
| `poll_hooks.dart` | Hook implementations wired by `lib/hooks/registry.dart` |
| `poll_model.dart` | Pure poll parsing, content builders and `computePollResults` |
| `location_model.dart` | `geo:` URI parsing/formatting and `m.location` content |
| `poll_features.dart` | `PollFeatures` / `LocationFeatures` interfaces and resolvers |
| `matrix_polls.dart` | Matrix implementation (relations cache, sends) |
| `poll_view.dart` | Timeline/history poll body, End poll confirmation |
| `create_poll_screen.dart` | Create Poll / Edit poll |
| `poll_history_screen.dart` | Room details → Polls (Ongoing / Past) |
| `share_location_screen.dart` | Share location (map, pin, device location) |
| `location_view.dart`, `location_map.dart` | Timeline preview, full-screen viewer, OSM helpers |

## Wire format

Sent exactly as Element X does: unstable `org.matrix.msc3381.poll.start`
with `org.matrix.msc1767.text` fallback, `…poll.response` and `…poll.end`
with `m.reference` relations, and poll edits as `m.replace` with
`m.new_content`. Both unstable and stable (`m.poll.*`) forms are read.
Locations are `m.location` messages with `geo_uri`,
`org.matrix.msc3488.location`, `org.matrix.msc3488.asset` (`m.self` or
`m.pin`), `org.matrix.msc3488.ts` and an MSC1767 text body.

## How relations are read

The core timeline projection (`ChatEntry`) hides poll responses, ends and
edits, and the SDK's `getDisplayEvent` only applies `m.room.message` edits.
`MatrixPolls` therefore keeps its own per-poll cache without core changes:

1. When a poll is first displayed it fetches `m.reference` and `m.replace`
   relations from `/relations` (100 per page, at most 10 pages per type),
   decrypting encrypted relations read-only.
2. Afterwards it listens to `client.onTimelineEvent` and `onHistoryEvent`
   for new responses, ends, edits and redactions. Local echoes are ignored
   until the server copy arrives; our own sends are recorded immediately.
3. The cache is tied to one SDK client and is dropped when
   `isSessionCurrent` fails.

All sends go through `RoomEventFeatures.sendRoomEvent`. `m.relates_to` is
cleartext in encrypted rooms by Matrix spec, as in Element X.

## Map tiles

`flutter_map` with OpenStreetMap standard tiles, the
`© OpenStreetMap contributors` attribution (links to the copyright page) and
`userAgentPackageName: 'net.samrussell.parallax'`. Location permission is
requested only when the user taps "Move the map to my location"; if it was
already granted the map centres on the device without prompting.
