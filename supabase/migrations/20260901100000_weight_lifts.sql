-- Weight lifting log: one row per lift entry.
--
-- The lift name is free text rather than a vocabulary table — the Weights
-- page derives the list of lift types (and the record weight for each) from
-- the entries themselves, so a new lift type is created simply by logging
-- the first entry that names it.

create table public.weight_lifts (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    -- Which lift this entry is for ("Bench press", "Deadlift", …). Compared
    -- as typed, so the client trims what it inserts.
    lift        text not null check (char_length(lift) between 1 and 100),
    -- Pounds. One decimal covers fractional plates.
    weight_lb   numeric(6, 1) not null check (weight_lb > 0),
    reps        integer check (reps between 1 and 999),
    -- The day the lift happened, in the lifter's own timezone; entries can be
    -- backfilled onto past days.
    lifted_on   date not null default current_date,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

comment on table public.weight_lifts is
    'Weight lifting log: one row per set logged (lift name, weight in pounds, optional reps, day). Lift types and record weights are derived from these rows — there is no separate lift-type table.';

-- The page loads a profile's history newest first and groups by lift.
create index weight_lifts_profile_day_idx
    on public.weight_lifts (profile_id, lifted_on desc, created_at desc);

create trigger weight_lifts_set_updated_at
    before update on public.weight_lifts
    for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.weight_lifts enable row level security;

create policy "Weight lifts are viewable by their owner"
    on public.weight_lifts for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Weight lifts are insertable by their owner"
    on public.weight_lifts for insert
    to authenticated
    with check (profile_id = (select public.current_profile_id()));

create policy "Weight lifts are updatable by their owner"
    on public.weight_lifts for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Weight lifts are deletable by their owner"
    on public.weight_lifts for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- The claude role reads every application table; its select grant arrives via
-- default privileges (20260816000300).
create policy "claude reads everything"
    on public.weight_lifts for select
    to claude
    using (true);

-- Privileges mirror the policies exactly (see 20260816000200): both gates
-- must open for a row to be reachable, and anon gets nothing. Edit logging
-- attaches itself via the event trigger from 20260831010000.
grant select, insert, update, delete on public.weight_lifts to authenticated;
