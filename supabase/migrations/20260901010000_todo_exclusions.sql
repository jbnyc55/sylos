-- Deleting a single occurrence of a recurring todo — gcal's "this event".
--
-- A recurring todo is one row expanded client-side (20260828060000), so
-- removing one day from the series needs somewhere to record the removal: an
-- EXDATE, in iCalendar terms. One row here per removed occurrence; the rule
-- still matches the day, and the client drops it after expansion. As in RFC
-- 5545, exclusion happens after the rule (and its count) generates
-- occurrences, so an excluded day still spends one of an "ends after N
-- times" budget rather than pushing the series a step later.
--
-- The other two gcal delete choices need no schema: "this and following" is
-- an update setting until_date to the day before the occurrence, and "all"
-- deletes the todo row (todo_done and these rows cascade with it).
--
-- Distinct from a skipped mark in todo_done: skipped says "I looked at this
-- occurrence and let it go" and stays visible as history; an exclusion says
-- the occurrence was never scheduled and renders nothing.

create table public.todo_exclusion (
    todo_id     uuid not null references public.todo (id) on delete cascade,
    day         date not null,
    created_at  timestamptz not null default now(),
    primary key (todo_id, day)
);

comment on table public.todo_exclusion is
    'One row per deleted occurrence of a recurring todo (an EXDATE): the rule still matches this day, the client shows nothing.';

-- ---------------------------------------------------------------------------
-- Row level security — owned through the todo, exactly like todo_done.
-- ---------------------------------------------------------------------------

alter table public.todo_exclusion enable row level security;

create policy "Todo exclusions are viewable by the todo's owner"
    on public.todo_exclusion for select
    to authenticated
    using (exists (
        select 1 from public.todo t
        where t.id = todo_id
          and t.profile_id = (select public.current_profile_id())
    ));

create policy "Todo exclusions are insertable by the todo's owner"
    on public.todo_exclusion for insert
    to authenticated
    with check (exists (
        select 1 from public.todo t
        where t.id = todo_id
          and t.profile_id = (select public.current_profile_id())
    ));

-- Delete undoes an accidental "delete this day"; no update — a row either
-- excludes its day or doesn't exist.
create policy "Todo exclusions are deletable by the todo's owner"
    on public.todo_exclusion for delete
    to authenticated
    using (exists (
        select 1 from public.todo t
        where t.id = todo_id
          and t.profile_id = (select public.current_profile_id())
    ));

-- The claude role reads everything, like every application table.
create policy "claude reads everything"
    on public.todo_exclusion for select
    to claude
    using (true);

-- Privileges mirror the policies exactly (see 20260816000200).
grant select, insert, delete on public.todo_exclusion to authenticated;
