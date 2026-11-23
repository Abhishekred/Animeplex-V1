# AnimePlex daily R2 data snapshots

Deployed in Cloudflare account `312660d6e5351a8947eddeded55f6c5c` and Supabase project
`iwiujqjipotwvigvaaid`.

* Private R2 bucket: `animeplex-backups` (NO public R2 URL).
* Cloudflare Worker: `https://animeplex-backup.ttest.workers.dev`.
* Supabase cron job: `animeplex-daily-r2-data-backup`, daily at **01:30 UTC**.
* R2 lifecycle: delete snapshot objects after **30 days**.
* Source SQL: `sql/001_daily_offsite_data_snapshot.sql` (applied to Supabase).

## REQUIRED one-time activation

Create a strong, random **64-character hexadecimal** token in a password manager;
never paste it into chat or GitHub. Save the **same** token in:

1. **Cloudflare** > Workers > `animeplex-backup` > Settings > Variables and Secrets,
   secret type, name `BACKUP_TOKEN`.
2. **Supabase** > Database > Vault, create secret named `animeplex_r2_backup_token`
   with the *same* value.

No full data snapshot occurs before both secrets match.

Afterward run SQL manually as admin:
`select animeplex_private.enqueue_offsite_backup();`
Then inspect asynchronous `net._http_response` for HTTP 201 and check the private
R2 bucket for a file under `snapshots/YYYY-MM-DD/`. Never mark backup
verified merely because the scheduler exists.

## Exact scope / caveats

This is an **off-site JSON application-data snapshot**, not a complete
Postgres `pg_dump`: it exports public app tables plus select Auth and private
PIN tables. It intentionally excludes Stremio configuration while that
feature remains on hold. **Schema definitions, policies, extensions, Auth
infrastructure, storage objects, PITR/WAL, and full restore automation are
NOT included**. Set up periodic `pg_dump` or Supabase paid backups separately
for full disaster recovery. One snapshot is capped at 16 MiB, and larger
exports fail rather than silently truncating data.

The snapshot can contain personal and authentication data. Keep its R2
bucket private, strictly restrict access, and never log or publish its
contents. A 30-day retention rule is active.
