-- The starter's silo vocabulary: close friends, friends, work
-- ---------------------------------------------------------------------------
-- Silos are the sharing containers — a member sees exactly the records
-- that share a silo with them — so the starter should open with a
-- vocabulary about PEOPLE, not one owner's old logging categories.
--
-- Two cleanups and one seed, all idempotent:
--
-- 1. The legacy vocabulary goes. 'money', 'calories', 'wellness' and
--    'goal' were seeded in 20260828 as note *types* (kinds of logs) and
--    rode the note_types → silos rename; they mean nothing to a fresh
--    fork. 'syla' was the old job editor's filter for instruction docs
--    — both of its jobs are done elsewhere now (an event's instructions
--    attach through event_docs; "Syla reads this" is the doc_syla
--    mark). 'skills' likewise only mirrored the skills/ path folder:
--    the agent and the app load skills by path, never by silo. And Syla
--    never needed a silo for access anyway: the claude role reads all
--    of public, silos gate members. Each is deleted only while
--    genuinely unused — no placements anywhere, no members — so a
--    database where the owner actually filed things keeps its silos.
--
-- 2. The migration-seeded doc placements leave 'syla' and 'skills'
--    first: those were made by migration (20260928/20260929), not by an
--    owner, so they must not keep the silos alive. Docs an owner placed
--    there by hand still do.
--
-- 3. The three starter silos arrive with descriptions in the prose
--    Syla's filing run reads (the app splits them on "But not:"), and
--    conservative defaults: new members in a silo may read it, and
--    propose nothing until the owner says so.

-- 1 ─ Detach the migration-seeded doc placements from the legacy silos:
--     the job docs from 'syla' (20260928/20260929) and the skill docs
--     from 'skills' (20260929). Both silos only ever mirrored what the
--     docs' own path folders (syla/, skills/) already say — the agent
--     and the app load skills by path, never by silo — so neither label
--     earns a container. Docs an owner placed by hand still count.
delete from public.doc_silos j
using public.silos s, public.docs d
where j.silo_id = s.id
  and j.doc_id = d.id
  and ((s.name = 'syla' and d.path like 'syla/%')
    or (s.name = 'skills' and d.path like 'skills/%'));

-- 2 ─ Drop the legacy vocabulary wherever it is genuinely unused.
delete from public.silos s
where s.name in ('money', 'calories', 'wellness', 'goal', 'syla', 'skills')
  and not exists (select 1 from public.note_silos          x where x.silo_id = s.id)
  and not exists (select 1 from public.doc_silos           x where x.silo_id = s.id)
  and not exists (select 1 from public.todo_silos          x where x.silo_id = s.id)
  and not exists (select 1 from public.cell_silos          x where x.silo_id = s.id)
  and not exists (select 1 from public.event_silos         x where x.silo_id = s.id)
  and not exists (select 1 from public.vibe_code_app_silos x where x.silo_id = s.id)
  and not exists (select 1 from public.silo_members        x where x.silo_id = s.id);

-- 3 ─ The starter vocabulary: three circles of people.
-- Descriptions stay under the column's 200-character check.
insert into public.silos (name, description, default_allows_sql)
select v.name, v.description, true
from (values
        ('close friends',
         'Your inner circle — plans, personal wins and struggles, photos, what you''d tell your best friends.' || E'\n' ||
         'But not: work, money details, or anything you''d keep to yourself.'),
        ('friends',
         'Things any friend could see — hangout plans, hobbies, recommendations, casual updates.' || E'\n' ||
         'But not: private feelings, health, money, or work.'),
        ('work',
         'Work life — projects, meetings, colleagues, career plans, professional notes and docs.' || E'\n' ||
         'But not: anything personal or social.')
     ) as v (name, description)
where not exists (select 1 from public.silos s where s.name = v.name);

-- 4 ─ The seeded skills/about doc told the agent to place new skills in
--     the skills silo; the path prefix is the filing now. Patched only
--     while the sentence is still the seeded one, so an owner's edits
--     to the doc are never overwritten.
update public.docs
set html = replace(html,
    'Save with <code>scripts/doc-save</code> and place it in the <code>skills</code> silo with <code>scripts/doc-silo</code> (see <code>skills/docs</code> for both).',
    'Save with <code>scripts/doc-save</code> under a <code>skills/</code> path (see <code>skills/docs</code>).')
where path = 'skills/about'
  and html like '%place it in the <code>skills</code> silo%';
