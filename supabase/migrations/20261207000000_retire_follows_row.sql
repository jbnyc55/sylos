-- The Connections row retires: Connections is the shell's own surface.
--
-- Like Chat (20261203) and Notes (20261204), Connections leaves the
-- vibe_code_apps roster: the client draws its tile from the bundle and
-- opens its own native page (the redesigned Connections lifecycle),
-- so the seeded stub only kept a second, JavaScript door on Home.
-- Guarded by the stub's own text plus its seeded names (the row was
-- seeded 'Followers' and renamed 'Connections' in 20261130): a real
-- build or an owner's own rename stays theirs, and deletion sticks.

delete from public.vibe_code_apps
where slug = 'follows'
  and name in ('Connections', 'Followers')
  and html like '%rendered by the Sylos shell%';
