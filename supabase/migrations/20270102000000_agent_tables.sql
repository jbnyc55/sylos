-- Agent tables: bulk data under the agent's own role — owner-approved,
-- structurally fenced, and private by construction.
--
-- Until now the user-tables invariant was absolute: claude reads the
-- owner's tables and never writes them, so every big import had to squeeze
-- through seed_sql (capped at 5 MB) or the owner's own session. This
-- migration adds the owner-granted exception without weakening the rule
-- anywhere else: a user-table proposal may be flagged AGENT-WRITABLE, and
-- when the owner applies it, a second agent role gains full DML on exactly
-- the tables that proposal created. 200 MB of chat history is then a few
-- dozen plain INSERT batches through one new RPC — no seed cap, no owner
-- session, and still no schema change ever made by the agent itself.
--
-- The boundary is a role, not a rule:
--
--   * `claude_writer` is a NOLOGIN role with no standing grants. The only
--     privileges it ever holds are per-table grants installed by
--     apply_agent_writability(), which refuses any table not owned by
--     user_tables_owner — so product tables are out of reach the way they
--     are for the sandbox role: Postgres holds nothing to honor.
--   * Scripts never mention the role (the lint refuses the word): the
--     grants are uniform machinery, and the owner's visibility is the
--     flag on the proposal card, not a grant line buried in SQL.
--   * The owner can turn it off per table at any time — data_tables grows
--     an agent_writable flag updated like siloed_at, and the flag's
--     trigger installs or removes the grants.
--
-- Siloing is untouched, and sharing SUSPENDS writing. An agent table
-- registers with the warden like any table, starts unsiloed in the Silo
-- Soon backlog, and only the owner ever places it — the agent still has
-- no write path into placements. The write policy installed here checks,
-- on every row, that the table has no silo placements and no named
-- followers: the moment the owner shares the table, the agent's writes
-- stop until it is private again. A bulk load can never leak into
-- follower_rq because of a placement made mid-upload.
--
-- row_edits stays the undo log, with one storage concession: an INSERT by
-- claude_writer into an id-bearing table logs attribution without the row
-- image — undoing an insert needs its id, not a copy of it, and a 200 MB
-- load must not cost 400. Updates and deletes keep full before-images,
-- and every other role logs exactly as before.

-- ---------------------------------------------------------------------------
-- The role
-- ---------------------------------------------------------------------------

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'claude_writer') then
        create role claude_writer nologin;
    end if;
end
$$;

grant usage on schema public to claude_writer;

