-- Fix: current_actor_id() must not require entering the auth schema.
--
-- The claude role deliberately holds no usage on schema auth, so the
-- invoker-security helper failed ('permission denied for schema auth') the
-- moment a log trigger called auth.uid() during claude's own DML — breaking
-- every wiki write and agent-log append. The helper becomes security
-- definer: the auth.uid() lookup runs as the function's owner, while the
-- function still only reads two request-scoped settings and returns the
-- caller's own identity. It touches no table and can leak nothing that
-- isn't already the caller's.

create or replace function public.current_actor_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
    select coalesce(
        nullif(current_setting('app.guest_id', true), '')::uuid,
        auth.uid()
    )
$$;

comment on function public.current_actor_id() is
    'The specific actor behind current_user: the guest (app.guest_id, set by authenticate_guest) or the signed-in user (auth.uid()). Null when the role itself is the whole identity, e.g. the claude role until per-agent ids exist. Security definer only so roles without auth-schema access can be logged.';
