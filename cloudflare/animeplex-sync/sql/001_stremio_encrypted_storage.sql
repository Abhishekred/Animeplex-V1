-- AnimePlex Cloudflare/Supabase VPS replacement: Stremio encrypted configuration.
-- Only ciphertext is stored. Worker keeps the SAME AES-256-GCM secret as the old VPS.
-- This migration is additive; existing profile, My List and History rows are untouched.
begin;
create schema if not exists sync_private;
create table if not exists sync_private.stremio_configurations (
  user_key text primary key,
  version bigint not null default 0,
  payload jsonb,
  updated_at timestamptz not null default now()
);
revoke all on sync_private.stremio_configurations from public, anon, authenticated;
alter table sync_private.stremio_configurations enable row level security;

create or replace function public.stremio_configuration(
  p_expected_version bigint default null,
  p_payload jsonb default null
) returns jsonb language plpgsql security definer set search_path = '' as $function$
declare
  owner_key text := (select auth.uid())::text;
  stored sync_private.stremio_configurations%rowtype;
  accepted boolean;
begin
  if owner_key is null or coalesce((select auth.jwt()->>'is_anonymous') = 'true', false) then
    raise sqlstate 'PT401' using message = 'Sign in required';
  end if;
  if p_expected_version is not null and (
    p_expected_version < 0
    or p_payload is null
    or p_payload->>'format' is distinct from 'stremio-server-v1'
    or octet_length(p_payload::text) > 2097152
  ) then
    raise sqlstate 'PT400' using message = 'Invalid encrypted configuration';
  end if;
  insert into sync_private.stremio_configurations(user_key) values(owner_key)
    on conflict do nothing;
  select * into stored from sync_private.stremio_configurations
    where user_key = owner_key for update;
  accepted := p_expected_version is null or p_expected_version = stored.version;
  if p_expected_version is not null and accepted then
    update sync_private.stremio_configurations
    set version = version + 1, payload = p_payload, updated_at = clock_timestamp()
    where user_key = owner_key returning * into stored;
  end if;
  return jsonb_build_object('version', stored.version, 'payload', stored.payload, 'accepted', accepted);
end;
$function$;
revoke all on function public.stremio_configuration(bigint, jsonb) from public, anon;
grant execute on function public.stremio_configuration(bigint, jsonb) to authenticated;
notify pgrst, 'reload schema';
commit;
