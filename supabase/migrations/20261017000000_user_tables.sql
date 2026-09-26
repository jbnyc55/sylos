-- User tables: the owner's own tables, proposed by Syla, approved in the
-- app, created in the database — no fork, no merge, no Xcode build.
--
-- The flow ("put this CSV into a table and make me an app"):
--   1. Syla reads the upload, writes CREATE TABLE + RLS + policies as a
--      user_table_proposals row through propose_user_table() — her usual
--      gated, rq-key write path. Data rides along as plain INSERTs in
--      seed_sql. The proposal is inert.
--   2. The owner sees the card in the Syla tab's Inbox — title, summary,
--      the SQL itself — and taps Apply, Reject, or Revise, exactly like a
--      todo or map proposal.
--   3. Apply calls apply_user_table_proposal(), which executes the
--      approved script and tells PostgREST to reload, so the table is
--      queryable (and vibe-app-buildable) immediately.
--
-- The trust story, in three layers:
--   * The owner is the authority: nothing runs until they approve a row,
--     and the full SQL is visible on the card.
--   * A real privilege boundary, not a promise: approved scripts execute
--     as `user_tables_owner`, a NOLOGIN role whose only power is CREATE
--     on schema public. It owns the tables it creates and nothing else —
--     it cannot read or alter product tables, touch other schemas, mint
--     roles, or grant anything it does not own. A malicious script is
--     boxed in even if a careless approval lets it through.
--   * Tripwires on top: proposals are linted at both propose and apply
--     time — no SECURITY DEFINER, no role games, no functions/triggers,
--     no write grants to claude. The lint is a guard rail, not the
--     boundary; the role is the boundary.
--
-- The invariant the owner chose: user tables are the user's. claude reads
-- them (like everything in public), and never writes them — no grant, no
-- RPC, no trigger path. All writes go through the owner's own
-- authenticated session (the vibe app, or the app itself).

-- ---------------------------------------------------------------------------
-- The sandbox role that owns every user table
-- ---------------------------------------------------------------------------

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'user_tables_owner') then
        create role user_tables_owner nologin;
    end if;
end
$$;

grant usage, create on schema public to user_tables_owner;
-- postgres needs membership to own the apply function below and to set the
-- role's default privileges here.
grant user_tables_owner to postgres;

-- Tables the sandbox role creates get the standard access automatically:
-- claude can read them (its per-table RLS policy still comes from the
-- proposal script), the owner's session gets full DML (row access still
-- gated by the script's policies), and identity sequences work.
alter default privileges for role user_tables_owner in schema public
    grant select on tables to claude;
alter default privileges for role user_tables_owner in schema public
    grant select, insert, update, delete on tables to authenticated;
alter default privileges for role user_tables_owner in schema public
    grant usage, select on sequences to authenticated;

-- ---------------------------------------------------------------------------
-- The proposal queue
-- ---------------------------------------------------------------------------

create table public.user_table_proposals (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    -- The card's headline ("workouts — from workouts.csv") and the
    -- plain-English case for it.
    title       text not null check (char_length(title) between 1 and 120),
    summary     text not null check (char_length(summary) between 1 and 2000),
    -- The schema change itself: CREATE TABLE / ALTER TABLE / DROP TABLE
    -- plus RLS and policies, exactly as it will run.
    ddl_sql     text not null check (char_length(ddl_sql) between 1 and 100000),
    -- Optional data load (plain INSERTs), applied right after the DDL in
    -- the same transaction. Bounded — bigger datasets enter through the
    -- vibe app under the owner's own session instead.
    seed_sql    text check (seed_sql is null or char_length(seed_sql) <= 5000000),
    status      text not null default 'pending'
                    check (status in ('pending', 'applied', 'failed', 'denied',
                                      'changes_requested', 'withdrawn')),
    -- The owner's free-text change request (status changes_requested);
    -- owner-written only, same as the other proposal queues.
    feedback    text check (feedback is null or char_length(feedback) between 1 and 2000),
    -- Why an apply failed, written by apply_user_table_proposal() so Syla
    -- can read it and revise.
    error       text,
    created_at  timestamptz not null default now(),
    resolved_at timestamptz
);

