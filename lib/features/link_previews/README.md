# Link previews

Shows the page title and a small image for the first web link in a message,
under the message text (WhatsApp/Element style).

- `link_previews.dart` — the `LinkPreview` model, the `LinkPreviewSource`
  interface a backend implements, and `firstPreviewableLink` (built on the
  rich timeline's link tokenizer, so Matrix permalinks and email addresses
  are not previews).
- `link_preview_cache.dart` — one cache per backend: memory LRU, one request
  per URL at a time, successes saved per account on disk (newest 300),
  failures retried after 10 minutes and never saved.
- `link_preview_card.dart` — the bubble footer. Nothing is shown while
  loading, or when the page has no preview.
- `link_preview_hooks.dart` — the entry footer and the Settings → Media →
  Link previews section.

## Privacy

The **homeserver** fetches the page (`GET /_matrix/client/v1/media/preview_url`),
not the phone, and hosts the preview image as an `mxc://` URI. In an ordinary
room the server can already read the link, so previews are on by default. In
an encrypted room that would tell the server what was sent, so previews stay
off unless the user turns on **Preview links in encrypted chats**. A room
whose encryption state is unknown is treated as encrypted.

Saved previews (page titles and image IDs) are deleted on sign-out together
with the account's thumbnail folder. Images load through the backend's usual
avatar loader: 96 px thumbnails, size-bounded, disk-cached, four at a time.

## Tests

`test/link_previews_test.dart` covers link extraction, JSON tolerance, cache
hits/dedup/negative TTL/disk persistence/LRU/clearing, the gating rules
(settings, media kinds, redactions, encrypted and unknown rooms, backends
without support) and the card inside a real message bubble. No live server
is contacted: `MatrixBackend.fetchLinkPreview` is the only network path and
is faked in tests.
