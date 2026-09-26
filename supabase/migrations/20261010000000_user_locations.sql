-- User locations: where each person's phone has been, and the map of it.
--
-- The iOS app (ios/) asks for location access during onboarding — Always
-- and precise, when the person allows it — and streams fixes here from the
-- background. The locations map is a vibe code app (vibes/locations,
-- served from vibe_code_apps like every app) opened at
-- your app (served from vibe_code_apps like every app).
--
-- Who sees what: everyone reads, writes and deletes their OWN points; the
-- owner reads everyone's. Anyone can create an account through the app's
-- magic link, so "all the users' locations" stays the owner's view — a
-- stranger who signs up sees their own trail and nobody else's.
--
-- Why the phone writes with a DEVICE KEY instead of the user's JWT: the
-- app hands its Supabase session to the web view, and the web view's
-- supabase-js owns refreshing it from then on. Refresh tokens rotate
-- (enable_refresh_token_rotation), so a second refresher — the app,
-- waking in the background to upload — would trip reuse detection and
-- revoke the session for both. Instead, right after sign-in the app trades
-- its session once for a location device key (register_location_device),
-- and every upload after that is record_locations(key, points) as anon.
-- The key does exactly one thing — append points for one profile — is
-- stored only as a sha256 hash, and dies with the device row (sign-out
-- calls forget_location_device).
--
-- Both tables get row_edits logging from the event trigger like every
-- table; points are append-only readings, so the log is their delete undo.

-- ---------------------------------------------------------------------------
-- Devices
-- ---------------------------------------------------------------------------

create table public.location_devices (
    id            uuid primary key default gen_random_uuid(),
    profile_id    uuid not null references public.profiles (id) on delete cascade,
    -- What the phone called itself at registration ("iPhone").
    name          text not null default '' check (char_length(name) <= 200),
    -- sha256 of the device key, hex. The key itself is shown to the phone
    -- once and never stored.
    token_hash    text not null unique check (char_length(token_hash) = 64),
    created_at    timestamptz not null default now(),
    last_seen_at  timestamptz
);

comment on table public.location_devices is
    'Phones allowed to append points to user_locations for one profile. Registered by register_location_device from a signed-in session; the device key lives only as a sha256 hash.';

create index location_devices_profile_id_idx on public.location_devices (profile_id);

-- ---------------------------------------------------------------------------
-- Points
-- ---------------------------------------------------------------------------

create table public.user_locations (
    id                   uuid primary key default gen_random_uuid(),
    profile_id           uuid not null references public.profiles (id) on delete cascade,
    device_id            uuid references public.location_devices (id) on delete set null,
    -- When the phone took the fix (CLLocation.timestamp), not when it
    -- arrived: uploads are batched and retried after being offline.
    recorded_at          timestamptz not null,
    latitude             double precision not null check (latitude between -90 and 90),
    longitude            double precision not null check (longitude between -180 and 180),
    -- Metres. Approximate-location grants report kilometres here; the map
    -- draws the circle rather than pretending to precision.
    horizontal_accuracy  double precision check (horizontal_accuracy >= 0),
    altitude             double precision,
    vertical_accuracy    double precision check (vertical_accuracy >= 0),
    -- m/s and degrees from north; null when the phone had no valid value.
    speed                double precision check (speed >= 0),
    course               double precision check (course >= 0 and course < 360),
    created_at           timestamptz not null default now(),
    -- A retried batch lands once: uploads insert with on conflict do nothing.
    unique (profile_id, recorded_at)
);

comment on table public.user_locations is
    'Location fixes from the iOS app, one row per point. Each person reads their own; the owner reads everyone''s. Written by record_locations with a device key; plotted by the locations vibe code app.';

create index user_locations_recorded_at_idx on public.user_locations (recorded_at desc);

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.location_devices enable row level security;
alter table public.user_locations enable row level security;

create policy "Location devices are viewable by their profile or the owner"
    on public.location_devices for select to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());
