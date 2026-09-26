-- Soft delete for the goal map.
--
-- Deleting a goal (or any cell) used to remove the rows outright, taking the
-- whole subtree and every todo_goals link with it via the cascades. Now the
-- app stamps deleted_at on the cell and everything under it instead: the
-- client filters live cells with `deleted_at is null`, and the rows — titles,
-- notes, ranks, todo links — stay in place, recoverable by clearing the
-- stamp. The delete grant and the cascades remain for a true purge.

alter table public.mind_map_cells
    add column deleted_at timestamptz;

comment on column public.mind_map_cells.deleted_at is
    'Soft delete: stamped on the cell and its whole subtree instead of deleting rows; null = live. The app filters on it in every query, todo embeds included; clearing it restores the cell.';

-- The page only ever loads live cells; the partial index keeps that read
-- cheap as deleted rows accumulate under the full-table index.
create index mind_map_cells_live_profile_parent_rank_idx
    on public.mind_map_cells (profile_id, parent_id, rank)
    where deleted_at is null;
