-- Timed todos — meetings. A todo has always been "some point that day"; a
-- meeting is the same row with a start and an end clock time, gcal-style.
-- Both columns or neither: a lone start (or a lone end) has no meaning here.
-- Times are local wall-clock, like every date in this schema — the app runs
-- in one person's one timezone, so no tz gymnastics.
--
-- Everything else composes for free: recurrence gives standing meetings,
-- todo_done still marks the occurrence handled, todo_exclusion still cancels
-- one day, and the agent proposal tables carry the two new fields in their
-- jsonb snapshots without a schema change.

alter table public.todo
    add column start_time time,
    add column end_time   time;

alter table public.todo
    add constraint todo_times_paired check ((start_time is null) = (end_time is null)),
    -- Same-day only, as a start: a meeting ends after it begins.
    add constraint todo_times_ordered check (end_time is null or end_time > start_time);

comment on column public.todo.start_time is
    'Meeting start (local wall clock). Null with end_time null = an untimed todo, just some point that day.';
comment on column public.todo.end_time is
    'Meeting end (local wall clock). Paired with start_time and strictly after it.';
