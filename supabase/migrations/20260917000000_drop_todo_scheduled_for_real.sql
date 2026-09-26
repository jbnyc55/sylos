-- Drop todo_scheduled, for real this time.
--
-- 20260909000000_free_floating_todos.sql already dropped this constraint —
-- but it shares its version stamp with 20260909000000_network_strategy_canvas.sql,
-- and with two files on one version the migration runner only recorded one
-- of them. Production kept the constraint, so adding a free-floating todo
-- (no times, no event) still failed with:
--
--     new row for relation "todo" violates check constraint "todo_scheduled"
--
-- This migration redoes 20260909000000_free_floating_todos under a version
-- of its own, idempotently, so it is correct whether or not the original
-- ever applied:
--
--   1. todo_scheduled goes. A row with times is an event, a row with an
--      event_id lives inside one, and a row with neither is a first-class
--      free-floating todo on its own start_date and recurrence.
--   2. Event deletion frees its todos (set null) rather than deleting
--      them — a no-op where the original migration already applied.

alter table public.todo
    drop constraint if exists todo_scheduled;

alter table public.todo
    drop constraint if exists todo_event_id_fkey;
alter table public.todo
    add constraint todo_event_id_fkey
        foreign key (event_id) references public.todo (id) on delete set null;

comment on column public.todo.event_id is
    'The event (a timed todo row) this todo belongs to. An attached todo inherits its event''s recurrence — its own schedule fields are ignored — and shows under the event''s group on the Today tab. Null on events themselves and on free-floating todos, which run on their own recurrence. On event delete the attachment clears (set null) so the todos float free rather than vanishing.';
