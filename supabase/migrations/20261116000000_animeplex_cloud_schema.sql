-- AnimePlex cloud schema for new Supabase project; preserved admin_* and app_* tables.

-- SOURCE supabase/migrations/0001_schema.sql
-- supabase/migrations/0001_schema.sql
-- All user-data tables key on user_key TEXT. Pre-migration rows hold the
-- Appwrite user id; migrate-account rewrites them to the Supabase auth uid
-- (as text) at claim time, after which user_key = auth.uid()::text always.

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  avatar_path text,                       -- Storage object path, e.g. legacy/<uid>.jpg
  legacy_uid text unique,                 -- Appwrite user id, null for post-switch signups
  needs_password_capture boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.mylist (
  user_key text not null,
  source_id text not null,
  item_id text not null,
  title text not null default '',
  cover text,
  cover_headers jsonb,
  url text,
  type text,
  status text,
  added_at bigint not null default 0,
  primary key (user_key, source_id, item_id)
);

create table if not exists public.history (
  user_key text not null,
  source_id text not null,
  show_id text not null,
  show_title text not null default '',
  cover text,
  cover_headers jsonb,
  show_url text,
  category text,
  episode_id text,
  episode_number double precision,
  episode_url text,
  position_ms bigint not null default 0,
  duration_ms bigint not null default 0,
  updated_at bigint not null default 0,
  mal_id text,
  primary key (user_key, source_id, show_id)
);

create table if not exists public.backups (
  user_key text primary key,
  payload text not null,                  -- JSON string, <=1MB
  updated_at timestamptz not null default now()
);

create table if not exists public.watch_rooms (
  code text primary key,                  -- 8-char room code
  host_key text not null,                 -- host's user_key (auth.uid()::text)
  status text not null default 'live',
  content jsonb,                          -- current content descriptor (episode, title, source)
  host_pos_ms bigint not null default 0,
  host_rate double precision not null default 1.0,
  host_playing boolean not null default true,
  updated_at timestamptz not null default now()
);

create table if not exists public.tv_pairings (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  tv_secret text not null,                -- TV-generated; gates reads of app_secret via the pair-tv function
  status text not null default 'pending', -- pending | approved | consumed
  device_name text not null default '',
  app_user_id text,
  app_secret text,
  tracker_blob text,
  expires_at bigint not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_tv_pairings_code on public.tv_pairings(code);



-- SOURCE supabase/migrations/0002_rls.sql
-- supabase/migrations/0002_rls.sql
alter table public.profiles     enable row level security;
alter table public.mylist       enable row level security;
alter table public.history      enable row level security;
alter table public.backups      enable row level security;
alter table public.watch_rooms  enable row level security;
alter table public.tv_pairings  enable row level security;

-- Helper: current user's key as text
-- (auth.uid() is uuid; user_key stores it as text)

-- profiles: own row full access
create policy profiles_self on public.profiles
  for all using (id = auth.uid()) with check (id = auth.uid());

-- mylist / history / backups: strictly own rows
create policy mylist_own on public.mylist
  for all using (user_key = auth.uid()::text) with check (user_key = auth.uid()::text);
create policy history_own on public.history
  for all using (user_key = auth.uid()::text) with check (user_key = auth.uid()::text);
create policy backups_own on public.backups
  for all using (user_key = auth.uid()::text) with check (user_key = auth.uid()::text);

-- watch_rooms: any authenticated user can read (join by code) and create;
-- update/delete host-only. Joining writes nothing (Presence covers it).
create policy rooms_read on public.watch_rooms
  for select to authenticated using (auth.uid() is not null);
create policy rooms_create on public.watch_rooms
  for insert with check (host_key = auth.uid()::text);
create policy rooms_host_update on public.watch_rooms
  for update using (host_key = auth.uid()::text) with check (host_key = auth.uid()::text);
create policy rooms_host_delete on public.watch_rooms
  for delete using (host_key = auth.uid()::text);

-- tv_pairings: clients may ONLY insert a pending row (a TV registering).
-- No client select/update/delete — the TV never reads the table; it learns
-- approval + the login secret via the pair-tv function's `poll` action (passing
-- the tv_secret it generated), and the function (service role) returns app_secret
-- only when that secret matches. This prevents any client reading another
-- device's app_secret / tracker_blob.
create policy pairings_insert on public.tv_pairings
  for insert with check (status = 'pending');

