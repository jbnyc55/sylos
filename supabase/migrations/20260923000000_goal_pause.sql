-- Pause a goal from the list view.
--
-- A stamped paused_at sets a top-level goal aside without touching its
-- tree: the row stays on the list (dimmed, with a Paused chip and a resume
-- button), its rank and cells are untouched, and clearing the stamp brings
-- it back exactly as it was. Paused goals also stop contributing to the
-- synergy scores computed on the tab (see 20260924000000) — a shelved
-- goal's ranking shouldn't inflate a shared cell's score.
--
-- The column lives on goal_method_cells like deleted_at does, and only the
-- owner writes it: the existing owner-update RLS policy already covers it,
-- and the claude role keeps its read-only view of the table.

alter table public.goal_method_cells add column paused_at timestamptz;

comment on column public.goal_method_cells.paused_at is
    'Pause stamp, set from the goal list; null = active. Meaningful on top-level goals (parent_id null): a paused goal stays listed and ranked but reads as set aside, and its occurrences count zero toward synergy scores. Clearing it resumes the goal unchanged.';
