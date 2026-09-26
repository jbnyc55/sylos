-- The third request kind: propose edits.
--
-- Alongside allows_sql (query directly) and allows_prompts (queue a
-- question), a group can now allow its members to propose changes to the
-- data. Same shape as the prompt queue (20260901030000), same trust story:
-- the member never writes a row themselves — a proposal is free text that
-- lands in the owner's queue, the owner applies or declines it by their own
-- hand, and the member reads the outcome back through guest_rq. The write
-- stays entirely on the owner's side of the boundary.

-- ---------------------------------------------------------------------------
-- The toggle
-- ---------------------------------------------------------------------------

alter table public.guest_groups
    add column allows_edits boolean not null default false;

comment on column public.guest_groups.allows_edits is
    'Members may queue free-text edit proposals for the owner to apply or decline (guest_edit_requests). Off by default; the member never writes data directly.';

grant update (allows_edits) on public.guest_groups to authenticated;

-- Members may see the toggle on their own groups, like the other two.
grant select (allows_edits) on public.guest_groups to guest;

-- ---------------------------------------------------------------------------
-- guest_edit_requests — the proposal queue
-- ---------------------------------------------------------------------------

create table public.guest_edit_requests (
    id           uuid primary key default gen_random_uuid(),
    guest_id     uuid not null references public.guests (id) on delete cascade,
    proposal     text not null check (char_length(proposal) between 1 and 4000),
    status       text not null default 'pending'
                     check (status in ('pending', 'applied', 'declined')),
    -- Optional note back to the proposer: what was done, or why not.
    response     text check (char_length(response) <= 20000),
    created_at   timestamptz not null default now(),
    resolved_at  timestamptz
);

comment on table public.guest_edit_requests is
    'Free-text edit proposals queued by members whose groups allow them. The owner applies or declines each one personally; the member reads the outcome back through guest_rq. Proposals never write data by themselves.';

alter table public.guest_edit_requests enable row level security;

-- Owner: sees the queue, resolves proposals, prunes old rows.
grant select, delete on public.guest_edit_requests to authenticated;
grant update (status, response, resolved_at) on public.guest_edit_requests to authenticated;

create policy "Edit proposals are viewable by the owner"
    on public.guest_edit_requests for select
    to authenticated
    using (public.is_owner());

create policy "Edit proposals are resolvable by the owner"
    on public.guest_edit_requests for update
    to authenticated
    using (public.is_owner())
    with check (public.is_owner());

create policy "Edit proposals are deletable by the owner"
    on public.guest_edit_requests for delete
    to authenticated
    using (public.is_owner());

-- Member: reads their own proposals and outcomes — ungated whoami surface,
-- like prompt requests. Writing goes through guest_submit_edit only.
grant select on public.guest_edit_requests to guest;

create policy "A member reads their own edit proposals"
    on public.guest_edit_requests for select
    to guest
    using (guest_id = public.current_guest_id());

create policy "claude reads everything"
    on public.guest_edit_requests for select
    to claude
    using (true);

-- ---------------------------------------------------------------------------
-- guest_submit_edit — token in, queued proposal out
-- ---------------------------------------------------------------------------
--
-- Mirrors guest_submit_prompt: SECURITY DEFINER because the guest role
-- holds no insert grant — this function is the single gate. It
-- authenticates the token, requires an edit-allowing group, caps the
-- backlog, and stamps app.guest_id so row_edits attributes the insert to
-- the member.

create function public.guest_submit_edit(_token text, _proposal text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    gid uuid;
    rid uuid;
begin
    gid := public.authenticate_guest(_token);

    if not exists (
        select 1
        from public.guest_group_members m
        join public.guest_groups g on g.id = m.group_id
        where m.guest_id = gid
          and g.allows_edits
    ) then
        raise exception 'your groups do not accept edit proposals'
            using errcode = '42501';
    end if;

    if _proposal is null or btrim(_proposal) = '' then
        raise exception 'empty proposal';
    end if;
    if char_length(_proposal) > 4000 then
        raise exception 'proposal is longer than 4000 characters';
    end if;

    if (select count(*) from public.guest_edit_requests
        where guest_id = gid and status = 'pending') >= 20 then
        raise exception 'you already have 20 pending proposals — wait for them to be resolved first';
    end if;

    perform set_config('app.guest_id', gid::text, true);

    insert into public.guest_edit_requests (guest_id, proposal)
    values (gid, btrim(_proposal))
    returning id into rid;

    return jsonb_build_object('id', rid, 'status', 'pending');
end;
$$;

comment on function public.guest_submit_edit(text, text) is
    'Queues one free-text edit proposal for the owner, if any of the token''s member''s groups allows edits. Returns the proposal id; the member polls it back through guest_rq.';

revoke all on function public.guest_submit_edit(text, text) from public;
grant execute on function public.guest_submit_edit(text, text) to anon;
