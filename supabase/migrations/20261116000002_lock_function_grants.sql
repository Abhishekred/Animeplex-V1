-- Supabase grants function EXECUTE directly to anon by default.
-- Explicitly revoke it from the PIN service, keeping authenticated access.
revoke execute on function public.profile_lock(text,text,text,text,text) from public, anon;
grant execute on function public.profile_lock(text,text,text,text,text) to authenticated;
revoke execute on function public.enforce_viewer_profile_limit() from public, anon, authenticated;
revoke execute on function public.bump_mylist_sync_version() from public, anon, authenticated;
revoke execute on function public.clear_mylist_sync_tombstone() from public, anon, authenticated;
revoke execute on function public.record_mylist_sync_delete() from public, anon, authenticated;
revoke execute on function public.preserve_profile_optional_fields() from public, anon, authenticated;
revoke execute on function sync_private.create_account_profile() from public, anon, authenticated;
