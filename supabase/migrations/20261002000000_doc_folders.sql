-- Folder order.
--
-- Folders exist only where doc paths say they do; until now their order
-- was alphabetical fate. This table gives a folder path a rank, so the
-- Docs tree can be arranged by dragging — a row per folder that has been
-- deliberately placed, absence meaning "after the ranked ones, by name".
-- When a folder is renamed or refiled, its rank row moves with it (the
-- app rewrites path here alongside the docs' own path rewrites).
--
-- The row_edits event trigger attaches history on creation.

create table public.doc_folders (
    -- The folder's full path, exactly as doc paths spell it.
    path        text primary key check (char_length(path) between 1 and 512),
    rank        integer not null default 0,
    created_at  timestamptz not null default now()
);

comment on table public.doc_folders is
    'One row per deliberately ordered folder of the docs tree. Folders themselves live only in doc paths; this is just their rank. Unranked folders sort after ranked ones, alphabetically.';

alter table public.doc_folders enable row level security;

-- The docs tree is the owner's; ranks follow the docs' own access story.
create policy "Folder ranks are readable by the owner"
    on public.doc_folders for select
    to authenticated
    using (public.is_owner());

create policy "The owner creates folder ranks"
    on public.doc_folders for insert
    to authenticated
    with check (public.is_owner());

create policy "The owner updates folder ranks"
    on public.doc_folders for update
    to authenticated
    using (public.is_owner())
    with check (public.is_owner());

create policy "The owner deletes folder ranks"
    on public.doc_folders for delete
    to authenticated
    using (public.is_owner());

create policy "claude reads folder ranks"
    on public.doc_folders for select
    to claude
    using (true);

grant select, insert, update, delete on public.doc_folders to authenticated;
grant select on public.doc_folders to claude;