create policy "Location devices are deletable by their profile or the owner"
    on public.location_devices for delete to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());

create policy "Locations are viewable by their profile or the owner"
    on public.user_locations for select to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());
create policy "Locations are insertable by their profile"
    on public.user_locations for insert to authenticated
    with check (profile_id = (select public.current_profile_id()));
create policy "Locations are deletable by their profile or the owner"
    on public.user_locations for delete to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());

create policy "claude reads location devices"
    on public.location_devices for select to claude using (true);
create policy "claude reads locations"
    on public.user_locations for select to claude using (true);

-- No insert grant on devices (register_location_device is the only door),
-- and the hash column stays out of every client's select list.
grant select (id, profile_id, name, created_at, last_seen_at), delete
    on public.location_devices to authenticated;
grant select, insert, delete on public.user_locations to authenticated;
grant select on public.location_devices to claude;
grant select on public.user_locations to claude;

-- ---------------------------------------------------------------------------
-- register_location_device — a signed-in session buys a device key
-- ---------------------------------------------------------------------------

create function public.register_location_device(_name text default '')
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

    _token := encode(extensions.gen_random_bytes(32), 'hex');

    insert into public.location_devices (profile_id, name, token_hash)
    values (_profile, left(coalesce(_name, ''), 200),
            encode(extensions.digest(_token, 'sha256'), 'hex'))
    returning id into _id;

    return jsonb_build_object('device_id', _id, 'token', _token);
end;
$$;

comment on function public.register_location_device(text) is
    'Registers the calling profile''s phone and returns its device key, shown once and stored only as a hash. The key authorizes record_locations for that profile and nothing else.';

revoke all on function public.register_location_device(text) from public;
grant execute on function public.register_location_device(text) to authenticated;

