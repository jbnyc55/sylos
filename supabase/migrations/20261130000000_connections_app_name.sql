-- The follows app presents as Connections.
--
-- The chat-first design (the "Connections — the app, redesigned"
-- board) names the app Connections: every relationship presents as
-- bidirectional even though the data layer keeps directional follows.
-- The home screens draw tile names from the row itself, so the seeded
-- row's name catches up. Guarded by the seeded values: a row the owner
-- renamed is theirs, not ours to touch (the stock_app_rows rule).

update public.vibe_code_apps
set name = 'Connections',
    hint = 'both ways, though you only ever see your side'
where slug = 'follows'
  and name = 'Followers';
