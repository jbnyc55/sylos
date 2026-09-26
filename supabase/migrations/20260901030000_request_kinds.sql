-- What a group's setting decides: how its members may ask, not where bytes go.
--
-- 20260901020000 moved the local/cloud processing declaration onto guest
-- groups. This migration replaces that model with the question the owner is
-- actually answering per group: what KIND of request may these people make?
-- Two kinds exist, and a group toggles each independently:
--
--   * allows_sql      — members may run read-only SQL directly through
--                       guest_rq and get rows back, scoped by the group's
--                       tag filters as before.
--   * allows_prompts  — members may queue a free-text prompt for the owner,
--                       who runs it and hands back the output
--                       (guest_prompt_requests, new here).
--
-- A group may allow both, either, or neither; neither means the group can
-- ask nothing at all. Union semantics are unchanged: each group is judged
-- on its own, so a guest in a sql-allowing group and a prompt-only group
-- direct-queries only what the sql-allowing group can see. The tag
-- allow/deny filters stay exactly as they are and keep scoping what direct
-- SQL can read; a queued prompt is answered by the owner personally, so its
-- scope is the owner's judgment, not RLS.
--
-- The processing declaration goes away with its column: guest_rq loses the
-- required _processing argument (back to its original two-argument shape,
-- which scripts/guest-rq still speaks), and current_guest_processing() is
-- dropped with the policies that read it.

-- ---------------------------------------------------------------------------
-- The two toggles
-- ---------------------------------------------------------------------------

alter table public.guest_groups
    add column allows_sql     boolean not null default false,
    add column allows_prompts boolean not null default false;

comment on column public.guest_groups.allows_sql is
    'Members may run read-only SQL directly through guest_rq, scoped by the group''s tag filters. Off by default; a group allowing neither kind can ask nothing.';

comment on column public.guest_groups.allows_prompts is
    'Members may queue free-text prompts for the owner to run and answer (guest_prompt_requests). Off by default.';

-- Every existing group could direct-query before this migration; keep that
-- working. Prompts stay off until the owner opts a group in.
update public.guest_groups set allows_sql = true;

-- The owner flips both from the Guests tab; the update policy from
-- 20260901020000 already covers guest_groups updates.
grant update (allows_sql, allows_prompts) on public.guest_groups to authenticated;

-- Guests may see their groups' toggles, so a refusal is explainable.
grant select (allows_sql, allows_prompts) on public.guest_groups to guest;

-- ---------------------------------------------------------------------------
-- Direct SQL: only sql-allowing groups connect guest to record
-- ---------------------------------------------------------------------------
--
-- Same allow-minus-deny shape as before, with the group condition swapped:
-- where the policy checked the declared processing location it now checks
-- allows_sql. The whoami policies stay ungated on purpose — a guest can
-- always read their own row, groups, toggles and prompt requests, whatever
-- their groups allow — so a prompt-only guest can still fetch answers
-- through guest_rq; the shared data is what these two policies scope.
--
-- The old policies drop first: they reference allowed_processing, and the
-- column cannot go while they depend on it.

drop policy "Guests read notes their groups allow and none deny" on public.manual_notes;
drop policy "Guests read pages their groups allow and none deny" on public.wiki_pages;

create policy "Guests read notes their groups allow and none deny"
    on public.manual_notes for select
    to guest
    using (exists (
        select 1
        from public.guest_group_members m
        join public.guest_groups g on g.id = m.group_id
        where m.guest_id = public.current_guest_id()
          and g.allows_sql
          and exists (
              select 1
              from public.manual_note_types j
              join public.guest_group_tags a
                on a.note_type_id = j.note_type_id and a.group_id = m.group_id
              where j.note_id = manual_notes.id
          )
          and not public.note_denied_for_group(manual_notes.id, m.group_id)
    ));

create policy "Guests read pages their groups allow and none deny"
    on public.wiki_pages for select
    to guest
    using (exists (
        select 1
        from public.guest_group_members m
        join public.guest_groups g on g.id = m.group_id
        where m.guest_id = public.current_guest_id()
          and g.allows_sql
          and exists (
              select 1
              from public.wiki_page_types j
              join public.guest_group_tags a
                on a.note_type_id = j.note_type_id and a.group_id = m.group_id
              where j.page_id = wiki_pages.id
          )
          and not public.page_denied_for_group(wiki_pages.id, m.group_id)
    ));

-- ---------------------------------------------------------------------------
-- The processing declaration goes away
-- ---------------------------------------------------------------------------

-- Takes its check constraint and column-scoped grants with it.
alter table public.guest_groups
    drop column allowed_processing;

drop function public.current_guest_processing();

