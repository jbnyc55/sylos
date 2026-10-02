-- The Chat row retires: chat is the native shell's own surface.
--
-- The stock chat app was seeded as a vibe_code_apps row (slug 'mash',
-- renamed 'chat' in 20261119) so the launchers could list it. Chat is
-- a TAB now — the client's own front door, not an app on the grid —
-- so the row only puts a second, JavaScript door on Home and in the
-- Apps list. Delete the seeded stub. Guarded by the stub's own text:
-- a row Syla replaced with a real build, or the owner renamed, is
-- theirs and stays. Deletion sticks, per the stock_app_rows rule —
-- migrations run once, so the row never comes back.

delete from public.vibe_code_apps
where slug = 'chat'
  and name = 'Chat'
  and html like '%rendered by the Sylos shell%';
