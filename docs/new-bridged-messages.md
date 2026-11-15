# New bridged messages

Status: **application code implemented for Google Messages, Facebook Messenger and Instagram behind off-by-default flags; the approved HTTPS provisioning routes are deployed and CI test builds enable the feature. Live creation and messaging acceptance are not yet tested.** Each service is independently enabled by its own trusted HTTPS Mautrix provisioning endpoint. The feature commit itself changed no production configuration, bridge process or Synapse configuration and created no real conversation or message; the HTTPS routes below were deployed afterwards under separate infrastructure approval.

## Architecture

Parallax is a Flutter app using `matrix` 14.1.0. There is no Parallax backend. Password, OIDC/MAS and SSO authentication produce a Matrix SDK client; the signed-in Matrix user ID and access token identify the Parallax user.

The feature module in `lib/features/bridged_messages/` uses that existing client and Mautrix's bridgev2 provisioning API. The bridge validates the Matrix token and `user_id`, and validates that an explicitly selected `login_id` belongs to that Matrix user. The provisioning shared secret stays on the server and is not used by Parallax.

The UI is an optional action in the existing Start chat screen. It uses separate read-only recipient resolution and explicit create/get-or-create confirmation. Creation is admitted through the session-owned `RoomCreationRequest`; room readiness uses `CreatedRoomWait`; navigation returns to the existing inbox/Start chat route and opens `RoomScreen`. No message is sent by this module. The existing composer and guarded messaging pipeline remain the only send path.

No contacts, account data or recipient results are persisted by this module. Account/session changes invalidate in-flight UI work. There is no contact cache to expire or clear.

## Deployed versions and immutable identities

The `latest` tags below are recorded only as configured labels, not as version evidence. Versions came from the running binary; image IDs and repository digests came from read-only Docker inspection.

| Service | Running version | Exact source commit | Image label | Running image ID | Repository digest |
|---|---|---|---|---|---|
| Google Messages | `v26.10+dev.ec503962` | `ec503962049cbd58352204d1419124462cc6ad15` | `dock.mau.dev/mautrix/gmessages:latest` | `sha256:6551af0a3228927c4d9ebbaef5594774a0e43161d4083bcfcc87e771db336162` | `sha256:6522573b3bbc7c6ce86c7d8540eb02241ebda1fc0f5ecc0325f06b7a57b51bda` |
| Messenger | `mautrix-facebook v26.10+dev.08b6a6e9` | `08b6a6e946a59a43df2c3eb61c0a657a0be47fd5` | `dock.mau.dev/mautrix/meta:latest` | `sha256:0275969caf64618797356ede21c9153ce71ad6dc8d515b3c699c6834fa88f71d` | `sha256:ca6247ced049c4d830f9d3849be81a841a97cb42d422c68a8cb654bcef7d4cc1` |
| Instagram | `mautrix-instagram v26.07+dev.cbbf9c81` | `cbbf9c81c15fa684c9f10c87c77268b412364b69` | `dock.mau.dev/mautrix/meta:ig-latest` | `sha256:9d6ed25c2058cb325fdc75b63313783a9272729770c55036043a1e1e20c2368b` | `sha256:2538f002d722de95e008df59ad47590001fbba050e21378df3584a1c0b482a33` |

The running Google Messages bridge is upstream Mautrix, **not** `rusty4444/gmessages-matrix`. The fork's legacy `POST /v1/start_chat` route is therefore not part of this implementation.

All three deployed configurations were read-only verified with `allow_matrix_auth: true` and debug endpoints disabled. Live `GET capabilities`, `GET logins` and `GET whoami` checks succeeded for each service using Matrix authentication. Sensitive account/profile fields were not recorded.

## Capability matrix

“Source verified” means the exact deployed commit implements the operation. It does not mean a real recipient-visible operation was tested.

| Capability | Google Messages | Messenger | Instagram |
|---|---|---|---|
| List contacts | Connector implements an unpaginated list, but advertises `contact_list=false`; not exposed in Parallax | Not advertised or implemented through the shared contact-list interface | Same as Messenger |
| Search recipients | Unsupported (`search=false`) | Supported (`search=true`), source verified | Supported (`search=true`), source verified |
| Resolve phone numbers | No reachability lookup (`lookup_phone=false`); arbitrary syntactically valid numbers can be used (`any_phone=true`) | Unsupported | Unsupported |
| Resolve usernames or remote IDs | Existing ghost/remote IDs can be resolved when their phone is known; no general username lookup | Numeric remote IDs/ghost MXIDs; names can be found through search, not a direct username lookup | Numeric remote IDs/ghost MXIDs; names can be found through search, not a direct username lookup |
| Start genuinely new remote DMs | **Supported by source:** `create_dm` calls Google `GetOrCreateConversation`; not live-tested | **Source attempts it:** create-thread tasks are called; recipient-visible effects and error reliability need controlled testing | **Not equivalent:** an unknown recipient gets a local Matrix portal; the first manual text can initiate the remote DM |
| Return existing conversations | Supported through remote get-or-create plus portal reuse | Existing portal returned | Existing portal returned |
| Create/join the Matrix portal | `CreateMatrixRoom` is called; 201 means a new Matrix portal | Same shared implementation | Same shared implementation |

