-- Private, daily application-data snapshot for AnimePlex.
-- Supabase Vault secret named animeplex_r2_backup_token MUST also be configured
-- as Cloudflare animeplex-backup Worker secret BACKUP_TOKEN before this can succeed.
-- Data-only JSON; schema/roles/indexes/WAL require separate pg_dump/PITR backup.
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
create schema if not exists animeplex_private;
revoke all on schema animeplex_private from public, anon, authenticated;

create or replace function animeplex_private.enqueue_offsite_backup()
returns bigint language plpgsql security definer set search_path = pg_catalog
as $$
declare
  backup_secret text;
  rec record;
  rows_json jsonb;
  snapshot_tables jsonb := '{}'::jsonb;
  payload jsonb;
  request_id bigint;
begin
  select decrypted_secret into backup_secret from vault.decrypted_secrets
   where name = 'animeplex_r2_backup_token' limit 1;
  if backup_secret is null or length(backup_secret) < 32 then
    raise exception 'AnimePlex backup secret not configured in Supabase Vault';
  end if;
  for rec in select table_schema, table_name from information_schema.tables
    where table_type='BASE TABLE'
      and ((table_schema='public' and table_name not in ('admin_rate_limit_buckets'))
      or (table_schema='auth' and table_name in ('users','identities'))
      or (table_schema='sync_private' and table_name in
          ('profile_pins','profile_pin_devices','profile_pin_grants')))
    order by table_schema, table_name
  loop
    execute format('select coalesce(jsonb_agg(to_jsonb(r)), ''[]''::jsonb) from %I.%I as r',
      rec.table_schema,rec.table_name) into rows_json;
    snapshot_tables := snapshot_tables || jsonb_build_object(
      rec.table_schema || '.' || rec.table_name, rows_json);
  end loop;
  payload:=jsonb_build_object('version',1,'project_ref','iwiujqjipotwvigvaaid',
    'created_at',clock_timestamp(),'tables',snapshot_tables);
  if octet_length(payload::text)>16*1024*1024 then
    raise exception 'AnimePlex snapshot exceeds 16 MiB';
  end if;
  select net.http_post(
    url:='https://animeplex-backup.ttest.workers.dev/v1/snapshot',
    headers:=jsonb_build_object('Content-Type','application/json',
      'Authorization','Bearer '||backup_secret),
    body:=payload,timeout_milliseconds:=20000) into request_id;
  return request_id;
end
$$;
revoke all on function animeplex_private.enqueue_offsite_backup()
  from public, anon, authenticated;
select cron.schedule('animeplex-daily-r2-data-backup','30 1 * * *',
  'select animeplex_private.enqueue_offsite_backup();');
