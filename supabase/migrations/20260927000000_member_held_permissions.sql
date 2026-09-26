-- Member-held permissions: the silo's toggles become defaults.
--
-- Until now the three request-kind toggles (allows_sql / allows_prompts /
-- allows_edits) lived on the silo, so everyone in a silo necessarily held
-- the same powers. Now each membership row carries its own copy of the
-- three flags: admitting a member stamps the silo's defaults onto their
-- silo_members row (a BEFORE INSERT trigger), and from then on the owner
-- can change that one person's permissions without touching the silo or
-- anyone else. The silo's own columns are renamed default_allows_* to say
-- what they now are — the template consulted at admit time only; flipping
-- a default never rewrites existing memberships.
--
-- Everything that used to read the silo's toggles now reads the
-- membership row: the member read policies on manual_notes and docs, and
-- the two submit RPCs. Existing rows are seeded from their silo's current
-- toggles, so on the day this applies every member can do exactly what
-- they could do yesterday.

-- ---------------------------------------------------------------------------
-- Memberships gain their own copy of the three flags
-- ---------------------------------------------------------------------------

alter table public.silo_members
    add column allows_sql     boolean,
    add column allows_prompts boolean,
    add column allows_edits   boolean;

update public.silo_members m
set allows_sql     = s.allows_sql,
    allows_prompts = s.allows_prompts,
    allows_edits   = s.allows_edits
from public.silos s
where s.id = m.silo_id;

alter table public.silo_members
    alter column allows_sql     set not null,
    alter column allows_prompts set not null,
    alter column allows_edits   set not null;

comment on table public.silo_members is
    'Which members belong to each silo, each row carrying that member''s own copy of the three request-kind permissions (seeded from the silo''s defaults on insert, then edited per person). Being in a silo with allows_sql on is what lets a member read its records; a member''s view is the union over their memberships.';

comment on column public.silo_members.allows_sql is
    'This member may read this silo''s records directly through member_rq. Seeded from the silo''s default_allows_sql when the membership is created; the owner''s per-person override afterwards.';
comment on column public.silo_members.allows_prompts is
    'This member may queue free-text prompts for the owner (member_prompt_requests). Seeded from the silo''s default_allows_prompts on insert, then per-person.';
comment on column public.silo_members.allows_edits is
    'This member may queue free-text edit proposals (member_edit_requests). Seeded from the silo''s default_allows_edits on insert, then per-person; members never write data directly.';

-- ---------------------------------------------------------------------------
-- The silo's toggles become defaults
-- ---------------------------------------------------------------------------
--
-- Column privileges follow a rename, so the owner's update grant and the
-- member's select grant from 20260926000000 carry over automatically.

alter table public.silos rename column allows_sql     to default_allows_sql;
alter table public.silos rename column allows_prompts to default_allows_prompts;
alter table public.silos rename column allows_edits   to default_allows_edits;

comment on column public.silos.default_allows_sql is
    'Default for new memberships: whether an admitted member may read this silo''s records through member_rq. Stamped onto the silo_members row at admit time; changing it later touches nobody already in.';
comment on column public.silos.default_allows_prompts is
    'Default for new memberships: whether an admitted member may queue free-text prompts. Stamped onto the silo_members row at admit time.';
comment on column public.silos.default_allows_edits is
    'Default for new memberships: whether an admitted member may queue free-text edit proposals. Stamped onto the silo_members row at admit time.';

-- The permissions a member holds are now on their own membership rows,
-- which they already read in full; the silo's defaults are the owner's
-- bookkeeping about future members, not part of any member's whoami.
revoke select (default_allows_sql, default_allows_prompts, default_allows_edits)
    on public.silos from member;

-- ---------------------------------------------------------------------------
-- Admitting a member stamps the defaults onto the new row
-- ---------------------------------------------------------------------------
--
-- NOT NULL is checked after BEFORE ROW triggers, so the plain
-- (member_id, silo_id) inserts every client already sends keep working;
-- an insert that names explicit flags wins over the defaults. Security
-- definer so the copy works whoever inserts, without needing a select
-- policy on silos for them.

create function public.silo_member_defaults()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    d record;
begin
    select default_allows_sql, default_allows_prompts, default_allows_edits
    into d
    from public.silos
    where id = new.silo_id;

    new.allows_sql     := coalesce(new.allows_sql,     d.default_allows_sql,     false);
    new.allows_prompts := coalesce(new.allows_prompts, d.default_allows_prompts, false);
    new.allows_edits   := coalesce(new.allows_edits,   d.default_allows_edits,   false);
    return new;
end;
$$;

