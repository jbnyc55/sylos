-- Every table is siloed or unsiloed. Nothing is invisible.
--
-- Silos are one vocabulary doing two jobs: organizing content and scoping
-- what members see. Six record types take part — notes, docs, todos, goal
-- cells, events and vibe code apps each have a per-row silo junction and a
-- by-hand siloed mark, so every one of their rows is either placed, marked
-- siloed, or sitting in the To-silo backlog. The other sixty-odd tables in
-- public had no such state at all: weight lifts, health samples, contacts,
-- locations, and above all the tables the owner creates through the
-- user-tables path lived outside the vocabulary entirely — not siloed, not
-- unsiloed, just invisible to the silo system, unreachable by any member,
-- and absent from the backlog. Nothing made a new table join the
-- vocabulary; forgetting was the default.
--
-- This migration makes the invariant a property of the database:
--
--   * A REGISTRY (data_tables) holds exactly one row per table in public.
--     The row says how the table is siloed —
--       'table'  the table is placed as a whole (table_silos / table_members
--                / siloed_at), the unit for data tables and every user table;
--       'rows'   each row is placed individually — the six record types
--                above, which keep their own junctions and marks;
--       'system' machinery, never shareable: the silo vocabulary itself,
--                members and their keys, tokens, logs, queues, junctions,
--                and child tables whose visibility rides their parent record.
--     Every table starts as 'table' — unsiloed, in the backlog, invisible to
--     members until the owner places or marks it. 'rows' and 'system' are
--     explicit declarations a migration makes with declare_table_siloing();
--     a user-table script cannot make them, so a user table is always a
--     placeable table.
--
--   * A WARDEN — reconcile_table_siloing(), SECURITY DEFINER as the
--     migration owner (postgres), the one role above both product tables
--     and user_tables_owner — runs from an event trigger after every CREATE
--     TABLE, ALTER TABLE and DROP TABLE in public. It registers new tables,
--     follows renames, forgets drops, enables row level security on every
--     table, and on every 'table' row grants the member role SELECT and
--     installs one generic policy: members read the table when it sits in a
--     silo where their membership allows SQL, or when it names them. The
--     same sentence as docs, applied to the table as the unit. Whoever
--     creates the table — a migration, or a user-table proposal applied as
--     the sandbox role — the result is the same, because the warden acts
--     with its own privileges, not the creator's.
--
-- The backfill below classifies every existing table. The To-silo backlog
-- for tables is one query: data_tables where siloing = 'table', no
-- placement, no siloed_at. The app lists those under Silo Soon next to the
-- notes and docs; a table the owner never wants to share is marked siloed
-- like any other record.

-- ---------------------------------------------------------------------------
-- First, the user-tables path has to be able to finish
-- ---------------------------------------------------------------------------
--
-- Found while testing this migration against the full chain: an approved
-- user-table proposal could not actually be applied. apply_user_table_proposal
-- runs its script as user_tables_owner, and two things that role never
-- received made every run fail before this file existed:
--
--   * the row_edits event trigger (20260831010000) attaches log_row_edit to
--     the new table as the creating role, and execute on that function is
--     not public — so CREATE TABLE itself raised "permission denied for
--     function log_row_edit";
--   * the function then records the outcome on user_table_proposals, and the
--     seed INSERTs write the new table — both fire the log trigger, which
--     appends to row_edits as user_tables_owner, which had no insert there.
--
-- Both grants are the same shape every other writing role has: insert on
-- the log only from trigger context (the pg_trigger_depth() policy), never
-- update or delete.

grant execute on function public.log_row_edit() to user_tables_owner;
grant insert on public.row_edits to user_tables_owner;

drop policy "only triggers append the log" on public.row_edits;
create policy "only triggers append the log" on public.row_edits
    for insert to claude, authenticated, service_role, user_tables_owner
    with check (pg_trigger_depth() > 0);

-- ---------------------------------------------------------------------------
-- The registry and the two junctions
-- ---------------------------------------------------------------------------

create table public.data_tables (
    id          uuid primary key default gen_random_uuid(),
    -- The table's name in public. Follows renames (the warden matches on
    -- table_oid), so junction rows survive an ALTER TABLE ... RENAME.
    table_name  text not null unique
                check (table_name ~ '^[a-z_][a-z0-9_]*$' and char_length(table_name) <= 63),
    -- pg_class.oid at registration; how the warden recognizes a renamed
    -- table. Re-adopted by name after a dump/restore changes every oid.
    table_oid   oid not null unique,
    -- Who owns the table: postgres for product tables, user_tables_owner
    -- for the owner's own tables (the user-tables path).
    owner_role  text not null,
    siloing     text not null default 'table'
                check (siloing in ('table', 'rows', 'system')),
    -- Marked siloed by hand: out of the To-silo backlog even without
    -- placements. Meaningful only while siloing = 'table'.
    siloed_at   timestamptz,
    -- True while the warden holds a table-level SELECT grant for member on
    -- this table — the only grant it will ever revoke.
    member_grant boolean not null default false,
    created_at  timestamptz not null default now()
);