-- Public name+avatar for the party UI, WITHOUT leaking legacy_uid /
-- needs_password_capture (RLS is row-level; a view is the column filter).
create or replace view public.public_profiles with (security_invoker = true) as
  select id, display_name, avatar_path from public.profiles;
grant select on public.public_profiles to authenticated;



-- SOURCE supabase/migrations/0003_storage.sql
-- supabase/migrations/0003_storage.sql
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

-- Public read (avatars shown via plain image widget).
create policy avatars_public_read on storage.objects
  for select using (bucket_id = 'avatars');

-- Authenticated users write only inside their own folder <uid>/...
create policy avatars_own_write on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_own_update on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy avatars_own_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);



-- SOURCE supabase/migrations/0003_realtime.sql
-- Realtime: Watch Together subscribes to Postgres changes on watch_rooms
-- (episode change / pause-stop anchor / host transfer / room end) over the same
-- channel that carries host-beat broadcast + presence + chat. The table MUST be
-- in the supabase_realtime publication or that binding errors and takes the
-- whole channel down (no sync, no roster, no chat). REPLICA IDENTITY FULL makes
-- the filtered UPDATE events carry the complete row. Writes here are rare (the
-- 4s beat is broadcast, zero-write), so the WAL cost is negligible.
alter publication supabase_realtime add table public.watch_rooms;
alter table public.watch_rooms replica identity full;



-- SOURCE supabase/migrations/0004_reading_history.sql
-- supabase/migrations/0004_reading_history.sql
-- Continue Reading: per-title reading progress for manga/novel mode, the
-- reading counterpart of public.history (Continue Watching). Not applied
-- automatically — run this by hand against the project, same as 0001-0003
-- were. Until it's run, ReadHistory degrades to local-only (see
-- lib/core/reading/read_history.dart).

create table if not exists public.reading_history (
  user_key text not null,
  source_id text not null,
  show_id text not null,
  title text not null default '',
  cover text,
  chapter_id text,
  chapter_number double precision,
  chapter_url text,
  pos integer not null default 0,
  total integer not null default 0,
  updated_ms bigint not null default 0,
  -- 'manga' or 'novel' — which reader a chapter opens in (see ReadEntry.type
  -- in lib/core/reading/read_history.dart). No default: the app always
  -- writes it now, and a row missing it is read back as 'novel' client-side
  -- (readEntryTypeFromName), not here — a DB default would silently paper
  -- over a future write path that forgets to set it.
  type text,
  primary key (user_key, source_id, show_id)
);

alter table public.reading_history enable row level security;

-- Same policy shape as history_own in 0002_rls.sql: strictly own rows.
create policy reading_history_own on public.reading_history
  for all using (user_key = auth.uid()::text) with check (user_key = auth.uid()::text);



-- SOURCE supabase/migrations/0005_viewer_profiles.sql
create table if not exists public.viewer_profiles (
  user_key text not null,
  profile_id text not null,
  name text not null check (char_length(btrim(name)) between 1 and 24),
  avatar integer not null default 0 check (avatar between 0 and 11),
  is_kids boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (user_key, profile_id)
);

create or replace function public.enforce_viewer_profile_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(hashtext(new.user_key), 0);
  if not exists (
    select 1 from public.viewer_profiles
    where user_key = new.user_key and profile_id = new.profile_id
  ) and (
    select count(*) from public.viewer_profiles where user_key = new.user_key
  ) >= 4 then
    raise exception 'A maximum of four profiles is allowed per account';
  end if;
  return new;
end;
$$;

drop trigger if exists viewer_profile_limit on public.viewer_profiles;
create trigger viewer_profile_limit
before insert on public.viewer_profiles
for each row execute function public.enforce_viewer_profile_limit();

alter table public.viewer_profiles enable row level security;
drop policy if exists viewer_profiles_own on public.viewer_profiles;
create policy viewer_profiles_own on public.viewer_profiles
  for all using (user_key = auth.uid()::text)
  with check (user_key = auth.uid()::text);

