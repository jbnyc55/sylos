-- Grant the API roles access to the application tables.
--
-- Row level security and table privileges are two separate gates, and a row is
-- only reachable through both. The init migration defined policies but never
-- granted the underlying privileges, so every client query failed with
-- "permission denied for table profiles" before RLS was ever consulted.
--
-- Privileges here deliberately mirror the policies exactly, so a table can
-- never be reachable in a way no policy describes:
--
--   profiles  select, update            -- inserted by trigger, deleted by cascade
--   notes     select, insert, update, delete
--
-- anon gets schema usage only. It needs that to reach PostgREST at all, but the
-- app requires a session, so it is granted nothing on either table.

grant usage on schema public to anon, authenticated;

grant select, update                 on public.profiles to authenticated;
grant select, insert, update, delete on public.notes    to authenticated;