-- guest_rq returns to its original two-argument contract (20260830050000):
-- one read-only statement, no declaration. The three-argument form is
-- dropped so PostgREST resolves the name unambiguously.
drop function public.guest_rq(text, text, text);

create function public.guest_rq(_token text, q text)
returns jsonb
language plpgsql
security invoker
as $$
declare
    gid    uuid;
    result jsonb;
begin
    gid := public.authenticate_guest(_token);

    if q is null or btrim(q) = '' then
        raise exception 'empty query';
    end if;
    if btrim(q) like '%;' then
        raise exception 'send one statement without a trailing semicolon';
    end if;

    perform set_config('app.guest_id', gid::text, true);

    set local statement_timeout = '15s';
    set local role guest;
    set local transaction_read_only = on;

    execute format(
        'select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from (%s) t', q)
    into result;

    return result;
end;
$$;

comment on function public.guest_rq(text, text) is
    'Runs one read-only SQL statement as the guest role, scoped by the token''s guest and their sql-allowing groups. Returns rows as a JSON array.';

revoke all on function public.guest_rq(text, text) from public;
grant execute on function public.guest_rq(text, text) to anon;

-- ---------------------------------------------------------------------------
-- guest_prompt_requests — the queue for the other kind of request
-- ---------------------------------------------------------------------------

create table public.guest_prompt_requests (
    id           uuid primary key default gen_random_uuid(),
    guest_id     uuid not null references public.guests (id) on delete cascade,
    prompt       text not null check (char_length(prompt) between 1 and 4000),
    status       text not null default 'pending'
                     check (status in ('pending', 'answered', 'declined')),
    response     text check (char_length(response) <= 20000),
    created_at   timestamptz not null default now(),
    answered_at  timestamptz
);

comment on table public.guest_prompt_requests is
    'Free-text prompts queued by guests whose groups allow them. The owner runs each one and writes the output into response; guests read their own rows back through guest_rq.';

alter table public.guest_prompt_requests enable row level security;

-- Owner: sees the whole queue, answers or declines, prunes old rows.
grant select, delete on public.guest_prompt_requests to authenticated;
grant update (status, response, answered_at) on public.guest_prompt_requests to authenticated;

create policy "Prompt requests are viewable by the owner"
    on public.guest_prompt_requests for select
    to authenticated
    using (public.is_owner());

create policy "Prompt requests are answerable by the owner"
    on public.guest_prompt_requests for update
    to authenticated
    using (public.is_owner())
    with check (public.is_owner());

create policy "Prompt requests are deletable by the owner"
    on public.guest_prompt_requests for delete
    to authenticated
    using (public.is_owner());

-- Guest: reads their own requests and answers — part of the ungated whoami
-- surface, so a prompt-only guest can fetch responses through guest_rq.
-- Writing goes through guest_submit_prompt below, never directly.
grant select on public.guest_prompt_requests to guest;

create policy "A guest reads their own prompt requests"
    on public.guest_prompt_requests for select
    to guest
    using (guest_id = public.current_guest_id());

create policy "claude reads everything"
    on public.guest_prompt_requests for select
    to claude
    using (true);

-- ---------------------------------------------------------------------------
-- guest_submit_prompt — token in, queued prompt out
-- ---------------------------------------------------------------------------
--
-- A separate RPC rather than a write through guest_rq, which is read-only by
-- design and stays that way. SECURITY DEFINER because the guest role holds
-- no insert grant — this function is the single gate: it authenticates the
-- token, requires a prompt-allowing group, caps the backlog, and stamps
-- app.guest_id first so the row_edits log attributes the insert to the
-- guest.

create function public.guest_submit_prompt(_token text, _prompt text)
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
          and g.allows_prompts
    ) then
        raise exception 'your groups do not accept prompt requests'
            using errcode = '42501';
    end if;

    if _prompt is null or btrim(_prompt) = '' then
        raise exception 'empty prompt';
    end if;
    if char_length(_prompt) > 4000 then
        raise exception 'prompt is longer than 4000 characters';
    end if;

    if (select count(*) from public.guest_prompt_requests
        where guest_id = gid and status = 'pending') >= 20 then
        raise exception 'you already have 20 pending requests — wait for answers first';
    end if;

    perform set_config('app.guest_id', gid::text, true);

    insert into public.guest_prompt_requests (guest_id, prompt)
    values (gid, btrim(_prompt))
    returning id into rid;

    return jsonb_build_object('id', rid, 'status', 'pending');
end;
$$;

comment on function public.guest_submit_prompt(text, text) is
    'Queues one free-text prompt for the owner, if any of the token''s guest''s groups allows prompts. Returns the request id; the guest polls it back through guest_rq.';

revoke all on function public.guest_submit_prompt(text, text) from public;
grant execute on function public.guest_submit_prompt(text, text) to anon;
