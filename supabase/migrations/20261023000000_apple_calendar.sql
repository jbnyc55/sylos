-- Apple Calendar & Reminders: the phone's EventKit stores, mirrored.
--
-- gcal covers Google; this covers everything the iPhone's Calendar app
-- fronts — iCloud, Exchange/Outlook, CalDAV, subscribed calendars — plus
-- the Reminders app, through one EventKit grant. Like Contacts, the
-- frameworks live on the device, so the app is the sync engine: with
-- full access granted it uploads through record_apple_events /
-- record_apple_reminders (one phone_devices key, scope 'eventkit'),
-- wholesale-replacing each mirror so deletions and moves fall out for
-- free. Syncs run on EKEventStoreChanged notifications and stale
-- foregrounds.
--
-- apple_event copies gcal_event's shape — the same timed-or-all-day
-- column pairs — so the Today grid and Syla's plans treat the two sources
-- alike. Events outside the sync window (a week back, two months ahead,
-- same as gcal) are the app's to exclude; reminders carry the incomplete
-- set plus the recently completed. Read-only: nothing ever writes back
-- to EventKit.

-- ---------------------------------------------------------------------------
-- apple_event — the mirrored calendar events
-- ---------------------------------------------------------------------------

create table public.apple_event (
    id             uuid primary key default gen_random_uuid(),
    profile_id     uuid not null references public.profiles (id) on delete cascade,
    device_id      uuid references public.phone_devices (id) on delete set null,
    -- calendarItemIdentifier plus the occurrence's start, built by the
    -- app — stable per occurrence, since recurring events expand to many
    -- occurrences sharing one identifier.
    event_id       text not null check (char_length(event_id) <= 400),
    calendar_title text not null default '' check (char_length(calendar_title) <= 300),
    title          text check (char_length(title) <= 1000),
    location       text check (char_length(location) <= 1000),
    -- Timed events carry timestamps; all-day events carry dates (end
    -- exclusive, matching gcal_event). Exactly one pair is set.
    starts_at      timestamptz,
    ends_at        timestamptz,
    start_day      date,
    end_day        date,
    synced_at      timestamptz not null default now(),

    unique (profile_id, event_id),
    check (
        (starts_at is not null and ends_at is not null and start_day is null and end_day is null)
        or
        (starts_at is null and ends_at is null and start_day is not null and end_day is not null)
    )
);

comment on table public.apple_event is
    'Read-only mirror of the phone''s EventKit calendars (iCloud, Exchange, CalDAV, subscribed — whatever the Calendar app fronts) over the sync window, gcal_event''s shape, replaced wholesale by record_apple_events. Nothing writes back to the phone.';

create index apple_event_window_idx on public.apple_event (profile_id, starts_at);
create index apple_event_allday_idx on public.apple_event (profile_id, start_day);

-- ---------------------------------------------------------------------------
-- apple_reminder — the mirrored reminders
-- ---------------------------------------------------------------------------

create table public.apple_reminder (
    id           uuid primary key default gen_random_uuid(),
    profile_id   uuid not null references public.profiles (id) on delete cascade,
    device_id    uuid references public.phone_devices (id) on delete set null,
    -- calendarItemIdentifier — reminders don't recur into occurrences the
    -- way events do, so the identifier alone is the key.
    reminder_id  text not null check (char_length(reminder_id) <= 400),
    list_title   text not null default '' check (char_length(list_title) <= 300),
    title        text check (char_length(title) <= 1000),
    -- A reminder may be due at a time, on a day, or never; at most one of
    -- the two due columns is set.
    due_at       timestamptz,
    due_day      date,
    completed    boolean not null default false,
    completed_at timestamptz,
    -- EKReminder.priority: 0 none, 1 high … 9 low, Apple's scale kept as is.
    priority     integer not null default 0 check (priority between 0 and 9),
    synced_at    timestamptz not null default now(),

    unique (profile_id, reminder_id),
    check (due_at is null or due_day is null)
);

comment on table public.apple_reminder is
    'Read-only mirror of the phone''s Reminders (the incomplete set plus the recently completed), replaced wholesale by record_apple_reminders. Nothing writes back to the phone — a reminder Syla should act on becomes a todo, not an EventKit write.';

create index apple_reminder_profile_id_idx on public.apple_reminder (profile_id);

-- ---------------------------------------------------------------------------
-- Row level security — the user_locations sentence, for both tables
-- ---------------------------------------------------------------------------

alter table public.apple_event enable row level security;
alter table public.apple_reminder enable row level security;

create policy "Apple events are viewable by their profile or the owner"
    on public.apple_event for select to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());
create policy "Apple events are deletable by their profile or the owner"
    on public.apple_event for delete to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());

create policy "Apple reminders are viewable by their profile or the owner"
    on public.apple_reminder for select to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());
create policy "Apple reminders are deletable by their profile or the owner"
    on public.apple_reminder for delete to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());

