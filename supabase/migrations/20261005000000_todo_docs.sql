-- Docs on todos and events.
--
-- Some events are really instructions — "Syla, run this skill" — and the
-- skill lives in a doc. Events created for Syla become syla_jobs rows,
-- which already carry doc_id; events and todos the owner keeps for
-- themselves get the same idea as a junction, todo_docs, following the
-- junction-per-record-type pattern (todo_silos, todo_members). Zero or
-- many docs per todo; the row_edits event trigger attaches history on
-- creation.

create table public.todo_docs (
    todo_id     uuid not null references public.todo (id) on delete cascade,
    doc_id      uuid not null references public.docs (id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (todo_id, doc_id)
);

create index todo_docs_doc_id_idx on public.todo_docs (doc_id);

alter table public.todo_docs enable row level security;

create policy "Todo docs follow the todo's owner"
    on public.todo_docs for all
    to authenticated
    using (exists (
        select 1 from public.todo t
        where t.id = todo_id
          and t.profile_id = (select public.current_profile_id())
    ))
    with check (exists (
        select 1 from public.todo t
        where t.id = todo_id
          and t.profile_id = (select public.current_profile_id())
    ));

create policy "claude reads todo docs" on public.todo_docs for select to claude using (true);

grant select, insert, delete on public.todo_docs to authenticated;
grant select on public.todo_docs to claude;