-- ---------------------------------------------------------------------------
-- record_locations — the phone's upload, as anon with the device key
-- ---------------------------------------------------------------------------
--
-- _points is a JSON array of {recorded_at, latitude, longitude,
-- horizontal_accuracy, altitude, vertical_accuracy, speed, course}.
-- Nothing in a batch can fail it — a phone must never retry one bad fix
-- forever — so bad fixes are dropped here (out-of-range coordinates, and
-- a negative horizontal accuracy: CoreLocation's "this fix is invalid"),
-- and the other negative "unknown" sentinels become nulls.

create function public.record_locations(_token text, _points jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _device   record;
    _given    integer;
    _inserted integer;
begin
    if _token is null or char_length(_token) <> 64 then
        raise exception 'missing or malformed device key' using errcode = '28000';
    end if;

    select id, profile_id into _device
    from public.location_devices
    where token_hash = encode(extensions.digest(_token, 'sha256'), 'hex');

    if _device.id is null then
        raise exception 'unknown device key' using errcode = '28000';
    end if;

    if _points is null or jsonb_typeof(_points) <> 'array' then
        raise exception 'points must be a JSON array';
    end if;
    _given := jsonb_array_length(_points);
    if _given > 1000 then
        raise exception 'at most 1000 points per call (got %)', _given;
    end if;

    set local statement_timeout = '30s';

    insert into public.user_locations (
        profile_id, device_id, recorded_at, latitude, longitude,
        horizontal_accuracy, altitude, vertical_accuracy, speed, course)
    select _device.profile_id, _device.id, p.recorded_at, p.latitude, p.longitude,
           p.horizontal_accuracy,
           p.altitude,
           case when p.vertical_accuracy >= 0 then p.vertical_accuracy end,
           case when p.speed >= 0 then p.speed end,
           case when p.course >= 0 and p.course < 360 then p.course end
    from jsonb_to_recordset(_points) as p (
        recorded_at timestamptz, latitude double precision, longitude double precision,
        horizontal_accuracy double precision, altitude double precision,
        vertical_accuracy double precision, speed double precision, course double precision)
    where p.recorded_at is not null
      and p.latitude between -90 and 90
      and p.longitude between -180 and 180
      and coalesce(p.horizontal_accuracy, 0) >= 0
    on conflict (profile_id, recorded_at) do nothing;

    get diagnostics _inserted = row_count;

    update public.location_devices set last_seen_at = now() where id = _device.id;

    return jsonb_build_object('inserted', _inserted, 'received', _given);
end;
$$;

comment on function public.record_locations(text, jsonb) is
    'Appends a batch of location fixes for the device key''s profile. Idempotent per (profile, recorded_at), so a retried batch is harmless. Raises 28000 for an unknown key.';

revoke all on function public.record_locations(text, jsonb) from public;
grant execute on function public.record_locations(text, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- forget_location_device — sign-out retires the key
-- ---------------------------------------------------------------------------

create function public.forget_location_device(_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _id uuid;
begin
    delete from public.location_devices
    where token_hash = encode(extensions.digest(coalesce(_token, ''), 'sha256'), 'hex')
    returning id into _id;

    return jsonb_build_object('device_id', _id);
end;
$$;

comment on function public.forget_location_device(text) is
    'Deletes the device holding this key (holding it is the proof). Its points stay, with device_id nulled. Called by the iOS app on sign-out.';

revoke all on function public.forget_location_device(text) from public;
grant execute on function public.forget_location_device(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- location_people — who is on the map
-- ---------------------------------------------------------------------------
--
-- profiles are readable only by their own user, so the owner's map could
-- not otherwise label anyone else's trail. Same visibility sentence as the
-- table: the owner gets everyone with points, anyone else gets themselves.

create function public.location_people()
returns table (
    profile_id  uuid,
    email       text,
    is_me       boolean,
    points      bigint,
    first_at    timestamptz,
    last_at     timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
    select p.id, p.email, p.id = public.current_profile_id(),
           count(*), min(l.recorded_at), max(l.recorded_at)
    from public.profiles p
    join public.user_locations l on l.profile_id = p.id
    where public.is_owner() or p.id = public.current_profile_id()
    group by p.id, p.email
$$;

comment on function public.location_people() is
    'The people whose points the caller may see — everyone for the owner, only themselves otherwise — with email, point count and first/last fix. Labels the locations map.';

revoke all on function public.location_people() from public;
grant execute on function public.location_people() to authenticated;

-- ---------------------------------------------------------------------------
-- Vibe code apps any signed-in person may open
-- ---------------------------------------------------------------------------
--
-- The locations map is the iOS app's only page, and its users are not the
-- owner — so its row must be readable by any signed-in session, which the
-- owner-or-member policies never allowed. The flag is per app and off by
-- default; the deploy's upsert never touches it, so it survives redeploys.
-- What the app then shows is still the data tables' RLS.

alter table public.vibe_code_apps
    add column open_to_signed_in boolean not null default false;

comment on column public.vibe_code_apps.open_to_signed_in is
    'When true, any signed-in session may read (and so run) this app, not just the owner and its members. Set by set_vibe_code_app_open (scripts/vibe-save --open-to-signed-in).';

create policy "Signed-in users read vibe code apps open to them"
    on public.vibe_code_apps for select to authenticated
    using (open_to_signed_in);

create function public.set_vibe_code_app_open(_slug text, _open boolean)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _id uuid;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    update public.vibe_code_apps
    set open_to_signed_in = coalesce(_open, false)
    where slug = _slug
    returning id into _id;

    if _id is null then
        raise exception 'no vibe code app with slug %', _slug;
    end if;

    return jsonb_build_object(
        'app_id', _id, 'slug', _slug, 'open_to_signed_in', coalesce(_open, false));
end;
$$;

comment on function public.set_vibe_code_app_open(text, boolean) is
    'Opens (or closes) one vibe code app to every signed-in session, as the claude role. Gated by assert_claude_rq_key().';

revoke all on function public.set_vibe_code_app_open(text, boolean) from public;
grant execute on function public.set_vibe_code_app_open(text, boolean) to anon;
