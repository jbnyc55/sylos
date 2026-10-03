-- Syla Task Cal is HER calendar, not the owner's.
--
-- 20261224000000 renamed the wrong tile: "Syla Task Cal" belongs on
-- the syla-jobs app — the whole calendar system dedicated to Syla,
-- where her task events and their runs live — not on the owner's own
-- Calendar. Put the human calendar's name back and move the new name
-- where it belongs. Both guarded by the names the migrations set, so
-- a row the owner renamed themselves stays theirs; the syla-jobs
-- guard also covers the original seeded name for installs where
-- 20261210000000's rename never matched.

update public.vibe_code_apps
set name = 'Calendar'
where slug = 'calendar'
  and name = 'Syla Task Cal';

update public.vibe_code_apps
set name = 'Syla Task Cal'
where slug = 'syla-jobs'
  and name in ('Syla Tasks', 'Syla Jobs');