create policy "claude reads apple events"
    on public.apple_event for select to claude using (true);
create policy "claude reads apple reminders"
    on public.apple_reminder for select to claude using (true);

grant select, delete on public.apple_event to authenticated;
grant select, delete on public.apple_reminder to authenticated;
grant select on public.apple_event to claude;
grant select on public.apple_reminder to claude;

-- ---------------------------------------------------------------------------
-- record_apple_events — the phone's upload, as anon with the device key
-- ---------------------------------------------------------------------------
--
-- _events is a JSON array of {event_id, calendar_title, title, location,
-- starts_at, ends_at, start_day, end_day}: the ENTIRE window each call
-- (wholesale replace). Rows that don't form exactly one valid time pair
-- are dropped rather than failing the batch.

create function public.record_apple_events(_token text, _events jsonb)
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
    select * into _device from public.phone_device_for(_token, 'eventkit');

    if _events is null or jsonb_typeof(_events) <> 'array' then
        raise exception 'events must be a JSON array';
    end if;
    _given := jsonb_array_length(_events);
    if _given > 5000 then
        raise exception 'at most 5000 events per call (got %)', _given;
    end if;

    set local statement_timeout = '60s';

    delete from public.apple_event where profile_id = _device.profile_id;

    insert into public.apple_event (
        profile_id, device_id, event_id, calendar_title, title, location,
        starts_at, ends_at, start_day, end_day)
    select _device.profile_id, _device.device_id,
           left(e.event_id, 400),
           left(coalesce(e.calendar_title, ''), 300),
           left(e.title, 1000),
           left(e.location, 1000),
           e.starts_at, e.ends_at, e.start_day, e.end_day
    from jsonb_to_recordset(_events) as e (
        event_id text, calendar_title text, title text, location text,
        starts_at timestamptz, ends_at timestamptz, start_day date, end_day date)
    where e.event_id is not null and e.event_id <> ''
      and (
        (e.starts_at is not null and e.ends_at is not null and e.start_day is null and e.end_day is null)
        or
        (e.starts_at is null and e.ends_at is null and e.start_day is not null and e.end_day is not null)
      )
    on conflict (profile_id, event_id) do nothing;

    get diagnostics _inserted = row_count;

    return jsonb_build_object('inserted', _inserted, 'received', _given);
end;
$$;

comment on function public.record_apple_events(text, jsonb) is
    'Replaces the device key''s profile''s Apple Calendar mirror with this batch — the whole sync window each call, so phone-side deletions and moves fall out. Raises 28000 for an unknown or wrong-scope key.';

revoke all on function public.record_apple_events(text, jsonb) from public;
grant execute on function public.record_apple_events(text, jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- record_apple_reminders — same shape, for the Reminders mirror
-- ---------------------------------------------------------------------------
--
-- _reminders is a JSON array of {reminder_id, list_title, title, due_at,
-- due_day, completed, completed_at, priority}; a due_at and due_day both
-- set is resolved in favor of the timestamp.

create function public.record_apple_reminders(_token text, _reminders jsonb)
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
    select * into _device from public.phone_device_for(_token, 'eventkit');

    if _reminders is null or jsonb_typeof(_reminders) <> 'array' then
        raise exception 'reminders must be a JSON array';
    end if;
    _given := jsonb_array_length(_reminders);
    if _given > 5000 then
        raise exception 'at most 5000 reminders per call (got %)', _given;
    end if;

    set local statement_timeout = '60s';

    delete from public.apple_reminder where profile_id = _device.profile_id;

    insert into public.apple_reminder (
        profile_id, device_id, reminder_id, list_title, title,
        due_at, due_day, completed, completed_at, priority)
    select _device.profile_id, _device.device_id,
           left(r.reminder_id, 400),
           left(coalesce(r.list_title, ''), 300),
           left(r.title, 1000),
           r.due_at,
           case when r.due_at is null then r.due_day end,
           coalesce(r.completed, false),
           r.completed_at,
           case when r.priority between 0 and 9 then r.priority else 0 end
    from jsonb_to_recordset(_reminders) as r (
        reminder_id text, list_title text, title text,
        due_at timestamptz, due_day date, completed boolean,
        completed_at timestamptz, priority integer)
    where r.reminder_id is not null and r.reminder_id <> ''
    on conflict (profile_id, reminder_id) do nothing;

    get diagnostics _inserted = row_count;

    return jsonb_build_object('inserted', _inserted, 'received', _given);
end;
$$;

comment on function public.record_apple_reminders(text, jsonb) is
    'Replaces the device key''s profile''s Reminders mirror with this batch — incomplete plus recently completed, wholesale. Raises 28000 for an unknown or wrong-scope key.';

revoke all on function public.record_apple_reminders(text, jsonb) from public;
grant execute on function public.record_apple_reminders(text, jsonb) to anon, authenticated;
