-- Proposal feedback: a third answer on agent edit proposals besides approve
-- and deny. The owner can now flag a proposal with free-text feedback
-- ("keep the cell, just rerank it", "make it weekly, not daily") — the row
-- moves to status 'changes_requested' and leaves the pending queue. The
-- edit-feedback skill then reads the flagged rows, revises each edit to
-- honor the feedback, and files the revision through the revise RPCs below,
-- which send the row back to 'pending' for a fresh review — or withdraw it
-- when the feedback reads as "drop the idea".
--
-- The trust story is unchanged. The claude role still never touches
-- mind_map_cells or todo: a revision only rewrites the *proposal*, and only
-- a proposal the owner explicitly flagged (RLS pins the update to
-- status = 'changes_requested'). The owner's feedback text itself stays
-- owner-only — the role holds no update grant on that column, so the words
-- being answered can never be rewritten by the agent answering them.

-- ---------------------------------------------------------------------------
-- Columns and statuses
-- ---------------------------------------------------------------------------

alter table public.agent_map_proposals
    add column feedback text
        check (feedback is null or char_length(feedback) between 1 and 2000);
alter table public.agent_todo_proposals
    add column feedback text
        check (feedback is null or char_length(feedback) between 1 and 2000);

comment on column public.agent_map_proposals.feedback is
    'The owner''s free-text change request on this proposal, written when they flag it (status changes_requested). Kept through the revision so a re-pending row shows what it was revised to answer. Owner-written only — the claude role cannot update it.';
comment on column public.agent_todo_proposals.feedback is
    'The owner''s free-text change request on this proposal, written when they flag it (status changes_requested). Kept through the revision so a re-pending row shows what it was revised to answer. Owner-written only — the claude role cannot update it.';

-- Two new statuses: changes_requested (owner flagged it; the feedback loop
-- owns it until revised) and withdrawn (the agent read the feedback as a
-- rejection and pulled the proposal itself).
alter table public.agent_map_proposals
    drop constraint agent_map_proposals_status_check;
alter table public.agent_map_proposals
    add constraint agent_map_proposals_status_check check
        (status in ('pending', 'approved', 'denied', 'changes_requested', 'withdrawn'));

alter table public.agent_todo_proposals
    drop constraint agent_todo_proposals_status_check;
alter table public.agent_todo_proposals
    add constraint agent_todo_proposals_status_check check
        (status in ('pending', 'approved', 'denied', 'changes_requested', 'withdrawn'));

-- The owner writes the feedback alongside the status flip; the existing
-- update policies already cover the row.
grant update (feedback) on public.agent_map_proposals to authenticated;
grant update (feedback) on public.agent_todo_proposals to authenticated;

-- ---------------------------------------------------------------------------
-- claude: may rewrite a proposal the owner flagged, and nothing else
-- ---------------------------------------------------------------------------
--
-- A revision restates the whole edit (kind, targets, snapshots, rationale)
-- and returns the row to pending; a withdrawal resolves it. Both are pinned
-- by RLS to rows sitting in changes_requested, so the role cannot touch a
-- pending, resolved, or withdrawn proposal — and the column list excludes
-- feedback, profile_id, source_day and created_at, which ride through the
-- revision untouched.

grant update (kind, cell_id, parent_id, goal_id, before, after,
              rationale, status, resolved_at)
    on public.agent_map_proposals to claude;
grant update (kind, todo_id, goal_id, before, after,
              rationale, status, resolved_at)
    on public.agent_todo_proposals to claude;

create policy "claude revises flagged proposals"
    on public.agent_map_proposals for update
    to claude
    using (status = 'changes_requested')
    with check (status in ('pending', 'withdrawn'));

create policy "claude revises flagged proposals"
    on public.agent_todo_proposals for update
    to claude
    using (status = 'changes_requested')
    with check (status in ('pending', 'withdrawn'));

-- ---------------------------------------------------------------------------
-- revise_map_edit / revise_todo_edit — the feedback loop's write path
-- ---------------------------------------------------------------------------
--
-- Same contract as the propose RPCs: gate on the Vault key, `set local role
-- claude`, one structured update — arguments, never SQL. A revision must
-- restate the full edit; passing --withdraw instead resolves the row as
-- withdrawn. Either way only a changes_requested row moves, so replaying a
-- call is a no-op error rather than a double-write.