comment on table public.user_table_proposals is
    'Schema changes for the owner''s own tables, proposed by Syla and inert until the owner applies one in the app. Applied scripts run as the sandboxed user_tables_owner role via apply_user_table_proposal(). Applied rows are kept: this table is the schema history of every user table.';

create index user_table_proposals_pending_idx
    on public.user_table_proposals (profile_id, status, created_at);

alter table public.user_table_proposals enable row level security;

-- Owner: reads the queue, resolves rows, prunes old ones.
grant select, delete on public.user_table_proposals to authenticated;
grant update (status, resolved_at, feedback) on public.user_table_proposals to authenticated;

create policy "Table proposals are viewable by their owner"
    on public.user_table_proposals for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Table proposals are resolvable by their owner"
    on public.user_table_proposals for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Table proposals are deletable by their owner"
    on public.user_table_proposals for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- claude: reads everything, inserts pending rows through the RPC below,
-- and may rewrite only rows the owner flagged or an apply bounced.
create policy "claude reads everything"
    on public.user_table_proposals for select
    to claude
    using (true);

create policy "claude proposes user tables"
    on public.user_table_proposals for insert
    to claude
    with check (status = 'pending');

grant insert (profile_id, title, summary, ddl_sql, seed_sql)
    on public.user_table_proposals to claude;

create policy "claude revises flagged proposals"
    on public.user_table_proposals for update
    to claude
    using (status in ('changes_requested', 'failed'))
    with check (status in ('pending', 'withdrawn'));

grant update (title, summary, ddl_sql, seed_sql, status, resolved_at)
    on public.user_table_proposals to claude;

-- The apply function below runs as user_tables_owner and needs to read
-- the row it is applying and record the outcome.
grant select on public.user_table_proposals to user_tables_owner;
grant update (status, error, resolved_at) on public.user_table_proposals to user_tables_owner;

create policy "the apply function reads proposals"
    on public.user_table_proposals for select
    to user_tables_owner
    using (true);

create policy "the apply function records outcomes"
    on public.user_table_proposals for update
    to user_tables_owner
    using (true)
    with check (true);

-- ---------------------------------------------------------------------------
-- The lint: tripwires over proposed SQL
-- ---------------------------------------------------------------------------
--
-- Run at propose, revise, AND apply time. These are guard rails against the
-- scripts Syla should never write — the privilege boundary itself is the
-- user_tables_owner role. Kept deliberately blunt: a false rejection costs a
-- revision, a false pass costs nothing the role doesn't already contain.

create or replace function public.assert_user_table_sql(_sql text, _is_ddl boolean)
returns void
language plpgsql
immutable
as $$
begin
    if _sql is null or btrim(_sql) = '' then
        raise exception 'the script is empty';
    end if;
    if _sql ~* 'security\s+definer' then
        raise exception 'user table scripts may not create SECURITY DEFINER objects';
    end if;
    if _sql ~* '\m(set|reset)\s+(local\s+|session\s+)?role\M'
       or _sql ~* 'session_authorization' or _sql ~* 'session\s+authorization' then
        raise exception 'user table scripts may not switch roles';
    end if;
    if _sql ~* 'alter\s+default\s+privileges' then
        raise exception 'user table scripts may not alter default privileges';
    end if;
    if _sql ~* 'create\s+(or\s+replace\s+)?(function|procedure|trigger|event\s+trigger)' then
        raise exception 'user table scripts may not create functions or triggers — tables, indexes, RLS and policies only';
    end if;
    if _sql ~* '\m(create|alter|drop)\s+(role|user|group)\M' then
        raise exception 'user table scripts may not manage roles';
    end if;
    if _sql ~* '\mgrant\M[^;]*\m(insert|update|delete|truncate|all|execute|usage|create|references|trigger)\M[^;]*\mclaude\M'
       or _sql ~* 'create\s+policy[^;]*\mfor\s+(insert|update|delete|all)\M[^;]*\mclaude\M' then
        raise exception 'user tables are the owner''s: claude may be granted select and nothing else';
    end if;
    if _is_ddl then
        if _sql ~* '\m(auth|storage|vault|cron|extensions|net|graphql|graphql_public|realtime|supabase_functions|pgsodium|pgbouncer|pg_catalog|information_schema)\s*\.' then
            raise exception 'user table scripts stay in schema public';
        end if;
        if _sql ~* '\mcreate\s+table\M' and _sql !~* 'enable\s+row\s+level\s+security' then
            raise exception 'every new table must enable row level security in the same script';
        end if;
        if _sql ~* '\m(commit|rollback|begin)\s*;' then
            raise exception 'user table scripts may not contain transaction control — each proposal is one transaction';
        end if;
    end if;
