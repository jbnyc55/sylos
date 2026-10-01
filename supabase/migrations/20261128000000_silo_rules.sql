-- Silo rules: silos are pure data slices, and say so in sentences.
--
-- The rebuild strips every reply semantic out of silos — who Syla answers,
-- and how, lives entirely on the connection (followers.syla_reply_mode +
-- reply_rules, 20261120000000 / 20261122000000). What remains of a silo
-- is the slice itself: which records fall in. This table holds the
-- slice's definition as the owner reads it — an ordered-enough list of
-- plain-English inclusion/exclusion sentences, one row each, typed by
-- what they carve on:
--
--   except_tag      "…but nothing tagged private"
--   except_source   "…but nothing synced from Plaid"
--   except_time     "…but nothing from before 2025"
--   only_include    "only workout notes"
--   except_words    "…but nothing mentioning the surprise party"
--
-- The sentences GUIDE Syla's siloing (her placement jobs read them before
-- placing a record; a new synced source fails safe — out of every silo —
-- and then asks), and the UI renders them on the silo's page. They are
-- not themselves enforcement: placement stays the junction rows, reads
-- stay RLS, and a membership change Syla wants goes through syla_approvals
-- kind 'silo_membership' (20261125000000) for the owner to apply — she
-- has no write path here or into any placement junction.

create table public.silo_rules (
    id         uuid primary key default gen_random_uuid(),
    silo_id    uuid not null references public.silos (id) on delete cascade,
    kind       text not null
               check (kind in ('except_tag', 'except_source', 'except_time',
                               'only_include', 'except_words')),
    body       text not null check (char_length(body) between 1 and 200),
    created_at timestamptz not null default now()
);

comment on table public.silo_rules is
    'The plain-English definition of a silo''s slice: inclusion/exclusion sentences (by tag, source, time, keyword, or only-include) the owner writes and Syla''s placement jobs honor. Guidance, not enforcement — placement is still the junction rows, and Syla proposes membership changes through syla_approvals rather than writing any.';
comment on column public.silo_rules.kind is
    'What the sentence carves on: except_tag / except_source / except_time / except_words exclude matching records from the slice; only_include narrows it to what it names.';
comment on column public.silo_rules.body is
    'The sentence as the UI shows it, e.g. ''nothing tagged private''. Free text — Syla reads it, the database does not parse it.';

create index silo_rules_silo_id_idx on public.silo_rules (silo_id, created_at);

alter table public.silo_rules enable row level security;
select public.declare_table_siloing('silo_rules', 'system');

-- The silo vocabulary is the owner's; so are its rules. Followers never
-- read them — what a silo excludes can be as telling as what it holds.
create policy "Silo rules are the owner's"
    on public.silo_rules for all to authenticated
    using (public.is_owner()) with check (public.is_owner());
create policy "claude reads silo rules"
    on public.silo_rules for select to claude using (true);

grant select, insert, update, delete on public.silo_rules to authenticated;
grant select on public.silo_rules to claude;
