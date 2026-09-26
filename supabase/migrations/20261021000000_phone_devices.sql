-- Phone devices: one scoped key per native integration, shared plumbing
-- for every "this phone" mirror (contacts, Apple Calendar & Reminders,
-- Health).
--
-- These integrations live in iOS frameworks the server can never reach
-- (CNContactStore, EventKit, HealthKit), so the phone is the sync engine:
-- it reads the framework and uploads rows. Uploads happen from the
-- background, which is exactly the situation user_locations solved with a
-- device key — a second refresher of the rotating Supabase session would
-- trip reuse detection — so this generalizes that model instead of
-- inventing another: enabling an integration trades the signed-in session
-- once for a key (register_phone_device), background batches authenticate
-- with the key alone, and disabling (or sign-out) retires it.
--
-- Each key carries ONE scope and can only feed that scope's mirror for
-- that profile, keeping the location property — "the key does exactly one
-- thing" — while sharing one table and one register/forget pair.
-- location_devices predates this and stays as it is.
--
-- Like every table, both get row_edits logging from the event trigger.

create table public.phone_devices (
    id            uuid primary key default gen_random_uuid(),
    profile_id    uuid not null references public.profiles (id) on delete cascade,
    -- Which mirror this key may feed. One key, one scope.
    scope         text not null check (scope in ('contacts', 'eventkit', 'health')),
    -- What the phone called itself at registration ("iPhone").
    name          text not null default '' check (char_length(name) <= 200),
    -- sha256 of the device key, hex. The key itself is shown to the phone
    -- once and never stored.
    token_hash    text not null unique check (char_length(token_hash) = 64),
    created_at    timestamptz not null default now(),
    last_seen_at  timestamptz
);

comment on table public.phone_devices is
    'Phones allowed to feed one native mirror (scope: contacts, eventkit or health) for one profile — the user_locations device-key model, generalized. Registered by register_phone_device from a signed-in session; the key lives only as a sha256 hash and dies with the row.';

create index phone_devices_profile_id_idx on public.phone_devices (profile_id);

alter table public.phone_devices enable row level security;

create policy "Phone devices are viewable by their profile or the owner"
    on public.phone_devices for select to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());
create policy "Phone devices are deletable by their profile or the owner"
    on public.phone_devices for delete to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());

create policy "claude reads phone devices"
    on public.phone_devices for select to claude using (true);

-- No insert grant (register_phone_device is the only door), and the hash
-- column stays out of every client's select list.
grant select (id, profile_id, scope, name, created_at, last_seen_at), delete
    on public.phone_devices to authenticated;
grant select on public.phone_devices to claude;

-- ---------------------------------------------------------------------------
-- register_phone_device — a signed-in session buys a scoped key
-- ---------------------------------------------------------------------------

create function public.register_phone_device(_scope text, _name text default '')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _profile uuid := public.current_profile_id();
    _token   text;
    _id      uuid;
begin
    if _profile is null then
        raise exception 'sign in before registering a device' using errcode = '28000';
    end if;
    if _scope is null or _scope not in ('contacts', 'eventkit', 'health') then
        raise exception 'scope must be contacts, eventkit or health (got %)', _scope;
    end if;

    _token := encode(extensions.gen_random_bytes(32), 'hex');

    insert into public.phone_devices (profile_id, scope, name, token_hash)
    values (_profile, _scope, left(coalesce(_name, ''), 200),
            encode(extensions.digest(_token, 'sha256'), 'hex'))
    returning id into _id;

    return jsonb_build_object('device_id', _id, 'token', _token);
end;
$$;

comment on function public.register_phone_device(text, text) is
    'Registers the calling profile''s phone for one native mirror and returns its device key, shown once and stored only as a hash. The key authorizes that scope''s record_* RPC for that profile and nothing else.';

revoke all on function public.register_phone_device(text, text) from public;
grant execute on function public.register_phone_device(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- forget_phone_device — disabling the integration (or sign-out) retires it
-- ---------------------------------------------------------------------------

create function public.forget_phone_device(_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _id uuid;
begin
    delete from public.phone_devices
    where token_hash = encode(extensions.digest(coalesce(_token, ''), 'sha256'), 'hex')
    returning id into _id;

    return jsonb_build_object('device_id', _id);
end;
$$;

comment on function public.forget_phone_device(text) is
    'Deletes the device holding this key (holding it is the proof). Its mirror rows stay, with device_id nulled. Called by the iOS app when an integration is turned off and on sign-out.';

revoke all on function public.forget_phone_device(text) from public;
grant execute on function public.forget_phone_device(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- phone_device_for — the record_* RPCs' shared key check
-- ---------------------------------------------------------------------------
-- Internal: resolves a key to (device_id, profile_id) iff it exists and
-- carries the expected scope, stamping last_seen_at. Not granted to any
-- role — only the security definer record_* functions reach it.

create function public.phone_device_for(_token text, _scope text)
returns table (device_id uuid, profile_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
    _device record;
begin
    if _token is null or char_length(_token) <> 64 then
        raise exception 'missing or malformed device key' using errcode = '28000';
    end if;

    select d.id, d.profile_id into _device
    from public.phone_devices d
    where d.token_hash = encode(extensions.digest(_token, 'sha256'), 'hex')
      and d.scope = _scope;

    if _device.id is null then
        raise exception 'unknown device key' using errcode = '28000';
    end if;

    update public.phone_devices set last_seen_at = now() where id = _device.id;

    return query select _device.id, _device.profile_id;
end;
$$;

comment on function public.phone_device_for(text, text) is
    'Resolves a phone device key to (device_id, profile_id) when it exists with the expected scope; raises 28000 otherwise. Internal — called only by the record_* mirror RPCs, granted to nobody.';

revoke all on function public.phone_device_for(text, text) from public;
