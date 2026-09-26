-- Hand-ordered todos.
--
-- The checklist used to render in creation order. Long-press-drag
-- reordering in the app needs an order it can write, so todos get
-- sort_rank: a float whose default is the row's creation moment in
-- epoch seconds — new todos land at the end exactly as before, and no
-- existing list changes order on migration. A drag writes the moved
-- todo's rank as the midpoint of its new neighbors', so one reorder is
-- one row's update, never a renumbering.
--
-- The rank is global to the todo, not per day: a recurring todo dragged
-- up the list rises on every day it appears, which is what a standing
-- priority means.

alter table public.todo add column sort_rank double precision;

update public.todo set sort_rank = extract(epoch from created_at);

alter table public.todo
    alter column sort_rank set not null,
    alter column sort_rank set default extract(epoch from now());

comment on column public.todo.sort_rank is
    'Hand-ordered position, ascending. Defaults to the creation moment (epoch seconds), so untouched lists stay in creation order; the app writes neighbor midpoints on drag-reorder.';
