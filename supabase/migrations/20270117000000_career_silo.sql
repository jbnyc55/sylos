-- The starter's third circle: 'work' becomes 'career'
-- ---------------------------------------------------------------------------
-- The starter vocabulary (20261012000000_starter_silos.sql) seeded three
-- circles of people: 'close friends', 'friends' and 'work'. The third is
-- really about a person's career — projects, plans, the professional
-- self — and the app's Silos walkthrough now teaches the vocabulary by
-- that name, so the seed follows it.
--
-- Conservative and idempotent, the starter-silos migration's manner:
-- only a 'work' silo still wearing the exact seeded rulebook is renamed
-- — an owner who edited or wrote their own vocabulary keeps it — and
-- never when a 'career' silo already exists. A fresh fork runs the 2026
-- seed first and arrives here pristine, so a new database opens with
-- 'career'; placements and members ride along with the row, since
-- nothing references a silo by name.

update public.silos s
set name = 'career',
    description =
      'Career — projects, meetings, colleagues, career plans, professional notes and docs.' || E'\n' ||
      'But not: anything personal or social.'
where s.name = 'work'
  and s.description =
      'Work life — projects, meetings, colleagues, career plans, professional notes and docs.' || E'\n' ||
      'But not: anything personal or social.'
  and not exists (select 1 from public.silos c where c.name = 'career');
