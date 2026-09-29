-- The default app: which app the client opens at launch.
--
-- A Sylos install is a personal Supabase project that hosts apps — vibe
-- code apps, one self-contained HTML file per row (20261008000000) — and
-- one of them is the one the client boots straight into. default_app
-- names it: 'mash' (the stock chat app), 'todos' (the classic tabs), or
-- the slug of any vibe_code_apps row. The two stock names are the
-- client's to resolve, and either must work before the stock rows have
-- even been seeded, so there is deliberately no foreign key onto
-- vibe_code_apps.slug — a dangling value simply falls back to the
-- default at launch. It is a preference, not a grant: what a session may
-- actually open is still decided by each app's own RLS.
--
-- Who may set it: 20261104000000 column-scoped the authenticated update
-- grant on profiles to email alone, so this column needs a grant of its
-- own. The init migration's own-row policy ("Profiles are updatable by
-- their owner") already bounds any update to the session's own row —
-- which covers the owner — and choosing a launch app is exactly as
-- personal, and as harmless, as email, so the grant goes to
-- authenticated: every profile picks its own.

alter table public.profiles
    add column default_app text not null default 'mash'
        check (char_length(default_app) <= 80);

comment on column public.profiles.default_app is
    'Which app the client opens at launch: ''mash'' (the stock chat app), ''todos'' (the classic tabs), or a vibe_code_apps slug. A per-profile client preference, updatable by each session on its own row like email; not a grant — the app''s own RLS decides what actually opens.';

grant update (default_app) on public.profiles to authenticated;
