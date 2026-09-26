-- A todo occurrence can now be skipped, not just done.
--
-- todo_done grows a status column: 'done' stays the default (every existing
-- row keeps meaning what it meant), and 'skipped' records "I looked at this
-- occurrence and deliberately let it go". Either way the occurrence is
-- handled — the distinction is for honest history, and for the missed-todos
-- section, which only chases occurrences with no row at all.
--
-- Flipping an occurrence between done and skipped is an update on its
-- existing row (the client upserts), so the owner gains update alongside
-- the existing insert and delete.

alter table public.todo_done
    add column status text not null default 'done'
        check (status in ('done', 'skipped'));

comment on table public.todo_done is
    'One row per handled occurrence: this todo, on this day, done or deliberately skipped. No row means unhandled.';

create policy "Todo completions are updatable by the todo's owner"
    on public.todo_done for update
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

grant update on public.todo_done to authenticated;