create table if not exists public.profile_mylist (
  user_key text not null,
  profile_id text not null,
  source_id text not null,
  item_id text not null,
  title text not null default '',
  cover text,
  cover_headers jsonb,
  url text,
  type text,
  status text,
  added_at bigint not null default 0,
  primary key (user_key, profile_id, source_id, item_id),
  foreign key (user_key, profile_id)
    references public.viewer_profiles(user_key, profile_id) on delete cascade
);

create table if not exists public.profile_history (
  user_key text not null,
  profile_id text not null,
  source_id text not null,
  show_id text not null,
  show_title text not null default '',
  cover text,
  cover_headers jsonb,
  show_url text,
  category text,
  episode_id text,
  episode_number double precision,
  episode_url text,
  position_ms bigint not null default 0,
  duration_ms bigint not null default 0,
  updated_at bigint not null default 0,
  mal_id text,
  primary key (user_key, profile_id, source_id, show_id),
  foreign key (user_key, profile_id)
    references public.viewer_profiles(user_key, profile_id) on delete cascade
);

create table if not exists public.profile_reading_history (
  user_key text not null,
  profile_id text not null,
  source_id text not null,
  show_id text not null,
  title text not null default '',
  cover text,
  chapter_id text,
  chapter_number double precision,
  chapter_url text,
  pos integer not null default 0,
  total integer not null default 0,
  updated_ms bigint not null default 0,
  type text,
  primary key (user_key, profile_id, source_id, show_id),
  foreign key (user_key, profile_id)
    references public.viewer_profiles(user_key, profile_id) on delete cascade
);

create table if not exists public.profile_list_categories (
  user_key text not null,
  profile_id text not null,
  id uuid not null default gen_random_uuid(),
  name text not null,
  position integer not null default 0,
  primary key (user_key, profile_id, id),
  foreign key (user_key, profile_id)
    references public.viewer_profiles(user_key, profile_id) on delete cascade
);

create table if not exists public.profile_mylist_categories (
  user_key text not null,
  profile_id text not null,
  source_id text not null,
  item_id text not null,
  category_id uuid not null,
  primary key (user_key, profile_id, source_id, item_id, category_id),
  foreign key (user_key, profile_id)
    references public.viewer_profiles(user_key, profile_id) on delete cascade,
  foreign key (user_key, profile_id, category_id)
    references public.profile_list_categories(user_key, profile_id, id)
    on delete cascade
);

alter table public.profile_mylist enable row level security;
alter table public.profile_history enable row level security;
alter table public.profile_reading_history enable row level security;
alter table public.profile_list_categories enable row level security;
alter table public.profile_mylist_categories enable row level security;

create policy profile_mylist_own on public.profile_mylist
  for all using (user_key = auth.uid()::text)
  with check (user_key = auth.uid()::text);
create policy profile_history_own on public.profile_history
  for all using (user_key = auth.uid()::text)
  with check (user_key = auth.uid()::text);
create policy profile_reading_history_own on public.profile_reading_history
  for all using (user_key = auth.uid()::text)
  with check (user_key = auth.uid()::text);
create policy profile_list_categories_own on public.profile_list_categories
  for all using (user_key = auth.uid()::text)
  with check (user_key = auth.uid()::text);
create policy profile_mylist_categories_own on public.profile_mylist_categories
  for all using (user_key = auth.uid()::text)
  with check (user_key = auth.uid()::text);



-- SOURCE supabase/migrations/0006_viewer_profile_photos.sql
alter table public.viewer_profiles
  add column if not exists photo_url text;



-- SOURCE supabase/migrations/0007_mylist_incremental_sync.sql
-- Versioned My List changes let clients fetch only rows changed since their
-- last successful sync. Existing list rows stay in place and start at version 0.
alter table public.mylist
  add column if not exists sync_id bigint generated always as identity,
  add column if not exists sync_version bigint not null default 0;

alter table public.profile_mylist
  add column if not exists sync_id bigint generated always as identity,
  add column if not exists sync_version bigint not null default 0;

create unique index if not exists mylist_user_sync_id_unique
  on public.mylist(user_key, sync_id);
create unique index if not exists profile_mylist_user_sync_id_unique
  on public.profile_mylist(user_key, profile_id, sync_id);
create index if not exists mylist_sync_version_idx
  on public.mylist(user_key, sync_version);
create index if not exists profile_mylist_sync_version_idx
  on public.profile_mylist(user_key, profile_id, sync_version);

