-- The calendar app presents as Syla Task Cal.
--
-- The calendar reads as Syla's task calendar everywhere — the chat's
-- approval card says "put it on Syla's task calendar", and the Home
-- tile should say the same thing instead of a bare "Calendar". Home
-- screens draw tile names from the row itself, so the seeded row's
-- name catches up (the slug stays calendar — slugs are plumbing,
-- names are presentation). Guarded by the seeded name: a row the
-- owner renamed is theirs, per the stock_app_rows rule.

update public.vibe_code_apps
set name = 'Syla Task Cal'
where slug = 'calendar'
  and name = 'Calendar';
