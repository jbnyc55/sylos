-- Home is the default: after logging into Sylos you get the launcher —
-- the list of every app you can open, from your own database and from
-- any member's project whose silo includes you. default_app's default
-- moves from 'mash' to 'home' accordingly; 'home' is a stock name the
-- client resolves, like 'mash' and 'todos'. Rows that already hold a
-- value keep it — a person who pinned an app keeps booting into it.

alter table public.profiles
    alter column default_app set default 'home';

comment on column public.profiles.default_app is
    'Which app the client opens at launch: ''home'' (the launcher — every app you can open), ''mash'' (the stock chat app), ''todos'' (the classic tabs), or a vibe_code_apps slug. A per-profile client preference, updatable by each session on its own row like email; not a grant — the app''s own RLS decides what actually opens.';
