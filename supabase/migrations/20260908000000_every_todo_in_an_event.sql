-- Every todo belongs to an event — no more Unscheduled tray.
--
-- 20260907000000 introduced the event model but left legacy untimed,
-- unattached todos in place for manual adoption. The owner's verdict: that
-- does not work. This migration finishes the move:
--
--   1. DATA — every unscheduled todo is attached to a catch-all "Daily
--      todos" event (created here per profile that needs one: daily,
--      8:00–8:30am, starting today). Nothing is lost; everything now shows
--      up inside an event on the grid, and the owner can move todos
--      between events from the event sheet.
--   2. INVARIANT — a check constraint makes the model law: a todo row
--      either has times (it is an event) or an event_id (it lives in one).
--   3. LIFECYCLE — deleting an event now deletes its todos with it
--      (cascade), gcal-style, instead of orphaning them back into a state
--      the app no longer has a home for. The sheet's delete confirm is the
--      guard rail.

-- 1. Adopt the strays. The catch-all is only created for profiles that
--    actually have unscheduled todos, so a clean database stays clean.
with owners as (
    select distinct profile_id
    from public.todo
    where start_time is null and event_id is null
),
made as (
    insert into public.todo
        (profile_id, title, start_date, start_time, end_time, freq, interval_n)
    select profile_id, 'Daily todos', current_date, '08:00', '08:30', 'daily', 1
    from owners
    returning id, profile_id
)
update public.todo t
set event_id = made.id
from made
where t.profile_id = made.profile_id
  and t.start_time is null
  and t.event_id is null;

-- 2. The model, enforced: times (an event) or an event (a todo in one).
--    todo_times_paired already guarantees start_time implies end_time.
alter table public.todo
    add constraint todo_scheduled
        check (event_id is not null or start_time is not null);

-- 3. An event's todos go with it. Replaces 20260907000000's set-null,
--    which would have recreated exactly the unscheduled state this
--    migration abolishes.
alter table public.todo
    drop constraint todo_event_id_fkey;
alter table public.todo
    add constraint todo_event_id_fkey
        foreign key (event_id) references public.todo (id) on delete cascade;

comment on column public.todo.event_id is
    'The event (a timed todo row) this todo belongs to. An attached todo inherits its event''s recurrence — its own schedule fields are ignored — and shows inside the event''s sheet on the Today grid. Null exactly on events themselves (todo_scheduled enforces times-or-event), and an event''s todos are deleted with it.';
