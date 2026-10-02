-- The syla-jobs app presents as Syla Tasks.
--
-- Home screens draw tile names from the row itself, so the seeded
-- row's name catches up (the slug stays syla-jobs — slugs are plumbing,
-- names are presentation). Guarded by the seeded name: a row the owner
-- renamed is theirs, per the stock_app_rows rule.

update public.vibe_code_apps
set name = 'Syla Tasks'
where slug = 'syla-jobs'
  and name = 'Syla Jobs';
