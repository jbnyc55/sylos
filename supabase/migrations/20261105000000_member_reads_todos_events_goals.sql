-- Members read todos, events and goal cells in their silos.
--
-- The junction-per-record-type pattern gave todos (todo_silos /
-- todo_members, 20261003000000), events (event_silos / event_members,
-- 20261006000000) and goal cells (cell_silos / cell_members,
-- 20261003000000) their placements, but the member role was never let
-- in: no select grant, no policy. So a friend switched on in the app's
-- account stack answered "permission denied for table todo" the moment
-- their page asked. Notes, docs and vibe code apps already carry the
-- sentence; this gives the other three the same one, verbatim: a member
-- reads a row when it sits in a silo their membership reads (allows_sql
-- on, the member-held permission) or when it names them.
--
-- Two small extensions the tree shapes need. A todo inside an event is
-- readable when its event is — the event is the context the todo lives
-- in, and a shared event with invisible todos would read as empty. A
-- goal cell is readable when it or any ancestor is placed — sharing a
-- goal shares its map; the methods under it are the goal.
--
-- As on vibe_code_apps, each record policy's subqueries run under the
-- junction tables' own RLS, so members get read on the junction rows
-- that concern them.

-- ── Junctions: what concerns this member ────────────────────────────────

create policy "A member reads todo silo links in their silos"
    on public.todo_silos for select
    to member
    using (exists (
        select 1 from public.silo_members sm
        where sm.silo_id = todo_silos.silo_id
          and sm.member_id = public.current_member_id()
    ));
create policy "A member reads todo links naming them"
    on public.todo_members for select
    to member
    using (member_id = public.current_member_id());

create policy "A member reads event silo links in their silos"
    on public.event_silos for select
    to member
    using (exists (
        select 1 from public.silo_members sm
        where sm.silo_id = event_silos.silo_id
          and sm.member_id = public.current_member_id()
    ));
create policy "A member reads event links naming them"
    on public.event_members for select
    to member
    using (member_id = public.current_member_id());

create policy "A member reads cell silo links in their silos"
    on public.cell_silos for select
    to member
    using (exists (
        select 1 from public.silo_members sm
        where sm.silo_id = cell_silos.silo_id
          and sm.member_id = public.current_member_id()
    ));
create policy "A member reads cell links naming them"
    on public.cell_members for select
    to member
    using (member_id = public.current_member_id());

-- ── Events ──────────────────────────────────────────────────────────────

create policy "Members read events in their silos or naming them"
    on public.events for select
    to member
    using (
        exists (
            select 1
            from public.event_silos j
            join public.silo_members sm on sm.silo_id = j.silo_id
            where j.event_id = events.id
              and sm.member_id = public.current_member_id()
              and sm.allows_sql
        )
        or exists (
            select 1 from public.event_members em
            where em.event_id = events.id
              and em.member_id = public.current_member_id()
        )
    );

-- ── Todos: placed themselves, or inside a readable event ────────────────

create policy "Members read todos in their silos, naming them, or in their events"
    on public.todo for select
    to member
    using (
        exists (
            select 1
            from public.todo_silos j
            join public.silo_members sm on sm.silo_id = j.silo_id
            where j.todo_id = todo.id
              and sm.member_id = public.current_member_id()
              and sm.allows_sql
        )
        or exists (
            select 1 from public.todo_members tm
            where tm.todo_id = todo.id
              and tm.member_id = public.current_member_id()
        )
        or (
            todo.event_id is not null
            and (
                exists (
                    select 1
                    from public.event_silos j
                    join public.silo_members sm on sm.silo_id = j.silo_id
                    where j.event_id = todo.event_id
                      and sm.member_id = public.current_member_id()
                      and sm.allows_sql
                )
                or exists (
                    select 1 from public.event_members em
                    where em.event_id = todo.event_id
                      and em.member_id = public.current_member_id()
                )
            )
        )
    );

-- ── Goal cells: placed themselves, or under a placed ancestor ───────────

-- The ancestor walk reads goal_method_cells from inside its own policy,
-- which RLS would reject as recursion, so this one is security definer:
-- it bypasses row security to climb the tree, and scopes itself by the
-- calling member exactly as the inline policies do. Depth is bounded.
create function public.member_reads_cell(_cell uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    with recursive chain as (
        select c.id, c.parent_id, 1 as depth
        from public.goal_method_cells c
        where c.id = _cell
        union all
        select p.id, p.parent_id, chain.depth + 1
        from public.goal_method_cells p
        join chain on p.id = chain.parent_id
        where chain.depth < 32
    )
    select exists (
        select 1
        from chain
        join public.cell_silos j on j.cell_id = chain.id
        join public.silo_members sm on sm.silo_id = j.silo_id
        where sm.member_id = public.current_member_id()
          and sm.allows_sql
    )
    or exists (
        select 1
        from chain
        join public.cell_members cm on cm.cell_id = chain.id
        where cm.member_id = public.current_member_id()
    )
$$;

comment on function public.member_reads_cell(uuid) is
    'Whether the calling member (app.member_id, set by member_rq) may read this goal cell: it, or any ancestor, sits in a silo their membership reads with allows_sql on, or names them. Security definer only to climb the tree past goal_method_cells'' own row security.';

revoke all on function public.member_reads_cell(uuid) from public;
grant execute on function public.member_reads_cell(uuid) to member;

create policy "Members read goal cells placed with them, or under one"
    on public.goal_method_cells for select
    to member
    using (public.member_reads_cell(id));

-- ── Grants ──────────────────────────────────────────────────────────────

grant select on public.todo to member;
grant select on public.events to member;
grant select on public.goal_method_cells to member;
grant select on public.todo_silos to member;
grant select on public.todo_members to member;
grant select on public.event_silos to member;
grant select on public.event_members to member;
grant select on public.cell_silos to member;
grant select on public.cell_members to member;
