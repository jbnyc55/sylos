-- Events own todos.
--
-- The Today tab becomes a gcal-style day grid, and the model sharpens with
-- it: an EVENT is a todo row with a start and end time — the blocks on the
-- grid — and a TODO now belongs to an event, through the new event_id
-- self-reference. An attached todo has no schedule of its own: it occurs
-- exactly when its event does (the client and the routines derive due-ness
-- from the parent's recurrence), and it is checked off per occurrence in
-- todo_done as before. Free-floating untimed todos are no longer part of
-- the model; existing rows without times keep working but surface in an
-- Unscheduled tray until the owner attaches each to an event or gives it
-- times of its own.
--
-- Nothing here changes who may write what: the owner's grants on todo
-- cover the new column, and the claude role still only reads.

alter table public.todo
    add column event_id uuid references public.todo (id) on delete set null,
    add constraint todo_event_not_self check (event_id is null or event_id <> id);

comment on column public.todo.event_id is
    'The event (a timed todo row) this todo belongs to. An attached todo inherits its event''s recurrence — its own schedule fields are ignored — and shows inside the event''s sheet on the Today grid. Null on events themselves and on legacy unattached todos. On event delete the attachment clears (set null) so the todos surface for reassignment rather than vanishing.';

-- The event sheet asks for an event's todos.
create index todo_event_id_idx on public.todo (event_id) where event_id is not null;
