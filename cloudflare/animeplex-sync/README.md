# AnimePlex Cloudflare + Supabase VPS replacement (STAGING ONLY)

This folder replaces the **HTTP contract** of `sync.zangetsu.online`, without requiring a permanent VPS. It does **not** switch installed APKs or remove the old VPS. Production cutover requires a Cloudflare deployment, verified secrets, data migration, and end-to-end tests.

## Components

- Cloudflare Worker `animeplex-sync`: forwards the exact allowlisted PostgREST table paths to the existing AnimePlex Supabase REST API, including `X-Profile-Grants`, pagination and `Prefer` headers. Supabase's authenticated user JWT and database RLS remain authoritative; no service-role key or unrestricted proxy is used.
- Existing `public.profile_lock` RPC in the AnimePlex Supabase project: checks PIN, recovery, device grants and backup access using its private SQL tables and restrictive RLS.
- Worker `/klipy/v1/gifs/search`, `/klipy/v1/gifs/items`, `/klipy/v1/gifs/share/:slug`: JWT-checked, route-allowlisted KLIPY relay; the external KLIPY credential stays a Worker secret. Rate-limited at 120 requests per user per 60 seconds, per Cloudflare location.
- Worker `/stremio/v1/configuration`, `/stremio/v1/seal`, `/stremio/v1/open`: AES-256-GCM authenticated encryption with user-bound AAD `stremio-server-v1|<user-id>`, same envelope format as the VPS service. Versioned compare-and-swap storage uses the new `public.stremio_configuration` RPC in Supabase. SQL file: `sql/001_stremio_encrypted_storage.sql`; applied to the connected AnimePlex project and permission-tested.
- Existing `cloudflare/log-intake`: source updated to accept both legacy Zangetsu and new AnimePlex JWT issuers; **redeploy this existing Worker separately** before relying on new-account avatar uploads or log intake. In its environment, point `PROFILE_LOCK_API_BASE` to the verified new sync endpoint only at cutover.

## Existing app URLs / endpoints

Use the same **root** `VPS_SYNC_URL` for all of these routes:

```
/history  /profile_history  /reading_history  /profile_reading_history
/mylist  /profile_mylist  /list_categories  /profile_list_categories
/mylist_categories  /profile_mylist_categories
/mylist_sync_clock  /mylist_sync_tombstones  /viewer_profiles  /backups
/rpc/profile_lock
/klipy/v1/gifs/search  /klipy/v1/gifs/items  /klipy/v1/gifs/share/:slug
/stremio/v1/seal  /stremio/v1/open  /stremio/v1/configuration
```

**Out of scope for this Worker:** Supabase Auth, Watch Together Realtime, TV pairing, releases, and admin controls. They already use separate Supabase endpoints and must be verified independently.

## Deploy (Cloudflare account action required)

1. Connect GitHub to Cloudflare Workers (Workers & Pages → Create Worker → Import repository) with repository `Abhishekred/Animeplex-V1`, branch `test2`, **root directory `cloudflare/animeplex-sync`**. Worker name `animeplex-sync` as in `wrangler.toml`. Or add GitHub Actions repository secrets `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`, then run the **Deploy AnimePlex Cloudflare Sync (manual)** workflow.
2. Configure Worker secrets in Cloudflare **(never commit, paste into chat, or put in public GitHub files)**:
   - `KLIPY_API_KEY` — the existing upstream KLIPY API credential. Without it GIF search returns 503.
   - `STREMIO_AES256_KEY` — base64 of the ORIGINAL VPS 32-byte `stremio_key`. **Do not use a new key if you need to decrypt old encrypted data.** Without it Stremio returns 503.
3. Check Worker health at `https://<your-worker-domain>/health`: it reports `klipy`, `stremio`, and `rateLimit` binding status, but cannot prove those credentials are valid. The Worker uses a public **publishable** Supabase key only; private table access is enforced by the signed-in user's JWT and RLS.
4. Run `node --test cloudflare/animeplex-sync/test/worker.test.mjs` and `node --test cloudflare/log-intake/avatar_slot.test.mjs` (also covered by GitHub Cloudflare Sync CI). Then run the **read-only smoke checks** with a disposable Supabase test account JWT:
   ```bash
   ANIMEPLEX_SYNC_URL=https://YOUR_WORKER.workers.dev ANIMEPLEX_TEST_JWT=TEST_ACCOUNT_TOKEN node cloudflare/animeplex-sync/smoke.mjs
   ```
5. Verify real account sign-in, name/avatar, My List add/remove and multiple devices, reading/watching progress, 4 viewer profiles, profile PIN grant enforcement, locked profile privacy, backup/restore, TV pairing, Watch Together, encrypted Stremio backups (including old ciphertext), KLIPY and offline retry. Verify storage and free-tier quotas. Test independently on Android phone and TV.
6. **Only after passing full parity and data migration** build a staging APK with `--dart-define=VPS_SYNC_URL=https://YOUR_WORKER.workers.dev`. Do not edit the default app URL or production APK prematurely. Keep the VPS and pre-cutover backup for rollback.
7. Old-user cloud records still on the VPS require an authorized export and verified import into the AnimePlex Supabase project. This repo does **not** have access to the old VPS database or the old Stremio encryption key. A SQL schema match is not a data migration. Do not delete the old VPS or old encrypted backups.

## Security and free-tier constraints

- Worker permits only the allowlisted PostgREST paths and the explicit public proxy routes; refuses all other paths, including privileged Supabase Auth/admin endpoints.
- All data calls forward the **user JWT**, not a service-role key. Supabase RLS enforces account/profile ownership, including PIN locks.
- Cloudflare rate limiter is **per-location, approximate**, not a globally strict counter.
- Cloudflare Workers Free has limits (100,000 requests/day; 10ms CPU per request as documented Nov 2026). Supabase Free can pause from inactivity and has usage quotas. Thus ₹0/month and feature-equivalence do **not** imply guaranteed 24/7 uptime or unlimited traffic.
- Backup scheduling and R2 restoration replace the old VPS's systemd + `pg_dump` arrangement only after separate verification. The current Worker does not claim to provide automatic full database backups.
- Do not move users to the new endpoint until the live endpoint exists and every security and data-parity check passes.
