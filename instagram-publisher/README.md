# TT Actualidad / Instagram: staging-only publisher

This directory is a **non-deployed backend preparation**, not a working Telegram integration. Its purpose is to minimize changes to production while the existing X workflow remains untouched.

## Contract
- Account: @ttactualidad (Instagram user ID 17841414511690117), linked through Facebook page TT Actualidad.
- Manual selection per item from the existing Telegram messages for TTiTTulares and TTendencias. No automatic posting on READY, and no expiry date for the pilot.
- Instagram status must be independent of X "Publicado" and "Desestimar"; never delete a Telegram message as a side effect of publishing to Instagram.
- Use a validated AI image as a public HTTPS JPEG URL and the text shown in Telegram, with a truthful AI illustration disclosure. PNG images must first be converted to JPEG and hosted; no re-generation needed.
- A unique key (source:event_id) prevents an item from being published twice across image revisions.

## Backend currently available
- GET /health reports service identity, with active:false (not a claim of configured publication).
- POST /publish accepts source, event_id, revision, telegram_message_id, image_url and caption, *only* from a trusted server with Authorization: Bearer [INSTAGRAM_INTERNAL_SECRET].
- The URL is restricted to the existing generated-images JPEG directories; captions must be <= 2200 characters.
- D1 state machine reserves a unique item, creates a media container, checks its FINISHED status and calls media_publish. On an uncertain outcome it blocks further publication until reconciliation, rather than risking duplicates.
- There is no token or password in this repository.


## Dedicated D1 database (created, not yet initialized)
- Database name: `tt-actualidad-instagram`
- Database ID: `4eacd44c-212c-4a49-a907-fbbf561b969f`
- Worker binding: `IG_DB` (configured in `wrangler.jsonc`).
- Schema (idempotent): `migrations/0001_instagram_posts.sql`.
- To initialize later after Cloudflare authorization, from the `instagram-publisher` directory: `npx wrangler d1 execute tt-actualidad-instagram --remote --file=migrations/0001_instagram_posts.sql`.
- Alternatively, paste the two SQL statements from the migration into the Cloudflare **D1 Console** for this database; they are safe to run more than once.
- An empty database is not ready for publication, and should not be considered live.

## Still necessary before any production activation
1. Obtain a fresh **suitable long-lived** Facebook Page token (the old app authorization was revoked after its token was shown in a screenshot). Confirm correct scope and rotation. Never paste credentials in chat, source or logs.
2. Configure a **separate** Cloudflare Worker and separate D1 database binding IG_DB, with secret INSTAGRAM_PAGE_ACCESS_TOKEN and secret INSTAGRAM_INTERNAL_SECRET (random, 32+ chars); INSTAGRAM_USER_ID is non-secret configuration. Do not install into the existing TT Control D1 database.
3. Wire the verified existing Telegram callback routes for each bot. On button click: verify the allowed chat and the original delivery identity before building a trusted request. Do not take image or text from public request parameters.
4. Add exactly one independent "Publicar en Instagram" button to both existing Telegram keyboards and their refresh/retry paths. Send results back by editing the button to a link "Publicado en Instagram" or a recoverable error without touching X status, text or images.
5. Prepare a durable snapshot of source event, revision, Telegram message ID, caption and actual AI JPEG when sending Telegram; items may disappear from editorial "prepared" after they are marked Published on X.
6. Add automated tests against mocked Meta API, idempotency and Telegram callbacks. Test on preview and deploy only after validation.

**No user steps are needed at this stage.** This component is intentionally fail-closed until the callback integration and Cloudflare secrets have been completed.
