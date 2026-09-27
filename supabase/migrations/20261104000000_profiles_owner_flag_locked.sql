-- profiles: a session may update its own email, nothing else.
--
-- 20260816000200 granted `update` on the whole of public.profiles to
-- authenticated, and the policy only says "your own row". Since then
-- the row grew is_owner (the app-management gate behind is_owner()) and
-- user_id is what ties it to the session — both of which a signed-in
-- member, trial account or stranger (sign-up is open) could PATCH on
-- their own row through PostgREST. The crown trigger and the
-- single-owner index limit the damage, but "RLS is the entire
-- authorization layer" means the grant should not allow it at all.
-- Column-scoped now: email only. No client updates anything else on
-- profiles; the trigger fills the row at sign-up.

revoke update on public.profiles from authenticated;
grant update (email) on public.profiles to authenticated;
