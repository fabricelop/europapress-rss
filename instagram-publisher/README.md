# TT Actualidad / Instagram: staging-only publisher

The isolated publisher Worker has been deployed at `https://tt-actualidad-instagram-pilot.fabricelop.workers.dev`. Telegram routing, new Meta authorization and explicit pilot activation are still pending; it is not yet a functioning end-to-end Instagram integration. Its purpose is to minimize changes to production while the existing X workflow remains untouched.

## Contract
- Account: @ttactualidad (Instagram user ID 17841414511690117), linked through Facebook page TT Actualidad.
- Manual selection per item from the existing Telegram messages for TTiTTulares and TTendencias. No automatic posting on READY, and no expiry date for the pilot.
- Instagram status must be independent of X "Publicado" and "Desestimar"; never delete a Telegram message as a side effect of publishing to Instagram.
- Use a validated AI image as a public HTTPS JPEG URL and the text shown in Telegram, with a truthful AI illustration disclosure. PNG images must first be converted to JPEG and hosted; no re-generation needed.
- A unique key (source:event_id) prevents an item from being published twice across image revisions.

## Backend currently available
- GET /health reports service identity and the actual active flag; it becomes true only when the explicit activation switch and the required secrets/bindings are present.
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

## Cloudflare TT Control runtime investigation (8 October 2026)
- Worker `tt-control` serves `/api/ttittulares-webhook-version` (HTTP 200, `2026-10-08-telegram-callback-preflight-v1`). The TTiTTulares and TTendencias Cloudflare Workers both pass read-only health checks.
- Authenticated read-only Cloudflare API GETs for `tt-control/content/v2` and `tt-control` both returned HTTP 200 with `multipart/form-data`, approximately 480 KB.
- Earlier diagnostics searched the entire multipart response as text and found no `telegram`, `callback`, or JS imports. **These negative searches are not evidence that the active Worker lacks the routes.** Inspect the MIME parts and original Worker entrypoint before modifying routing.
- Production `tt-control` has not been redeployed or altered. Live pilot publisher remains inactive until configured with safe Meta credentials and proven Telegram routing.
- Latest local authenticated MIME-part inspection found a SINGLE textual JavaScript script of ~137 KB, including literal `/api/telegram-webhook` and `/api/ttittulares-telegram-callback`; `tt:p` and `tt:d` were not both found as raw literals. This establishes a Telegram callback forwarder exists. It does NOT yet establish whether `tt:i` is accepted: classify the callback dispatch safely before patching or deploying the gateway. The raw Worker may be bundled/minified; code should not be pasted in chat.

## Integration work staged in PR #112 (no deployment)
- `shared/instagram_pilot.py`: opt-in JPEG creation, factual text plus AI disclosure, guarded "📸 Publicar en Instagram" Telegram button.
- `.github/workflows/send-ttittulares-ready-telegram.yml`: prepares and commits JPEG + immutable Instagram snapshot on the Telegram delivery row (disabled unless `INSTAGRAM_PILOT_ENABLED=1`).
- `trends/send_explained_telegram.py` and its delivery workflow: same controlled path for TTendencias, without changing X buttons.
- `no-vercel/ttittulares-worker/src/index.js`: new verified `tt:i:event_id` handler, checks the delivered Telegram message and configured allowed chat, reads its trusted GitHub snapshot, invokes the publisher; never touches X decisions.
- `trends/telegram_bot.py`: new `tx:i:trend_id:revision` handler, checking the registered Telegram chat and delivered message, independent from `tx:p/tx:d`.
- Automated unit tests and staging CI; **no actual Meta posting has been exercised**.

**Deployment blockers (must verify in live infrastructure):**
1. The deployed `tt-control` gateway was inspected read-only: it has `/api/telegram-webhook` and `/api/ttittulares-telegram-callback`, a `service.fetch` forwarder, and a generic `tt:` prefix near that forwarder. No explicit `p/d`-only filter was detected. Do **not** redeploy the gateway: first deploy the updated downstream TTiTTulares Worker, then verify a real `tt:i` callback with Meta still disabled and existing X actions untouched.
2. Confirm that TTendencias runs the `trends/telegram_bot.py` package listener with the new code and supply `INSTAGRAM_PUBLISHER_URL` and `INSTAGRAM_INTERNAL_SECRET` as private runtime variables.
3. Set separate secret `INSTAGRAM_ALLOWED_CHAT_ID` on the TTiTTulares Worker, and `INSTAGRAM_PUBLISHER_URL` and `INSTAGRAM_INTERNAL_SECRET`. Never expose the real Telegram bot tokens or page token.
4. Install the isolated Instagram Worker, its D1 binding, and a newly authorized long-lived Meta Page token, without touching the existing Cloudflare Workers. Check token expiry/refresh.
5. Confirm end-to-end with one selected post and verify Telegram retains X actions, the archive and IA images, receives Meta permalink, and does not duplicate on repeated click. Only then set the repo variable `INSTAGRAM_PILOT_ENABLED=1`.
6. For a container still processing after background polls, the pilot currently asks the user to retry; a reliable scheduled retry and Telegram status notification should be added before promising entirely hands-off completion in every case.

## Still necessary before any production activation
1. Obtain a fresh **suitable long-lived** Facebook Page token (the old app authorization was revoked after its token was shown in a screenshot). Confirm correct scope and rotation. Never paste credentials in chat, source or logs.
2. Configure a **separate** Cloudflare Worker and separate D1 database binding IG_DB, with secret INSTAGRAM_PAGE_ACCESS_TOKEN and secret INSTAGRAM_INTERNAL_SECRET (random, 32+ chars); INSTAGRAM_USER_ID is non-secret configuration. Do not install into the existing TT Control D1 database.
3. Wire the verified existing Telegram callback routes for each bot. On button click: verify the allowed chat and the original delivery identity before building a trusted request. Do not take image or text from public request parameters.
4. Add exactly one independent "Publicar en Instagram" button to both existing Telegram keyboards and their refresh/retry paths. Send results back by editing the button to a link "Publicado en Instagram" or a recoverable error without touching X status, text or images.
5. Prepare a durable snapshot of source event, revision, Telegram message ID, caption and actual AI JPEG when sending Telegram; items may disappear from editorial "prepared" after they are marked Published on X.
6. Add automated tests against mocked Meta API, idempotency and Telegram callbacks. Test on preview and deploy only after validation.

**Activation must remain disabled until one selected post has been validated end-to-end.** The Worker refuses publication when `INSTAGRAM_PUBLISH_ENABLED` is not exactly `1`. Production Telegram routing stays unchanged until the downstream integration is verified.
