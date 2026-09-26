-- The wiki is history as a name: the app already says Docs everywhere it
-- speaks (#117), and this migration renames the substance to match — tables,
-- columns, RPCs, the guest-visibility helper, triggers, indexes, constraints
-- and policy names. wiki_pages becomes docs; wiki_page_types becomes
-- doc_note_types (page_id → doc_id), matching manual_note_types' shape.
--
-- What deliberately does NOT change: row_edits. The log is append-only by
-- contract — entries are never rewritten, not even their labels — so rows
-- written before this migration keep table_name = 'wiki_pages' /
-- 'wiki_page_types', while the trigger stamps new rows with the new names.
-- Readers of a doc's history therefore match both names; history only grows.
--
-- Renames leave every dependent in place: policies, triggers and column
-- grants bind by OID, so the guest column-scoped select on docs, the
-- allow-minus-deny policies and the log triggers all survive untouched.
-- Only things that resolve names at *runtime* need recreating, and that is
-- exactly the plpgsql/sql function bodies below.
--
-- Version note: this file first shipped stamped 20260907000000, colliding
-- with 20260907000000_todo_events.sql. Migration versions are the primary
-- key of the tracking table, so only one file per version is ever recorded —
-- todo_events won and this one silently never ran, leaving production on
-- wiki_pages while the app asked for docs ("Could not find the table
-- 'public.docs' in the schema cache"). Re-stamped after the last applied
-- migration so it deploys as new; the body is unchanged and everything it
-- renames still exists under its old name in production.

-- ---------------------------------------------------------------------------
-- Tables and columns
-- ---------------------------------------------------------------------------

alter table public.wiki_pages rename to docs;
alter table public.wiki_page_types rename to doc_note_types;
alter table public.doc_note_types rename column page_id to doc_id;

comment on table public.docs is
    'Docs: self-contained HTML documents, nested by /-separated path. Freely editable by the claude role; every change is captured in row_edits by trigger.';
comment on table public.doc_note_types is
    'Which tags each doc carries — the same note_types vocabulary as manual notes, organizing the docs and driving guest visibility (20260831040000). Changes land in row_edits by the auto-attached trigger.';

-- ---------------------------------------------------------------------------
-- Constraint, index and trigger names
-- ---------------------------------------------------------------------------
--
-- Nothing reads these by name, but they surface in error messages and \d
-- output, so they follow the tables they belong to.

alter table public.docs rename constraint wiki_pages_pkey to docs_pkey;
alter table public.docs rename constraint wiki_pages_path_key to docs_path_key;
alter table public.docs rename constraint wiki_pages_path_check to docs_path_check;
alter table public.docs rename constraint wiki_pages_title_check to docs_title_check;
alter table public.docs rename constraint wiki_pages_html_check to docs_html_check;

alter table public.doc_note_types
    rename constraint wiki_page_types_pkey to doc_note_types_pkey;
alter table public.doc_note_types
    rename constraint wiki_page_types_page_id_note_type_id_key
    to doc_note_types_doc_id_note_type_id_key;
alter table public.doc_note_types
    rename constraint wiki_page_types_page_id_fkey to doc_note_types_doc_id_fkey;
alter table public.doc_note_types
    rename constraint wiki_page_types_note_type_id_fkey
    to doc_note_types_note_type_id_fkey;

alter index public.wiki_page_types_type_page_idx
    rename to doc_note_types_type_doc_idx;

alter trigger wiki_pages_set_updated_at on public.docs
    rename to docs_set_updated_at;
alter trigger wiki_pages_log_edits on public.docs
    rename to docs_log_edits;
alter trigger wiki_page_types_log_edits on public.doc_note_types
    rename to doc_note_types_log_edits;

-- ---------------------------------------------------------------------------
-- Policy names
-- ---------------------------------------------------------------------------
--
-- The owner policies also shed their pre-guest-era "signed-in" names
-- (20260831030000 already tightened them to is_owner()).

alter policy "Wiki pages are readable by signed-in users" on public.docs
    rename to "Docs are readable by the owner";
alter policy "Signed-in users create pages" on public.docs
    rename to "The owner creates docs";
alter policy "Signed-in users update pages" on public.docs
    rename to "The owner updates docs";
alter policy "Signed-in users delete pages" on public.docs
    rename to "The owner deletes docs";
alter policy "claude creates pages" on public.docs
    rename to "claude creates docs";
alter policy "claude updates pages" on public.docs
    rename to "claude updates docs";
alter policy "claude deletes pages" on public.docs
    rename to "claude deletes docs";

alter policy "Page tags are viewable by the owner" on public.doc_note_types
    rename to "Doc tags are viewable by the owner";
alter policy "Page tags are insertable by the owner" on public.doc_note_types
    rename to "Doc tags are insertable by the owner";
alter policy "Page tags are deletable by the owner" on public.doc_note_types
    rename to "Doc tags are deletable by the owner";
alter policy "claude tags pages" on public.doc_note_types
    rename to "claude tags docs";
alter policy "claude untags pages" on public.doc_note_types
    rename to "claude untags docs";
alter policy "Guests read page tag links in their groups" on public.doc_note_types
    rename to "Guests read doc tag links in their groups";

-- ---------------------------------------------------------------------------
-- doc_denied_for_group and the guest docs policy
-- ---------------------------------------------------------------------------
--
-- These two go together and both need full recreation: the helper's
-- parameter rename (_page_id → _doc_id) is beyond create-or-replace, and
-- the policy depends on the helper, so it must drop first and return last.
-- The recreated policy is 20260901030000's current shape, only respelled.

drop policy "Guests read pages their groups allow and none deny" on public.docs;
drop function public.page_denied_for_group(uuid, uuid);

create function public.doc_denied_for_group(_doc_id uuid, _group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.doc_note_types j
        join public.guest_group_denied_tags d on d.note_type_id = j.note_type_id
        where j.doc_id = _doc_id
          and d.group_id = _group_id
    )
$$;

comment on function public.doc_denied_for_group(uuid, uuid) is
    'True when the doc carries any tag the group denies. Same RLS-bypassing rationale as note_denied_for_group.';

revoke all on function public.doc_denied_for_group(uuid, uuid) from public;
grant execute on function public.doc_denied_for_group(uuid, uuid) to guest;

create policy "Guests read docs their groups allow and none deny"
    on public.docs for select
    to guest
    using (exists (
        select 1
        from public.guest_group_members m
        join public.guest_groups g on g.id = m.group_id
        where m.guest_id = public.current_guest_id()
          and g.allows_sql
          and exists (
              select 1
              from public.doc_note_types j
              join public.guest_group_tags a
                on a.note_type_id = j.note_type_id and a.group_id = m.group_id
              where j.doc_id = docs.id
          )
          and not public.doc_denied_for_group(docs.id, m.group_id)
    ));

-- ---------------------------------------------------------------------------
-- The write RPCs — save_doc, move_doc, delete_doc, tag_doc
-- ---------------------------------------------------------------------------
--
-- Same rename-then-replace shape: the rename keeps each function's grants
-- (execute to anon, revoked from public) and the replace updates the body
-- for the new table names. Callers are scripts/doc-save, doc-move,
-- doc-delete and doc-tag, which ship in the same commit.

alter function public.save_wiki_page(text, text, text) rename to save_doc;

create or replace function public.save_doc(_path text, _title text, _html text)
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

    _existed := exists (select 1 from public.docs where path = _path);

    insert into public.docs (path, title, html)
    values (_path, _title, _html)
    on conflict (path) do update
        set title = excluded.title,
            html  = excluded.html
    returning id into _id;

    return jsonb_build_object(
        'doc_id', _id,
        'path',   _path,
        'op',     case when _existed then 'updated' else 'created' end
    );
end;
$$;

comment on function public.save_doc(text, text, text) is
    'Creates or replaces one doc by path, as the claude role. Gated by assert_claude_rq_key().';

alter function public.move_wiki_page(text, text) rename to move_doc;

create or replace function public.move_doc(_from text, _to text)
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

    if exists (select 1 from public.docs where path = _to) then
        raise exception 'a doc already exists at %', _to;
    end if;

    update public.docs
    set path = _to
    where path = _from
    returning id into _id;

    if _id is null then
        raise exception 'no doc at %', _from;
    end if;

    return jsonb_build_object('doc_id', _id, 'from', _from, 'to', _to);
end;
$$;

comment on function public.move_doc(text, text) is
    'Renames one doc''s path, as the claude role. Gated by assert_claude_rq_key().';

alter function public.delete_wiki_page(text) rename to delete_doc;

create or replace function public.delete_doc(_path text)
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

    delete from public.docs
    where path = _path
    returning id into _id;

    if _id is null then
        raise exception 'no doc at %', _path;
    end if;

    return jsonb_build_object('doc_id', _id, 'path', _path, 'op', 'deleted');
end;
$$;

comment on function public.delete_doc(text) is
    'Deletes one doc by path (recoverably — the row image is in row_edits), as the claude role. Gated by assert_claude_rq_key().';

alter function public.tag_wiki_page(text, uuid[]) rename to tag_doc;

create or replace function public.tag_doc(_path text, _type_ids uuid[])
returns jsonb
language plpgsql
security invoker
as $$
declare
    _doc_id uuid;
    removed integer;
    added   integer;
begin
    perform public.assert_claude_rq_key();

    if _type_ids is null then
        raise exception 'type_ids must be an array (possibly empty), not null';
    end if;

    set local statement_timeout = '30s';
    set local role claude;

    select id into _doc_id from public.docs where path = _path;
    if _doc_id is null then
        raise exception 'no doc at %', _path;
    end if;

    delete from public.doc_note_types
    where doc_id = _doc_id
      and note_type_id <> all (_type_ids);
    get diagnostics removed = row_count;

    insert into public.doc_note_types (doc_id, note_type_id)
    select _doc_id, unnest(_type_ids)
    on conflict do nothing;
    get diagnostics added = row_count;

    return jsonb_build_object(
        'doc_id',  _doc_id,
        'path',    _path,
        'tags',    coalesce(array_length(_type_ids, 1), 0),
        'added',   added,
        'removed', removed
    );
end;
$$;

comment on function public.tag_doc(text, uuid[]) is
    'Sets one doc''s tag set to exactly the given note_types, as the claude role. Gated by assert_claude_rq_key().';
