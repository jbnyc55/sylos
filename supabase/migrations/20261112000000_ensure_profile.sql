-- ensure_profile: a profile for every session, even one born in a gap.
--
-- The profiles row is made by handle_new_user, an after-insert trigger
-- on auth.users (init migration). On a one-tap install the migrations
-- arrive in batches over a couple of minutes, and an account created in
-- the window before the trigger exists — a fast finger on the login
-- step of a project still catching up — is an auth user with no
-- profile, forever: every client boot then fails at "load your
-- profile". Seen in the field on a fresh install; this closes it.
--
-- ensure_profile() is the client's self-heal: idempotent, callable by
-- any signed-in session, it inserts the missing row exactly as
-- handle_new_user would (user_id + email, nothing else) and returns the
-- row either way. The insert fires the same profile triggers as the
-- signup path — crown_first_profile included, so a healed first account
-- is still crowned the owner.

create function public.ensure_profile()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _uid uuid := (select auth.uid());
    _row public.profiles%rowtype;
begin
    if _uid is null then
        raise exception 'no session';
    end if;

    select * into _row from public.profiles where user_id = _uid;
    if not found then
        insert into public.profiles (user_id, email)
        select u.id, u.email from auth.users u where u.id = _uid
        on conflict (user_id) do nothing;
        select * into _row from public.profiles where user_id = _uid;
        if not found then
            raise exception 'no auth user for this session';
        end if;
    end if;

    return jsonb_build_object('id', _row.id, 'email', _row.email);
end;
$$;

comment on function public.ensure_profile() is
    'Self-heal for an account created before handle_new_user existed (a one-tap install still applying migrations): inserts the calling session''s missing profiles row exactly as the signup trigger would — same insert, same profile triggers, crowning included — and returns {id, email} either way. Idempotent.';

revoke all on function public.ensure_profile() from public;
grant execute on function public.ensure_profile() to authenticated;