Portal creation, sync membership, encryption readiness and first-message interoperability still require live acceptance tests. HTTP 200/201 does not establish whether the **remote** thread already existed. Parallax therefore returns `createdOrExisting=unknown` and records only `portalCreated` from the status code.

## Meta implementation and source assessment

**Facebook Messenger and Instagram are implemented alongside Google Messages using the deployed provisioning API, an explicit submit-only search UI and service-specific disclosures.** Implementation was verified against the exact deployed commits and mocked responses; no live Meta search or creation endpoint was called.

### Shared recipient flow

Both deployed connectors advertise `search=true` and `create_dm=true`, but direct resolution accepts a **numeric Meta user ID**, not an arbitrary username. The safe flow is therefore:

1. Select the exact bridge account.
2. Submit an explicit name/username search (not search-as-you-type).
3. Select a returned person and review their name/avatar/available identifiers.
4. Confirm **Open conversation**, which calls `create_dm` with the result's numeric ID and the selected `login_id`.

Search uses:

```http
POST /v3/search_users?user_id=<redacted>&login_id=<redacted>
Content-Type: application/json

{"query":"<name-or-username>"}
```

Response shape:

```json
{
  "results": [
    {
      "id": "<numeric-meta-user-id>",
      "name": "<display-name>",
      "avatar_url": "mxc://<redacted>",
      "identifiers": ["instagram:<username>"],
      "mxid": "@<bridge-ghost>:<server>"
    }
  ]
}
```

Messenger currently filters results to one-to-one threads the viewer can message and de-duplicates IDs. Instagram returns its search results without an equivalent `CanViewerMessage` filter; Parallax skips missing or non-positive numeric IDs (such as `id: "0"`), de-duplicates repeated IDs and caps search results at 50. Messenger search also launches a secondary upstream search task whose result is ignored, so proxy/application rate limiting should not assume one UI search means only one upstream request. Search updates local ghost metadata but does not create a Matrix room or remote conversation.

The documented alternative of inviting the returned ghost MXID through normal Matrix room creation is not recommended for this flow: bridgev2 iterates the user's logins rather than accepting Parallax's selected `login_id`, and its ghost-invite handler contains a portal-creation race warning. The provisioning API provides the required account binding and room ID directly.

### Facebook Messenger behaviour

Deployed source: commit `08b6a6e946a59a43df2c3eb61c0a657a0be47fd5`, `pkg/connector/startchat.go`.

- Search: `SearchUserTask`; result names, avatars and ghost MXIDs are returned through provisioning.
- Resolve/create: `ParseIDFromString` accepts a signed-64-bit decimal identifier without a leading sign. Parallax uses only positive signed-64-bit IDs returned by search rather than accepting arbitrary typed IDs.
- Create: issues `CreateThreadTask` and `CreateWhatsAppDM`, then returns/creates the Matrix portal. These are immediate Meta-side setup operations, not just a local placeholder.
- **Reliability caveat:** the code overwrites the first task's error with the `CreateWhatsAppDM` result and only logs a `CreateWhatsAppDM` failure before returning portal data. A successful `create_dm` therefore does not prove remote thread setup succeeded. Controlled first-send/reply tests are mandatory. If those failures matter in practice, upstream error propagation should be fixed rather than hidden by Parallax.
- Messenger can wait up to 60 seconds for its connection (`ConnectWaitTimeout`), and `search_users` then synchronously refreshes each result's ghost profile (avatar download, Synapse upload, display name). Live searches on 2026-11-16 measured 44s while CONNECTED, and the morning's first attempt took 65s — the old 65-second deadline aborted it (nginx logged a 499). Parallax uses an 80-second bounded deadline for Meta read and search operations and maps `FI.MAU.NOT_CONNECTED` to a safe disconnected error.

Current upstream `main` (`c032c9fbbf79c17e389f37c3e4ee0134025f00ec` when inspected) retains the same create/error behaviour, so an upgrade alone is not evidence that this caveat is fixed.

### Instagram behaviour

