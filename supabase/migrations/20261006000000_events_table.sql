-- Events become their own table, structured the way a calendar does it.
--
-- An EVENT occupies time: title, start/end clock times, gcal-shaped
-- recurrence, per-day exclusions, attachments (docs, silos, members,
-- goals) — and an assignee: 'me', or 'syla', whose events fire her
-- routine when their start time arrives, passing the event (its row,
-- its child todos, its attached docs) as the instructions. A TODO is
-- checked off; it keeps its due day and recurrence and may belong to
-- an event through event_id.
--
-- Until now an event was a todo row with times. This migration moves
-- those rows into public.events with their ids intact (so event_id
-- references survive), carries their junction rows over, folds the
-- enabled syla_jobs in as Syla's events, repoints the run queue at
-- events, and drops the old jobs system. There is no old system.

-- ── The events table ─────────────────────────────────────────────────────

create table public.events (
    id            uuid primary key default gen_random_uuid(),
    profile_id    uuid not null references public.profiles (id) on delete cascade,
    title         text not null check (char_length(title) between 1 and 2000),
    start_date    date not null,
    start_time    time not null,
    end_time      time not null,
    freq          text check (freq in ('daily', 'weekly', 'monthly', 'yearly')),
    interval_n    integer not null default 1 check (interval_n between 1 and 999),
    byweekday     smallint[] check (byweekday <@ array[0, 1, 2, 3, 4, 5, 6]::smallint[]),
    month_mode    text check (month_mode in ('day_of_month', 'nth_weekday')),
    month_nth     smallint check (month_nth = -1 or month_nth between 1 and 5),
    until_date    date,
    count_n       integer check (count_n >= 1),
    assignee      text not null default 'me' check (assignee in ('me', 'syla')),
    last_fired_on date,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),

    constraint events_times_ordered   check (end_time > start_time),
    constraint events_end_needs_freq  check (freq is not null or (until_date is null and count_n is null)),
    constraint events_one_end_at_most check (until_date is null or count_n is null)
);

comment on table public.events is
    'Calendar events, gcal-shaped: recurring rules expanded client-side, occurrences cancelled per-day in event_exclusion. Never completed — todos hanging off an event (todo.event_id) are what gets checked. assignee=''syla'' events fire her routine at start time.';
comment on column public.events.assignee is
    'Whose event. ''me'': the owner attends it. ''syla'': she performs it — the dispatcher queues a run when start_time arrives.';
comment on column public.events.last_fired_on is
    'For assignee=''syla'': the local date the dispatcher last queued a run — the once-a-day latch.';

create index events_profile_id_start_date_idx
    on public.events (profile_id, start_date desc);

create trigger events_set_updated_at
    before update on public.events
    for each row execute function public.set_updated_at();

alter table public.events enable row level security;
grant select, insert, update, delete on public.events to authenticated;
grant select on public.events to claude;

create policy "Events are viewable by their owner"
    on public.events for select to authenticated
    using (profile_id = (select public.current_profile_id()));
create policy "Events are insertable by their owner"
    on public.events for insert to authenticated
    with check (profile_id = (select public.current_profile_id()));
create policy "Events are updatable by their owner"
    on public.events for update to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));
create policy "Events are deletable by their owner"
    on public.events for delete to authenticated
    using (profile_id = (select public.current_profile_id()));
create policy "claude reads events"
    on public.events for select to claude using (true);

-- Rescheduling (or creating) a Syla event resets the once-a-day latch: a
-- start time already past today counts as fired, so the event fires from
-- its next occurrence, never retroactively. Event times are the owner's
-- local wall clock; this personal app pins the zone here and in the
-- dispatcher.
create function public.events_syla_reset_latch()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    _reset boolean;
    _local timestamptz := now() at time zone 'America/New_York';
begin
    if new.assignee <> 'syla' then
        return new;
    end if;
    if tg_op = 'INSERT' then
        _reset := true;
    else
        _reset := new.start_time is distinct from old.start_time
                  or new.start_date is distinct from old.start_date
                  or new.freq is distinct from old.freq
                  or new.byweekday is distinct from old.byweekday
                  or new.assignee is distinct from old.assignee;
    end if;
    if _reset then
        new.last_fired_on := case
            when new.start_time <= (_local)::time then (_local)::date
        end;
    end if;
    return new;
