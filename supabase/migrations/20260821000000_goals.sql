-- goals: a single text field per row, owned by a profile. Mirrors notes.

create table public.goals (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    body        text not null check (char_length(body) between 1 and 10000),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create index goals_profile_id_created_at_idx
    on public.goals (profile_id, created_at desc);

create trigger goals_set_updated_at
    before update on public.goals
    for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.goals enable row level security;

-- goals: fully owned by the profile that created them.
create policy "Goals are viewable by their owner"
    on public.goals for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Goals are insertable by their owner"
    on public.goals for insert
    to authenticated
    with check (profile_id = (select public.current_profile_id()));

create policy "Goals are updatable by their owner"
    on public.goals for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Goals are deletable by their owner"
    on public.goals for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- The claude role reads every application table; new tables opt in explicitly
-- (see 20260816000300). Its select grant arrives via default privileges.
create policy "claude reads everything"
    on public.goals for select
    to claude
    using (true);

-- Privileges mirror the policies exactly (see 20260816000200): both gates must
-- open for a row to be reachable, and anon gets nothing.
grant select, insert, update, delete on public.goals to authenticated;