Deployed source: commit `cbbf9c81c15fa684c9f10c87c77268b412364b69`, `pkg/igconnector/startchat.go`, `handlematrix.go` and `pkg/msgconv/igconv/from-matrix.go`.

- Search: Instagram's user-search GraphQL query returns the numeric interoperable messaging user ID, display name, username, avatar and ghost information.
- Existing portal: returned immediately without remote thread setup.
- Existing remote thread without a Matrix room: the bridge resolves its Instagram thread ID, fetches thread information and creates the Matrix portal.
- No known remote thread: `create_dm` creates a local Matrix DM portal with minimal membership. The first manually sent **text** can address the recipient and initiate the Instagram DM. Media requires an existing Instagram thread ID and cannot be the first message.
- **Acceptance caveat:** the deployed first-text path still has an upstream TODO questioning whether it is using the correct recipient ID form. Treat new-Instagram-DM delivery as unverified until a controlled test proves it. Do not describe portal creation alone as a successfully created Instagram conversation.

Current upstream adds `GetUserForNewDM` to enrich a new portal's user info and improves some error wrapping, but retains the same first-text recipient mechanism. Upgrading may be worthwhile for fixes, but does not remove the need for live new-DM testing.

### Implementation boundary

Separate opt-in HTTPS provisioning URLs enable Google Messages, Messenger and Instagram independently. When multiple services are configured, account discovery runs per service so one degraded or unreachable bridge produces a warning banner without hiding healthy accounts on other services. The module uses explicit submit-only search (`POST /v3/search_users`), positive numeric remote-ID recipients, authenticated `mxc://` result avatars, per-service errors/deadlines and the disclosures above, while keeping the same single-flight creation admission and joined-room wait. No Synapse change is needed. Basic UI wiring needs no Meta fork; reliable genuinely-new remote creation may still require upstream fixes if controlled live tests expose the Messenger error-propagation or Instagram first-text issues.

## Verified API operations

Base URL: a trusted, credential-free HTTPS URL ending in `/_matrix/provision`.

Authentication on every operation:

```http
Authorization: Bearer <existing-matrix-access-token>
```

Query parameters:

```text
user_id=<signed-in-matrix-user-id>
login_id=<login-id-returned-by-whoami>  # optional; required for explicit account selection
```

The bridge checks Matrix authentication and login ownership. Parallax never accepts a bridge URL from recipient input and never uses another account's login ID discovered outside the authenticated `whoami` response.

### Capabilities

```http
GET /v3/capabilities?user_id=<redacted>
```

Google Messages returned:

```json
{
  "resolve_identifier": {
    "create_dm": true,
    "lookup_phone": false,
    "lookup_email": false,
    "lookup_username": false,
    "any_phone": true,
    "contact_list": false,
    "search": false
  }
}
```

### Accounts

```http
GET /v3/whoami?user_id=<redacted>
```

Redacted response shape:

```json
{
  "logins": [
    {
      "id": "<account-login-id>",
      "name": "<account-label>",
      "state": {"state_event": "CONNECTED"}
    }
  ]
}
```

`GET /v3/logins` returns `{"login_ids": ["<account-login-id>"]}`; the UI uses `whoami` because it also supplies labels and state.

### Read-only recipient resolution

```http
GET /v3/resolve_identifier/<url-encoded-E.164-number>?user_id=<redacted>&login_id=<redacted>
```

A live check with a fictional-use international number returned only:

```json
{"id": "<same-number>"}
```

In the Google connector this is deliberately synthetic: no remote lookup, ghost, portal or reachability proof occurred. The UI consequently describes the number as syntactically valid, not reachable or RCS-capable.

### Explicit open/create

```http
POST /v3/create_dm/<url-encoded-E.164-number>?user_id=<redacted>&login_id=<redacted>
```

There is no request body. Redacted success response:

```json
{
  "id": "<remote-user-id>",
  "mxid": "<bridge-ghost-matrix-id>",
  "dm_room_mxid": "<matrix-room-id>"
}
```

- HTTP 200: the Matrix portal already existed.
- HTTP 201: `CreateMatrixRoom` created the Matrix portal.
- Neither response distinguishes a genuinely new remote thread from an existing one.
- No greeting, test message or other timeline event is sent by this operation in Parallax.

### Errors, time limits and retries

The adapter maps `M_INVALID_PARAM`, `M_NOT_JSON`, `M_NOT_FOUND`, `M_UNRECOGNIZED`, `FI.MAU.NOT_LOGGED_IN`, `FI.MAU.NOT_CONNECTED`, Matrix auth failures, permission errors and rate limits to safe categories without displaying bridge response details. Meta can report `M_LIMIT_EXCEEDED` with HTTP 400 rather than 429.

