-- Rename the map's cells: mind_map_cells → goal_method_cells.
--
-- The table's rows have always been goals and their ranked methods of
-- action; the name now says so. The rename carries every dependent object
-- with it — foreign keys (todo_goals, agent_map_proposals,
-- agent_todo_proposals), RLS policies, grants, triggers and indexes all
-- follow the table automatically — so this migration only renames the
-- table itself, then re-titles the attached objects so their names match,
-- and leaves a compatibility view behind under the old name.

alter table public.mind_map_cells rename to goal_method_cells;

comment on table public.goal_method_cells is
    'Ranked goal map: a forest of goal method cells. parent_id null = a top-level goal; children are its ranked methods of action, each recursively a goal of its own. The composite (parent_id, profile_id) FK pins every child to its parent''s profile.';

-- ---------------------------------------------------------------------------
-- Re-title the attached objects
-- ---------------------------------------------------------------------------
--
-- Cosmetic but worth it: constraint and index names surface in error
-- messages and query plans, and a goal_method_cells error naming
-- mind_map_cells would send the reader hunting for a table that no longer
-- exists. Renamed by catalog lookup rather than by guessing the generated
-- names.

do $$
declare
    r record;
begin
    for r in
        select conname from pg_constraint
        where conrelid = 'public.goal_method_cells'::regclass
          and conname like 'mind\_map\_cells%'
    loop
        execute format(
            'alter table public.goal_method_cells rename constraint %I to %I',
            r.conname, replace(r.conname, 'mind_map_cells', 'goal_method_cells'));
    end loop;

    -- Constraint renames above already renamed their backing indexes; this
    -- catches the standalone ones (the two (profile_id, parent_id, rank)
    -- indexes, full and live-only).
    for r in
        select indexname from pg_indexes
        where schemaname = 'public' and tablename = 'goal_method_cells'
          and indexname like 'mind\_map\_cells%'
    loop
        execute format('alter index public.%I rename to %I',
            r.indexname, replace(r.indexname, 'mind_map_cells', 'goal_method_cells'));
    end loop;

    for r in
        select tgname from pg_trigger
        where tgrelid = 'public.goal_method_cells'::regclass
          and not tgisinternal
          and tgname like 'mind\_map\_cells%'
    loop
        execute format('alter trigger %I on public.goal_method_cells rename to %I',
            r.tgname, replace(r.tgname, 'mind_map_cells', 'goal_method_cells'));
    end loop;
end
$$;

alter policy "Mind map cells are viewable by their owner"
    on public.goal_method_cells rename to "Goal method cells are viewable by their owner";
alter policy "Mind map cells are insertable by their owner"
    on public.goal_method_cells rename to "Goal method cells are insertable by their owner";
alter policy "Mind map cells are updatable by their owner"
    on public.goal_method_cells rename to "Goal method cells are updatable by their owner";
alter policy "Mind map cells are deletable by their owner"
    on public.goal_method_cells rename to "Goal method cells are deletable by their owner";

-- ---------------------------------------------------------------------------
-- Comments that named the old table
-- ---------------------------------------------------------------------------

comment on table public.todo_goals is
    'Which goal map cells each todo serves. goal_id references goal_method_cells; both foreign keys in the primary key is what lets PostgREST embed the many-to-many.';

comment on table public.agent_map_proposals is
    'Structured goal-map edits proposed by the daily routine (add/update/retire a goal_method_cells row), pending until the owner approves or denies each in the app. The owner''s own session applies approved edits; the claude role only ever inserts proposals, through propose_map_edit().';

comment on table public.day_summary is
    'Per-day rollup of the raw logs, written by the daily Claude routine. stats: {"insights": text, "goals": [{"id": uuid, "title": text, "status": "green"|"yellow"|"red", "why": text, "map_suggestions"?: [text], "todo_suggestions"?: [text]}], "<metric>": {"value": number, "description": text}}. goals[].id is a goal_method_cells uuid.';

comment on column public.goal_method_cells.notes is
    'Free-form notes about the cell, edited in the drawer that opens when the cell is selected on the canvas.';

comment on column public.goal_method_cells.deleted_at is
    'Soft delete: stamped on the cell and its whole subtree instead of deleting rows; null = live. The app filters on it in every query, todo embeds included; clearing it restores the cell.';

-- ---------------------------------------------------------------------------
-- Compatibility view for the deploy gap
-- ---------------------------------------------------------------------------
--
-- The frontend and the database deploy separately, so the build querying
-- mind_map_cells can be live for a while after this migration applies. A
-- security-invoker view under the old name keeps it working: simple enough
-- to be auto-updatable, so its reads and writes pass straight through to
-- the renamed table — RLS, row_edits logging and PostgREST embedding
-- (todo_goals → mind_map_cells resolves through it) included. Drop it once
-- no deployed client names mind_map_cells.

create view public.mind_map_cells
    with (security_invoker = true)
    as select * from public.goal_method_cells;

comment on view public.mind_map_cells is
    'Temporary compatibility alias for goal_method_cells, kept while deployed clients still query the old name. Drop when none do.';

grant select, insert, update, delete on public.mind_map_cells to authenticated;
grant select on public.mind_map_cells to claude;