end;
$$;

comment on function public.assert_user_table_sql(text, boolean) is
    'Tripwires over a proposed user-table script: no definers, role games, functions/triggers, claude write grants, foreign schemas, or unprotected tables. A lint, not the boundary — approved scripts run as the sandboxed user_tables_owner role either way.';

-- ---------------------------------------------------------------------------
-- propose_user_table — Syla's write path over HTTPS
-- ---------------------------------------------------------------------------

create or replace function public.propose_user_table(
    _profile_id uuid,
    _title      text,
    _summary    text,
    _ddl_sql    text,
    _seed_sql   text default null
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    existing uuid;
    result   jsonb;
begin
    perform public.assert_claude_rq_key();
    perform public.assert_user_table_sql(_ddl_sql, true);
    if _seed_sql is not null then
        perform public.assert_user_table_sql(_seed_sql, false);
    end if;

    set local statement_timeout = '30s';
    set local role claude;

    -- The same schema change, still pending: hand its id back.
    select id into existing
    from public.user_table_proposals
    where profile_id = _profile_id
      and status = 'pending'
      and ddl_sql = _ddl_sql
    limit 1;

    if existing is not null then
        return jsonb_build_object('id', existing, 'status', 'pending',
                                  'duplicate', true);
    end if;

    if (select count(*) from public.user_table_proposals
        where profile_id = _profile_id and status = 'pending') >= 10 then
        raise exception 'there are already 10 pending table proposals — wait for the owner to resolve some first';
    end if;

    insert into public.user_table_proposals
        (profile_id, title, summary, ddl_sql, seed_sql)
    values
        (_profile_id, _title, _summary, _ddl_sql, _seed_sql)
    returning jsonb_build_object('id', id, 'title', title, 'status', status)
    into result;

    return result;
end;
$$;

comment on function public.propose_user_table(uuid, text, text, text, text) is
    'Files one pending user-table proposal as the claude role — Syla''s only path toward new tables. Gated by assert_claude_rq_key(); linted by assert_user_table_sql(); idempotent against identical pending DDL; the backlog is capped at 10.';

revoke all on function public.propose_user_table(uuid, text, text, text, text) from public;
grant execute on function public.propose_user_table(uuid, text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- revise_user_table — the feedback (and failure) loop's write path
-- ---------------------------------------------------------------------------
--
-- Same contract as revise_todo_edit, with one addition: a failed apply also
-- lands back here — Syla reads the error column, fixes the script, and
-- returns the row to pending for another look.

create or replace function public.revise_user_table(
    _id       uuid,
    _withdraw boolean default false,
    _title    text default null,
    _summary  text default null,
    _ddl_sql  text default null,
    _seed_sql text default null
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    result jsonb;
begin
    perform public.assert_claude_rq_key();

    if not _withdraw then
        if _title is null or _summary is null or _ddl_sql is null then
            raise exception 'a revision restates the whole proposal — _title, _summary and _ddl_sql are required (or pass _withdraw)';
        end if;
        perform public.assert_user_table_sql(_ddl_sql, true);
        if _seed_sql is not null then
            perform public.assert_user_table_sql(_seed_sql, false);
        end if;
    end if;

    set local statement_timeout = '30s';
    set local role claude;

    if _withdraw then
        update public.user_table_proposals
        set status = 'withdrawn', resolved_at = now()
        where id = _id and status in ('changes_requested', 'failed')
        returning jsonb_build_object('id', id, 'status', status)
        into result;
    else
        update public.user_table_proposals
        set title    = _title,
            summary  = _summary,
            ddl_sql  = _ddl_sql,
            seed_sql = _seed_sql,
            status   = 'pending',
            resolved_at = null
        where id = _id and status in ('changes_requested', 'failed')
        returning jsonb_build_object('id', id, 'title', title, 'status', status)
        into result;
    end if;

    if result is null then
        raise exception 'no table proposal % is awaiting changes', _id;
    end if;

    return result;
end;
$$;

comment on function public.revise_user_table(uuid, boolean, text, text, text, text) is
    'Rewrites one changes_requested or failed table proposal — restating the whole proposal and returning it to pending — or withdraws it. The claude role''s only update path on user_table_proposals; gated by assert_claude_rq_key().';

revoke all on function public.revise_user_table(uuid, boolean, text, text, text, text) from public;
grant execute on function public.revise_user_table(uuid, boolean, text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- apply_user_table_proposal — the owner's approval, executed
-- ---------------------------------------------------------------------------
--
-- SECURITY DEFINER and owned by user_tables_owner, so the approved script
-- runs with exactly that role's privileges: CREATE on public, ownership of
-- the tables it has created, nothing else. Callable only by the signed-in
-- owner, only on their own pending row. A failed script rolls back cleanly
-- and the row records the error for Syla to revise; a successful one marks
-- the row applied and reloads PostgREST so the new table serves at once.

create or replace function public.apply_user_table_proposal(_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    proposal public.user_table_proposals%rowtype;
begin
    select * into proposal
    from public.user_table_proposals
    where id = _id
      and status = 'pending'
      and profile_id = (select public.current_profile_id())
    for update;

    if not found then
        raise exception 'no pending table proposal % belongs to you', _id;
    end if;

    -- Re-lint at the moment of truth, not just at proposal time.
    perform public.assert_user_table_sql(proposal.ddl_sql, true);
    if proposal.seed_sql is not null then
        perform public.assert_user_table_sql(proposal.seed_sql, false);
    end if;

    begin
        execute proposal.ddl_sql;
        if proposal.seed_sql is not null then
            execute proposal.seed_sql;
        end if;
    exception when others then
        update public.user_table_proposals
        set status = 'failed', error = sqlerrm, resolved_at = now()
        where id = _id;
        return jsonb_build_object('id', _id, 'status', 'failed', 'error', sqlerrm);
    end;

    update public.user_table_proposals
    set status = 'applied', error = null, resolved_at = now()
    where id = _id;

    notify pgrst, 'reload schema';

    return jsonb_build_object('id', _id, 'status', 'applied');
end;
$$;

comment on function public.apply_user_table_proposal(uuid) is
    'Executes one pending user-table proposal as the sandboxed user_tables_owner role — the owner''s Apply button. DDL and seed run in one transaction; failure rolls the schema back and records the error on the row; success marks it applied and reloads PostgREST.';

grant execute on function public.current_profile_id() to user_tables_owner;
alter function public.apply_user_table_proposal(uuid) owner to user_tables_owner;

revoke all on function public.apply_user_table_proposal(uuid) from public;
grant execute on function public.apply_user_table_proposal(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Syla's skill: how to build a user table (and the app on top of it)
-- ---------------------------------------------------------------------------

insert into public.docs (path, title, html)
select 'skills/user-tables', 'Creating user tables', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Creating user tables</title>
<style>
  body { margin: 0 auto; max-width: 42rem; padding: 2rem 1.25rem 4rem;
         font: 16px/1.6 system-ui, sans-serif; color: #1a1a1a; background: #fdfdfc; }
  h1 { font-size: 1.6rem; } h2 { font-size: 1.2rem; margin-top: 2rem; }
  code, pre { font-family: ui-monospace, monospace; background: #f0efec; border-radius: 4px; }
  code { padding: 0.1em 0.3em; } pre { padding: 0.75rem; overflow-x: auto; }
  @media (prefers-color-scheme: dark) {
    body { color: #e8e6e3; background: #16181a; }
    code, pre { background: #24272b; }
  }
</style></head>
<body>
<h1>Creating user tables</h1>
<p>When the owner wants data of their own in the database — "put this CSV into a table", "track my workouts", usually followed by "and make me an app for it" — you do not need the fork or a migration merge. Propose the table; the owner approves it from your Inbox card; the database creates it on the spot. The plumbing is <code>notes/07-user-tables.md</code> in the repo.</p>
<h2>First, do you even need a table?</h2>
<p>Prefer a new silo, a doc, or existing tables over a new one — generic text over structured columns, until an aggregation actually needs structure. A table is right when the data is genuinely tabular (a CSV, a log with fixed fields) or an app needs to query and write rows.</p>
<h2>The proposal</h2>
<pre>scripts/propose-user-table --profile &lt;uuid&gt; \
    --title "workouts — from workouts.csv" \
    --summary "A table for the 3,400 workout rows you uploaded, one per session, plus the app to browse them." \
    --ddl-file table.sql --seed-file seed.sql</pre>
<p><code>table.sql</code> follows this exact shape — RLS in the same script, owner policies, a read-only policy for you:</p>
<pre>create table public.workouts (
    id         uuid primary key default gen_random_uuid(),
    done_on    date not null,
    kind       text not null,
    minutes    integer,
    notes      text,
    created_at timestamptz not null default now()
);
alter table public.workouts enable row level security;
create policy "Owner has full access" on public.workouts
    for all to authenticated using (true) with check (true);
create policy "claude reads everything" on public.workouts
    for select to claude using (true);</pre>
<p><code>seed.sql</code> is plain <code>insert into public.workouts (…) values (…);</code> batches — a few hundred rows per statement. Keep the seed under about 2&nbsp;MB; for a bigger dataset propose the table alone and give the vibe app an import screen, so the data enters under the owner's own session.</p>
<h2>Boundaries (enforced, not advisory)</h2>
<ul>
<li><strong>User tables are the owner's.</strong> You read them like everything else; you never get a write path — no grant, no RPC, no trigger. Propose neither. The lint rejects the script and the sandbox role could not honor it anyway.</li>
<li>Tables, indexes, RLS and policies only — no functions, triggers, roles, other schemas, or SECURITY DEFINER anything. Scripts run as a sandboxed role that owns only user tables, so they cannot touch product tables either way.</li>
<li>Type inference from a CSV: default anything ambiguous to <code>text</code> and nullable. A tightening <code>alter table</code> can be a later proposal once an aggregation needs it.</li>
<li>Changing or dropping a user table later is simply another proposal (<code>alter table …</code> / <code>drop table …</code>) — the sandbox role owns them, the owner approves.</li>
</ul>
<h2>After it applies</h2>
<p>PostgREST reloads on apply, so the table serves immediately. Build the vibe app with <code>scripts/vibe-save</code> as usual — it queries the new table under the owner's auth, which the approved policies already allow. A failed apply puts the row in status <code>failed</code> with the database's error on it: read it, fix the script, and resubmit with <code>scripts/revise-user-table</code>. The same script revises a card the owner flagged with feedback.</p>
<p>Done looks like: the proposal card applied, the table queryable through <code>scripts/rq</code>, the data in, and the app on the Apps tab reading and writing it.</p>
<footer>doc <code>skills/user-tables</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'skills/user-tables');

insert into public.doc_silos (doc_id, silo_id)
select d.id, s.id
from public.docs d
join public.silos s on s.name = 'skills'
where d.path = 'skills/user-tables'
  and not exists (select 1 from public.doc_silos j
                  where j.doc_id = d.id and j.silo_id = s.id);
