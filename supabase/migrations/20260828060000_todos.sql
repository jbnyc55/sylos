-- Todos, reached by clicking a day on the streak calendar.
--
-- One row per todo, not per occurrence: a recurring todo stores its rule in
-- Google-Calendar-shaped fields and the client expands which days it lands
-- on. Completion is per occurrence — a (todo, day) pair in todo_done — so
-- checking off today's instance of a daily todo says nothing about
-- tomorrow's.
--
-- The recurrence fields, mirroring gcal's custom-recurrence dialog:
--
--   freq         null = does not repeat; daily | weekly | monthly | yearly
--   interval_n   every N days/weeks/months/years
--   byweekday    weekly only: which weekdays (JS getDay(): 0=Sun … 6=Sat)
--   month_mode   monthly only: same day-of-month as start_date, or the
--                nth weekday of the month
--   month_nth    monthly nth_weekday only: 1..5, or -1 for "last"
--   until_date   ends on a date (inclusive)
--   count_n      ends after N occurrences
--
-- start_date anchors everything: the first occurrence, the weekday/day-of-
-- month/month that monthly and yearly rules repeat on, and the due date when
-- freq is null.

create table public.todo (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    title       text not null check (char_length(title) between 1 and 2000),
    start_date  date not null,
    freq        text check (freq in ('daily', 'weekly', 'monthly', 'yearly')),
    interval_n  integer not null default 1 check (interval_n between 1 and 999),
    byweekday   smallint[] check (byweekday <@ array[0, 1, 2, 3, 4, 5, 6]::smallint[]),
    month_mode  text check (month_mode in ('day_of_month', 'nth_weekday')),
    month_nth   smallint check (month_nth = -1 or month_nth between 1 and 5),
    until_date  date,
    count_n     integer check (count_n >= 1),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),

    -- A one-off cannot have an end, and gcal's dialog offers one end or the
    -- other, never both.
    constraint todo_end_needs_freq  check (freq is not null or (until_date is null and count_n is null)),
    constraint todo_one_end_at_most check (until_date is null or count_n is null)
);

comment on table public.todo is
    'One row per todo; recurring rules in gcal-shaped fields, expanded client-side. Completion lives in todo_done.';

create index todo_profile_id_start_date_idx
    on public.todo (profile_id, start_date desc);

create trigger todo_set_updated_at
    before update on public.todo
    for each row execute function public.set_updated_at();

create table public.todo_done (
    todo_id       uuid not null references public.todo (id) on delete cascade,
    day           date not null,
    completed_at  timestamptz not null default now(),
    primary key (todo_id, day)
);

comment on table public.todo_done is
    'One row per completed occurrence: this todo, done on this day.';

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.todo      enable row level security;
alter table public.todo_done enable row level security;

-- todo: fully owned by the profile that created it.
create policy "Todos are viewable by their owner"
    on public.todo for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Todos are insertable by their owner"
    on public.todo for insert
    to authenticated
    with check (profile_id = (select public.current_profile_id()));

create policy "Todos are updatable by their owner"
    on public.todo for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Todos are deletable by their owner"
    on public.todo for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- todo_done: owned through the todo it completes.
create policy "Todo completions are viewable by the todo's owner"
    on public.todo_done for select
    to authenticated
    using (exists (
        select 1 from public.todo t
        where t.id = todo_id
          and t.profile_id = (select public.current_profile_id())
    ));

create policy "Todo completions are insertable by the todo's owner"
    on public.todo_done for insert
    to authenticated
    with check (exists (
        select 1 from public.todo t
        where t.id = todo_id
          and t.profile_id = (select public.current_profile_id())
    ));

create policy "Todo completions are deletable by the todo's owner"
    on public.todo_done for delete
    to authenticated
    using (exists (
        select 1 from public.todo t
        where t.id = todo_id
          and t.profile_id = (select public.current_profile_id())
    ));

-- The claude role reads both, like every application table.
create policy "claude reads everything"
    on public.todo for select
    to claude
    using (true);

create policy "claude reads everything"
    on public.todo_done for select
    to claude
    using (true);

-- Privileges mirror the policies exactly (see 20260816000200).
grant select, insert, update, delete on public.todo      to authenticated;
grant select, insert, delete         on public.todo_done to authenticated;