create table if not exists public.mylist_sync_clock (
  user_key text not null,
  profile_scope text not null default '',
  version bigint not null default 0,
  primary key (user_key, profile_scope)
);

create table if not exists public.mylist_sync_tombstones (
  user_key text not null,
  profile_scope text not null default '',
  source_id text not null,
  item_id text not null,
  sync_version bigint not null,
  primary key (user_key, profile_scope, source_id, item_id)
);
create index if not exists mylist_sync_tombstones_version_idx
  on public.mylist_sync_tombstones(user_key, profile_scope, sync_version);

alter table public.mylist_sync_clock enable row level security;
alter table public.mylist_sync_tombstones enable row level security;
drop policy if exists mylist_sync_clock_read_own on public.mylist_sync_clock;
create policy mylist_sync_clock_read_own on public.mylist_sync_clock
  for select using (user_key = auth.uid()::text);
drop policy if exists mylist_sync_tombstones_read_own
  on public.mylist_sync_tombstones;
create policy mylist_sync_tombstones_read_own on public.mylist_sync_tombstones
  for select using (user_key = auth.uid()::text);
grant select on public.mylist_sync_clock, public.mylist_sync_tombstones
  to authenticated;

create or replace function public.bump_mylist_sync_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  row_data jsonb;
  owner_key text;
  profile_key text;
  next_version bigint;
begin
  row_data := to_jsonb(new);
  owner_key := row_data ->> 'user_key';
  profile_key := coalesce(row_data ->> 'profile_id', '');

  insert into public.mylist_sync_clock(user_key, profile_scope, version)
  values (owner_key, profile_key, 1)
  on conflict (user_key, profile_scope) do update
    set version = public.mylist_sync_clock.version + 1
  returning version into next_version;

  new.sync_version := next_version;
  return new;
end;
$$;

create or replace function public.clear_mylist_sync_tombstone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  row_data jsonb;
begin
  row_data := to_jsonb(new);
  delete from public.mylist_sync_tombstones
  where user_key = row_data ->> 'user_key'
    and profile_scope = coalesce(row_data ->> 'profile_id', '')
    and source_id = row_data ->> 'source_id'
    and item_id = row_data ->> 'item_id';
  return new;
end;
$$;

create or replace function public.record_mylist_sync_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  row_data jsonb;
  owner_key text;
  profile_key text;
  source_key text;
  item_key text;
  next_version bigint;
begin
  -- Removing a viewer profile cascades its list; the profile itself is gone,
  -- so those rows must not leave permanent per-item deletion markers behind.
  if pg_trigger_depth() > 1 then
    return old;
  end if;

  row_data := to_jsonb(old);
  owner_key := row_data ->> 'user_key';
  profile_key := coalesce(row_data ->> 'profile_id', '');
  source_key := row_data ->> 'source_id';
  item_key := row_data ->> 'item_id';

  insert into public.mylist_sync_clock(user_key, profile_scope, version)
  values (owner_key, profile_key, 1)
  on conflict (user_key, profile_scope) do update
    set version = public.mylist_sync_clock.version + 1
  returning version into next_version;

  insert into public.mylist_sync_tombstones(
    user_key, profile_scope, source_id, item_id, sync_version
  ) values (owner_key, profile_key, source_key, item_key, next_version)
  on conflict (user_key, profile_scope, source_id, item_id) do update
    set sync_version = excluded.sync_version;
  return old;
end;
$$;

drop trigger if exists mylist_sync_version on public.mylist;
create trigger mylist_sync_version
before insert or update on public.mylist
for each row execute function public.bump_mylist_sync_version();
drop trigger if exists mylist_sync_clear_tombstone on public.mylist;
create trigger mylist_sync_clear_tombstone
after insert or update on public.mylist
for each row execute function public.clear_mylist_sync_tombstone();
drop trigger if exists mylist_sync_delete on public.mylist;
create trigger mylist_sync_delete
after delete on public.mylist
for each row execute function public.record_mylist_sync_delete();

