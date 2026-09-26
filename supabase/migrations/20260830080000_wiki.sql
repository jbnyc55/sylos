-- A wiki of self-contained HTML pages, and the trigger-written edit log that
-- makes every change to it undoable (skills/wiki).
--
-- Two tables with opposite trust models:
--
--   wiki_pages — the claude role edits this freely: insert, update and delete
--     are all granted, a first for that role. Each page is one complete
--     standalone HTML document (the check constraint insists on a doctype),
--     addressed by a /-separated path, so pages nest like folders and any one
--     of them can be mailed around and renders anywhere with no server behind
--     it.
--
--   row_edits — the undo log. An AFTER trigger on wiki_pages appends one row
--     per insert, update and delete, capturing the full before and after row
--     as JSON, whoever performed the change. This is a different mechanism
--     from agent_edits on purpose: agent_edits is voluntary self-reporting,
--     useless as an undo guarantee for a role allowed to delete. Here the
--     trigger fires regardless of who runs the DML, and the log's only
--     insert policy demands pg_trigger_depth() > 0 — so the claude role
--     cannot skip an entry (triggers are not optional for a role holding
--     mere DML grants), cannot forge one (a direct insert is outside any
--     trigger and is refused), and cannot rewrite one (no update or delete
--     grant exists, for anyone). The trigger runs SECURITY INVOKER exactly
--     so that edited_by = current_user names the real actor rather than the
--     function owner. Any edit or deletion is undone by writing old_row
--     back.
--
-- row_edits is deliberately generic — table_name plus row images — so a later
-- table gets the same protection with one `create trigger` line. Two known
-- edges of the trigger approach, both closed here: TRUNCATE does not fire row
-- triggers, so nobody but the owner may truncate (no grant exists); and a
-- role that owned the table could disable its triggers, but claude holds DML
-- grants only, never ownership.
--
-- The wiki's write path for claude follows the tag_note pattern
-- (20260830030000): structured RPCs gated on the Vault key,
-- `set local role claude`, no dynamic SQL.

-- ---------------------------------------------------------------------------
-- wiki_pages
-- ---------------------------------------------------------------------------

