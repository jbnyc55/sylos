-- streak_marks: one X on the streak calendar. A mark is just the fact that a
-- day is crossed off, owned by a profile; unmarking deletes the row, so there
-- is nothing to update and no updated_at.

create table public.streak_marks (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    day         date not null,
    created_at  timestamptz not null default now(),

    -- A day is either marked or not; holding twice must never stack rows.
    unique (profile_id, day)
);

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.streak_marks enable row level security;

-- streak_marks: fully owned by the profile that created them.
create policy "Streak marks are viewable by their owner"
    on public.streak_marks for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Streak marks are insertable by their owner"
    on public.streak_marks for insert
    to authenticated
    with check (profile_id = (select public.current_profile_id()));

create policy "Streak marks are deletable by their owner"
    on public.streak_marks for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- The claude role reads every application table; new tables opt in explicitly
-- (see 20260816000300). Its select grant arrives via default privileges.
create policy "claude reads everything"
    on public.streak_marks for select
    to claude
    using (true);

-- Privileges mirror the policies exactly (see 20260816000200): both gates must
-- open for a row to be reachable, and anon gets nothing. No update — a mark is
-- only ever created or deleted.
grant select, insert, delete on public.streak_marks to authenticated;