-- PostgREST connects as `authenticator`; membership is what makes
-- `set local role claude_writer` legal inside the RPC below — it grants
-- nothing by itself (20260820000000's pattern).
do $$
begin
    if exists (select from pg_roles where rolname = 'authenticator') then
        grant claude_writer to authenticator;
    end if;
end
$$;

-- ---------------------------------------------------------------------------
-- The log: claude_writer appends like every writing role — but an id-bearing
-- INSERT skips the row image
-- ---------------------------------------------------------------------------

grant execute on function public.log_row_edit() to claude_writer;
grant insert on public.row_edits to claude_writer;

-- The images-match-the-op constraint learns the imageless insert: an
-- INSERT may omit new_row only when row_id identifies the row instead.
-- UPDATE and DELETE shapes are unchanged.
alter table public.row_edits drop constraint row_edits_check1;
alter table public.row_edits add constraint row_edits_check1
    check (case op
               when 'DELETE' then new_row is null
               when 'UPDATE' then new_row is not null
               else new_row is not null or row_id is not null
           end);

drop policy "only triggers append the log" on public.row_edits;
create policy "only triggers append the log" on public.row_edits
    for insert to claude, authenticated, service_role, user_tables_owner, claude_writer
    with check (pg_trigger_depth() > 0);

create or replace function public.log_row_edit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    _old    jsonb := case when tg_op = 'INSERT' then null else to_jsonb(old) end;
    _new    jsonb := case when tg_op = 'DELETE' then null else to_jsonb(new) end;
    _row_id text;
begin
    _row_id := coalesce(_new ->> 'id', _old ->> 'id');

    -- The bulk-ingest concession: a claude_writer INSERT into a table with
    -- an id column keeps the log row (attribution; undo = delete by id)
    -- but not the image, so a 200 MB load does not write 400. Tables
    -- without an id keep the image — it is the only thing identifying the
    -- row — and updates/deletes keep full images for every role.
    if tg_op = 'INSERT' and current_user = 'claude_writer' and _row_id is not null then
        _new := null;
    end if;

    insert into public.row_edits (table_name, row_id, op, edited_by, actor_id, old_row, new_row)
    values (
        tg_table_name,
        _row_id,
        tg_op,
        current_user,
        public.current_actor_id(),
        _old,
        _new
    );

    return null;
end;
$$;

comment on function public.log_row_edit() is
    'AFTER row trigger: appends the full before/after row images to row_edits as the role doing the DML, so edited_by and actor_id cannot be masked. Works on any table; row_id is taken from the image''s id field when one exists. One concession: claude_writer INSERTs into id-bearing tables log without the new-row image — bulk ingest attribution without doubling storage; its updates and deletes keep full images.';

-- ---------------------------------------------------------------------------
-- The registry learns the flag
-- ---------------------------------------------------------------------------

alter table public.data_tables
    add column agent_writable boolean not null default false;

comment on column public.data_tables.agent_writable is
    'The owner''s standing grant: claude_writer holds full DML on this table (installed/removed by the flag''s trigger). Only tables owned by user_tables_owner can carry it — apply_agent_writability() refuses the rest. Writes are additionally suspended, whatever this flag says, while the table sits in any silo or names any follower.';

-- The owner flips it like siloed_at; the trigger below does the grants.
grant update (agent_writable) on public.data_tables to authenticated;

-- The apply function (running as user_tables_owner) flags the tables an
-- agent-writable proposal created. Select it needs too — same shape as its
-- user_table_proposals access.
grant select on public.data_tables to user_tables_owner;
grant update (agent_writable) on public.data_tables to user_tables_owner;

create policy "the apply function reads the registry"
    on public.data_tables for select to user_tables_owner
    using (true);

create policy "the apply function flags agent tables"
    on public.data_tables for update to user_tables_owner
    using (true) with check (true);

-- ---------------------------------------------------------------------------
-- Private means private: the write-suspending check
-- ---------------------------------------------------------------------------
--
-- The accidental-publication guard. Evaluated by the per-table policy on
-- every claude_writer row operation: true only while the table has no silo
-- placements and no named followers. SECURITY DEFINER because claude_writer
-- deliberately holds no grants on the junctions.

create function public.agent_table_is_private(_table_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select not exists (select 1 from public.table_silos j where j.table_id = _table_id)
       and not exists (select 1 from public.table_followers f where f.table_id = _table_id);
$$;

comment on function public.agent_table_is_private(uuid) is
    'Whether the registered table is shared with nobody: no table_silos placements, no table_followers rows. The body of every "Syla writes this table while it is private" policy — sharing a table suspends the agent''s writes on it until it is private again. The siloed_at mark and the unsiloed backlog both count as private.';

revoke all on function public.agent_table_is_private(uuid) from public;
grant execute on function public.agent_table_is_private(uuid) to claude_writer;

-- ---------------------------------------------------------------------------
-- Installing and removing the grants
-- ---------------------------------------------------------------------------
--
-- SECURITY DEFINER as the migration owner (postgres) — the warden's
-- arrangement exactly (20261101000000): the one role that can grant on a
-- sandbox-owned table whoever asked for the change.

create function public.apply_agent_writability(_table_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    d    record;
    _tbl text;
    _pol text := 'Syla writes this table while it is private';
    _has boolean;
    _seq record;
begin
    select id, table_name, owner_role, agent_writable into d
    from public.data_tables where id = _table_id;
    if d.id is null then
        return;
    end if;
    if to_regclass(format('public.%I', d.table_name)) is null then
        return;
    end if;
    _tbl := format('public.%I', d.table_name);

    -- The structural fence: only tables the sandbox role owns. A product
    -- table (owned by postgres) refuses the flag outright, which also
    -- aborts the owner's UPDATE that tried to set it.
    if d.agent_writable and d.owner_role <> 'user_tables_owner' then
        raise exception 'only user tables can be agent-writable — % is not owned by user_tables_owner', d.table_name;
    end if;

    select exists (
        select 1 from pg_catalog.pg_policy p
        where p.polrelid = _tbl::regclass and p.polname = _pol
    ) into _has;

    if d.agent_writable then
        execute format('grant select, insert, update, delete on %s to claude_writer', _tbl);
        -- Identity/serial columns need their sequences. (A sequence added
        -- by a later proposal is picked up by re-flagging the table.)
        for _seq in
            select s.oid::regclass::text as seqname
            from pg_catalog.pg_class s
            join pg_catalog.pg_depend dep on dep.objid = s.oid
                 and dep.classid = 'pg_class'::regclass
                 and dep.refclassid = 'pg_class'::regclass
            where s.relkind = 'S' and dep.refobjid = _tbl::regclass
        loop
            execute format('grant usage, select on sequence %s to claude_writer', _seq.seqname);
        end loop;
        if not _has then
            execute format(
                'create policy %I on %s for all to claude_writer using ((select public.agent_table_is_private(%L::uuid)))
                 with check ((select public.agent_table_is_private(%L::uuid)))',
                _pol, _tbl, d.id, d.id);
        end if;
    else
        if _has then
            execute format('drop policy %I on %s', _pol, _tbl);
        end if;
        execute format('revoke select, insert, update, delete on %s from claude_writer', _tbl);
        for _seq in
            select s.oid::regclass::text as seqname
            from pg_catalog.pg_class s
            join pg_catalog.pg_depend dep on dep.objid = s.oid
                 and dep.classid = 'pg_class'::regclass
                 and dep.refclassid = 'pg_class'::regclass
            where s.relkind = 'S' and dep.refobjid = _tbl::regclass
        loop
            execute format('revoke usage, select on sequence %s from claude_writer', _seq.seqname);
        end loop;
    end if;
end;
$$;

comment on function public.apply_agent_writability(uuid) is
    'Makes one table match its agent_writable flag: full claude_writer DML plus the while-it-is-private policy on, both off otherwise. Refuses any table not owned by user_tables_owner. Idempotent; called by the registry trigger below.';

revoke all on function public.apply_agent_writability(uuid) from public;

create function public.data_tables_agent_writable_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.apply_agent_writability(new.id);
    return null;
end;
$$;

create trigger data_tables_agent_writable_changed
    after update of agent_writable on public.data_tables
    for each row
    when (old.agent_writable is distinct from new.agent_writable)
    execute function public.data_tables_agent_writable_changed();

-- ---------------------------------------------------------------------------
-- The proposal carries the ask, visibly
-- ---------------------------------------------------------------------------

alter table public.user_table_proposals
    add column agent_writable boolean not null default false;

comment on column public.user_table_proposals.agent_writable is
    'The proposal asks for agent write access: applying it flags every table the script created as agent_writable in data_tables (the grants follow from the flag''s trigger). Shown on the card — the owner approves the access together with the schema.';

grant insert (agent_writable) on public.user_table_proposals to claude;
grant update (agent_writable) on public.user_table_proposals to claude;

-- ---------------------------------------------------------------------------
-- The lint: scripts never name the writer role
-- ---------------------------------------------------------------------------
--
-- Same body as 20261017000000 plus one clause. Write access is the flag,
-- installed uniformly at apply time — a grant line in a script would be a
-- second, non-uniform path the card does not surface.

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
    if _sql ~* '\mclaude_writer\M' then
        raise exception 'scripts never name claude_writer — agent write access is the proposal''s agent_writable flag, installed at apply time';
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
    'Tripwires over a proposed user-table script: no definers, role games, functions/triggers, claude or claude_writer grants, foreign schemas, or unprotected tables. A lint, not the boundary — approved scripts run as the sandboxed user_tables_owner role either way.';

-- ---------------------------------------------------------------------------
-- propose_user_table / revise_user_table learn the flag
-- ---------------------------------------------------------------------------
--
-- New parameter, so new signatures: the old functions are dropped (two
-- same-named RPCs would make the PostgREST call ambiguous) and the
-- grants restated.

drop function public.propose_user_table(uuid, text, text, text, text);

create function public.propose_user_table(
    _profile_id     uuid,
    _title          text,
    _summary        text,
    _ddl_sql        text,
    _seed_sql       text default null,
    _agent_writable boolean default false
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
      and agent_writable = coalesce(_agent_writable, false)
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
        (profile_id, title, summary, ddl_sql, seed_sql, agent_writable)
    values
        (_profile_id, _title, _summary, _ddl_sql, _seed_sql,
         coalesce(_agent_writable, false))
    returning jsonb_build_object('id', id, 'title', title, 'status', status,
                                 'agent_writable', agent_writable)
    into result;

    return result;
end;
$$;

comment on function public.propose_user_table(uuid, text, text, text, text, boolean) is
    'Files one pending user-table proposal as the claude role — Syla''s only path toward new tables. _agent_writable asks for write access on the tables the script creates, granted only by the owner''s apply. Gated by assert_claude_rq_key(); linted by assert_user_table_sql(); idempotent against identical pending DDL; the backlog is capped at 10.';

revoke all on function public.propose_user_table(uuid, text, text, text, text, boolean) from public;
grant execute on function public.propose_user_table(uuid, text, text, text, text, boolean) to anon;

drop function public.revise_user_table(uuid, boolean, text, text, text, text);

create function public.revise_user_table(
    _id             uuid,
    _withdraw       boolean default false,
    _title          text default null,
    _summary        text default null,
    _ddl_sql        text default null,
    _seed_sql       text default null,
    _agent_writable boolean default false
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
        set title          = _title,
            summary        = _summary,
            ddl_sql        = _ddl_sql,
            seed_sql       = _seed_sql,
            agent_writable = coalesce(_agent_writable, false),
            status         = 'pending',
            resolved_at    = null
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

comment on function public.revise_user_table(uuid, boolean, text, text, text, text, boolean) is
    'Rewrites one changes_requested or failed table proposal — restating the whole proposal, agent_writable included, and returning it to pending — or withdraws it. The claude role''s only update path on user_table_proposals; gated by assert_claude_rq_key().';

revoke all on function public.revise_user_table(uuid, boolean, text, text, text, text, boolean) from public;
grant execute on function public.revise_user_table(uuid, boolean, text, text, text, text, boolean) to anon;

-- ---------------------------------------------------------------------------
-- Apply: an agent-writable proposal flags exactly the tables it created
-- ---------------------------------------------------------------------------
--
-- Same function, same owner (user_tables_owner — CREATE OR REPLACE keeps
-- it), one addition: snapshot the sandbox role's tables before the script,
-- and afterwards set agent_writable on the new ones. The UPDATE fires the
-- registry trigger, which installs the grants as the warden's owner.
-- Everything stays inside the one begin/exception block, so a failure
-- rolls the flags back with the schema.

create or replace function public.apply_user_table_proposal(_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    proposal public.user_table_proposals%rowtype;
    _before  oid[];
    _flagged integer := 0;
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

    select coalesce(array_agg(c.oid), '{}') into _before
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and c.relowner = 'user_tables_owner'::regrole;

    begin
        execute proposal.ddl_sql;
        if proposal.seed_sql is not null then
            execute proposal.seed_sql;
        end if;

        if proposal.agent_writable then
            -- The warden's event trigger has already registered the new
            -- tables; flag them, which installs the grants.
            update public.data_tables d
            set agent_writable = true
            from pg_catalog.pg_class c
            join pg_catalog.pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind = 'r'
              and c.relowner = 'user_tables_owner'::regrole
              and c.oid <> all (_before)
              and d.table_oid = c.oid;
            get diagnostics _flagged = row_count;
            if _flagged = 0 then
                raise exception 'an agent-writable proposal must create at least one table — to open an existing table, the owner flips it in the app';
            end if;
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

    return jsonb_build_object('id', _id, 'status', 'applied',
                              'agent_tables', _flagged);
end;
$$;

comment on function public.apply_user_table_proposal(uuid) is
    'Executes one pending user-table proposal as the sandboxed user_tables_owner role — the owner''s Apply button. DDL and seed run in one transaction; an agent-writable proposal additionally flags the tables it created in data_tables (which installs claude_writer''s grants); failure rolls everything back and records the error on the row; success marks it applied and reloads PostgREST.';

-- ---------------------------------------------------------------------------
-- run_agent_write_sql — the bulk write path over HTTPS
-- ---------------------------------------------------------------------------
--
-- The write twin of run_readonly_sql, bounded by the claude_writer role:
-- whatever the batch says, Postgres holds grants only on agent-writable
-- user tables, and the per-table policy suspends even those while the
-- table is shared. The lint below closes the one hole grants cannot — a
-- batch trying to switch out of the role mid-script.

create function public.assert_agent_write_sql(_sql text)
returns void
language plpgsql
immutable
as $$
begin
    if _sql is null or btrim(_sql) = '' then
        raise exception 'the script is empty';
    end if;
    if char_length(_sql) > 10000000 then
        raise exception 'send at most 10 MB per call — split a bigger load into batches';
    end if;
    if _sql ~* '\m(set|reset)\s+(local\s+|session\s+)?role\M'
       or _sql ~* 'session_authorization' or _sql ~* 'session\s+authorization' then
        raise exception 'write batches may not switch roles';
    end if;
    if _sql ~* '\m(commit|rollback|begin)\s*;' then
        raise exception 'write batches may not contain transaction control — each call is one transaction';
    end if;
end;
$$;

comment on function public.assert_agent_write_sql(text) is
    'Tripwires over an agent write batch: bounded size, no role switching, no transaction control. A lint, not the boundary — the batch runs as claude_writer, whose only grants are the agent-writable tables, either way.';

create function public.run_agent_write_sql(_sql text)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _n bigint;
begin
    perform public.assert_claude_rq_key();
    perform public.assert_agent_write_sql(_sql);

    set local statement_timeout = '120s';
    set local role claude_writer;

    execute _sql;
    get diagnostics _n = row_count;

    return jsonb_build_object('rows', _n);
end;
$$;

comment on function public.run_agent_write_sql(text) is
    'Runs one batch of plain SQL (INSERT/UPDATE/DELETE statements, up to 10 MB) as the claude_writer role — full DML on agent-writable user tables, nothing anywhere else, and suspended per table while it is shared. Returns the last statement''s row count. Gated by assert_claude_rq_key().';

revoke all on function public.run_agent_write_sql(text) from public;
grant execute on function public.run_agent_write_sql(text) to anon;

-- ---------------------------------------------------------------------------
-- The skill learns agent tables
-- ---------------------------------------------------------------------------
--
-- House pattern: targeted, guarded text swaps on the seeded doc
-- (20261217's style), so an owner's own edits elsewhere survive.

update public.docs
set html = replace(html,
    '<li><strong>User tables are the owner''s.</strong> You read them like everything else; you never get a write path — no grant, no RPC, no trigger. Propose neither. The lint rejects the script and the sandbox role could not honor it anyway.</li>',
    '<li><strong>User tables start as the owner''s.</strong> You read them like everything else and, by default, write none of them — no grant, no RPC, no trigger. The one exception is a table the owner approved as agent-writable (the "Agent tables" section below). Scripts still never grant your roles anything: the lint rejects it, and the sandbox role could not honor it anyway.</li>')
where path = 'skills/user-tables';

update public.docs
set html = replace(html,
    'Keep the seed under about 2&nbsp;MB; for a bigger dataset propose the table alone and give the vibe app an import screen, so the data enters under the owner''s own session.',
    'Keep the seed under about 2&nbsp;MB. For a genuinely big dataset (tens or hundreds of MB), propose the table with <code>--agent-writable</code> and load the data yourself after the apply — the "Agent tables" section below. The vibe-app import screen remains the right path when the data should enter under the owner''s own session.')
where path = 'skills/user-tables';

update public.docs
set html = replace(html,
    '<footer>doc <code>skills/user-tables</code></footer>',
    '<h2>Agent tables — bulk data under your own role</h2>'
    || '<p>By default you never write a user table. The exception the owner can grant: propose the table with <code>--agent-writable</code> on <code>scripts/propose-user-table</code>, and say in the summary that you are asking for write access and why ("so I can load the 200&nbsp;MB of exported DMs you uploaded"). The card shows the ask; applying it gives your writer role full DML — insert, update, delete — on exactly the tables that proposal created, and on nothing else, ever. The role holds no other grants, so product tables are out of reach by construction.</p>'
    || '<p>Write through <code>scripts/agent-write</code> (the <code>run_agent_write_sql</code> RPC): batches of plain <code>insert into public.&lt;table&gt; … values …;</code> statements, a few MB per call (10&nbsp;MB hard cap, 120&nbsp;s timeout) — a 200&nbsp;MB load is a few dozen calls. Your inserts log attribution to <code>row_edits</code> without the row image; your updates and deletes keep full before-images like every other write.</p>'
    || '<p>Two things never change. <strong>Siloing:</strong> the table registers the moment it exists, starts unsiloed in the Silo Soon backlog, and only the owner ever places it — you still have no write path into placements, so remind the owner the table is theirs to silo or keep private. <strong>Sharing suspends writing:</strong> the moment the table sits in any silo or names any follower, your writes to it stop (the while-it-is-private policy). An RLS refusal on an agent table means it is shared now — tell the owner what you were loading and let them decide; never work around it. The owner can also turn writability off per table at any time.</p>'
    || '<footer>doc <code>skills/user-tables</code></footer>')
where path = 'skills/user-tables'
  and html not like '%Agent tables — bulk data under your own role%';