end;
$$;

create trigger events_syla_reset_latch
    before insert or update on public.events
    for each row execute function public.events_syla_reset_latch();

-- ── The event-side junctions and exclusions ──────────────────────────────

create table public.event_silos (
    event_id    uuid not null references public.events (id) on delete cascade,
    silo_id     uuid not null references public.silos (id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (event_id, silo_id)
);
create table public.event_members (
    event_id    uuid not null references public.events (id) on delete cascade,
    member_id   uuid not null references public.members (id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (event_id, member_id)
);
create table public.event_docs (
    event_id    uuid not null references public.events (id) on delete cascade,
    doc_id      uuid not null references public.docs (id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (event_id, doc_id)
);
-- event_goals mirrors todo_goals: goal_id points at the goal map's cells.
create table public.event_goals (
    event_id  uuid not null references public.events (id) on delete cascade,
    goal_id   uuid not null references public.goal_method_cells (id) on delete cascade,
    primary key (event_id, goal_id)
);

create table public.event_exclusion (
    event_id    uuid not null references public.events (id) on delete cascade,
    day         date not null,
    created_at  timestamptz not null default now(),
    primary key (event_id, day)
);
comment on table public.event_exclusion is
    'One row per deleted occurrence of a recurring event (an EXDATE).';

create index event_silos_silo_id_idx on public.event_silos (silo_id);
create index event_members_member_id_idx on public.event_members (member_id);
create index event_docs_doc_id_idx on public.event_docs (doc_id);
create index event_goals_goal_id_idx on public.event_goals (goal_id);

alter table public.event_silos enable row level security;
alter table public.event_members enable row level security;
alter table public.event_docs enable row level security;
alter table public.event_goals enable row level security;
alter table public.event_exclusion enable row level security;

create policy "Event silos follow the event's owner"
    on public.event_silos for all to authenticated
    using (exists (select 1 from public.events e where e.id = event_id
                     and e.profile_id = (select public.current_profile_id())))
    with check (exists (select 1 from public.events e where e.id = event_id
                     and e.profile_id = (select public.current_profile_id())));
create policy "Event members follow the event's owner"
    on public.event_members for all to authenticated
    using (exists (select 1 from public.events e where e.id = event_id
                     and e.profile_id = (select public.current_profile_id())))
    with check (exists (select 1 from public.events e where e.id = event_id
                     and e.profile_id = (select public.current_profile_id())));
create policy "Event docs follow the event's owner"
    on public.event_docs for all to authenticated
    using (exists (select 1 from public.events e where e.id = event_id
                     and e.profile_id = (select public.current_profile_id())))
    with check (exists (select 1 from public.events e where e.id = event_id
                     and e.profile_id = (select public.current_profile_id())));
create policy "Event goals follow the event's owner"
    on public.event_goals for all to authenticated
    using (exists (select 1 from public.events e where e.id = event_id
                     and e.profile_id = (select public.current_profile_id())))
    with check (exists (select 1 from public.events e where e.id = event_id
                     and e.profile_id = (select public.current_profile_id())));
create policy "Event exclusions follow the event's owner"
    on public.event_exclusion for all to authenticated
    using (exists (select 1 from public.events e where e.id = event_id
                     and e.profile_id = (select public.current_profile_id())))
    with check (exists (select 1 from public.events e where e.id = event_id
                     and e.profile_id = (select public.current_profile_id())));

create policy "claude reads event silos" on public.event_silos for select to claude using (true);
create policy "claude reads event members" on public.event_members for select to claude using (true);
create policy "claude reads event docs" on public.event_docs for select to claude using (true);
create policy "claude reads event goals" on public.event_goals for select to claude using (true);
create policy "claude reads event exclusions" on public.event_exclusion for select to claude using (true);

grant select, insert, delete on public.event_silos to authenticated;
grant select, insert, delete on public.event_members to authenticated;
grant select, insert, delete on public.event_docs to authenticated;
grant select, insert, delete on public.event_goals to authenticated;
grant select, insert, delete on public.event_exclusion to authenticated;
grant select on public.event_silos to claude;
grant select on public.event_members to claude;
grant select on public.event_docs to claude;
grant select on public.event_goals to claude;
grant select on public.event_exclusion to claude;

-- ── Move the timed rows over, ids intact ─────────────────────────────────

insert into public.events (
    id, profile_id, title, start_date, start_time, end_time,
    freq, interval_n, byweekday, month_mode, month_nth, until_date, count_n,
    created_at, updated_at
)
select id, profile_id, title, start_date, start_time, end_time,
       freq, interval_n, byweekday, month_mode, month_nth, until_date, count_n,
       created_at, updated_at
from public.todo
where start_time is not null;

insert into public.event_silos (event_id, silo_id, created_at)
select todo_id, silo_id, created_at from public.todo_silos
where todo_id in (select id from public.events);
delete from public.todo_silos where todo_id in (select id from public.events);

insert into public.event_members (event_id, member_id, created_at)
select todo_id, member_id, created_at from public.todo_members
where todo_id in (select id from public.events);
delete from public.todo_members where todo_id in (select id from public.events);

insert into public.event_docs (event_id, doc_id, created_at)
select todo_id, doc_id, created_at from public.todo_docs
where todo_id in (select id from public.events);
delete from public.todo_docs where todo_id in (select id from public.events);

insert into public.event_goals (event_id, goal_id)
select todo_id, goal_id from public.todo_goals
where todo_id in (select id from public.events);
delete from public.todo_goals where todo_id in (select id from public.events);

insert into public.event_exclusion (event_id, day, created_at)
select todo_id, day, created_at from public.todo_exclusion
where todo_id in (select id from public.events);
delete from public.todo_exclusion where todo_id in (select id from public.events);

-- Events are never "done"; stray marks on old event rows retire.
delete from public.todo_done where todo_id in (select id from public.events);

-- ── The todo table slims to tasks ────────────────────────────────────────

alter table public.todo drop constraint todo_event_id_fkey;
delete from public.todo where id in (select id from public.events);
alter table public.todo
    add constraint todo_event_id_fkey
    foreign key (event_id) references public.events (id) on delete cascade;
alter table public.todo drop constraint todo_times_paired;
alter table public.todo drop constraint todo_times_ordered;
alter table public.todo drop column start_time;
alter table public.todo drop column end_time;

comment on table public.todo is
    'Tasks: one row per todo, checked off per occurrence in todo_done. Recurrence in gcal-shaped fields, expanded client-side. A todo may belong to an event (event_id) and then inherits its schedule.';
comment on column public.todo.event_id is
    'The event this todo belongs to. An attached todo inherits its event''s recurrence — its own schedule fields are ignored. An event''s todos are deleted with it.';

-- ── The enabled syla_jobs fold in as Syla's events ──────────────────────
-- fire_at and days_of_week were stored in UTC; events speak local wall
-- clock, so both shift by the day offset. One-offs keep their date;
-- repeaters anchor on today. est_minutes becomes the end time. Disabled
-- jobs are abandoned drafts and do not come over.

do $$
declare
    j record;
    _start time;
    _end time;
    _end_i interval;
    _shift integer;
    _days integer[];
    _event_id uuid;
    _anchor date := (now() at time zone 'America/New_York')::date;
begin
    for j in select * from public.syla_jobs where enabled loop
        _start := ((date '2026-01-15' + j.fire_at) at time zone 'utc'
                   at time zone 'America/New_York')::time;
        _shift := (((date '2026-01-15' + j.fire_at) at time zone 'utc'
                    at time zone 'America/New_York')::date - date '2026-01-15');
        select array_agg(distinct ((d + _shift) % 7 + 7) % 7)
        into _days
        from unnest(j.days_of_week) as d;

        _end_i := _start::interval + make_interval(mins => greatest(j.est_minutes, 1));
        _end := case when _end_i >= interval '23:59' then time '23:59'
                     else (_end_i)::time end;
        if _end <= _start then
            _end := time '23:59';
        end if;

        insert into public.events (
            profile_id, title, assignee,
            start_date, start_time, end_time,
            freq, interval_n, byweekday
        ) values (
            j.profile_id, j.name, 'syla',
            coalesce(j.run_on, _anchor), _start, _end,
            case when j.run_on is not null then null
                 when _days @> array[0, 1, 2, 3, 4, 5, 6] then 'daily'
                 else 'weekly' end,
            1,
            case when j.run_on is null and not (_days @> array[0, 1, 2, 3, 4, 5, 6])
                 then _days::smallint[] else null end
        )
        returning id into _event_id;

        insert into public.event_docs (event_id, doc_id)
        values (_event_id, j.doc_id)
        on conflict do nothing;
    end loop;
end;
$$;

-- ── The run queue repoints at events ─────────────────────────────────────

alter table public.syla_job_runs
    add column event_id uuid references public.events (id) on delete cascade;

delete from public.syla_job_runs;

drop policy "Syla job runs are viewable by the job's owner" on public.syla_job_runs;

alter table public.syla_job_runs drop column job_id;
alter table public.syla_job_runs alter column event_id set not null;

create index syla_job_runs_event_idx on public.syla_job_runs (event_id, queued_at desc);

comment on table public.syla_job_runs is
    'One row per firing of a Syla event (events.assignee=''syla''). Inserted ''queued'' by the dispatcher; a Syla session moves it to ''running'' via claim_syla_runs() and to ''done''/''failed'' via finish_syla_run(). The dispatcher fails runs nobody claims (3 fires, 20 minutes apart) or nobody finishes (2 hours).';

create policy "Runs are viewable by the event's owner"
    on public.syla_job_runs for select to authenticated
    using (exists (
        select 1 from public.events e
        where e.id = syla_job_runs.event_id
          and e.profile_id = (select public.current_profile_id())
    ));

-- ── The dispatcher: due Syla events fire her routine ─────────────────────
-- Supports the shapes the app's form allows for her: one-offs, daily and
-- weekly (interval 1, no count cap); until_date and event_exclusion are
-- honored. Times are local wall clock.

create or replace function public.syla_dispatch()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    _now        timestamptz := now();
    _local_time time := (now() at time zone 'America/New_York')::time;
    _local_date date := (now() at time zone 'America/New_York')::date;
    _to_fire    uuid[];
    _names      text;
    _url        text;
    _token      text;
    _req        bigint;
begin
    -- Queue newly due events, latching last_fired_on in the same statement.
    with due as (
        update public.events e
        set last_fired_on = _local_date
        where e.assignee = 'syla'
          and e.start_time <= _local_time
          and (e.last_fired_on is null or e.last_fired_on < _local_date)
          and (e.until_date is null or e.until_date >= _local_date)
          and case
                when e.freq is null then e.start_date = _local_date
                when e.freq = 'daily' and e.interval_n = 1
                  then e.start_date <= _local_date
                when e.freq = 'weekly' and e.interval_n = 1
                  then e.start_date <= _local_date
                   and extract(dow from _local_date)::smallint
                       = any (coalesce(e.byweekday, array[]::smallint[]))
                else false
              end
          and not exists (
              select 1 from public.event_exclusion x
              where x.event_id = e.id and x.day = _local_date
          )
        returning e.id
    )
    insert into public.syla_job_runs (event_id)
    select id from due;

    -- A claimed run that never reported back: fail it so it shows in the app.
    update public.syla_job_runs
    set status = 'failed', finished_at = _now,
        summary = 'Timed out: a session claimed this run but never finished it.'
    where status = 'running' and started_at < _now - interval '2 hours';

    -- A queued run the webhook could not get claimed after three fires.
    update public.syla_job_runs
    set status = 'failed', finished_at = _now,
        summary = 'The webhook fired three times but no session claimed the run.'
    where status = 'queued' and fire_count >= 3
      and fired_at < _now - interval '20 minutes';

    -- Fire the routine once for everything still queued that has not been
    -- fired recently. One session handles the whole batch.
    select array_agg(r.id), string_agg(distinct e.title, ', ')
    into _to_fire, _names
    from public.syla_job_runs r
    join public.events e on e.id = r.event_id
    where r.status = 'queued'
      and (r.fired_at is null or r.fired_at < _now - interval '20 minutes');

    if _to_fire is null then
        return;
    end if;

    select decrypted_secret into _url
    from vault.decrypted_secrets where name = 'syla_webhook_url';
    select decrypted_secret into _token
    from vault.decrypted_secrets where name = 'syla_webhook_token';

    -- No credential yet: leave the runs queued, where the tab shows them.
    if _url is null or _token is null then
        return;
    end if;

    _req := net.http_post(
        url := _url,
        headers := jsonb_build_object(
            'Authorization',     'Bearer ' || _token,
            'anthropic-version', '2023-06-01',
            'anthropic-beta',    'experimental-cc-routine-2026-04-01',
            'Content-Type',      'application/json'),
        body := jsonb_build_object(
            'text', 'Queued Syla events: ' || _names
                    || '. The syla_job_runs queue is the source of truth. '
                    || 'Each run points at an events row assigned to you: do '
                    || 'what the event says — the row, its child todos '
                    || '(todo.event_id) and its attached docs (event_docs -> '
                    || 'docs) together are the instructions.'),
        timeout_milliseconds := 15000);

    update public.syla_job_runs
    set fired_at = _now, fire_count = fire_count + 1, fire_request_id = _req
    where id = any (_to_fire);
end;
$$;

-- ── The claim RPC follows the queue's new shape ──────────────────────────

create or replace function public.claim_syla_runs()
returns jsonb
language plpgsql
security invoker
as $$
declare
    result jsonb;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    with claimed as (
        update public.syla_job_runs
        set status = 'running', started_at = now()
        where status = 'queued'
        returning id, event_id
    )
    select coalesce(jsonb_agg(jsonb_build_object(
               'run_id',   c.id,
               'event_id', e.id,
               'event',    e.title,
               'starts',   e.start_time,
               'ends',     e.end_time,
               'docs',     coalesce((
                   select jsonb_agg(jsonb_build_object('path', d.path, 'title', d.title))
                   from public.event_docs ed
                   join public.docs d on d.id = ed.doc_id
                   where ed.event_id = e.id), '[]'::jsonb),
               'todos',    coalesce((
                   select jsonb_agg(child.title)
                   from public.todo child
                   where child.event_id = e.id), '[]'::jsonb))), '[]')
    into result
    from claimed c
    join public.events e on e.id = c.event_id;

    return result;
end;
$$;

comment on function public.claim_syla_runs() is
    'Claims every queued Syla-event run (queued → running) as the claude role and returns each with its event title, times, attached docs and child todos — the event is the instructions. Gated by assert_claude_rq_key().';

-- ── The old system goes ──────────────────────────────────────────────────

drop trigger syla_jobs_reset_latch on public.syla_jobs;
drop function public.syla_jobs_reset_latch();
drop table public.syla_jobs;

-- ── The starter's owner seeding follows the queue's new shape ─────────────
--
-- 20260930000000_first_signup_owner crowns the first profile and seeds
-- Syla's starter jobs — into syla_jobs, which no longer exists. Replace
-- the seeding body (the trigger stays): the same four capabilities, now
-- as Syla's events, each carrying its instructions doc through
-- event_docs. Times are local wall clock (the dispatcher's zone); the
-- reset-latch trigger keeps a just-created event from firing
-- retroactively today.

create or replace function public.seed_owner_defaults()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.events (profile_id, title, assignee,
                               start_date, start_time, end_time, freq, interval_n)
    select new.id, s.title, 'syla',
           (now() at time zone 'America/New_York')::date, s.starts, s.ends, 'daily', 1
    from (values
            ('Daily note siloing',   time '06:15', time '06:30', 'syla/note-siloing'),
            ('Daily edit feedback',  time '06:30', time '06:45', 'syla/edit-feedback'),
            ('Goal synergy linking', time '06:45', time '07:00', 'syla/goal-synergy'),
            ('Morning day summary',  time '07:00', time '07:30', 'syla/daily-summary')
         ) as s (title, starts, ends, doc_path)
    where not exists (select 1 from public.events e
                      where e.title = s.title and e.assignee = 'syla');

    insert into public.event_docs (event_id, doc_id)
    select e.id, d.id
    from (values
            ('Daily note siloing',   'syla/note-siloing'),
            ('Daily edit feedback',  'syla/edit-feedback'),
            ('Goal synergy linking', 'syla/goal-synergy'),
            ('Morning day summary',  'syla/daily-summary')
         ) as s (title, doc_path)
    join public.events e on e.title = s.title and e.assignee = 'syla'
    join public.docs d on d.path = s.doc_path
    on conflict do nothing;

    return new;
end
$$;
