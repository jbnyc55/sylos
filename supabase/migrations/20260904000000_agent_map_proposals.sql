-- Agent goal-map proposals: structured edits the daily routine files against
-- the goal map, for the owner to approve or deny one by one in the app.
--
-- The daily-summary routine has always been advisory about the map — its
-- map_suggestions are free text inside day_summary.stats. This table turns
-- each concrete suggestion into an applyable row: what kind of edit, which
-- cell, the before and after. The trust story is unchanged and matches
-- guest_edit_requests: the agent never touches mind_map_cells. A proposal is
-- inert until the OWNER approves it in the app, and it is the owner's own
-- authenticated session that performs the mind_map_cells write — the claude
-- role gains no write on the map from any of this.

create table public.agent_map_proposals (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    -- add: a new cell under parent_id (null = a new top-level goal).
    -- update: change fields on cell_id (title, notes and/or rank).
    -- retire: soft-delete cell_id and its subtree.
    kind        text not null check (kind in ('add', 'update', 'retire')),
    cell_id     uuid references public.mind_map_cells (id) on delete cascade,
    parent_id   uuid references public.mind_map_cells (id) on delete cascade,
    -- The top-level goal the edit serves, for grouping in the UI. Kept even
    -- if that goal is later removed — the proposal still reads.
    goal_id     uuid references public.mind_map_cells (id) on delete set null,
    -- Row snapshots for the approve/deny UI: `before` is the cell as the
    -- routine read it, `after` the fields the edit would write. Only title,
    -- notes and rank ever appear in `after`; the client applies nothing else.
    before      jsonb check (before is null or jsonb_typeof(before) = 'object'),
    after       jsonb check (after  is null or jsonb_typeof(after)  = 'object'),
    rationale   text not null check (char_length(rationale) between 1 and 2000),
    -- The summarized day whose data argued for this edit.
    source_day  date,
    status      text not null default 'pending'
                    check (status in ('pending', 'approved', 'denied')),
    created_at  timestamptz not null default now(),
    resolved_at timestamptz,

    -- The shape each kind requires: an add has no target cell but must say
    -- what to create; update and retire name their cell.
    check (
        case kind
            when 'add'    then cell_id is null and after is not null
            when 'update' then cell_id is not null and after is not null
            else               cell_id is not null
        end
    )
);

comment on table public.agent_map_proposals is
    'Structured goal-map edits proposed by the daily routine (add/update/retire a mind_map_cells row), pending until the owner approves or denies each in the app. The owner''s own session applies approved edits; the claude role only ever inserts proposals, through propose_map_edit().';

-- The badge on the Goal map tab asks for pending rows.
create index agent_map_proposals_pending_idx
    on public.agent_map_proposals (profile_id, status, created_at);

alter table public.agent_map_proposals enable row level security;

-- ---------------------------------------------------------------------------
-- Owner: reads the queue, resolves proposals, prunes old rows.
-- ---------------------------------------------------------------------------

grant select, delete on public.agent_map_proposals to authenticated;
grant update (status, resolved_at) on public.agent_map_proposals to authenticated;

create policy "Map proposals are viewable by their owner"
    on public.agent_map_proposals for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Map proposals are resolvable by their owner"
    on public.agent_map_proposals for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Map proposals are deletable by their owner"
    on public.agent_map_proposals for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- ---------------------------------------------------------------------------
-- claude: reads everything, inserts pending rows through the RPC below.
-- ---------------------------------------------------------------------------

create policy "claude reads everything"
    on public.agent_map_proposals for select
    to claude
    using (true);

create policy "claude proposes map edits"
    on public.agent_map_proposals for insert
    to claude
    with check (status = 'pending');

-- Column-scoped like the role's other writes: status, resolved_at, id and
-- created_at stay on their defaults — a proposal can only ever be born
-- pending and unresolved.
grant insert (profile_id, kind, cell_id, parent_id, goal_id,
              before, after, rationale, source_day)
    on public.agent_map_proposals to claude;

-- ---------------------------------------------------------------------------
-- propose_map_edit — the routine's write path over HTTPS
-- ---------------------------------------------------------------------------
--
-- Same contract as upsert_day_summary / log_weight_lift: gate on the Vault
-- key, `set local role claude`, one structured insert — arguments, never SQL.
-- Re-filing an edit already pending returns the existing row instead of
-- stacking a duplicate, so re-running a day is idempotent; a capped backlog
-- keeps a runaway routine from flooding the owner's queue.

create or replace function public.propose_map_edit(
    _profile_id uuid,
    _kind       text,
    _rationale  text,
    _cell_id    uuid  default null,
    _parent_id  uuid  default null,
    _goal_id    uuid  default null,
    _before     jsonb default null,
    _after      jsonb default null,
    _source_day date  default null
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    existing uuid;
    result   jsonb;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    -- The same edit, still pending: hand its id back rather than duplicate.
    select id into existing
    from public.agent_map_proposals
    where profile_id = _profile_id
      and status = 'pending'
      and kind = _kind
      and cell_id is not distinct from _cell_id
      and parent_id is not distinct from _parent_id
      and after is not distinct from _after
    limit 1;

    if existing is not null then
        return jsonb_build_object('id', existing, 'status', 'pending',
                                  'duplicate', true);
    end if;

    if (select count(*) from public.agent_map_proposals
        where profile_id = _profile_id and status = 'pending') >= 30 then
        raise exception 'there are already 30 pending map proposals — wait for the owner to resolve some first';
    end if;

    insert into public.agent_map_proposals
        (profile_id, kind, cell_id, parent_id, goal_id,
         before, after, rationale, source_day)
    values
        (_profile_id, _kind, _cell_id, _parent_id, _goal_id,
         _before, _after, _rationale, _source_day)
    returning jsonb_build_object('id', id, 'kind', kind, 'status', status)
    into result;

    return result;
end;
$$;

comment on function public.propose_map_edit(uuid, text, text, uuid, uuid, uuid, jsonb, jsonb, date) is
    'Files one pending goal-map edit proposal as the claude role — the daily routine''s write path for map suggestions. Gated by assert_claude_rq_key(); idempotent against identical pending proposals; the backlog is capped at 30.';

revoke all on function public.propose_map_edit(uuid, text, text, uuid, uuid, uuid, jsonb, jsonb, date) from public;
grant execute on function public.propose_map_edit(uuid, text, text, uuid, uuid, uuid, jsonb, jsonb, date) to anon;
