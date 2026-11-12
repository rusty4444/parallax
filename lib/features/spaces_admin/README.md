# Space administration (spaces_admin)

Element X v26.11.0 parity for creating and administering Spaces:
`features/space/impl` (AddRoomToSpace, LeaveSpace, SpaceSettings, root Space
screen), `features/securityandprivacy` (ManageAuthorizedSpaces) and
`features/createroom` (New space).

## Where users find it

| Feature | Entry points |
|---|---|
| New space (name, topic, avatar, private / ask to join / public with address), then "Add rooms" | Start chat → **New space**; Space switcher → **New space** pill; Spaces browser → **+** |
| Space menu (explore, manage rooms, settings, leave) | Long-press a Space in the home Space switcher |
| Manage rooms: add existing rooms, create a room in the Space, mark suggested, move up/down, remove | Space menu → **Manage rooms**; Spaces browser → **Manage rooms**; Space settings → **Manage rooms** |
| Space settings (Element X SpaceSettings) | Space menu / Spaces browser → **Space settings** (`RoomDetailsScreen` for a Space: name, topic, avatar, people, roles & permissions, security & privacy, leave; encryption, notifications, favourite, call, report and timeline sections hidden) |
| Leave space with room choice; last-admin warning and "Choose admins" | Space menu, Spaces browser, Space settings → **Leave space** |
| Manage authorised spaces (`restricted` / `knock_restricted` allow lists) | Room info → Security & privacy → **Space members**, **Ask to join (space members join directly)**, **Manage spaces** |
| Add an ordinary room to a Space | Room info → **Add to space** |

## Matrix writes

All in `MatrixSpacesAdmin`, through `RoomEventFeatures.setRoomState` after a
fresh server read of power levels (the synced cache is only used to decide
what to show):

- New Space: `/createRoom` with `creation_content.type = m.space`,
  `power_level_content_override` `{events_default: 100, invite: 0|50}` as in
  Element, `history_visibility: invited` for private and `join_rule: knock`
  for ask to join. Shares the inbox's single-flight `RoomCreationRequest`.
- New room in a Space: `m.space.parent` (canonical, `via`) in the initial
  state, `restricted`/`knock_restricted` with an allow rule for the Space
  (room version picked from `/capabilities` when the default is too old),
  then `m.space.child` once synced. A failed link is retried without
  re-creating the room.
- Add rooms: `m.space.child` `{via, suggested?}` (existing content kept), then
  `m.space.parent` on joined children when permitted (canonical unless the
  room already names another canonical parent).
- Remove: empty `m.space.child`, and the child's `m.space.parent` when
  permitted. Suggested: read-modify-write of the child content.
- Reorder: spec ordering (`order` then `origin_server_ts` then room ID); a
  move writes one midpoint `order` when possible, otherwise renumbers only
  the prefix up to the moved room (`planSpaceChildMove`).
- Leave: selected rooms first, the Space last (Element X); stops at the first
  failure and keeps the Space.

## Verification limits

Tests prove request shapes (mock HTTP transport with the real SDK), ordering
rules and screen behaviour. They do not prove live homeserver behaviour: room
version negotiation, server-side restricted-join checks, federation `via`
routing and multi-client ordering need a real homeserver and a second client.