Google Messages read operations have a 15-second application deadline; Meta read and search operations have an 80-second deadline to cover Messenger's 60-second connection wait plus synchronous ghost-profile refresh (live searches measured 44-65s even while CONNECTED). Creation has an 85-second deadline across services, allowing for Google Messages' 60-second phone-response limit, Messenger's connection wait and portal work. Both stay below the proxy's 90-second read timeout. The request uses `package:http` abort support so the production IO client cancels pending request/response work at the deadline; abandoning a Dart Future alone would leave sockets running. A 10-second visible admission timer exposes delayed confirmation without allowing another submission. Network failures, timeouts, create-time 403 responses, malformed success responses and unknown server failures during creation remain **uncertain** and blocked from automatic retry. In particular, Google credential failures can be returned after its get-or-create RPC, so HTTP 403 is not treated as proof of non-creation. Room IDs acknowledged before the hard transport deadline are retained for the same session. An aborted request cannot later supply its room ID to Parallax, and its remote outcome still requires ordinary inbox inspection. Restarting the app loses this in-memory admission record; ordinary sync/inbox inspection is required before trying again.

There is no exactly-once claim. Google Messages uses get-or-create semantics and Mautrix reuses the portal key, but an ambiguous client failure cannot prove that nothing was created.

## Configuration and rollout

The feature is unavailable unless the flag and at least one valid HTTPS Mautrix provisioning URL are supplied at build time:

```sh
flutter build apk \
  --dart-define=PARALLAX_NEW_BRIDGED_MESSAGES=true \
  --dart-define=PARALLAX_GMESSAGES_PROVISIONING_URL=https://gmessages.example.org/_matrix/provision \
  --dart-define=PARALLAX_MESSENGER_PROVISIONING_URL=https://messenger.example.org/_matrix/provision \
  --dart-define=PARALLAX_INSTAGRAM_PROVISIONING_URL=https://instagram.example.org/_matrix/provision \
  --dart-define=PARALLAX_PHONE_DEFAULT_REGION=AU
```

Each service URL is optional; only configured services are queried or offered in the UI. `PARALLAX_PHONE_DEFAULT_REGION` is optional and applies only to Google Messages phone input. The device locale is used when it is absent; national input without any region is rejected rather than guessed. Australia is not hard-coded globally.

Configuration rules:

- HTTPS is mandatory; user info, query strings, fragments and non-Mautrix base paths are rejected.
- Redirects are disabled so the Matrix token cannot be forwarded to another endpoint.
- Responses are capped at 128 KiB and recipient input at 64 characters.
- The HTTPS proxy must forward `Authorization`, `user_id` and `login_id`, and should rate-limit discovery/creation.
- Provisioning identifiers are path parameters, and account selection uses query parameters. The app does not log them, but the bridge/reverse proxy access-log configuration must redact the full request target: recipient paths plus `user_id` and `login_id` query values. Redacting only the phone-number path is insufficient.
- No shared secret, bridge credential or other secret belongs in these Dart defines or in a URL.

The approved HTTPS routes are deployed on the Synology `matrix-server` nginx (`/usr/local/etc/nginx/conf.d/http.matrix.conf`, pre-change backup `http.matrix.conf.bak.bridged-provision-20261115-210633`, applied 2026-11-16 AEDT):

- `https://matrix.samprim.net/gmessages/_matrix/provision` → `127.0.0.1:29336`
- `https://matrix.samprim.net/meta/_matrix/provision` → `127.0.0.1:29335`
- `https://matrix.samprim.net/instagram/_matrix/provision` → `127.0.0.1:29337`

Each route applies a per-IP `limit_req` zone (30 requests/minute, burst 15, `nodelay`; excess requests get 503), a redacted access-log format that records only `METHOD /_matrix/provision/[redacted] PROTOCOL` plus status/bytes/user-agent (recipient paths and `user_id`/`login_id` query values never reach `matrix_access.log`), and 90-second proxy read/send timeouts that outlast Mautrix's 60-second waits while staying above Parallax's 80s/85s application deadlines. Unauthenticated requests return the bridge's `401 M_MISSING_TOKEN`; a 20-request burst verified 16 admissions then 503s. The Instagram route and its `/.well-known/matrix/mautrix` entry were added in the same change (well-known backup `mautrix.json.bak.bridged-provision-20261115-210633`).

The underlying bridge listeners remain plain HTTP on LAN ports `29336`/`29335`/`29337`; binding them to loopback only is a separate hardening follow-up. CI (`.gitea/workflows/android-apk.yml`) now builds per-commit test APKs with `PARALLAX_NEW_BRIDGED_MESSAGES=true`, the three deployed provisioning URLs and `PARALLAX_PHONE_DEFAULT_REGION=AU`.