create table public.wiki_pages (
    id          uuid primary key default gen_random_uuid(),
    -- Folder-style nesting lives in the path, object-storage style:
    -- 'health/sleep/experiments' sits inside the health/sleep "folder"
    -- without any folder rows to keep consistent. Lowercase slug segments
    -- separated by single slashes.
    path        text not null unique
                check (path ~ '^[a-z0-9-]+(/[a-z0-9-]+)*$'
                       and char_length(path) <= 400),
    title       text not null check (char_length(title) between 1 and 200),
    -- One complete, self-contained document: inline styles, no external
    -- fetches, so the page renders identically from the app, a download, or
    -- an email attachment. The doctype check is a cheap tripwire against
    -- saving fragments; self-containedness itself is the skill's contract
    -- (skills/wiki), not something SQL can prove.
    html        text not null
                check (html ~* '^\s*<!doctype html' and char_length(html) <= 2000000),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

comment on table public.wiki_pages is
    'Wiki of self-contained HTML documents, nested by /-separated path. Freely editable by the claude role; every change is captured in row_edits by trigger.';

create trigger wiki_pages_set_updated_at
    before update on public.wiki_pages
    for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- row_edits — the trigger-written undo log
-- ---------------------------------------------------------------------------

create table public.row_edits (
    id          bigint generated always as identity primary key,
    table_name  text not null,
    row_id      uuid not null,
    op          text not null check (op in ('INSERT', 'UPDATE', 'DELETE')),
    -- current_user at DML time: 'claude' through the RPCs, 'authenticated'
    -- from the app. Recorded by the trigger, so it cannot be spoofed.
    edited_by   text not null,
    old_row     jsonb,
    new_row     jsonb,
    created_at  timestamptz not null default now(),
    -- The op names exactly which images exist: an insert has no before, a
    -- delete no after, an update both.
    check ((op = 'INSERT') = (old_row is null)),
    check ((op = 'DELETE') = (new_row is null))
);

comment on table public.row_edits is
    'Append-only row-image log, written only from inside the log_row_edit trigger (the insert policy requires pg_trigger_depth() > 0). old_row is the undo: write it back to revert the change. No update or delete grant exists for any role.';

-- "This page's history" and "what changed lately" are the two reads.
create index row_edits_row_idx on public.row_edits (table_name, row_id, id desc);
create index row_edits_created_at_idx on public.row_edits (created_at desc);

-- SECURITY INVOKER (the default), deliberately: the insert into row_edits
-- runs as whoever ran the DML, which makes edited_by honest and lets RLS —
-- rather than a definer bypass — arbitrate the write. The role doing the
-- edit therefore needs insert on row_edits, but only trigger-context inserts
-- satisfy the policy below, so the grant is not a forgery path.
create function public.log_row_edit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    _row_id uuid;
begin
    if tg_op = 'DELETE' then
        _row_id := old.id;
    else
        _row_id := new.id;
    end if;

    insert into public.row_edits (table_name, row_id, op, edited_by, old_row, new_row)
    values (
        tg_table_name,
        _row_id,
        tg_op,
        current_user,
        case when tg_op = 'INSERT' then null else to_jsonb(old) end,
        case when tg_op = 'DELETE' then null else to_jsonb(new) end
    );

    return null;
end;
$$;

comment on function public.log_row_edit() is
    'AFTER row trigger: appends the full before/after row images to row_edits as the role doing the DML, so edited_by cannot be masked.';

-- Only triggers run this; execute-permission on trigger functions is checked
-- against the table owner at creation time, so no role needs a grant.
revoke all on function public.log_row_edit() from public;

create trigger wiki_pages_log_edits
    after insert or update or delete on public.wiki_pages
    for each row execute function public.log_row_edit();

-- ---------------------------------------------------------------------------
-- Row level security + grants
-- ---------------------------------------------------------------------------

alter table public.wiki_pages enable row level security;
alter table public.row_edits enable row level security;

-- claude: full DML on the wiki, select-only on the log. The asymmetry is the
-- point — the role may do anything to a page precisely because it can do
-- nothing to the record of having done it.
grant select, insert, update, delete on public.wiki_pages to claude;
-- insert on row_edits exists only to let the invoker-security trigger append
-- as claude; the trigger-depth policy below refuses it everywhere else.
grant select, insert on public.row_edits to claude;

create policy "claude reads everything" on public.wiki_pages
    for select to claude using (true);
create policy "claude creates pages" on public.wiki_pages
    for insert to claude with check (true);
create policy "claude updates pages" on public.wiki_pages
    for update to claude using (true) with check (true);
create policy "claude deletes pages" on public.wiki_pages
    for delete to claude using (true);

create policy "claude reads everything" on public.row_edits
    for select to claude using (true);

-- The log's one write path: an insert issued from inside a trigger. A direct
-- insert has pg_trigger_depth() = 0 and is refused, and neither claude nor
-- authenticated can create functions or triggers to fake the depth (no
-- create on any schema, no trigger privilege on any table).
create policy "only triggers append the log" on public.row_edits
    for insert to claude, authenticated
    with check (pg_trigger_depth() > 0);

-- Signed-in users get the same wiki access (the app's restore button is an
-- ordinary update or re-insert), and read the log to review and undo.
grant select, insert, update, delete on public.wiki_pages to authenticated;
grant select, insert on public.row_edits to authenticated;

create policy "Wiki pages are readable by signed-in users" on public.wiki_pages
    for select to authenticated using (true);
create policy "Signed-in users create pages" on public.wiki_pages
    for insert to authenticated with check (true);
create policy "Signed-in users update pages" on public.wiki_pages
    for update to authenticated using (true) with check (true);
create policy "Signed-in users delete pages" on public.wiki_pages
    for delete to authenticated using (true);

create policy "Row edits are readable by signed-in users" on public.row_edits
    for select to authenticated using (true);

-- Deliberately absent: any update or delete grant on row_edits, for any
-- role. Entries can be read and acted on, never rewritten or removed.

-- ---------------------------------------------------------------------------
-- save_wiki_page — create or update one page, over HTTPS
-- ---------------------------------------------------------------------------

create or replace function public.save_wiki_page(_path text, _title text, _html text)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _existed boolean;
    _id      uuid;
begin
    perform public.assert_claude_rq_key();

    if _path is null or _title is null or _html is null then
        raise exception 'path, title and html are all required';
    end if;

    set local statement_timeout = '30s';
    set local role claude;

    _existed := exists (select 1 from public.wiki_pages where path = _path);

    insert into public.wiki_pages (path, title, html)
    values (_path, _title, _html)
    on conflict (path) do update
        set title = excluded.title,
            html  = excluded.html
    returning id into _id;

    return jsonb_build_object(
        'page_id', _id,
        'path',    _path,
        'op',      case when _existed then 'updated' else 'created' end
    );
end;
$$;

comment on function public.save_wiki_page(text, text, text) is
    'Creates or replaces one wiki page by path, as the claude role. Gated by assert_claude_rq_key().';

revoke all on function public.save_wiki_page(text, text, text) from public;
grant execute on function public.save_wiki_page(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- move_wiki_page — rename one page's path, over HTTPS
-- ---------------------------------------------------------------------------
--
-- One page at a time; moving a "folder" is a move per page inside it, each
-- individually logged and so individually undoable.

create or replace function public.move_wiki_page(_from text, _to text)
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

    if exists (select 1 from public.wiki_pages where path = _to) then
        raise exception 'a page already exists at %', _to;
    end if;

    update public.wiki_pages
    set path = _to
    where path = _from
    returning id into _id;

    if _id is null then
        raise exception 'no page at %', _from;
    end if;

    return jsonb_build_object('page_id', _id, 'from', _from, 'to', _to);
end;
$$;

comment on function public.move_wiki_page(text, text) is
    'Renames one wiki page''s path, as the claude role. Gated by assert_claude_rq_key().';

revoke all on function public.move_wiki_page(text, text) from public;
grant execute on function public.move_wiki_page(text, text) to anon;

-- ---------------------------------------------------------------------------
-- delete_wiki_page — remove one page, over HTTPS
-- ---------------------------------------------------------------------------
--
-- Deletion is allowed because it is reversible: the trigger stores the full
-- row in row_edits before this returns, and restoring is writing old_row
-- back via save_wiki_page or the app.

create or replace function public.delete_wiki_page(_path text)
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

    delete from public.wiki_pages
    where path = _path
    returning id into _id;

    if _id is null then
        raise exception 'no page at %', _path;
    end if;

    return jsonb_build_object('page_id', _id, 'path', _path, 'op', 'deleted');
end;
$$;

comment on function public.delete_wiki_page(text) is
    'Deletes one wiki page by path (recoverably — the row image is in row_edits), as the claude role. Gated by assert_claude_rq_key().';

revoke all on function public.delete_wiki_page(text) from public;
grant execute on function public.delete_wiki_page(text) to anon;
