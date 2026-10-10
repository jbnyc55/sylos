-- My Calendar and Syla's Calendar.
--
-- The two calendar tiles get plainer names: the owner's Calendar
-- becomes "My Calendar", and Syla Task Cal (the syla-jobs app —
-- Syla's whole calendar, her task events and their runs) becomes
-- "Syla's Calendar". Home screens draw tile names from the row
-- itself (the slugs stay calendar / syla-jobs — slugs are plumbing,
-- names are presentation). Both guarded by the names the earlier
-- migrations set, so a row the owner renamed themselves stays
-- theirs, per the stock_app_rows rule.

update public.vibe_code_apps
set name = 'My Calendar'
where slug = 'calendar'
  and name = 'Calendar';

update public.vibe_code_apps
set name = 'Syla''s Calendar'
where slug = 'syla-jobs'
  and name = 'Syla Task Cal';

-- The silo-sweep mirror's function comment still pointed readers at
-- "Syla Tasks" (the tile's name two renames ago); have it name the
-- tile as it reads today.
comment on function public.silo_settings_mirror_event() is
    'Keeps the seeded Silo sweep event''s calendar shape mirroring silo_settings (daily → the daily_time block; thrice → 09:00–18:00; hourly → all day; weekly → the block on Sunday) so Syla''s Calendar shows the real schedule, and re-pins last_fired_on = 9999-12-31 after the reshape — the sweep branch stays the event''s only dispatcher.';