comment on table public.data_tables is
    'One row per table in public, kept by the siloing warden (an event trigger): how the table is siloed — as a whole (table), per row (rows), or never (system) — and, for whole tables, the by-hand siloed mark. A table missing from here is a bug the warden fixes on the next DDL.';
comment on column public.data_tables.siloing is
    'table: placed as a whole through table_silos / table_members (the default, and the only option for user tables). rows: each row placed through its own junction (notes, docs, todos, goal cells, events, vibe code apps). system: machinery — silo vocabulary, members and keys, tokens, logs, queues, junctions, child tables — never shareable. Declared by migrations with declare_table_siloing().';
comment on column public.data_tables.siloed_at is
    'Marked siloed by hand: out of the To-silo backlog even without table_silos placements. Null = still unsiloed unless table_silos says otherwise.';
comment on column public.data_tables.member_grant is
    'Whether the warden granted member SELECT on the whole table (siloing = table). It revokes only what it granted; column grants a migration made are never touched.';

create table public.table_silos (
    table_id    uuid not null references public.data_tables (id) on delete cascade,
    silo_id     uuid not null references public.silos (id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (table_id, silo_id)
);

create table public.table_members (
    table_id    uuid not null references public.data_tables (id) on delete cascade,
    member_id   uuid not null references public.members (id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (table_id, member_id)
);

comment on table public.table_silos is
    'Which silos a whole table sits in. Placing a table in a silo IS the grant: every row of it becomes readable through member_rq to that silo''s members whose membership allows SQL. Only tables registered with siloing = table can be placed.';
comment on table public.table_members is
    'The individual exception: the named member reads every row of the table whatever the silo placements say.';

create index table_silos_silo_id_idx on public.table_silos (silo_id);
create index table_members_member_id_idx on public.table_members (member_id);

alter table public.data_tables   enable row level security;
alter table public.table_silos   enable row level security;
alter table public.table_members enable row level security;

-- The owner reads the registry and marks tables siloed; the classification
-- itself (siloing) is a migration's declaration, not a switch in the app.
grant select on public.data_tables to authenticated;
grant update (siloed_at) on public.data_tables to authenticated;

create policy "The table registry is viewable by the owner"
    on public.data_tables for select
    to authenticated
    using (public.is_owner());

create policy "Tables are marked siloed by the owner"
    on public.data_tables for update
    to authenticated
    using (public.is_owner())
    with check (public.is_owner());

-- Placements follow the owner, like every junction.
grant select, insert, delete on public.table_silos to authenticated;
grant select, insert, delete on public.table_members to authenticated;

create policy "Table silos follow the owner"
    on public.table_silos for all
    to authenticated
    using (public.is_owner()) with check (public.is_owner());

create policy "Table members follow the owner"
    on public.table_members for all
    to authenticated
    using (public.is_owner()) with check (public.is_owner());

-- claude reads all three, like every application table; placing a whole
-- table is the owner's act alone — no write path for the agent.
grant select on public.data_tables   to claude;
grant select on public.table_silos   to claude;
grant select on public.table_members to claude;

create policy "claude reads the table registry" on public.data_tables   for select to claude using (true);
create policy "claude reads table silos"        on public.table_silos   for select to claude using (true);
create policy "claude reads table members"      on public.table_members for select to claude using (true);

-- Only a whole table can be placed. The registry row decides, and a row
-- leaving 'table' loses its placements (the trigger further down).
create function public.assert_table_placeable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if not exists (
        select 1 from public.data_tables d
        where d.id = new.table_id and d.siloing = 'table'
    ) then
        raise exception 'only a table registered with siloing = table can be placed in a silo or shared with a member';
    end if;
    return new;
end;
$$;

comment on function public.assert_table_placeable() is
    'BEFORE INSERT on table_silos / table_members: a placement needs a data_tables row with siloing = table. Per-row types and system tables are never placed as a whole.';

create trigger table_silos_placeable
    before insert on public.table_silos
    for each row execute function public.assert_table_placeable();

create trigger table_members_placeable
    before insert on public.table_members
    for each row execute function public.assert_table_placeable();

-- ---------------------------------------------------------------------------
-- The member read rule for a whole table
-- ---------------------------------------------------------------------------
--
-- The docs sentence with the table as the unit: in one of my sql-allowing
-- silos, or naming me. Security invoker — it reads the junctions under the
-- member's own policies below, so a missing policy fails closed.

create function public.member_reads_table(_table_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
    select exists (
        select 1
        from public.table_silos j
        join public.silo_members sm on sm.silo_id = j.silo_id
        where j.table_id = _table_id
          and sm.member_id = public.current_member_id()
          and sm.allows_sql
    )
    or exists (
        select 1 from public.table_members tm
        where tm.table_id = _table_id
          and tm.member_id = public.current_member_id()
    );
$$;

comment on function public.member_reads_table(uuid) is
    'Whether the current member (app.member_id) reads the whole table registered under this id: it sits in a silo where their membership allows SQL, or it names them. The body of every "Members read this table" policy the warden installs.';

-- Whoami for members: their table grants are explainable, like their
-- doc and note grants.
grant select on public.table_silos   to member;
grant select on public.table_members to member;
grant select (id, table_name, siloing) on public.data_tables to member;

create policy "A member reads table silo links in their silos"
    on public.table_silos for select
    to member
    using (exists (
        select 1 from public.silo_members sm
        where sm.silo_id = table_silos.silo_id
          and sm.member_id = public.current_member_id()
    ));

create policy "A member reads table links naming them"
    on public.table_members for select
    to member
    using (member_id = public.current_member_id());

create policy "A member reads the registry rows of tables they can read"
    on public.data_tables for select
    to member
    using (public.member_reads_table(id));

-- ---------------------------------------------------------------------------
-- The warden
-- ---------------------------------------------------------------------------
--
-- Two SECURITY DEFINER functions owned by the migration runner (postgres):
-- the one role that owns every product table and, through its membership
-- in user_tables_owner, holds owner rights on every user table. That is
-- what lets the same rule land on a table whoever created it — the
-- sandbox role could not grant or create policies on anyone's behalf, and
-- a migration author could forget. Neither is a path for anyone else:
-- execute is revoked from public, and the only callers are the event
-- trigger and the registry's own trigger.

-- Grants and the policy one table needs for its current siloing.
create function public.apply_table_siloing(_table_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    d      record;
    _tbl   text;
    _pol   text := 'Members read this table in their silos or naming them';
    _has   boolean;
    _cols  text;
begin
    select id, table_name, siloing, member_grant into d
    from public.data_tables where id = _table_id;
    if d.id is null then
        return;
    end if;

    -- The table itself may already be gone (a DROP mid-transaction); the
    -- reconcile pass removes the row.
    if to_regclass(format('public.%I', d.table_name)) is null then
        return;
    end if;
    _tbl := format('public.%I', d.table_name);

    -- RLS is the entire authorization layer: every table has it on.
    if not (select c.relrowsecurity from pg_catalog.pg_class c where c.oid = _tbl::regclass) then
        execute format('alter table %s enable row level security', _tbl);
    end if;

    select exists (
        select 1 from pg_catalog.pg_policy p
        where p.polrelid = _tbl::regclass and p.polname = _pol
    ) into _has;

    if d.siloing = 'table' then
        if not d.member_grant and not pg_catalog.has_table_privilege('member', _tbl, 'select') then
            execute format('grant select on %s to member', _tbl);
            update public.data_tables set member_grant = true where id = d.id;
        end if;
        if not _has then
            execute format(
                'create policy %I on %s for select to member using ((select public.member_reads_table(%L::uuid)))',
                _pol, _tbl, d.id);
        end if;
    else
        if _has then
            execute format('drop policy %I on %s', _pol, _tbl);
        end if;
        if d.member_grant then
            -- Only ever the grant the warden made itself. A table-level
            -- REVOKE also drops explicit column grants (pg_attribute.attacl,
            -- the member role's usual surface), so those are re-granted.
            select string_agg(pg_catalog.quote_ident(a.attname), ', ')
            into _cols
            from pg_catalog.pg_attribute a
            where a.attrelid = _tbl::regclass
              and a.attnum > 0 and not a.attisdropped
              and a.attacl is not null
              and exists (
                  select 1 from pg_catalog.aclexplode(a.attacl) e
                  where e.grantee = 'member'::regrole and e.privilege_type = 'SELECT');
            execute format('revoke select on %s from member', _tbl);
            if _cols is not null then
                execute format('grant select (%s) on %s to member', _cols, _tbl);
            end if;
            update public.data_tables set member_grant = false where id = d.id;
        end if;
    end if;
end;
$$;

comment on function public.apply_table_siloing(uuid) is
    'Makes one table match its registry row: RLS on; for siloing = table, member SELECT plus the generic "Members read this table" policy; otherwise neither (revoking only the grant the warden itself made). Idempotent; called by the warden and by the registry''s siloing trigger.';

revoke all on function public.apply_table_siloing(uuid) from public;

-- The full pass: registry = pg_class, then every row applied. (_apply false
-- registers without touching grants — the backfill below classifies first,
-- so no table is granted as 'table' only to be revoked a statement later.)
create function public.reconcile_table_siloing(_apply boolean default true)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    r record;
begin
    -- The DDL below re-enters the event trigger; one pass at a time.
    if current_setting('sylos.reconciling', true) = 'on' then
        return;
    end if;
    perform set_config('sylos.reconciling', 'on', true);

    -- 1. Renames: a row whose oid still names a live table follows the name.
    for r in
        select d.id, d.table_name as old_name, c.relname as new_name
        from public.data_tables d
        join pg_catalog.pg_class c on c.oid = d.table_oid
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r' and c.relname <> d.table_name
    loop
        delete from public.data_tables where table_name = r.new_name and id <> r.id;
        update public.data_tables set table_name = r.new_name where id = r.id;
    end loop;

    -- 2. After a restore every oid is new: a row whose oid matches nothing
    --    but whose name still names a table adopts the table's new oid.
    update public.data_tables d
    set table_oid = c.oid
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and c.relname = d.table_name
      and c.oid <> d.table_oid
      and not exists (select 1 from pg_catalog.pg_class x where x.oid = d.table_oid)
      and not exists (select 1 from public.data_tables o where o.table_oid = c.oid);

    -- 3. Dropped tables leave the registry (placements cascade).
    delete from public.data_tables d
    where not exists (
        select 1
        from pg_catalog.pg_class c
        join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r' and c.oid = d.table_oid
    );

    -- 4. New tables arrive as 'table': unsiloed, in the backlog.
    insert into public.data_tables (table_name, table_oid, owner_role)
    select c.relname, c.oid, pg_catalog.pg_get_userbyid(c.relowner)
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r'
      and not exists (select 1 from public.data_tables d where d.table_oid = c.oid);

    -- 5. Every table matches its row.
    if _apply then
        for r in select id from public.data_tables loop
            perform public.apply_table_siloing(r.id);
        end loop;
    end if;

    perform set_config('sylos.reconciling', 'off', true);
end;
$$;

comment on function public.reconcile_table_siloing(boolean) is
    'The siloing warden: makes data_tables mirror the tables in public (register new, follow renames, forget drops) and applies each row. Runs from the event trigger after CREATE/ALTER/DROP TABLE; safe to call by hand after any restore.';

revoke all on function public.reconcile_table_siloing(boolean) from public;

create function public.tables_stay_siloed()
returns event_trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.reconcile_table_siloing();
end;
$$;

comment on function public.tables_stay_siloed() is
    'Event trigger body: after any CREATE, ALTER or DROP TABLE, the warden reconciles the registry — so a table in public is never outside the silo vocabulary, whoever created it.';

create event trigger tables_stay_siloed
    on ddl_command_end
    when tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO', 'ALTER TABLE', 'DROP TABLE')
    execute function public.tables_stay_siloed();

-- A declaration is a migration's statement about a table: flipping the
-- classification re-applies grants and drops any placements that no longer
-- make sense.
create function public.data_tables_siloing_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.siloing <> 'table' then
        delete from public.table_silos   where table_id = new.id;
        delete from public.table_members where table_id = new.id;
        update public.data_tables set siloed_at = null where id = new.id and siloed_at is not null;
    end if;
    perform public.apply_table_siloing(new.id);
    return null;
end;
$$;

create trigger data_tables_siloing_changed
    after update of siloing on public.data_tables
    for each row
    when (old.siloing is distinct from new.siloing)
    execute function public.data_tables_siloing_changed();

create function public.declare_table_siloing(_table text, _siloing text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    if _siloing not in ('table', 'rows', 'system') then
        raise exception 'siloing must be table, rows or system (got %)', _siloing;
    end if;
    -- The event trigger already registered it; an older database that never
    -- ran the trigger for this table is healed here.
    if not exists (select 1 from public.data_tables where table_name = _table) then
        perform public.reconcile_table_siloing();
    end if;
    update public.data_tables set siloing = _siloing where table_name = _table;
    if not found then
        raise exception 'no table named public.% to declare', _table;
    end if;
end;
$$;

comment on function public.declare_table_siloing(text, text) is
    'A migration''s declaration of how a table is siloed: rows (its own per-row junction) or system (machinery, never shareable). Every table is table (placeable as a whole) until declared otherwise; user-table scripts cannot call this.';

revoke all on function public.declare_table_siloing(text, text) from public;

-- ---------------------------------------------------------------------------
-- Backfill: every existing table classified
-- ---------------------------------------------------------------------------
--
-- Register first, declare second, apply last — so the per-row and system
-- tables are never granted as whole tables in between.

select public.reconcile_table_siloing(false);

-- The six per-row record types keep their own junctions and marks.
select public.declare_table_siloing(t, 'rows')
from unnest(array[
    'manual_notes', 'docs', 'todo', 'goal_method_cells', 'events', 'vibe_code_apps'
]) as t;

-- Machinery: the silo vocabulary and every junction, members and their
-- keys, tokens and secrets, logs, queues, and the child tables whose
-- visibility rides their parent record (todo_done rides the todo,
-- uploads ride the note, vibe_code_app_files ride the app).
select public.declare_table_siloing(t, 'system')
from unnest(array[
    -- the vocabulary and the registry itself
    'silos', 'silo_members', 'members', 'data_tables', 'table_silos', 'table_members',
    'note_silos', 'note_members', 'doc_silos', 'doc_members', 'todo_silos', 'todo_members',
    'cell_silos', 'cell_members', 'event_silos', 'event_members',
    'vibe_code_app_silos', 'vibe_code_app_members', 'goal_cell_link_members',
    'silo_asks', 'silo_ask_candidates', 'silo_bench_runs', 'silo_bench_cases', 'silo_bench_results',
    -- identity, keys, tokens, secrets
    'profiles', 'peers', 'integrations', 'gcal_connection', 'gcal_oauth_state', 'plaid_item',
    'phone_devices', 'location_devices', 'push_devices', 'push_queue',
    -- logs and queues
    'row_edits', 'agent_edits', 'syla_job_runs',
    'agent_map_proposals', 'agent_todo_proposals', 'auto_approve_rules', 'user_table_proposals',
    'member_prompt_requests', 'member_edit_requests', 'member_silo_requests',
    -- child tables riding a per-row parent
    'doc_folders', 'doc_syla', 'event_docs', 'event_exclusion', 'event_goals',
    'goal_cell_links', 'note_uploads', 'uploads',
    'todo_docs', 'todo_done', 'todo_exclusion', 'todo_goals', 'todo_group',
    'vibe_code_app_files'
]) as t
where exists (select 1 from public.data_tables d where d.table_name = t);

-- Everything else — apple_event, apple_reminder, card_purchase, day_summary,
-- device_contacts, gcal_event, health_samples, network_collective_members,
-- network_strategies, network_strategy_cards, user_locations, weight_lifts,
-- and every user table — stays 'table': unsiloed, in the backlog, shareable
-- as a whole once the owner places it. Now the grants and policies land.

select public.reconcile_table_siloing();

-- ---------------------------------------------------------------------------
-- The user-tables skill learns where its tables end up
-- ---------------------------------------------------------------------------
--
-- Docs are data: this lands in row_edits like any edit. Patched only while
-- the seeded footer is intact and the section is absent, so an owner's
-- edits are never overwritten.

update public.docs
set html = replace(html,
    '<footer>doc <code>skills/user-tables</code></footer>',
    '<h2>Every table is siloed or unsiloed</h2>'
    || '<p>A table you create is registered the moment it exists (the <code>data_tables</code> registry, kept by a database event trigger) and starts <em>unsiloed</em>: invisible to every member and listed under Silo Soon on the Syla tab, next to unsiloed notes and docs. The owner places the whole table in silos or names members on it from there (<code>table_silos</code> / <code>table_members</code>), or marks it siloed to keep it private — that is the only way rows of a user table ever reach a member, through <code>member_rq</code>. You never place tables yourself; there is no write path for it. A user table cannot be declared per-row or system: it is always the whole table that is shared or not.</p>'
    || '<footer>doc <code>skills/user-tables</code></footer>')
where path = 'skills/user-tables'
  and html like '%<footer>doc <code>skills/user-tables</code></footer>%'
  and html not like '%Every table is siloed or unsiloed%';
