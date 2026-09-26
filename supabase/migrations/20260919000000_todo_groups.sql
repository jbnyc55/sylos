-- Todos can be gathered into named groups.
--
-- On the day list, holding a free-floating todo and dropping it onto
-- another one gathers the pair into a GROUP: a todo_group row the two
-- todos point at through the new todo.group_id. A group changes nothing
-- about scheduling — each member keeps its own recurrence and its own
-- todo_done marks — it only changes how a day renders: when two or more
-- of a group's members land on the same day, the day shows one collapsible
-- group row (a caret where the checkbox would be) with the members folded
-- inside; a day where only one member shows up renders that todo plainly,
-- no group around it.
--
-- Deleting a group frees its members (group_id clears to null) rather than
-- deleting them, the same shape as event deletion.

create table public.todo_group (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    title       text not null check (char_length(title) between 1 and 200),
    created_at  timestamptz not null default now()
);

comment on table public.todo_group is
    'A named gathering of todos. Display-only: members keep their own schedules and marks; a day folds two-or-more co-occurring members into one collapsible row.';

alter table public.todo
    add column group_id uuid references public.todo_group (id) on delete set null;

comment on column public.todo.group_id is
    'The group this todo belongs to, if any. Purely presentational — days where several members co-occur fold them under the group''s row. On group delete the membership clears (set null).';

-- The day list asks for a group's members.
create index todo_group_id_idx on public.todo (group_id) where group_id is not null;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.todo_group enable row level security;

create policy "Todo groups are viewable by their owner"
    on public.todo_group for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Todo groups are insertable by their owner"
    on public.todo_group for insert
    to authenticated
    with check (profile_id = (select public.current_profile_id()));

create policy "Todo groups are updatable by their owner"
    on public.todo_group for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Todo groups are deletable by their owner"
    on public.todo_group for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- The claude role reads it, like every application table.
create policy "claude reads everything"
    on public.todo_group for select
    to claude
    using (true);

-- Privileges mirror the policies exactly (see 20260816000200).
grant select, insert, update, delete on public.todo_group to authenticated;
