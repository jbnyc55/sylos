-- Auto-approve rules: standing consent for a NARROW category of agent edit
-- proposals, asked for by the agent and granted by the owner in the app.
--
-- The daily routine files goal-map and todo edits as pending proposals the
-- owner resolves one by one. When a category has earned trust — the owner
-- has approved the same narrow shape of edit again and again, never denying
-- it — the routine may file a rule request here: one queue, one kind, an
-- exact set of `after` columns, optionally pinned to a single target row.
-- The owner approves or denies the request from the Auto approve tab.
--
-- The trust story is unchanged. An approved rule does NOT let the claude
-- role write the goal map or the todo list: proposals are still inserted
-- pending exactly as before, and it is the OWNER'S OWN SESSION — the app,
-- next time it loads the queue — that applies a matching pending proposal
-- and stamps it approved, recording which rule let it through
-- (auto_rule_id). The rule is standing consent executed by the owner's
-- client, not a new database privilege; revoking it in the app stops the
-- auto-applies immediately, and every edit it ever let through stays
-- visible in the Auto approve tab's history.

create table public.auto_approve_rules (
    id           uuid primary key default gen_random_uuid(),
    profile_id   uuid not null references public.profiles (id) on delete cascade,
    -- Which proposal queue the rule covers.
    queue        text not null
                     check (queue in ('agent_map_proposals', 'agent_todo_proposals')),
    -- The one proposal kind covered. retire is deliberately absent below:
    -- destructive edits always need a human tap.
    kind         text not null,
    -- The exact `after` keys the rule covers, sorted. A proposal matches
    -- only when its after keys are a SUBSET of these — a rule for {rank}
    -- never lets a title change through.
    columns      text[] not null,
    -- Optional pin to one row: the cell/todo an update or complete targets,
    -- or the parent cell / event an add goes into. Null = any target, which
    -- the owner should grant sparingly.
    target_id    uuid,
    -- Human label for the pinned target at request time, so the rule still
    -- reads after the row is renamed or gone.
    target_label text check (target_label is null or char_length(target_label) between 1 and 200),
    -- The agent's case: the approval streak that argues the category is safe.
    rationale    text not null check (char_length(rationale) between 1 and 2000),
    status       text not null default 'pending'
                     check (status in ('pending', 'approved', 'denied', 'revoked')),
    created_at   timestamptz not null default now(),
    -- When the pending request was answered (approved or denied).
    resolved_at  timestamptz,
    -- When an approved rule was switched back off.
    revoked_at   timestamptz,

    -- Narrowness is structural, not just policy: per queue, only the kinds
    -- and columns an approved proposal can actually write — and never
    -- retire. `complete` covers exactly its day field.
    check (
        case queue
            when 'agent_map_proposals' then
                kind in ('add', 'update')
                and columns <@ array['title', 'notes', 'rank']::text[]
            else
                kind in ('add', 'update', 'complete')
                and columns <@ array['day', 'title', 'event_id', 'start_date',
                                     'start_time', 'end_time', 'freq', 'interval_n',
                                     'byweekday', 'month_mode', 'month_nth',
                                     'until_date', 'count_n']::text[]
        end
    ),
    check (cardinality(columns) between 1 and 4),
    check (kind <> 'complete' or columns = array['day']::text[])
);

comment on table public.auto_approve_rules is
    'Standing approvals for narrow categories of agent edit proposals (one queue, one kind, an exact column set, optionally one target row). The agent requests a rule through propose_auto_approve_rule(); the owner approves, denies, or later revokes it in the app. An approved rule is executed by the owner''s own client — matching pending proposals are applied and stamped approved with auto_rule_id — never by the claude role.';

create index auto_approve_rules_profile_status_idx
    on public.auto_approve_rules (profile_id, status);

alter table public.auto_approve_rules enable row level security;

-- ---------------------------------------------------------------------------
-- Owner: reads the rules, answers requests, revokes, prunes.
-- ---------------------------------------------------------------------------

grant select, delete on public.auto_approve_rules to authenticated;
grant update (status, resolved_at, revoked_at) on public.auto_approve_rules to authenticated;

create policy "Auto-approve rules are viewable by their owner"
    on public.auto_approve_rules for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Auto-approve rules are resolvable by their owner"
    on public.auto_approve_rules for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Auto-approve rules are deletable by their owner"
    on public.auto_approve_rules for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- ---------------------------------------------------------------------------
-- claude: reads everything, inserts pending requests through the RPC below.
-- ---------------------------------------------------------------------------

create policy "claude reads everything"
    on public.auto_approve_rules for select
    to claude
    using (true);

create policy "claude requests auto-approve rules"
    on public.auto_approve_rules for insert
    to claude
    with check (status = 'pending');

