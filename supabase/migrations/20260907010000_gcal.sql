-- Google Calendar pull: the owner connects their Google account with OAuth
-- (the gcal edge function runs the flow and holds the client secret), and a
-- sync copies their calendar's events into gcal_event, which the Today grid
-- draws alongside the app's own events — read-only mirrors, never editable
-- here and never written back to Google.
--
-- Secrecy boundaries, sharpest first: the OAuth refresh/access tokens live
-- only in gcal_connection, which NOBODY but the service role (the edge
-- function) can read — the browser gets a token-free status view below, and
-- the claude role's default select privilege is revoked outright. The
-- mirrored events themselves are ordinary app data: owner-readable, and
-- claude-readable like every other table, so the daily routine can see the
-- calendar too.

-- ---------------------------------------------------------------------------
-- gcal_connection — one row per connected Google account (one per profile)
-- ---------------------------------------------------------------------------

create table public.gcal_connection (
    profile_id       uuid primary key references public.profiles (id) on delete cascade,
    google_email     text,
    refresh_token    text not null,
    access_token     text,
    token_expires_at timestamptz,
    last_synced_at   timestamptz,
    created_at       timestamptz not null default now()
);

comment on table public.gcal_connection is
    'The owner''s Google Calendar OAuth grant, written by the gcal edge function. Tokens are service-role-only: the owner''s session sees a token-free status view (gcal_status) and may delete the row to disconnect; the claude role cannot read this table at all.';

alter table public.gcal_connection enable row level security;

-- The claude role inherits select on new tables by default privilege;
-- tokens are the one thing it must never see, so revoke outright rather
-- than rely on the missing policy.
revoke all on public.gcal_connection from claude;

-- The owner can disconnect (delete) but never read the row itself — status
-- goes through the view below, so token columns have no browser-reachable
-- select path at all.
grant delete on public.gcal_connection to authenticated;

create policy "Own gcal connection is deletable"
    on public.gcal_connection for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- Token-free status for the app: connected as whom, synced when.
create view public.gcal_status
    with (security_invoker = false)
    as select profile_id, google_email, last_synced_at, created_at
       from public.gcal_connection
       where profile_id = (select public.current_profile_id());

comment on view public.gcal_status is
    'The signed-in owner''s Google Calendar connection, minus the tokens — the only read path the browser has onto gcal_connection.';

grant select on public.gcal_status to authenticated;

-- ---------------------------------------------------------------------------
-- gcal_oauth_state — CSRF states for the in-flight OAuth redirect
-- ---------------------------------------------------------------------------

create table public.gcal_oauth_state (
    state      text primary key,
    profile_id uuid not null references public.profiles (id) on delete cascade,
    created_at timestamptz not null default now()
);

comment on table public.gcal_oauth_state is
    'One row per OAuth flow in flight: the random state handed to Google, mapped back to the profile when the callback returns. Service-role-only; rows are deleted on use and are worthless afterwards.';

alter table public.gcal_oauth_state enable row level security;
revoke all on public.gcal_oauth_state from claude;

-- ---------------------------------------------------------------------------
-- gcal_event — the mirrored events
-- ---------------------------------------------------------------------------

create table public.gcal_event (
    id              uuid primary key default gen_random_uuid(),
    profile_id      uuid not null references public.profiles (id) on delete cascade,
    google_event_id text not null,
    calendar_id     text not null default 'primary',
    summary         text,
    -- Timed events carry timestamps; all-day events carry dates (end
    -- exclusive, as Google sends them). Exactly one pair is set.
    starts_at       timestamptz,
    ends_at         timestamptz,
    start_day       date,
    end_day         date,
    synced_at       timestamptz not null default now(),

    unique (profile_id, google_event_id),
    check (
        (starts_at is not null and ends_at is not null and start_day is null and end_day is null)
        or
        (starts_at is null and ends_at is null and start_day is not null and end_day is not null)
    )
);

comment on table public.gcal_event is
    'Read-only mirror of the owner''s Google Calendar events over the sync window, written by the gcal edge function''s sync. The Today grid draws these alongside the app''s own events; nothing here ever writes back to Google.';

create index gcal_event_window_idx on public.gcal_event (profile_id, starts_at);
create index gcal_event_allday_idx on public.gcal_event (profile_id, start_day);

alter table public.gcal_event enable row level security;

grant select on public.gcal_event to authenticated;

create policy "Own gcal events are viewable"
    on public.gcal_event for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "claude reads everything"
    on public.gcal_event for select
    to claude
    using (true);
