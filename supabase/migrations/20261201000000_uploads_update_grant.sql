-- Files app: the rename needs the update grant.
--
-- 20261118000000_files_app.sql gave uploads an owner UPDATE policy
-- (the Files app's rename writes uploads.name) but never granted
-- update on the table — and this schema grants explicitly
-- (20260816000200), so the policy alone leaves the rename failing
-- with "permission denied for table uploads". The grant catches up
-- with the policy; RLS still scopes every update to the owner's rows.

grant update on public.uploads to authenticated;
