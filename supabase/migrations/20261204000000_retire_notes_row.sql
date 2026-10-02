-- The Notes row retires: the Drop tab took its job.
--
-- Quick capture lives in the Drop tab now (the chute: drop anything,
-- Syla's sort files it), which is what the Notes app was for — quick
-- lines, kept raw. The seeded stub row only kept a second, JavaScript
-- door on Home and in the Apps list. Same rule as the Chat row
-- (20261203): delete the stub, guarded by its own text, so a real
-- build or an owner's rename stays theirs, and deletion sticks.

delete from public.vibe_code_apps
where slug = 'notes'
  and name = 'Notes'
  and html like '%rendered by the Sylos shell%';
