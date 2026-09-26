-- A todo in an event may thin the event's days with a rule of its own.
--
-- Since 20260908000000 a todo attached to an event took every one of the
-- event's occurrences and its own schedule fields were ignored — so a
-- "Daily todos" event could not hold a todo that is due every 2 days,
-- and the composer hid Repeats for such todos entirely. The client now
-- reads the child's rule as a filter over the event's days: no rule
-- means every occurrence (unchanged for every existing row), a rule
-- means only the event days the rule also picks, anchored on the todo's
-- own start_date. This is a client-side rule (recurrence is expanded in
-- the app, never in SQL), so the only change here is the column's
-- documentation catching up.

comment on column public.todo.event_id is
    'The event this todo belongs to. An attached todo shows on its event''s days: all of them when its own freq is null, or only those its own rule (freq, interval_n, byweekday, …, anchored on its start_date) also picks. An event''s todos are deleted with it.';
