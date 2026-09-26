-- Silo Bench: an eval for the siloing bot.
--
-- The siloing job (docs: syla/siloing) weighs every silo for a record and
-- ends each in one of three outcomes: PLACE it (sure, and no exclusion in
-- play), LEAVE it off (a weak fit), or ASK the owner (strongly considered,
-- not sure enough). Silo Bench is a fixed set of cases with the right
-- answers, so a bot — a new model, a rewritten prompt — can be graded
-- before it touches real records.
--
-- A CASE is self-contained: the record's text, and a snapshot of the silos
-- to judge it against (name + description, i.e. the silo's rulebook) each
-- with the expected outcome. Snapshotting the vocabulary keeps a case's
-- answer stable when the live silos are renamed or rewritten.
--
-- A RUN is one bot taking the bench; a RESULT is its answer for one case,
-- {"<silo name>": "place" | "leave" | "ask"} (a silo it didn't mention
-- counts as "leave"). The views grade it, and single out LEAKS — placing a
-- record in a silo it should have stayed out of — because silos drive
-- member visibility: a leak shows a record to real people, while a miss
-- only hides it.
--
-- The owner writes cases from the Silo Bench vibe code app; bots write runs
-- and results through the gated RPCs below (scripts/silo-bench).

-- ---------------------------------------------------------------------------
-- Cases
-- ---------------------------------------------------------------------------

-- Every element {name, description?, expected}, names unique, expected one
-- of the three outcomes. Immutable so it can back a check constraint.
create function public.silo_bench_silos_valid(_silos jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
    select jsonb_typeof(_silos) = 'array'
       and jsonb_array_length(_silos) between 1 and 20
       and not exists (
           select 1 from jsonb_array_elements(_silos) s
           where jsonb_typeof(s) <> 'object'
              or jsonb_typeof(s->'name') is distinct from 'string'
              or char_length(s->>'name') not between 1 and 100
              or s->>'expected' is null
              or s->>'expected' not in ('place', 'leave', 'ask')
              or (s ? 'description' and jsonb_typeof(s->'description') not in ('string', 'null'))
       )
       and (select count(distinct s->>'name') from jsonb_array_elements(_silos) s)
           = jsonb_array_length(_silos)
$$;

create table public.silo_bench_cases (
    id           uuid primary key default gen_random_uuid(),
    title        text not null check (char_length(title) between 1 and 200),
    -- What the record would be in the app: a jot or a doc.
    record_kind  text not null default 'note' check (record_kind in ('note', 'doc')),
    record_text  text not null check (char_length(record_text) between 1 and 20000),
    -- [{name, description, expected: place|leave|ask}] — the vocabulary
    -- snapshot and the answer key in one.
    silos        jsonb not null check (public.silo_bench_silos_valid(silos)),
    -- Why the answer is the answer, for whoever reads a failure.
    rationale    text not null default '' check (char_length(rationale) <= 5000),
    -- Retired cases stay (old results still point at them) but aren't served.
    active       boolean not null default true,
    created_at   timestamptz not null default now(),
    updated_at   timestamptz not null default now()
);

comment on table public.silo_bench_cases is
    'Silo Bench eval cases: a record''s text plus a snapshot of the silos to judge it against, each with the expected outcome (place / leave / ask). Edited in the Silo Bench vibe code app.';

create trigger silo_bench_cases_set_updated_at
    before update on public.silo_bench_cases
    for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Runs and results
-- ---------------------------------------------------------------------------

-- {"<silo name>": "place" | "leave" | "ask"} and nothing else.
create function public.silo_bench_predicted_valid(_predicted jsonb)
returns boolean
language sql
immutable
set search_path = ''
as $$
    select jsonb_typeof(_predicted) = 'object'
       and not exists (
           select 1 from jsonb_each(_predicted) p
           where jsonb_typeof(p.value) <> 'string'
              or p.value #>> '{}' not in ('place', 'leave', 'ask'))
$$;

create table public.silo_bench_runs (
    id           uuid primary key default gen_random_uuid(),
    -- Who took the bench: model, prompt version — whatever tells runs apart.
    bot          text not null check (char_length(bot) between 1 and 200),
    notes        text not null default '' check (char_length(notes) <= 5000),
    created_at   timestamptz not null default now(),
    finished_at  timestamptz
);

comment on table public.silo_bench_runs is
    'One bot taking Silo Bench. Started and finished through silo_bench_start_run / silo_bench_finish_run (scripts/silo-bench).';

create table public.silo_bench_results (
    id          uuid primary key default gen_random_uuid(),
    run_id      uuid not null references public.silo_bench_runs (id) on delete cascade,
    case_id     uuid not null references public.silo_bench_cases (id) on delete cascade,
    -- {"<silo name>": "place" | "leave" | "ask"}; unmentioned silos = leave.
    predicted   jsonb not null check (public.silo_bench_predicted_valid(predicted)),
    reasoning   text not null default '' check (char_length(reasoning) <= 10000),
    created_at  timestamptz not null default now(),
    unique (run_id, case_id)
);

comment on table public.silo_bench_results is
    'A bot''s answer for one Silo Bench case in one run. Graded by the silo_bench_grades view.';

create index silo_bench_results_case_id_idx on public.silo_bench_results (case_id);

-- ---------------------------------------------------------------------------
-- Grading
-- ---------------------------------------------------------------------------

-- One row per (result, silo): expected vs predicted, and what kind of miss.
create view public.silo_bench_decisions
with (security_invoker = on) as
select r.run_id,
       r.case_id,
       r.id as result_id,
       s->>'name' as silo,
       s->>'expected' as expected,
       coalesce(r.predicted->>(s->>'name'), 'leave') as predicted,
       coalesce(r.predicted->>(s->>'name'), 'leave') = s->>'expected' as correct,
       -- Placed where it should not be: the privacy failure.
       coalesce(r.predicted->>(s->>'name'), 'leave') = 'place'
           and s->>'expected' <> 'place' as leak,
       -- Should have been placed, wasn't: only hides the record.
       s->>'expected' = 'place'
           and coalesce(r.predicted->>(s->>'name'), 'leave') <> 'place' as miss
from public.silo_bench_results r
join public.silo_bench_cases c on c.id = r.case_id
cross join lateral jsonb_array_elements(c.silos) s;

comment on view public.silo_bench_decisions is
    'Silo Bench, one row per graded silo decision: expected vs predicted outcome, correct, leak (placed where it should not be) and miss (not placed where it should be).';

-- One row per result: the case is right only when every silo is right.
create view public.silo_bench_grades
with (security_invoker = on) as
select run_id,
       case_id,
       result_id,
       bool_and(correct) as case_correct,
       count(*) as decisions,
       count(*) filter (where correct) as decisions_correct,
       count(*) filter (where leak) as leaks,
       count(*) filter (where miss) as misses
from public.silo_bench_decisions
group by run_id, case_id, result_id;

comment on view public.silo_bench_grades is
    'Silo Bench, one row per result: whether the whole case was right, and its decision, leak and miss counts.';

-- One row per run: the scoreboard.
create view public.silo_bench_scores
with (security_invoker = on) as
select run.id as run_id,
       run.bot,
       run.notes,
       run.created_at,
       run.finished_at,
       count(g.result_id) as cases_answered,
       count(g.result_id) filter (where g.case_correct) as cases_correct,
       coalesce(sum(g.decisions), 0)::bigint as decisions,
       coalesce(sum(g.decisions_correct), 0)::bigint as decisions_correct,
       coalesce(sum(g.leaks), 0)::bigint as leaks,
       coalesce(sum(g.misses), 0)::bigint as misses
from public.silo_bench_runs run
left join public.silo_bench_grades g on g.run_id = run.id
group by run.id;

comment on view public.silo_bench_scores is
    'Silo Bench scoreboard, one row per run: cases answered and fully correct, silo decisions correct, leaks and misses.';

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.silo_bench_cases enable row level security;
alter table public.silo_bench_runs enable row level security;
alter table public.silo_bench_results enable row level security;

create policy "Silo bench cases belong to the owner"
    on public.silo_bench_cases for all to authenticated
    using (public.is_owner()) with check (public.is_owner());
create policy "Silo bench runs are viewable by the owner"
    on public.silo_bench_runs for select to authenticated
    using (public.is_owner());
create policy "Silo bench runs are deletable by the owner"
    on public.silo_bench_runs for delete to authenticated
    using (public.is_owner());
create policy "Silo bench results are viewable by the owner"
    on public.silo_bench_results for select to authenticated
    using (public.is_owner());

-- The bot reads the cases and writes its own runs and results — through
-- the RPCs below, every write imaged into row_edits.
create policy "claude reads silo bench cases"
    on public.silo_bench_cases for select to claude using (true);
create policy "claude reads silo bench runs"
    on public.silo_bench_runs for select to claude using (true);
create policy "claude starts silo bench runs"
    on public.silo_bench_runs for insert to claude with check (true);
create policy "claude finishes silo bench runs"
    on public.silo_bench_runs for update to claude using (true) with check (true);
create policy "claude reads silo bench results"
    on public.silo_bench_results for select to claude using (true);
create policy "claude records silo bench results"
    on public.silo_bench_results for insert to claude with check (true);
create policy "claude re-records silo bench results"
    on public.silo_bench_results for update to claude using (true) with check (true);

grant select, insert, update, delete on public.silo_bench_cases to authenticated;
grant select, delete on public.silo_bench_runs to authenticated;
grant select on public.silo_bench_results to authenticated;
grant select on public.silo_bench_decisions, public.silo_bench_grades, public.silo_bench_scores
    to authenticated;
grant select on public.silo_bench_cases to claude;
grant select, insert, update on public.silo_bench_runs to claude;
grant select, insert, update on public.silo_bench_results to claude;
grant select on public.silo_bench_decisions, public.silo_bench_grades, public.silo_bench_scores
    to claude;

-- ---------------------------------------------------------------------------
-- The bot's RPCs (scripts/silo-bench)
-- ---------------------------------------------------------------------------

create function public.silo_bench_start_run(_bot text, _notes text default '')
returns jsonb
language plpgsql
security invoker
as $$
declare
    _id uuid;
begin
    perform public.assert_claude_rq_key();
    set local statement_timeout = '30s';
    set local role claude;

    insert into public.silo_bench_runs (bot, notes)
    values (_bot, coalesce(_notes, ''))
    returning id into _id;

    return jsonb_build_object('run_id', _id);
end;
$$;

create function public.silo_bench_record(
    _run uuid, _case uuid, _predicted jsonb, _reasoning text default ''
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _id uuid;
begin
    perform public.assert_claude_rq_key();
    set local statement_timeout = '30s';
    set local role claude;

    if exists (select 1 from public.silo_bench_runs where id = _run and finished_at is not null) then
        raise exception 'run % is finished', _run;
    end if;

    insert into public.silo_bench_results (run_id, case_id, predicted, reasoning)
    values (_run, _case, _predicted, coalesce(_reasoning, ''))
    on conflict (run_id, case_id) do update
        set predicted = excluded.predicted,
            reasoning = excluded.reasoning
    returning id into _id;

    return (
        select jsonb_build_object(
            'result_id', _id,
            'case_correct', g.case_correct,
            'leaks', g.leaks,
            'misses', g.misses)
        from public.silo_bench_grades g
        where g.result_id = _id
    );
end;
$$;

create function public.silo_bench_finish_run(_run uuid)
returns jsonb
language plpgsql
security invoker
as $$
begin
    perform public.assert_claude_rq_key();
    set local statement_timeout = '30s';
    set local role claude;

    update public.silo_bench_runs
    set finished_at = coalesce(finished_at, now())
    where id = _run;

    return (select to_jsonb(s) from public.silo_bench_scores s where s.run_id = _run);
end;
$$;

comment on function public.silo_bench_start_run(text, text) is
    'Starts one Silo Bench run for a named bot, as the claude role. Gated by assert_claude_rq_key().';
comment on function public.silo_bench_record(uuid, uuid, jsonb, text) is
    'Records (or re-records) a bot''s answer for one case in an open run and returns its grade, as the claude role. Gated by assert_claude_rq_key().';
comment on function public.silo_bench_finish_run(uuid) is
    'Closes a Silo Bench run and returns its scoreboard row, as the claude role. Gated by assert_claude_rq_key().';

revoke all on function public.silo_bench_start_run(text, text) from public;
grant execute on function public.silo_bench_start_run(text, text) to anon;
revoke all on function public.silo_bench_record(uuid, uuid, jsonb, text) from public;
grant execute on function public.silo_bench_record(uuid, uuid, jsonb, text) to anon;
revoke all on function public.silo_bench_finish_run(uuid) from public;
grant execute on function public.silo_bench_finish_run(uuid) to anon;

-- ---------------------------------------------------------------------------
-- Starter cases
-- ---------------------------------------------------------------------------
--
-- Synthetic, written against rules shaped like the live ones (a friends
-- silo that excludes the embarrassing and anything about payment; a work
-- silo with only its name to go on), covering each outcome and the
-- exclusion-wins rule. Edit or retire them in the app.

insert into public.silo_bench_cases (title, record_text, silos, rationale) values
(
    'Plain life update → besties',
    'Went hiking at Bear Mountain with Dana on Saturday, the fall colors were unreal. Planning to go back in October.',
    '[{"name":"besties","description":"Everything\nBut not: It''s embarrassing or it''s payment","expected":"place"},
      {"name":"investors","description":null,"expected":"leave"}]',
    'Ordinary shareable life news: the besties inclusion ("Everything") matches and no exclusion is in play. Nothing about the company.'
),
(
    'Embarrassing → exclusion wins',
    'Tripped on the escalator at Grand Central in front of a whole tour group and my coffee went everywhere. Mortified.',
    '[{"name":"besties","description":"Everything\nBut not: It''s embarrassing or it''s payment","expected":"leave"},
      {"name":"investors","description":null,"expected":"leave"}]',
    'Matches "Everything" but trips "embarrassing" — exclusion wins, so it stays out.'
),
(
    'Payment detail → exclusion wins',
    'Paid Marco back $240 for the cabin via Venmo, and sent the landlord the October rent.',
    '[{"name":"besties","description":"Everything\nBut not: It''s embarrassing or it''s payment","expected":"leave"},
      {"name":"investors","description":null,"expected":"leave"}]',
    'Payments are explicitly excluded from besties; nothing investor-relevant.'
),
(
    'Company financials → investors, ask on besties',
    'Q3 update: MRR up 18% month over month, closed two enterprise pilots, runway now 20 months after the bridge note.',
    '[{"name":"besties","description":"Everything\nBut not: It''s embarrassing or it''s payment","expected":"ask"},
      {"name":"investors","description":null,"expected":"place"}]',
    'Squarely an investor update: place. Besties says "Everything", but whether company revenue and runway count as "payment" is exactly the owner''s call — strongly considered, unsure: ask.'
),
(
    'Ambiguous person → ask',
    'Coffee with Priya tomorrow at 9 — she wants to hear what we are building.',
    '[{"name":"besties","description":"Everything\nBut not: It''s embarrassing or it''s payment","expected":"place"},
      {"name":"investors","description":null,"expected":"ask"}]',
    'Besties takes everything that is not embarrassing or payment: place. Whether it belongs with investors turns on who Priya is — a fact the owner knows at a glance. Strong but unsure: ask, do not place.'
),
(
    'Mundane → everything means everything',
    'Remember to buy AA batteries and descale the kettle.',
    '[{"name":"besties","description":"Everything\nBut not: It''s embarrassing or it''s payment","expected":"place"},
      {"name":"investors","description":null,"expected":"leave"}]',
    'Besties'' inclusion is literally "Everything" and a chore list is neither embarrassing nor payment: place. Nothing to do with the company: leave investors off (no ask).'
),
(
    'Keyword trap → judge by meaning',
    'Watched a documentary about early-stage investors in the 1980s. Fun, but the ending dragged.',
    '[{"name":"besties","description":"Everything\nBut not: It''s embarrassing or it''s payment","expected":"place"},
      {"name":"investors","description":null,"expected":"leave"}]',
    'The word "investors" appears but the record is a movie opinion, not company news — judge by meaning. Shareable with besties.'
),
(
    'Mixed record → place one, ask one',
    'Great weekend: my sister''s wedding was beautiful. Also finalized the pitch deck for Monday''s partner meeting.',
    '[{"name":"besties","description":"Everything\nBut not: It''s embarrassing or it''s payment","expected":"place"},
      {"name":"investors","description":null,"expected":"ask"}]',
    'Two focuses. The wedding is bestie life news, so besties is a clear place. The pitch deck fits investors, but placing the whole record would show the wedding to them too, and investors has no rulebook beyond its name — strongly considered, not sure: ask (the job would also try to split the note).'
);
