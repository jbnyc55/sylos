-- Agent todo proposals: the todo-list twin of agent_map_proposals
-- (20260904000000). The daily routine's todo_suggestions were advisory text
-- inside day_summary.stats; each concrete one now also lands here as a
-- structured row — add / update / retire a public.todo row, with before and
-- after snapshots — pending until the owner approves or denies it from the
-- badge on the todo list.
--
-- Same trust story as the map table: the agent never touches public.todo.
-- A proposal is inert until the OWNER approves it in the app, and it is the
-- owner's own authenticated session that performs the todo write — the
-- claude role gains no write on todos from any of this.

create table public.agent_todo_proposals (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    -- add: a new todo. update: change fields on todo_id. retire: delete
    -- todo_id (the whole series, history included — the owner sees which).
    kind        text not null check (kind in ('add', 'update', 'retire')),
    todo_id     uuid references public.todo (id) on delete cascade,
    -- The goal-map cell the todo serves: what an approved add links through
    -- todo_goals, and how the UI groups the proposal. Kept nullable — not
    -- every todo serves a mapped goal.
    goal_id     uuid references public.mind_map_cells (id) on delete set null,
    -- Row snapshots for the approve/deny UI: `before` is the todo as the
    -- routine read it, `after` the fields the edit would write. Only the
    -- todo's own gcal-shaped fields (title, start_date, freq, interval_n,
    -- byweekday, month_mode, month_nth, until_date, count_n) ever appear in
    -- `after`; the client applies nothing else.
    before      jsonb check (before is null or jsonb_typeof(before) = 'object'),
    after       jsonb check (after  is null or jsonb_typeof(after)  = 'object'),
    rationale   text not null check (char_length(rationale) between 1 and 2000),
    -- The summarized day whose data argued for this edit.
    source_day  date,
    status      text not null default 'pending'
                    check (status in ('pending', 'approved', 'denied')),
    created_at  timestamptz not null default now(),
    resolved_at timestamptz,

    -- The shape each kind requires, mirroring the map table's check.
    check (
        case kind
            when 'add'    then todo_id is null and after is not null
            when 'update' then todo_id is not null and after is not null
            else               todo_id is not null
        end
    )
);

comment on table public.agent_todo_proposals is
    'Structured todo edits proposed by the daily routine (add/update/retire a public.todo row), pending until the owner approves or denies each in the app. The owner''s own session applies approved edits; the claude role only ever inserts proposals, through propose_todo_edit().';

-- The badge on the todo list asks for pending rows.
create index agent_todo_proposals_pending_idx
    on public.agent_todo_proposals (profile_id, status, created_at);

alter table public.agent_todo_proposals enable row level security;

-- ---------------------------------------------------------------------------
-- Owner: reads the queue, resolves proposals, prunes old rows.
-- ---------------------------------------------------------------------------

grant select, delete on public.agent_todo_proposals to authenticated;
grant update (status, resolved_at) on public.agent_todo_proposals to authenticated;

create policy "Todo proposals are viewable by their owner"
    on public.agent_todo_proposals for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Todo proposals are resolvable by their owner"
    on public.agent_todo_proposals for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Todo proposals are deletable by their owner"
    on public.agent_todo_proposals for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- ---------------------------------------------------------------------------
-- claude: reads everything, inserts pending rows through the RPC below.
-- ---------------------------------------------------------------------------

create policy "claude reads everything"
    on public.agent_todo_proposals for select
    to claude
    using (true);

create policy "claude proposes todo edits"
    on public.agent_todo_proposals for insert
    to claude
    with check (status = 'pending');

-- Column-scoped like the map table: status, resolved_at, id and created_at
-- stay on their defaults — a proposal can only ever be born pending.
grant insert (profile_id, kind, todo_id, goal_id,
              before, after, rationale, source_day)
    on public.agent_todo_proposals to claude;

-- ---------------------------------------------------------------------------
-- propose_todo_edit — the routine's write path over HTTPS
-- ---------------------------------------------------------------------------
--
-- The propose_map_edit contract, retargeted: gate on the Vault key,
-- `set local role claude`, one structured insert. Identical pending
-- proposals dedupe; the backlog is capped at 30.

create or replace function public.propose_todo_edit(
    _profile_id uuid,
    _kind       text,
    _rationale  text,
    _todo_id    uuid  default null,
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
    from public.agent_todo_proposals
    where profile_id = _profile_id
      and status = 'pending'
      and kind = _kind
      and todo_id is not distinct from _todo_id
      and after is not distinct from _after
    limit 1;

    if existing is not null then
        return jsonb_build_object('id', existing, 'status', 'pending',
                                  'duplicate', true);
    end if;

    if (select count(*) from public.agent_todo_proposals
        where profile_id = _profile_id and status = 'pending') >= 30 then
        raise exception 'there are already 30 pending todo proposals — wait for the owner to resolve some first';
    end if;

    insert into public.agent_todo_proposals
        (profile_id, kind, todo_id, goal_id, before, after, rationale, source_day)
    values
        (_profile_id, _kind, _todo_id, _goal_id, _before, _after, _rationale, _source_day)
    returning jsonb_build_object('id', id, 'kind', kind, 'status', status)
    into result;

    return result;
end;
$$;

comment on function public.propose_todo_edit(uuid, text, text, uuid, uuid, jsonb, jsonb, date) is
    'Files one pending todo edit proposal as the claude role — the daily routine''s write path for todo suggestions. Gated by assert_claude_rq_key(); idempotent against identical pending proposals; the backlog is capped at 30.';

revoke all on function public.propose_todo_edit(uuid, text, text, uuid, uuid, jsonb, jsonb, date) from public;
grant execute on function public.propose_todo_edit(uuid, text, text, uuid, uuid, jsonb, jsonb, date) to anon;
