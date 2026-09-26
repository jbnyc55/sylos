-- Integration probe, and the todo model written down.
--
-- The GitHub → Supabase auto-deploy stopped applying migrations around
-- 20260915 — everything since carries "applied manually via dashboard" in
-- schema_migrations. The prime suspect, the duplicate version stamp
-- 20260909000000 (free_floating_todos vs network_strategy_canvas), is
-- removed in the same commit: the free_floating file is deleted outright,
-- since 20260917000000_drop_todo_scheduled_for_real redoes its work
-- idempotently and is already recorded in production.
--
-- This migration is the canary: harmless and idempotent. If it shows up in
-- schema_migrations under its own file name after the merge, the pipeline
-- is healthy again; if it too has to be applied by hand, the failure lies
-- elsewhere and the integration's run needs reading in the dashboard.

comment on table public.todo is
    'Todos and events in one table: a row with start/end times is an event (a block on the calendar day grid), a row with an event_id lives inside that event and inherits its recurrence, and a row with neither is a free-floating todo on its own start_date and recurrence. Done-ness lives per occurrence in todo_done; "this day" deletes in todo_exclusion.';