create or replace function public.revise_map_edit(
    _id        uuid,
    _withdraw  boolean default false,
    _kind      text  default null,
    _rationale text  default null,
    _cell_id   uuid  default null,
    _parent_id uuid  default null,
    _goal_id   uuid  default null,
    _before    jsonb default null,
    _after     jsonb default null
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    result jsonb;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    if _withdraw then
        update public.agent_map_proposals
        set status = 'withdrawn', resolved_at = now()
        where id = _id and status = 'changes_requested'
        returning jsonb_build_object('id', id, 'status', status)
        into result;
    else
        if _kind is null or _rationale is null then
            raise exception 'a revision restates the whole edit — _kind and _rationale are required (or pass _withdraw)';
        end if;

        update public.agent_map_proposals
        set kind      = _kind,
            cell_id   = _cell_id,
            parent_id = _parent_id,
            goal_id   = _goal_id,
            before    = _before,
            after     = _after,
            rationale = _rationale,
            status    = 'pending'
        where id = _id and status = 'changes_requested'
        returning jsonb_build_object('id', id, 'kind', kind, 'status', status)
        into result;
    end if;

    if result is null then
        raise exception 'no map proposal % is awaiting changes', _id;
    end if;

    return result;
end;
$$;

comment on function public.revise_map_edit(uuid, boolean, text, text, uuid, uuid, uuid, jsonb, jsonb) is
    'Rewrites one changes_requested map proposal per the owner''s feedback — restating the whole edit and returning it to pending — or withdraws it. The claude role''s only update path on agent_map_proposals; gated by assert_claude_rq_key().';

revoke all on function public.revise_map_edit(uuid, boolean, text, text, uuid, uuid, uuid, jsonb, jsonb) from public;
grant execute on function public.revise_map_edit(uuid, boolean, text, text, uuid, uuid, uuid, jsonb, jsonb) to anon;

create or replace function public.revise_todo_edit(
    _id        uuid,
    _withdraw  boolean default false,
    _kind      text  default null,
    _rationale text  default null,
    _todo_id   uuid  default null,
    _goal_id   uuid  default null,
    _before    jsonb default null,
    _after     jsonb default null
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    result jsonb;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    if _withdraw then
        update public.agent_todo_proposals
        set status = 'withdrawn', resolved_at = now()
        where id = _id and status = 'changes_requested'
        returning jsonb_build_object('id', id, 'status', status)
        into result;
    else
        if _kind is null or _rationale is null then
            raise exception 'a revision restates the whole edit — _kind and _rationale are required (or pass _withdraw)';
        end if;

        update public.agent_todo_proposals
        set kind      = _kind,
            todo_id   = _todo_id,
            goal_id   = _goal_id,
            before    = _before,
            after     = _after,
            rationale = _rationale,
            status    = 'pending'
        where id = _id and status = 'changes_requested'
        returning jsonb_build_object('id', id, 'kind', kind, 'status', status)
        into result;
    end if;

    if result is null then
        raise exception 'no todo proposal % is awaiting changes', _id;
    end if;

    return result;
end;
$$;

comment on function public.revise_todo_edit(uuid, boolean, text, text, uuid, uuid, jsonb, jsonb) is
    'Rewrites one changes_requested todo proposal per the owner''s feedback — restating the whole edit and returning it to pending — or withdraws it. The claude role''s only update path on agent_todo_proposals; gated by assert_claude_rq_key().';

revoke all on function public.revise_todo_edit(uuid, boolean, text, text, uuid, uuid, jsonb, jsonb) from public;
grant execute on function public.revise_todo_edit(uuid, boolean, text, text, uuid, uuid, jsonb, jsonb) to anon;

-- ---------------------------------------------------------------------------
-- Widen the propose RPCs' dedupe to cover flagged rows
-- ---------------------------------------------------------------------------
--
-- An edit sitting in changes_requested is already in front of the owner —
-- the daily routine re-filing the identical edit would stack a pending twin
-- next to the flagged one. Same bodies as 20260904000000/20260904100000,
-- with the dedupe's status filter widened from 'pending' alone to
-- ('pending', 'changes_requested').

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
    existing record;
    result   jsonb;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    -- The same edit, still open (pending or flagged for changes): hand its
    -- id back rather than duplicate.
    select id, status into existing
    from public.agent_map_proposals
    where profile_id = _profile_id
      and status in ('pending', 'changes_requested')
      and kind = _kind
      and cell_id is not distinct from _cell_id
      and parent_id is not distinct from _parent_id
      and after is not distinct from _after
    limit 1;

    if existing.id is not null then
        return jsonb_build_object('id', existing.id, 'status', existing.status,
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
    existing record;
    result   jsonb;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    -- The same edit, still open (pending or flagged for changes): hand its
    -- id back rather than duplicate.
    select id, status into existing
    from public.agent_todo_proposals
    where profile_id = _profile_id
      and status in ('pending', 'changes_requested')
      and kind = _kind
      and todo_id is not distinct from _todo_id
      and after is not distinct from _after
    limit 1;

    if existing.id is not null then
        return jsonb_build_object('id', existing.id, 'status', existing.status,
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
