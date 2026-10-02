-- Syla approvals: the generic Inbox card.
--
-- The Inbox is the approval surface — "Nothing Syla agrees to is final
-- until you approve it here." The structured queues that already exist
-- (agent_todo_proposals, agent_map_proposals, user_table_proposals,
-- chat_reply_proposals) each carry one shape of change; this table carries
-- the rest, the cards that are a judgment plus an optional payload:
--
--   * 'conclusion'      — an overnight Syla × Syla outcome to confirm
--                         ("Maya's Syla and I agree Friday 7pm works").
--                         Confirming usually means the owner approves a
--                         draft or lets an already-covered auto-reply
--                         stand; the conclusion itself changes nothing.
--   * 'calendar_add'    — payload carries the event fields; the OWNER'S
--                         client inserts the events row on approve.
--   * 'silo_membership' — Syla proposing a silo include/exclude change
--                         (silos are pure data slices — 20261128000000;
--                         a new synced source fails safe out of every
--                         silo, then asks here).
--   * 'other'           — a titled judgment with no payload.
--
-- House pattern throughout: the agent only ever inserts pending rows
-- (propose_approval, capped), and APPLYING is client-side as the owner —
-- the claude role gains no write on events, silos or anything else from
-- any of this.

create table public.syla_approvals (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null default public.current_profile_id()
                references public.profiles (id) on delete cascade,
    kind        text not null
                check (kind in ('conclusion', 'calendar_add', 'silo_membership', 'other')),
    chat_id     uuid references public.chats (id) on delete set null,
    follower_id uuid references public.followers (id) on delete set null,
    title       text not null check (char_length(title) between 1 and 200),
    detail      text check (detail is null or char_length(detail) <= 2000),
    -- calendar_add: {title, start_date, start_time, end_time}.
    -- silo_membership: {silo_id, action 'include'|'exclude', subject}.
    payload     jsonb check (payload is null or jsonb_typeof(payload) = 'object'),
    status      text not null default 'pending'
                check (status in ('pending', 'approved', 'dismissed')),
    created_at  timestamptz not null default now(),
    resolved_at timestamptz
);

comment on table public.syla_approvals is
    'The generic Inbox card: Syla × Syla conclusions, calendar adds, silo membership changes, and other judgments — pending until the owner rules. The agent inserts pending rows through propose_approval(); applying an approved card is the owner''s own client''s write (e.g. inserting the events row from a calendar_add payload), never the agent''s.';
comment on column public.syla_approvals.chat_id is
    'The conversation this card came out of, when one did — the Inbox links back to the thread.';
comment on column public.syla_approvals.follower_id is
    'The connection this card concerns, when one does (a conclusion names whose Syla agreed).';
comment on column public.syla_approvals.payload is
    'What approving applies, by kind — calendar_add: {title, start_date, start_time, end_time} for the events insert; silo_membership: {silo_id, action, subject}. The client applies nothing beyond its kind''s documented fields.';

create index syla_approvals_pending_idx
    on public.syla_approvals (profile_id, status, created_at);

alter table public.syla_approvals enable row level security;
select public.declare_table_siloing('syla_approvals', 'system');

create policy "Approvals are viewable by their owner"
    on public.syla_approvals for select to authenticated
    using (profile_id = (select public.current_profile_id()));
create policy "Approvals are resolvable by their owner"
    on public.syla_approvals for update to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));
create policy "Approvals are deletable by their owner"
    on public.syla_approvals for delete to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "claude reads approvals"
    on public.syla_approvals for select to claude using (true);
create policy "claude proposes approvals"
    on public.syla_approvals for insert to claude
    with check (status = 'pending');

grant select, delete on public.syla_approvals to authenticated;
grant update (status, resolved_at) on public.syla_approvals to authenticated;
grant select on public.syla_approvals to claude;
grant insert (profile_id, kind, chat_id, follower_id, title, detail, payload)
    on public.syla_approvals to claude;

-- ── The RPC ──────────────────────────────────────────────────────────────
--
-- Cards belong to the owner (this is a single-owner app; the agent session
-- carries no profile, so the RPC resolves it rather than trusting a
-- parameter). Capped at 30 pending, like the todo queue.

create function public.propose_approval(
    _kind        text,
    _title       text,
    _detail      text default null,
    _payload     jsonb default null,
    _chat_id     uuid default null,
    _follower_id uuid default null
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _profile uuid;
    _id      uuid;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    if _kind not in ('conclusion', 'calendar_add', 'silo_membership', 'other') then
        raise exception 'kind must be conclusion, calendar_add, silo_membership or other';
    end if;
    if _title is null or char_length(btrim(_title)) not between 1 and 200 then
        raise exception 'the title must be 1–200 characters';
    end if;
    if _detail is not null and char_length(_detail) > 2000 then
        raise exception 'the detail is longer than 2000 characters';
    end if;
    if _payload is not null and jsonb_typeof(_payload) <> 'object' then
        raise exception 'the payload must be a JSON object';
    end if;

    select id into _profile from public.profiles where is_owner;
    if _profile is null then
        raise exception 'this database has no owner yet';
    end if;

    if (select count(*) from public.syla_approvals
        where profile_id = _profile and status = 'pending') >= 30 then
        raise exception 'there are already 30 pending approvals — wait for the owner to resolve some first';
    end if;

    insert into public.syla_approvals
        (profile_id, kind, chat_id, follower_id, title, detail, payload)
    values
        (_profile, _kind, _chat_id, _follower_id, btrim(_title), _detail, _payload)
    returning id into _id;

    return jsonb_build_object('id', _id, 'kind', _kind, 'status', 'pending');
end;
$$;

comment on function public.propose_approval(text, text, text, jsonb, uuid, uuid) is
    'Files one pending Inbox card as the claude role — a Syla × Syla conclusion, a calendar add (payload = the events fields), a silo membership change, or another judgment. Applying is the owner''s client''s write on approve. Capped at 30 pending. Gated by assert_claude_rq_key().';

revoke all on function public.propose_approval(text, text, text, jsonb, uuid, uuid) from public;
grant execute on function public.propose_approval(text, text, text, jsonb, uuid, uuid) to anon;
