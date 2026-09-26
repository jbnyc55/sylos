-- Goals, and tagging todos with them.
--
-- A goal is a named direction ("get stronger", "ship the app") a todo can be
-- in service of. One row per goal — a short name plus a longer description —
-- and a todo_goals junction so a todo carries any number of goals, shown as
-- chips on the todo list. Distinct from the old free-text goals table that
-- 20260828030000 folded into manual_notes: that was journal entries about
-- goals; this is the structured vocabulary todos tag against.

-- ---------------------------------------------------------------------------
-- goals
-- ---------------------------------------------------------------------------

create table public.goals (
    id           uuid primary key default gen_random_uuid(),
    profile_id   uuid not null references public.profiles (id) on delete cascade,
    name         text not null check (char_length(name) between 1 and 80),
    description  text check (char_length(description) <= 2000),
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now(),

    -- Two goals with one name would make the chips ambiguous.
    unique (profile_id, name)
);

comment on table public.goals is
    'Named directions todos can be tagged with: a short name and a description. Per-profile; links live in todo_goals.';

create trigger goals_set_updated_at
    before update on public.goals
    for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- todo_goals — the junction
-- ---------------------------------------------------------------------------

create table public.todo_goals (
    todo_id  uuid not null references public.todo (id) on delete cascade,
    goal_id  uuid not null references public.goals (id) on delete cascade,
    primary key (todo_id, goal_id)
);

comment on table public.todo_goals is
    'Which goals each todo serves. Both foreign keys in the primary key is what lets PostgREST embed the many-to-many.';

-- "All todos under goal X" — the goal-page query — is this.
create index todo_goals_goal_todo_idx
    on public.todo_goals (goal_id, todo_id);

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.goals      enable row level security;
alter table public.todo_goals enable row level security;

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

-- todo_goals: owned through both ends. Select and delete follow the todo;
-- insert checks the goal too, so a link can only join a todo and a goal that
-- belong to the same caller.
create policy "Todo goal links are viewable by the todo's owner"
    on public.todo_goals for select
    to authenticated
    using (exists (
        select 1 from public.todo t
        where t.id = todo_id
          and t.profile_id = (select public.current_profile_id())
    ));

create policy "Todo goal links are insertable by the owner of both ends"
    on public.todo_goals for insert
    to authenticated
    with check (
        exists (
            select 1 from public.todo t
            where t.id = todo_id
              and t.profile_id = (select public.current_profile_id())
        )
        and exists (
            select 1 from public.goals g
            where g.id = goal_id
              and g.profile_id = (select public.current_profile_id())
        )
    );

create policy "Todo goal links are deletable by the todo's owner"
    on public.todo_goals for delete
    to authenticated
    using (exists (
        select 1 from public.todo t
        where t.id = todo_id
          and t.profile_id = (select public.current_profile_id())
    ));

-- The claude role reads both, like every application table.
create policy "claude reads everything"
    on public.goals for select
    to claude
    using (true);

create policy "claude reads everything"
    on public.todo_goals for select
    to claude
    using (true);

-- Privileges mirror the policies exactly (see 20260816000200).
grant select, insert, update, delete on public.goals      to authenticated;
grant select, insert, delete         on public.todo_goals to authenticated;
