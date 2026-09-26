-- Every edit is reversible — as code, not aspiration.
--
-- row_edits so far guarded wiki_pages alone; every other table could be
-- edited with no before-image kept, so "any change is undoable" was true of
-- the wiki and merely hoped-for elsewhere. This migration attaches the
-- log_row_edit trigger to every application table in public, and installs an
-- event trigger so a future table gets the same logging the moment it is
-- created — the reversibility twin of "no records fall through the cracks".
--
-- The two logs themselves stay unlogged, by design: row_edits logging itself
-- would recurse, and both logs are append-only for every role, so there is
-- no edit on them to reverse.

-- ---------------------------------------------------------------------------
-- Generalize row_edits beyond uuid-id tables
-- ---------------------------------------------------------------------------
--
-- Junction tables (manual_note_types, todo_done, …) have composite keys and
-- no id column. row_id therefore becomes nullable text, read out of the row
-- image rather than from a hard-coded old.id/new.id: null means "this table
-- has no single id" and the old_row/new_row images still identify the row.

alter table public.row_edits
    alter column row_id type text using row_id::text,
    alter column row_id drop not null;

comment on column public.row_edits.row_id is
    'The row''s id column as text, when the table has one; null for composite-key tables, where old_row/new_row identify the row.';

create or replace function public.log_row_edit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    _old jsonb := case when tg_op = 'INSERT' then null else to_jsonb(old) end;
    _new jsonb := case when tg_op = 'DELETE' then null else to_jsonb(new) end;
begin
    insert into public.row_edits (table_name, row_id, op, edited_by, actor_id, old_row, new_row)
    values (
        tg_table_name,
        coalesce(_new ->> 'id', _old ->> 'id'),
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
    'AFTER row trigger: appends the full before/after row images to row_edits as the role doing the DML, so edited_by and actor_id cannot be masked. Works on any table; row_id is taken from the image''s id field when one exists.';

-- ---------------------------------------------------------------------------
-- Attach the trigger to every existing application table
-- ---------------------------------------------------------------------------

do $$
declare
    t record;
begin
    for t in
        select tablename from pg_tables
        where schemaname = 'public'
          and tablename not in ('row_edits', 'agent_edits')
    loop
        execute format('drop trigger if exists %I on public.%I',
            t.tablename || '_log_edits', t.tablename);
        execute format(
            'create trigger %I after insert or update or delete on public.%I
             for each row execute function public.log_row_edit()',
            t.tablename || '_log_edits', t.tablename);
    end loop;
end
$$;

-- ---------------------------------------------------------------------------
-- And to every future table, automatically
-- ---------------------------------------------------------------------------
--
-- The db-level rule, not a convention: a CREATE TABLE in public leaves the
-- ddl_command_end hook with logging already attached. Forgetting is not an
-- available failure mode.

create function public.attach_row_edit_logging()
returns event_trigger
language plpgsql
set search_path = ''
as $$
declare
    obj record;
    _table text;
begin
    for obj in
        select * from pg_event_trigger_ddl_commands()
        where command_tag = 'CREATE TABLE'
    loop
        if obj.schema_name <> 'public' then
            continue;
        end if;
        _table := (parse_ident(obj.object_identity))[2];
        if _table in ('row_edits', 'agent_edits') then
            continue;
        end if;
        execute format('drop trigger if exists %I on public.%I',
            _table || '_log_edits', _table);
        execute format(
            'create trigger %I after insert or update or delete on public.%I
             for each row execute function public.log_row_edit()',
            _table || '_log_edits', _table);
    end loop;
end;
$$;

comment on function public.attach_row_edit_logging() is
    'Event trigger body: attaches log_row_edit to any table created in public, so reversibility is a property of the database, not of remembering.';

create event trigger tables_get_row_edit_logging
    on ddl_command_end
    when tag in ('CREATE TABLE')
    execute function public.attach_row_edit_logging();

-- ---------------------------------------------------------------------------
-- Grants: whoever may edit a table may (only via trigger) append to the log
-- ---------------------------------------------------------------------------
--
-- The insert grant is not a forgery path: the "only triggers append the log"
-- policy (20260830080000_wiki.sql) refuses any insert with
-- pg_trigger_depth() = 0, and none of these roles can create triggers.
-- service_role (the plaid edge function) bypasses RLS by attribute, so the
-- grant alone is what it needs.

grant insert on public.row_edits to service_role;
grant select on public.row_edits to service_role;

-- The trigger-depth policy currently names claude and authenticated; recreate
-- it naming service_role too, for defense in depth should its bypassrls
-- attribute ever be dropped.
drop policy "only triggers append the log" on public.row_edits;
create policy "only triggers append the log" on public.row_edits
    for insert to claude, authenticated, service_role
    with check (pg_trigger_depth() > 0);

-- Deliberately unchanged: no update or delete grant on row_edits for any
-- role, and no select for guests — the log stays append-only and private to
-- the owner (and claude). TRUNCATE is not row-logged; nobody but the table
-- owner holds it, and migrations should prefer deletes.