## Rollback

Disable `PARALLAX_NEW_BRIDGED_MESSAGES` and redistribute the previous build (or rebuild without the flag). With the flag absent/false, the Start chat tile and live adapter are not available. Invalid or absent HTTPS configuration also fails closed.

Rollback does not delete Matrix rooms, leave remote chats, alter bridge mappings or remove remote conversation history. Nothing needs to be rolled back on Synapse or the bridges because this feature does not modify them.

## Files changed

- `pubspec.yaml`, `pubspec.lock`: add the maintained pure-Dart `phone_numbers_parser` package (resolved 9.0.29).
- `CHANGELOG.md`: record Google Messages, Facebook Messenger and Instagram bridged conversation support.
- `lib/features/bridged_messages/bridged_message_models.dart`: capabilities, account/recipient/conversation models, safe errors, trusted multi-service configuration, phone normalisation, Meta search/ID validation and strict `mxc://` avatar parsing.
- `lib/features/bridged_messages/mautrix_bridged_messages.dart`: bounded Mautrix adapter (`capabilities`, `whoami`, `search_users`, `resolve_identifier`, `create_dm`), per-service deadlines, resilient multi-service discovery and Matrix session ownership.
- `lib/features/bridged_messages/bridged_message_features.dart`: optional module interface, partial-failure warnings and feature-flagged resolver.
- `lib/features/bridged_messages/new_bridged_message_screen.dart`: account selection, capability-driven phone lookup or explicit Meta search, authenticated `mxc://` avatars, service-specific disclosures, explicit confirmation, errors and delayed-readiness UI.
- `lib/features/rooms_admin/start_chat_screen.dart`: optional entry point.
- `lib/features/rooms_admin/admin_ui.dart`: semantic label for the shared busy indicator.
- `test/bridged_message_models_test.dart`, `test/mautrix_bridged_messages_test.dart`, `test/new_bridged_message_screen_test.dart`: mocked unit and widget coverage.
- `.gitea/workflows/android-apk.yml`: enable the feature flag and the deployed HTTPS provisioning URLs in CI test builds.
- `docs/new-bridged-messages.md`: record the deployed HTTPS routes, redaction/rate-limit verification and CI enablement.

## Verification record and remaining work

Focused automated coverage includes configuration rejection across all three services, phone parsing/default regions, search query normalisation and control-character rejection, positive signed-64-bit Meta ID validation, strict `mxc://` avatar parsing and Matrix room-ID validation, capability mapping and malformed-capability rejection, Matrix-auth request construction, explicit account selection, account/recipient isolation, Meta `search_users` deduplication and `id: "0"` filtering, existing-portal response mapping, disconnected/unsupported accounts (`FI.MAU.NOT_LOGGED_IN` and `FI.MAU.NOT_CONNECTED`), partial multi-service discovery warnings, safe errors/rate limits, read-only resolution/search versus creation, abort-aware 15s/65s/75s deadlines and uncertain outcomes, duplicate submission, route disposal/reopening, late acknowledgement, stale-review and stale-search invalidation, service-specific disclosures (Google Messages reachability, Messenger remote setup caveat, Instagram text-before-media caveat), delayed Matrix readiness with recipient locking, and accessibility live regions. All bridge operations use mocks; no real create, search or message endpoint was called.

Current local verification: `dart format --output=none --set-exit-if-changed lib test` and full `flutter analyze` report no issues, and the complete `flutter test` run passes **2,097 tests** with 74 existing skips (including **62 focused feature tests** across the three bridged-messages test suites). These are local mock/unit/widget results; CI builds and verifies the signed arm64 release APK.

Before release acceptance:

1. Secure HTTPS routes with rate limiting and full request-target log redaction (recipient path and account query values): **deployed and verified** — see Configuration and rollout.
2. Build the flagged app for a designated test account.
3. With designated recipients, test opening an existing conversation, portal creation for an existing thread, genuinely new Google Messages remote creation, manual first send, reply in the same room and repeat without duplicate portals.
4. Test disconnected/re-auth-required accounts, delayed membership/sync and ambiguous timeout recovery on controlled infrastructure.
5. Verify the composer through Parallax's existing encryption/trust/send guards. Automated widget tests are not live Matrix or E2EE proof.
6. Test Messenger and Instagram independently with designated test accounts: explicit search, opening existing threads, Messenger's remote thread setup caveat under reconnect/error conditions, and Instagram's text-before-media new-DM path. No bridge or Synapse source change was made in this commit.
