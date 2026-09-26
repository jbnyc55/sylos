-- Synergy links: the same idea living on more than one goal map.
--
-- A method of action often serves several goals at once — creatine can sit
-- on a "lift heavier" map and a "think clearly" map as two separate cells.
-- The maps are ranked and so are the cells, so once those cells are known
-- to be the same thing, all their rankings together say how much leverage
-- the shared idea has: that is its synergy score, computed client-side on
-- the Goal map tab from the live ranks (each occurrence contributes the
-- product of its rank weights down the path from its goal; a paused goal's
-- occurrence contributes zero).
--
-- The detection is the agent's job (a Syla job doc, seeded below): read
-- the map, judge which cells across different goals name the same concept,
-- and file the link through link_goal_cells(). Links are annotation — they
-- change nothing about the cells themselves — so unlike map edits they do
-- not go through the approval queue; the owner sees every link on the tab
-- and can unlink it there in one tap. The claude role still cannot touch
-- goal_method_cells.

create table public.goal_cell_links (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    -- The shared concept the linked cells all name, e.g. 'Creatine'.
    label       text not null check (char_length(label) between 1 and 200),
    -- Why the agent judged these cells the same — shown on the card.
    rationale   text check (rationale is null or char_length(rationale) <= 2000),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

comment on table public.goal_cell_links is
    'One synergy group: a shared concept that appears as cells on several goal maps. Members live in goal_cell_link_members; the synergy score is computed client-side from the live ranks. Written by the agent through link_goal_cells(); the owner unlinks from the Goal map tab.';

create table public.goal_cell_link_members (
    link_id     uuid not null references public.goal_cell_links (id) on delete cascade,
    cell_id     uuid not null references public.goal_method_cells (id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (link_id, cell_id),
    -- A cell means one thing: it can belong to at most one synergy group.
    unique (cell_id)
);

comment on table public.goal_cell_link_members is
    'Which goal_method_cells rows a synergy link groups. unique(cell_id): a cell belongs to at most one link, so link_goal_cells() grows an existing group rather than forking a rival one.';

-- The tab loads a profile's links and their members in one embedded query.
create index goal_cell_links_profile_idx
    on public.goal_cell_links (profile_id, created_at);

create trigger goal_cell_links_set_updated_at
    before update on public.goal_cell_links
    for each row execute function public.set_updated_at();

alter table public.goal_cell_links enable row level security;
alter table public.goal_cell_link_members enable row level security;

-- ---------------------------------------------------------------------------
-- Owner: reads the groups, renames a label, unlinks (whole group or one cell).
-- ---------------------------------------------------------------------------

grant select, delete on public.goal_cell_links to authenticated;
grant update (label) on public.goal_cell_links to authenticated;
grant select, delete on public.goal_cell_link_members to authenticated;

create policy "Cell links are viewable by their owner"
    on public.goal_cell_links for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Cell links are updatable by their owner"
    on public.goal_cell_links for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Cell links are deletable by their owner"
    on public.goal_cell_links for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Cell link members are viewable by their owner"
    on public.goal_cell_link_members for select
    to authenticated
    using (exists (select 1 from public.goal_cell_links l
                   where l.id = link_id
                     and l.profile_id = (select public.current_profile_id())));

create policy "Cell link members are deletable by their owner"
    on public.goal_cell_link_members for delete
    to authenticated
    using (exists (select 1 from public.goal_cell_links l
                   where l.id = link_id
                     and l.profile_id = (select public.current_profile_id())));

-- ---------------------------------------------------------------------------
-- claude: reads everything, links through the RPC below.
-- ---------------------------------------------------------------------------

create policy "claude reads cell links"
    on public.goal_cell_links for select
    to claude
    using (true);

create policy "claude reads cell link members"
    on public.goal_cell_link_members for select
    to claude
    using (true);

create policy "claude links cells"
    on public.goal_cell_links for insert
    to claude
    with check (true);

create policy "claude adds link members"
    on public.goal_cell_link_members for insert
    to claude
    with check (true);

grant insert (profile_id, label, rationale) on public.goal_cell_links to claude;
grant insert (link_id, cell_id) on public.goal_cell_link_members to claude;

-- ---------------------------------------------------------------------------
-- link_goal_cells — the agent's write path over HTTPS
-- ---------------------------------------------------------------------------
--
-- Same contract as propose_map_edit: gate on the Vault key, `set local role
-- claude`, arguments only. Idempotent and convergent: cells already grouped
-- stay grouped, and linking a set that overlaps one existing group grows
-- that group instead of creating a rival. Overlapping two different groups
-- is refused — that tangle is the owner's to resolve on the tab.

create or replace function public.link_goal_cells(
    _profile_id uuid,
    _label      text,
    _cell_ids   uuid[],
    _rationale  text default null
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _distinct   uuid[];
    _valid      int;
    _links      uuid[];
    _link_id    uuid;
    _created    boolean := false;
    _added      int;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    select array_agg(distinct c) into _distinct from unnest(_cell_ids) as c;
    if _distinct is null or array_length(_distinct, 1) < 2 then
        raise exception 'a link needs at least two distinct cells';
    end if;

    -- Every cell must be a live cell of this profile.
    select count(*) into _valid
    from public.goal_method_cells
    where id = any (_distinct)
      and profile_id = _profile_id
      and deleted_at is null;
    if _valid <> array_length(_distinct, 1) then
        raise exception 'every cell must be a live goal_method_cells row of this profile';
    end if;

    -- The groups these cells already belong to, if any.
    select array_agg(distinct m.link_id) into _links
    from public.goal_cell_link_members m
    where m.cell_id = any (_distinct);

    if _links is not null and array_length(_links, 1) > 1 then
        raise exception 'these cells span % existing links — the owner must unlink first',
            array_length(_links, 1);
    end if;

    if _links is not null then
        _link_id := _links[1];
    else
        insert into public.goal_cell_links (profile_id, label, rationale)
        values (_profile_id, _label, _rationale)
        returning id into _link_id;
        _created := true;
    end if;

    insert into public.goal_cell_link_members (link_id, cell_id)
    select _link_id, c from unnest(_distinct) as c
    on conflict do nothing;
    get diagnostics _added = row_count;

    return jsonb_build_object(
        'link_id', _link_id,
        'created', _created,
        'members_added', _added);
end;
$$;

comment on function public.link_goal_cells(uuid, text, uuid[], text) is
    'Links same-concept goal map cells into one synergy group as the claude role — the agent''s write path when it detects the same idea on several goal maps. Gated by assert_claude_rq_key(); idempotent, grows an overlapping group, refuses to bridge two existing groups.';

revoke all on function public.link_goal_cells(uuid, text, uuid[], text) from public;
grant execute on function public.link_goal_cells(uuid, text, uuid[], text) to anon;

-- ---------------------------------------------------------------------------
-- Seed: the Syla job that runs the detection
-- ---------------------------------------------------------------------------
-- Same shape as the original job seeds: the instructions doc
-- (syla/goal-synergy) is data, saved through scripts/doc-save, so a fresh
-- database without it simply seeds no job.

insert into public.syla_jobs (profile_id, name, doc_id, fire_at)
select p.id, 'Goal synergy linking', d.id, time '11:45'
from public.profiles p
join public.docs d on d.path = 'syla/goal-synergy'
where p.is_owner
  and not exists (select 1 from public.syla_jobs e where e.name = 'Goal synergy linking');