-- Column-scoped like the proposal tables: status, resolved_at, revoked_at,
-- id and created_at stay on their defaults — a rule is only ever born as a
-- pending request, and only the owner moves it from there.
grant insert (profile_id, queue, kind, columns, target_id, target_label, rationale)
    on public.auto_approve_rules to claude;

-- ---------------------------------------------------------------------------
-- The audit trail: which rule let a proposal through
-- ---------------------------------------------------------------------------
--
-- An auto-applied proposal resolves to plain 'approved' — the same terminal
-- state a manual tap produces — with auto_rule_id naming the rule that
-- stood in for the tap. The Auto approve tab's history is exactly the
-- proposals where this column is set. Owner-written only: the client stamps
-- it in the same update as the status flip, and the claude role holds no
-- grant on it.

alter table public.agent_map_proposals
    add column auto_rule_id uuid references public.auto_approve_rules (id) on delete set null;
alter table public.agent_todo_proposals
    add column auto_rule_id uuid references public.auto_approve_rules (id) on delete set null;

comment on column public.agent_map_proposals.auto_rule_id is
    'Set when this proposal was approved automatically under an auto_approve_rules row, by the owner''s own client. Null on manually resolved proposals.';
comment on column public.agent_todo_proposals.auto_rule_id is
    'Set when this proposal was approved automatically under an auto_approve_rules row, by the owner''s own client. Null on manually resolved proposals.';

grant update (auto_rule_id) on public.agent_map_proposals to authenticated;
grant update (auto_rule_id) on public.agent_todo_proposals to authenticated;

-- The Auto approve tab's history query.
create index agent_map_proposals_auto_rule_idx
    on public.agent_map_proposals (auto_rule_id) where auto_rule_id is not null;
create index agent_todo_proposals_auto_rule_idx
    on public.agent_todo_proposals (auto_rule_id) where auto_rule_id is not null;

-- ---------------------------------------------------------------------------
-- propose_auto_approve_rule — the routine's write path over HTTPS
-- ---------------------------------------------------------------------------
--
-- Same contract as the propose RPCs: gate on the Vault key, `set local role
-- claude`, one structured insert — arguments, never SQL. The column set is
-- stored sorted so identical categories always compare equal. A matching
-- rule already open (pending or approved) dedupes to the existing row; one
-- the owner denied or revoked in the last 90 days is an answer and refuses
-- outright; the pending backlog is capped low — rules should be rare.

create or replace function public.propose_auto_approve_rule(
    _profile_id   uuid,
    _queue        text,
    _kind         text,
    _columns      text[],
    _rationale    text,
    _target_id    uuid default null,
    _target_label text default null
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    cols     text[];
    existing record;
    result   jsonb;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    select array_agg(distinct c order by c) into cols from unnest(_columns) c;

    -- The same category, already answered no: a denial or revocation is an
    -- answer, not an invitation to re-ask.
    select id, status into existing
    from public.auto_approve_rules
    where profile_id = _profile_id
      and queue = _queue
      and kind = _kind
      and columns = cols
      and target_id is not distinct from _target_id
      and status in ('denied', 'revoked')
      and coalesce(revoked_at, resolved_at, created_at) >= now() - interval '90 days'
    limit 1;

    if existing.id is not null then
        raise exception 'a matching rule was % — that is an answer; do not re-ask', existing.status;
    end if;

    -- The same category, still open or already granted: hand it back.
    select id, status into existing
    from public.auto_approve_rules
    where profile_id = _profile_id
      and queue = _queue
      and kind = _kind
      and columns = cols
      and target_id is not distinct from _target_id
      and status in ('pending', 'approved')
    limit 1;

    if existing.id is not null then
        return jsonb_build_object('id', existing.id, 'status', existing.status,
                                  'duplicate', true);
    end if;

    if (select count(*) from public.auto_approve_rules
        where profile_id = _profile_id and status = 'pending') >= 3 then
        raise exception 'there are already 3 pending auto-approve requests — wait for the owner to answer them first';
    end if;

    insert into public.auto_approve_rules
        (profile_id, queue, kind, columns, target_id, target_label, rationale)
    values
        (_profile_id, _queue, _kind, cols, _target_id, _target_label, _rationale)
    returning jsonb_build_object('id', id, 'queue', queue, 'kind', kind,
                                 'columns', to_jsonb(columns), 'status', status)
    into result;

    return result;
end;
$$;

comment on function public.propose_auto_approve_rule(uuid, text, text, text[], text, uuid, text) is
    'Files one pending auto-approve rule request as the claude role — the daily routine''s path for asking whether a narrow category of edit proposal may auto-approve. Gated by assert_claude_rq_key(); refuses categories the owner denied or revoked in the last 90 days; dedupes against open rules; the pending backlog is capped at 3.';

revoke all on function public.propose_auto_approve_rule(uuid, text, text, text[], text, uuid, text) from public;
grant execute on function public.propose_auto_approve_rule(uuid, text, text, text[], text, uuid, text) to anon;
