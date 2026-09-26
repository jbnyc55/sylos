-- Hand-ordered docs and apps, same drag as the todo checklist.
--
-- Both columns follow doc_folders' convention rather than todo's: the
-- rank is NULLABLE with no default, ranked rows sort first, and unranked
-- rows keep their old order after them (docs by path, apps by name). So
-- nothing moves on migration, and a row gets a rank only when someone
-- deliberately places it. Reordering renumbers the touched siblings —
-- docs within one folder, or the apps list — with fresh float ranks.

alter table public.docs add column sort_rank double precision;

comment on column public.docs.sort_rank is
    'Hand-ordered position among the docs of its folder, ascending. Null sorts after every ranked sibling, by path — the doc_folders convention.';

alter table public.vibe_code_apps add column sort_rank double precision;

comment on column public.vibe_code_apps.sort_rank is
    'Hand-ordered position in the Apps list, ascending. Null sorts after every ranked app, by name.';
