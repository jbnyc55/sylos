-- Fold the two remaining free-text tables into manual_notes, completing the
-- consolidation started in 20260828010000:
--
--   notes  → note_type 'wellness'   (the Notes tab merges into Wellness)
--   goals  → note_type 'goal'
--
-- Rows keep their ids and timestamps, then the old tables are dropped —
-- their triggers and policies go with them. After this, every free-text log
-- lives in manual_notes and the daily aggregation routines have one table to
-- read.

insert into public.manual_notes (id, profile_id, note_type, body, created_at, updated_at)
select id, profile_id, 'wellness', body, created_at, updated_at
from public.notes;

insert into public.manual_notes (id, profile_id, note_type, body, created_at, updated_at)
select id, profile_id, 'goal', body, created_at, updated_at
from public.goals;

drop table public.notes;
drop table public.goals;
