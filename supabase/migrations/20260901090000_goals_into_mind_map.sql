-- Fold the goals vocabulary into the goal map.
--
-- The Goals tab is replaced by the goal map (mind map) list, so the
-- structured goals table goes away: every existing goal becomes a top-level
-- cell of the mind map — same id, so nothing referencing a goal moves — and
-- the todo_goals junction repoints its goal_id foreign key at
-- mind_map_cells. Todos keep their tags; the vocabulary they tag against is
-- now the goal map's top-level cells.

-- ---------------------------------------------------------------------------
-- 1. Every goal becomes a root cell, id preserved
-- ---------------------------------------------------------------------------
--
-- Appended after any cells the map already has, in the old tab's
-- alphabetical order. The description lands in the cell's notes.

insert into public.mind_map_cells (id, profile_id, parent_id, title, rank, notes, created_at)
select
    g.id,
    g.profile_id,
    null,
    g.name,
    coalesce((select max(c.rank)
              from public.mind_map_cells c
              where c.profile_id = g.profile_id and c.parent_id is null), -1)
      + row_number() over (partition by g.profile_id order by g.name),
    g.description,
    g.created_at
from public.goals g;

-- ---------------------------------------------------------------------------
-- 2. Repoint the junction
-- ---------------------------------------------------------------------------

alter table public.todo_goals
    drop constraint todo_goals_goal_id_fkey;

alter table public.todo_goals
    add constraint todo_goals_goal_id_fkey
        foreign key (goal_id) references public.mind_map_cells (id)
        on delete cascade;

comment on table public.todo_goals is
    'Which goal map cells each todo serves. goal_id references mind_map_cells; both foreign keys in the primary key is what lets PostgREST embed the many-to-many.';

-- The insert policy checked goal ownership against the goals table; the same
-- check now runs against the cells.
drop policy "Todo goal links are insertable by the owner of both ends" on public.todo_goals;
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
            select 1 from public.mind_map_cells c
            where c.id = goal_id
              and c.profile_id = (select public.current_profile_id())
        )
    );

-- ---------------------------------------------------------------------------
-- 3. Drop the old table — its policies and trigger fall with it
-- ---------------------------------------------------------------------------

drop table public.goals;
