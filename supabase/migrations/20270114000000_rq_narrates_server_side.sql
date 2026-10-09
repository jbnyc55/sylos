-- rq narrates server-side: the live status line survives the connector.
--
-- The receipt ladder's live narration — "Checking the calendar…",
-- "Going through your health logs…" under the owner's message — was
-- client-side: scripts/rq translated each query into a phrase and
-- stamped set_syla_run_status, keyed on SYLA_RUN_ID
-- (20261230000000_live_status_notes.sql). Then the Claude connector
-- became the default transport (20270110000000) and its rq tool posts
-- run_readonly_sql directly: no run id, no stamping — so connector
-- sessions show one static "Syla's reading…" however long the run
-- takes, and the deterministic narration quietly died.
--
-- The fix moves the translation into Postgres, where every transport
-- already lands: run_readonly_sql itself derives the phrase from the
-- statement (the same pure string matching — table → wording, no model
-- call, the raw SQL never shown; the only query-derived fragment is an
-- ilike search term, visible only to the owner whose database this is)
-- and stamps it on the owner's running runs before the transaction goes
-- read-only. Claims are worked one at a time, so "the running runs" is
-- almost always the one being worked; when a batch claim leaves several
-- running, they all wear the same line — cosmetic narration by design
-- (20261230000000's rule): the ladder's FACTS stay the timestamps and
-- the reply row. scripts/rq keeps its own explicit-run stamping — same
-- wording, and it still covers databases that lag this migration.

-- ---------------------------------------------------------------------------
-- syla_note_for_sql — the scripts/rq status_for translation, in SQL
-- ---------------------------------------------------------------------------

create function public.syla_note_for_sql(q text)
returns text
language plpgsql
immutable
as $$
declare
    _flat  text;
    _lower text;
    _table text;
    _base  text;
    _term  text;
begin
    _flat  := regexp_replace(coalesce(q, ''), E'[\\n\\t]', ' ', 'g');
    _lower := lower(_flat);
    -- The first FROM names the table; inside a CTE that's the innermost
    -- real table, which is a better label than the CTE's name anyway.
    _table := (regexp_match(_lower, 'from +(?:public\.)?"?([a-z0-9_]+)'))[1];

    if _table in ('docs', 'doc_folders', 'doc_syla') then
        _base := 'Reading up in your docs';
    elsif _table in ('notes', 'manual_notes', 'note_uploads', 'note_types') then
        _base := 'Going through your notes';
    elsif _table in ('chats', 'chat_messages', 'chat_members', 'chat_pokes') then
        _base := 'Reading the conversation';
    elsif _table in ('events', 'event_docs', 'event_exclusion', 'event_goals', 'apple_event', 'gcal_event') then
        _base := 'Checking the calendar';
    elsif _table in ('todo', 'todo_done', 'todo_group', 'todo_docs', 'todo_goals', 'apple_reminder') then
        _base := 'Looking over the to-dos';
    elsif _table in ('chute_items', 'chute_settings') then
        _base := 'Digging through the Chute';
    elsif _table in ('followers', 'follower_claims', 'peers') then
        _base := 'Checking your connections';
    elsif _table in ('silo_rules', 'silo_asks', 'silo_ask_candidates') or _table like '%\_silos' then
        _base := 'Reviewing your silos';
    elsif _table = 'syla_approvals' or _table like '%\_proposals' then
        _base := 'Checking what needs your sign-off';
    elsif _table = 'reply_rules' then
        _base := 'Checking the reply rules';
    elsif _table = 'uploads' then
        _base := 'Opening the attachment';
    elsif _table in ('minis', 'mini_files', 'mini_followers') then
        _base := 'Peeking at your minis';
    elsif _table = 'day_summary' then
        _base := 'Rereading the day summary';
    elsif _table in ('row_edits', 'agent_edits') then
        _base := 'Reviewing recent changes';
    elsif _table in ('syla_jobs', 'syla_job_runs') then
        _base := 'Checking my own task list';
    elsif _table = 'goals' then
        _base := 'Looking at your goals';
    elsif _table in ('mind_map_cells', 'cell_members', 'goal_cell_links') then
        _base := 'Tracing the mind map';
    elsif _table in ('health_samples', 'workouts', 'weight_lifts', 'food_log_entry', 'streak_marks') then
        _base := 'Going through your health logs';
    elsif _table in ('money_entry', 'card_purchase', 'plaid_item') then
        _base := 'Going over the money logs';
    elsif _table in ('wiki_pages', 'wiki_page_types') then
        _base := 'Flipping through the wiki';
    elsif _table in ('data_tables', 'user_table_proposals') then
        _base := 'Scanning your tables';
    elsif _table = 'guests' or _table like 'guest\_%' then
        _base := 'Checking guest access';
    elsif _table is null then
        if _lower like '%count(%' then
            _base := 'Crunching some numbers';
        else
            _base := 'Digging through the database';
        end if;
    else
        _base := 'Checking ' || replace(_table, '_', ' ');
    end if;

    if _table is not null then
        -- "Counting" reads badly after some phrases ("Counting reading
        -- the conversation") — counting keeps the plain table noun.
        if _lower like '%count(%' then
            _base := 'Crunching the numbers on ' || replace(_table, '_', ' ');
        end if;
        -- Upcoming-events scans deserve their own line.
        if _table = 'events' and _lower ~ 'start_date *>=' then
            _base := 'Scoping what is coming up';
        end if;
    end if;

    _term := (regexp_match(_flat, 'ilike +''%?([^%'']{1,40})%?''', 'i'))[1];
    _term := nullif(btrim(regexp_replace(coalesce(_term, ''), '[[:cntrl:]]', '', 'g')), '');
    if _term is not null then
        _base := _base || ' matching “' || _term || '”';
    end if;

    return _base || '…';
end;
$$;

comment on function public.syla_note_for_sql(text) is
    'Translates one rq statement into the Syla-voiced status line (the scripts/rq status_for mapping, server-side): first FROM table → wording, count() and upcoming-events overrides, the first ilike term quoted. Pure string matching — no model call, and the raw SQL is never shown.';

-- Derivation only — kept off the public surface; the claude role calls
-- it from inside run_readonly_sql's stamping update.
revoke all on function public.syla_note_for_sql(text) from public;
grant execute on function public.syla_note_for_sql(text) to claude;

-- ---------------------------------------------------------------------------
-- run_readonly_sql — same contract, now narrating
-- ---------------------------------------------------------------------------
--
-- Identical to 20260820000000's definition except for the narration
-- block: after switching to claude and before the transaction goes
-- read-only, stamp the derived note on the owner's running runs. The
-- same columns set_syla_run_status touches, under the same grant and
-- policy; best-effort on purpose — a failed stamp never fails the read.

create or replace function public.run_readonly_sql(q text)
returns jsonb
language plpgsql
security invoker
as $$
declare
    result jsonb;
begin
    perform public.assert_claude_rq_key();

    if q is null or btrim(q) = '' then
        raise exception 'empty query';
    end if;
    if btrim(q) like '%;' then
        raise exception 'send one statement without a trailing semicolon';
    end if;

    set local statement_timeout = '30s';
    set local role claude;

    begin
        update public.syla_job_runs
        set status_note = public.syla_note_for_sql(q), status_note_at = now()
        where status = 'running';
    exception when others then
        null;  -- narration, never the job
    end;

    set local transaction_read_only = on;

    execute format(
        'select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from (%s) t', q)
    into result;

    return result;
end;
$$;

comment on function public.run_readonly_sql(text) is
    'Runs one read-only SQL statement as the claude role and returns rows as a JSON array; each call also stamps the live status line on the owner''s running syla job runs, derived from the statement (syla_note_for_sql). Gated by assert_claude_rq_key().';