drop trigger if exists profile_mylist_sync_version on public.profile_mylist;
create trigger profile_mylist_sync_version
before insert or update on public.profile_mylist
for each row execute function public.bump_mylist_sync_version();
drop trigger if exists profile_mylist_sync_clear_tombstone on public.profile_mylist;
create trigger profile_mylist_sync_clear_tombstone
after insert or update on public.profile_mylist
for each row execute function public.clear_mylist_sync_tombstone();
drop trigger if exists profile_mylist_sync_delete on public.profile_mylist;
create trigger profile_mylist_sync_delete
after delete on public.profile_mylist
for each row execute function public.record_mylist_sync_delete();

notify pgrst, 'reload schema';



-- Data sets required by CategoryRemote for the default profile.
create table if not exists public.list_categories (
  id uuid primary key default gen_random_uuid(),
  user_key text not null,
  name text not null,
  position integer not null default 0,
  created_at timestamptz not null default now(),
  unique (user_key, name)
);
create table if not exists public.mylist_categories (
  user_key text not null,
  source_id text not null,
  item_id text not null,
  category_id uuid not null references public.list_categories(id) on delete cascade,
  primary key (user_key, source_id, item_id, category_id)
);
alter table public.list_categories enable row level security;
alter table public.mylist_categories enable row level security;
create policy list_categories_own on public.list_categories
  for all to authenticated using (user_key = (select auth.uid())::text)
  with check (user_key = (select auth.uid())::text);
create policy mylist_categories_own on public.mylist_categories
  for all to authenticated using (user_key = (select auth.uid())::text)
  with check (user_key = (select auth.uid())::text);

-- Newer viewer-profile fields sent by the AnimePlex UI.
alter table public.viewer_profiles
  add column if not exists accent_color bigint check (accent_color between 0 and 4294967295),
  add column if not exists material_you boolean,
  add column if not exists amoled boolean,
  add column if not exists bio text check (char_length(bio) <= 160),
  add column if not exists cover_url text check (char_length(cover_url) <= 2048);

-- Keep legacy clients from erasing new optional properties during upsert.
create or replace function public.preserve_profile_optional_fields()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.accent_color := coalesce(new.accent_color, old.accent_color);
  new.material_you := coalesce(new.material_you, old.material_you);
  new.amoled := coalesce(new.amoled, old.amoled);
  new.bio := coalesce(new.bio, old.bio);
  new.cover_url := coalesce(new.cover_url, old.cover_url);
  return new;
end;
$$;
create trigger preserve_profile_optional_fields
before update on public.viewer_profiles for each row
execute function public.preserve_profile_optional_fields();

-- Provision profiles for users who confirm email before their first session.
create schema if not exists sync_private;
revoke all on schema sync_private from public, anon;
create or replace function sync_private.create_account_profile()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
 insert into public.profiles(id, display_name)
 values(new.id, coalesce(new.raw_user_meta_data ->> 'name', ''))
 on conflict (id) do nothing;
 return new;
end;
$$;
revoke all on function sync_private.create_account_profile() from public, anon, authenticated;
create trigger animeplex_account_created after insert on auth.users
for each row execute function sync_private.create_account_profile();
insert into public.profiles (id,display_name)
select id, coalesce(raw_user_meta_data ->> 'name','') from auth.users
on conflict (id) do nothing;

-- Restrict direct API privileges. RLS supplies the per-user restriction.
revoke all on public.profiles, public.mylist, public.history, public.reading_history,
 public.backups, public.viewer_profiles, public.profile_mylist, public.profile_history,
 public.profile_reading_history, public.profile_list_categories, public.profile_mylist_categories,
 public.list_categories, public.mylist_categories, public.watch_rooms,
 public.mylist_sync_clock, public.mylist_sync_tombstones from anon;
grant select, insert, update, delete on public.profiles, public.mylist, public.history,
 public.reading_history, public.backups, public.viewer_profiles, public.profile_mylist,
 public.profile_history, public.profile_reading_history, public.profile_list_categories,
 public.profile_mylist_categories, public.list_categories, public.mylist_categories,
 public.watch_rooms to authenticated;
grant select on public.mylist_sync_clock, public.mylist_sync_tombstones to authenticated;
grant insert on public.tv_pairings to anon, authenticated;
revoke all on function public.enforce_viewer_profile_limit(), public.bump_mylist_sync_version(),
 public.clear_mylist_sync_tombstone(), public.record_mylist_sync_delete(),
 public.preserve_profile_optional_fields() from public, anon, authenticated;
notify pgrst, 'reload schema';
