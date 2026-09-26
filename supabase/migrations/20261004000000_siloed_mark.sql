-- The siloed mark.
--
-- "Unsiloed" stops being purely derived. Every record type can now be
-- marked siloed by hand — dismissed from the To-silo backlog without a
-- placement — or marked unsiloed, which clears the stamp (the app also
-- removes the placements) and puts it squarely back in the backlog.
--
-- Notes already carry this stamp as silos_vetted_at. Docs, todos and
-- goal cells get the same idea as siloed_at: null means "nobody has
-- called this handled"; a timestamp means it is out of the backlog even
-- with no placements. The owner's existing update policies cover the
-- writes.

alter table public.docs add column siloed_at timestamptz;
alter table public.todo add column siloed_at timestamptz;
alter table public.goal_method_cells add column siloed_at timestamptz;

comment on column public.docs.siloed_at is
    'Marked siloed by hand (or by Syla): out of the To-silo backlog even without placements. Null = still unsiloed unless doc_silos says otherwise.';
comment on column public.todo.siloed_at is
    'Marked siloed by hand: out of the To-silo backlog even without todo_silos placements.';
comment on column public.goal_method_cells.siloed_at is
    'Marked siloed by hand: out of the To-silo backlog even without cell_silos placements.';
