-- Wiki pages join the tag system: the same note_types vocabulary as manual
-- notes, the same undo log underneath.
--
-- A page's tags say what it is about; guest visibility hangs off them in
-- 20260831040000, where each guest group's allow and deny lists over the
-- same vocabulary decide what its members may see.
--
-- The junction is wiki_page_types → note_types: one vocabulary across notes
-- and wiki, so one term means the same thing everywhere. Tag and untag are
-- edits too — the row_edits event trigger (20260831010000) attaches logging
-- to this table the moment it is created, page-deletion cascades included.
--
-- Also fixed here: the wiki migration (20260830080000) predated this branch
-- learning the guests lesson (20260830050000) — a claiming guest briefly
-- holds an authenticated session, so "signed-in" is not "the owner". The
-- wiki_pages and row_edits policies are tightened to is_owner(), matching
-- every other owner-managed table.

-- ---------------------------------------------------------------------------
-- Owner-only, not merely signed-in
-- ---------------------------------------------------------------------------

alter policy "Wiki pages are readable by signed-in users"
    on public.wiki_pages using (public.is_owner());
alter policy "Signed-in users create pages"
    on public.wiki_pages with check (public.is_owner());
alter policy "Signed-in users update pages"
    on public.wiki_pages using (public.is_owner()) with check (public.is_owner());
alter policy "Signed-in users delete pages"
    on public.wiki_pages using (public.is_owner());
alter policy "Row edits are readable by signed-in users"
    on public.row_edits using (public.is_owner());

-- The trigger's insert path stays open to whoever edits: is_owner() would
-- wrongly block a future guest-writable audited table, and the trigger-depth
-- check already prevents abuse. No change to "only triggers append the log".

-- ---------------------------------------------------------------------------
-- wiki_page_types — the junction
-- ---------------------------------------------------------------------------

create table public.wiki_page_types (
    -- The uuid id gives the auto-attached row_edits logging a row_id to key
    -- on, so tag-link history reads like every other page history.
    id            uuid primary key default gen_random_uuid(),
    page_id       uuid not null references public.wiki_pages (id) on delete cascade,
    note_type_id  uuid not null references public.note_types (id) on delete cascade,
    unique (page_id, note_type_id)
);

comment on table public.wiki_page_types is
    'Which tags each wiki page carries — the same note_types vocabulary as manual notes, organizing the wiki and driving guest visibility (20260831040000). Changes land in row_edits by the auto-attached trigger.';

-- "All pages under tag X" is the guest-policy read and the tag-filter read.
create index wiki_page_types_type_page_idx
    on public.wiki_page_types (note_type_id, page_id);

-- No create trigger here: the tables_get_row_edit_logging event trigger
-- (20260831010000) already attached wiki_page_types_log_edits when the
-- table above was created.

alter table public.wiki_page_types enable row level security;

-- ---------------------------------------------------------------------------
-- Row level security + grants
-- ---------------------------------------------------------------------------

-- The owner manages tags from the app.
grant select, insert, delete on public.wiki_page_types to authenticated;

create policy "Page tags are viewable by the owner"
    on public.wiki_page_types for select
    to authenticated
    using (public.is_owner());

create policy "Page tags are insertable by the owner"
    on public.wiki_page_types for insert
    to authenticated
    with check (public.is_owner());

create policy "Page tags are deletable by the owner"
    on public.wiki_page_types for delete
    to authenticated
    using (public.is_owner());

-- claude tags and untags pages, mirroring "claude tags notes"
-- (20260830030000). Its page writes were granted in 20260830080000.
grant select, insert, delete on public.wiki_page_types to claude;

create policy "claude reads everything"
    on public.wiki_page_types for select
    to claude
    using (true);

create policy "claude tags pages"
    on public.wiki_page_types for insert
    to claude
    with check (true);

create policy "claude untags pages"
    on public.wiki_page_types for delete
    to claude
    using (true);

-- Deliberately NO guest access yet: it arrives in 20260831040000, where a
-- guest group's tag allow and deny lists decide which pages its members
-- may read.

-- ---------------------------------------------------------------------------
-- tag_wiki_page — one page's tag set, over HTTPS
-- ---------------------------------------------------------------------------
--
-- The tag_note of the wiki (20260830030000): sets the page's tag set to
-- exactly _type_ids. An empty array untags the page entirely. Idempotent;
-- every add and remove is individually captured in row_edits.

create or replace function public.tag_wiki_page(_path text, _type_ids uuid[])
returns jsonb
language plpgsql
security invoker
as $$
declare
    _page_id uuid;
    removed  integer;
    added    integer;
begin
    perform public.assert_claude_rq_key();

    if _type_ids is null then
        raise exception 'type_ids must be an array (possibly empty), not null';
    end if;

    set local statement_timeout = '30s';
    set local role claude;

    select id into _page_id from public.wiki_pages where path = _path;
    if _page_id is null then
        raise exception 'no page at %', _path;
    end if;

    delete from public.wiki_page_types
    where page_id = _page_id
      and note_type_id <> all (_type_ids);
    get diagnostics removed = row_count;

    insert into public.wiki_page_types (page_id, note_type_id)
    select _page_id, unnest(_type_ids)
    on conflict do nothing;
    get diagnostics added = row_count;

    return jsonb_build_object(
        'page_id', _page_id,
        'path',    _path,
        'tags',    coalesce(array_length(_type_ids, 1), 0),
        'added',   added,
        'removed', removed
    );
end;
$$;

comment on function public.tag_wiki_page(text, uuid[]) is
    'Sets one wiki page''s tag set to exactly the given note_types, as the claude role. Gated by assert_claude_rq_key().';

revoke all on function public.tag_wiki_page(text, uuid[]) from public;
grant execute on function public.tag_wiki_page(text, uuid[]) to anon;