comment on function public.silo_member_defaults() is
    'BEFORE INSERT on silo_members: fills any flag the insert left null with the silo''s default_allows_* value. The stamp that makes permissions member-held data.';

create trigger silo_members_defaults
    before insert on public.silo_members
    for each row execute function public.silo_member_defaults();

-- ---------------------------------------------------------------------------
-- The owner edits one membership's flags in place
-- ---------------------------------------------------------------------------

grant update (allows_sql, allows_prompts, allows_edits)
    on public.silo_members to authenticated;

create policy "Silo memberships are updatable by the owner"
    on public.silo_members for update
    to authenticated
    using (public.is_owner())
    with check (public.is_owner());

-- ---------------------------------------------------------------------------
-- Enforcement reads the membership row, not the silo
-- ---------------------------------------------------------------------------

drop policy "Members read notes in their silos or naming them" on public.manual_notes;

create policy "Members read notes in their silos or naming them"
    on public.manual_notes for select
    to member
    using (
        exists (
            select 1
            from public.note_silos j
            join public.silo_members sm on sm.silo_id = j.silo_id
            where j.note_id = manual_notes.id
              and sm.member_id = public.current_member_id()
              and sm.allows_sql
        )
        or exists (
            select 1 from public.note_members nm
            where nm.note_id = manual_notes.id
              and nm.member_id = public.current_member_id()
        )
    );

drop policy "Members read docs in their silos or naming them" on public.docs;

create policy "Members read docs in their silos or naming them"
    on public.docs for select
    to member
    using (
        exists (
            select 1
            from public.doc_silos j
            join public.silo_members sm on sm.silo_id = j.silo_id
            where j.doc_id = docs.id
              and sm.member_id = public.current_member_id()
              and sm.allows_sql
        )
        or exists (
            select 1 from public.doc_members dm
            where dm.doc_id = docs.id
              and dm.member_id = public.current_member_id()
        )
    );

-- The submit RPCs gate on the member's own rows now.

create or replace function public.member_submit_prompt(_token text, _prompt text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    mid uuid;
    rid uuid;
begin
    mid := public.authenticate_member(_token);

    if not exists (
        select 1
        from public.silo_members sm
        where sm.member_id = mid
          and sm.allows_prompts
    ) then
        raise exception 'none of your memberships allows prompt requests'
            using errcode = '42501';
    end if;

    if _prompt is null or btrim(_prompt) = '' then
        raise exception 'empty prompt';
    end if;
    if char_length(_prompt) > 4000 then
        raise exception 'prompt is longer than 4000 characters';
    end if;

    if (select count(*) from public.member_prompt_requests
        where member_id = mid and status = 'pending') >= 20 then
        raise exception 'you already have 20 pending requests — wait for answers first';
    end if;

    perform set_config('app.member_id', mid::text, true);

    insert into public.member_prompt_requests (member_id, prompt)
    values (mid, btrim(_prompt))
    returning id into rid;

    return jsonb_build_object('id', rid, 'status', 'pending');
end;
$$;

comment on function public.member_submit_prompt(text, text) is
    'Queues one free-text prompt for the owner, if any of the token''s member''s memberships allows prompts. Returns the request id; the member polls it back through member_rq.';

create or replace function public.member_submit_edit(_token text, _proposal text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    mid uuid;
    rid uuid;
begin
    mid := public.authenticate_member(_token);

    if not exists (
        select 1
        from public.silo_members sm
        where sm.member_id = mid
          and sm.allows_edits
    ) then
        raise exception 'none of your memberships allows edit proposals'
            using errcode = '42501';
    end if;

    if _proposal is null or btrim(_proposal) = '' then
        raise exception 'empty proposal';
    end if;
    if char_length(_proposal) > 4000 then
        raise exception 'proposal is longer than 4000 characters';
    end if;

    if (select count(*) from public.member_edit_requests
        where member_id = mid and status = 'pending') >= 20 then
        raise exception 'you already have 20 pending proposals — wait for them to be resolved first';
    end if;

    perform set_config('app.member_id', mid::text, true);

    insert into public.member_edit_requests (member_id, proposal)
    values (mid, btrim(_proposal))
    returning id into rid;

    return jsonb_build_object('id', rid, 'status', 'pending');
end;
$$;

comment on function public.member_submit_edit(text, text) is
    'Queues one free-text edit proposal for the owner, if any of the token''s member''s memberships allows edits. Returns the proposal id; the member polls it back through member_rq.';

comment on function public.member_rq(text, text) is
    'Runs one read-only SQL statement as the member role, scoped by the token''s member and the memberships whose allows_sql is on. Returns rows as a JSON array.';
