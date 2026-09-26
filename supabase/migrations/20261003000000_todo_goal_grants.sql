-- Silos and members for todos and goal cells.
--
-- The long-press drawer promises the same three things everywhere —
-- silos, members, Ask Syla — and until now todos and goal-map cells had
-- no junctions to hold the first two. The junction-per-record-type
-- pattern (note_silos/note_members, doc_silos/doc_members) extends to
-- them: todo_silos/todo_members on public.todo, cell_silos/cell_members
-- on public.goal_method_cells.
--
-- Placement is the visibility statement, exactly as for notes and docs.
-- (member_rq's server-side read paths grow into these tables separately;
-- the junctions land first so the owner can start placing.)
--
-- The row_edits event trigger attaches history to all four on creation.

create table public.todo_silos (
    todo_id     uuid not null references public.todo (id) on delete cascade,
    silo_id     uuid not null references public.silos (id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (todo_id, silo_id)
);

create table public.todo_members (
    todo_id     uuid not null references public.todo (id) on delete cascade,
    member_id   uuid not null references public.members (id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (todo_id, member_id)
);

create table public.cell_silos (
    cell_id     uuid not null references public.goal_method_cells (id) on delete cascade,
    silo_id     uuid not null references public.silos (id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (cell_id, silo_id)
);

create table public.cell_members (
    cell_id     uuid not null references public.goal_method_cells (id) on delete cascade,
    member_id   uuid not null references public.members (id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (cell_id, member_id)
);

create index todo_silos_silo_id_idx on public.todo_silos (silo_id);
create index todo_members_member_id_idx on public.todo_members (member_id);
create index cell_silos_silo_id_idx on public.cell_silos (silo_id);
create index cell_members_member_id_idx on public.cell_members (member_id);

alter table public.todo_silos enable row level security;
alter table public.todo_members enable row level security;
alter table public.cell_silos enable row level security;
alter table public.cell_members enable row level security;

-- Each junction follows its parent row's owner.

create policy "Todo silos follow the todo's owner"
    on public.todo_silos for all
    to authenticated
    using (exists (
        select 1 from public.todo t
        where t.id = todo_id
          and t.profile_id = (select public.current_profile_id())
    ))
    with check (exists (
        select 1 from public.todo t
        where t.id = todo_id
          and t.profile_id = (select public.current_profile_id())
    ));

create policy "Todo members follow the todo's owner"
    on public.todo_members for all
    to authenticated
    using (exists (
        select 1 from public.todo t
        where t.id = todo_id
          and t.profile_id = (select public.current_profile_id())
    ))
    with check (exists (
        select 1 from public.todo t
        where t.id = todo_id
          and t.profile_id = (select public.current_profile_id())
    ));

create policy "Cell silos follow the cell's owner"
    on public.cell_silos for all
    to authenticated
    using (exists (
        select 1 from public.goal_method_cells c
        where c.id = cell_id
          and c.profile_id = (select public.current_profile_id())
    ))
    with check (exists (
        select 1 from public.goal_method_cells c
        where c.id = cell_id
          and c.profile_id = (select public.current_profile_id())
    ));

create policy "Cell members follow the cell's owner"
    on public.cell_members for all
    to authenticated
    using (exists (
        select 1 from public.goal_method_cells c
        where c.id = cell_id
          and c.profile_id = (select public.current_profile_id())
    ))
    with check (exists (
        select 1 from public.goal_method_cells c
        where c.id = cell_id
          and c.profile_id = (select public.current_profile_id())
    ));

-- The claude role reads them, like every application table.
create policy "claude reads todo silos" on public.todo_silos for select to claude using (true);
create policy "claude reads todo members" on public.todo_members for select to claude using (true);
create policy "claude reads cell silos" on public.cell_silos for select to claude using (true);
create policy "claude reads cell members" on public.cell_members for select to claude using (true);

grant select, insert, delete on public.todo_silos to authenticated;
grant select, insert, delete on public.todo_members to authenticated;
grant select, insert, delete on public.cell_silos to authenticated;
grant select, insert, delete on public.cell_members to authenticated;
grant select on public.todo_silos to claude;
grant select on public.todo_members to claude;
grant select on public.cell_silos to claude;
grant select on public.cell_members to claude;
