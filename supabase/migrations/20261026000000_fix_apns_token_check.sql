-- Fix "invalid regular expression: invalid repetition counts" on enabling
-- notifications.
--
-- Postgres caps regex quantifiers {m,n} at 255, and 20261025 checked APNs
-- tokens with '^[0-9a-f]{1,400}$' — in the push_devices check constraint
-- and again inside register_push_device. The regex is only compiled when
-- evaluated, so the migration applied cleanly and the error surfaced on
-- the app's first register_push_device call. Same rule, expressed as an
-- uncounted regex plus a length check: lowercase hex, at most 400 chars
-- (today's tokens are 64; the headroom is for Apple growing them).
--
-- No row can predate this fix — every insert path hit the broken regex
-- first — so swapping the constraint validates an empty set.

alter table public.push_devices
    drop constraint push_devices_apns_token_check;
alter table public.push_devices
    add constraint push_devices_apns_token_check
    check (apns_token ~ '^[0-9a-f]+$' and char_length(apns_token) <= 400);

create or replace function public.register_push_device(
    _apns_token text, _environment text default 'production', _name text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _profile uuid := public.current_profile_id();
    _id      uuid;
begin
    if _profile is null then
        raise exception 'sign in before registering for push' using errcode = '28000';
    end if;
    if _apns_token is null or _apns_token !~ '^[0-9a-f]+$'
       or char_length(_apns_token) > 400 then
        raise exception 'malformed APNs token';
    end if;
    if _environment not in ('production', 'sandbox') then
        raise exception 'environment must be production or sandbox (got %)', _environment;
    end if;

    -- Upsert on the token: iOS may hand the same token again (re-enable,
    -- new session) or after a restore hand it to a different account —
    -- either way the latest registration owns it.
    insert into public.push_devices as d (profile_id, apns_token, environment, name)
    values (_profile, _apns_token, _environment, left(coalesce(_name, ''), 200))
    on conflict (apns_token) do update
        set profile_id = excluded.profile_id,
            environment = excluded.environment,
            name = excluded.name,
            last_seen_at = now()
    returning id into _id;

    return jsonb_build_object('device_id', _id);
end;
$$;
