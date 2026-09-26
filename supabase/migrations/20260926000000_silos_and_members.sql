-- Silos and members: the tag era ends.
--
-- The app's sharing vocabulary had three nouns — tags (note_types), member
-- groups (guest_groups) and members (guests) — and two rulebooks: junction
-- rows said what a record was about, and each group's allow/deny tag lists
-- plus per-doc grants decided who could read it. This migration collapses
-- all of that to two nouns:
--
--   * A SILO is a named container. Rows go into silos (note_silos,
--     doc_silos — where tag junctions used to be), members belong to silos
--     (silo_members), and the silo carries the request-kind toggles the
--     groups used to hold (allows_sql / allows_prompts / allows_edits). One
--     concept does the work of tags AND groups: a silo with no members is a
--     private category; a silo with members is a shared space.
--   * A MEMBER is a person (the renamed guests): invited by email, holding
--     a personal key. A row can also name members directly (doc_members,
--     note_members) — the individual exception that needs no silo.
--
-- Visibility becomes one sentence: a member reads a record when they share
-- a silo with it (and the silo allows SQL), or when the record names them.
-- The allow-minus-deny machinery goes away; what it used to COMPUTE is
-- materialized here once as silo placements, so on the day this applies
-- every member sees exactly what they saw yesterday:
--
--   * Every tag becomes a silo of the same name (ids kept — the tag
--     junctions survive as the silo junctions).
--   * Every group becomes a silo too (merging into the same-named tag-silo
--     when one exists), keeping its members and toggles.
--   * A record lands in a group's silo exactly when the old rule let that
--     group see it: it carried an allowed tag and no denied one. Per-doc
--     group grants (doc_guest_groups) become doc→silo placements the same
--     way, deny still winning at conversion time.
--
-- After conversion, deny has no lever — take a record out of a silo
-- instead. Direct person grants (doc_guests → doc_members) are untouched
-- and jots gain the same power (note_members).
--
-- The guest role, its GUC and its RPCs are renamed to member (the product
-- has said "member" for a while; now the database agrees). Every *_rq /
-- claim / submit entry point keeps a thin wrapper under its old name so
-- keys and commands already in the wild keep working. row_edits history is
-- append-only by contract, so old rows keep the old table names — readers
-- match both, as they have since the wiki→docs rename.

-- ---------------------------------------------------------------------------
-- Tags become silos, and absorb the groups
-- ---------------------------------------------------------------------------

alter table public.note_types rename to silos;

alter table public.silos
    add column allows_sql     boolean not null default false,
    add column allows_prompts boolean not null default false,
    add column allows_edits   boolean not null default false;

comment on table public.silos is
    'The app''s containers: rows are placed in silos (note_silos, doc_silos), members belong to silos (silo_members), and a member may read what shares a silo with them. A silo with no members is a private category.';

comment on column public.silos.allows_sql is
    'Members of this silo may read its records directly through member_rq. Off by default; a silo allowing nothing is organization only.';
comment on column public.silos.allows_prompts is
    'Members of this silo may queue free-text prompts for the owner (member_prompt_requests). Off by default.';
comment on column public.silos.allows_edits is
    'Members of this silo may queue free-text edit proposals (member_edit_requests). Off by default; members never write data directly.';

alter table public.silos rename constraint note_types_pkey to silos_pkey;
alter table public.silos rename constraint note_types_name_key to silos_name_key;
alter table public.silos rename constraint note_types_name_check to silos_name_check;
alter trigger note_types_log_edits on public.silos rename to silos_log_edits;

-- Where each group's identity ends up: the same-named silo when a tag
-- already used the name, else the group's own id carried over.
create temporary table _group_silo on commit drop as
select g.id as group_id, coalesce(s.id, g.id) as silo_id
from public.guest_groups g
left join public.silos s on s.name = g.name;

-- Groups sharing a tag's name merge into that silo, bringing their toggles.
update public.silos s
set allows_sql     = g.allows_sql,
    allows_prompts = g.allows_prompts,
    allows_edits   = g.allows_edits
from public.guest_groups g
where g.name = s.name;

-- The rest arrive as new silos under their old ids, so the membership
-- junction below only needs remapping for the merged ones.
insert into public.silos (id, name, allows_sql, allows_prompts, allows_edits, created_at)
select g.id, g.name, g.allows_sql, g.allows_prompts, g.allows_edits, g.created_at
from public.guest_groups g
where not exists (select 1 from public.silos s where s.name = g.name);

-- ---------------------------------------------------------------------------
-- Guests become members; memberships move from groups to silos
-- ---------------------------------------------------------------------------

alter table public.guests rename to members;
alter table public.members rename constraint guests_pkey to members_pkey;
alter table public.members rename constraint guests_email_key to members_email_key;
alter trigger guests_log_edits on public.members rename to members_log_edits;

comment on table public.members is
    'People invited to read shared records through member_rq. Tokens are issued by claim_member_token after email proof and live only as sha256 hashes; null token_hash means no access.';

alter table public.guest_group_members rename to silo_members;
alter table public.silo_members rename column guest_id to member_id;
alter table public.silo_members rename column group_id to silo_id;
alter table public.silo_members
    rename constraint guest_group_members_pkey to silo_members_pkey;
alter table public.silo_members
    rename constraint guest_group_members_guest_id_fkey to silo_members_member_id_fkey;
alter trigger guest_group_members_log_edits on public.silo_members
    rename to silo_members_log_edits;

-- Repoint memberships at the merged silos: drop the FK into guest_groups,
-- remap merged ids, and re-anchor on silos.
alter table public.silo_members
    drop constraint guest_group_members_group_id_fkey;

update public.silo_members m
set silo_id = map.silo_id
from _group_silo map
where map.group_id = m.silo_id
  and map.silo_id <> m.silo_id;

alter table public.silo_members
    add constraint silo_members_silo_id_fkey
    foreign key (silo_id) references public.silos (id) on delete cascade;

comment on table public.silo_members is
    'Which members belong to each silo. Being in a silo is what lets a member read its records (when the silo allows SQL); a member''s view is the union over their silos.';

-- ---------------------------------------------------------------------------
-- The row↔silo junctions (the old tag junctions, renamed)
-- ---------------------------------------------------------------------------

alter table public.manual_note_types rename to note_silos;
alter table public.note_silos rename column note_type_id to silo_id;
alter table public.note_silos
    rename constraint manual_note_types_pkey to note_silos_pkey;
alter table public.note_silos
    rename constraint manual_note_types_note_id_fkey to note_silos_note_id_fkey;
alter table public.note_silos
    rename constraint manual_note_types_note_type_id_fkey to note_silos_silo_id_fkey;
alter index public.manual_note_types_type_note_idx rename to note_silos_silo_note_idx;
alter trigger manual_note_types_log_edits on public.note_silos
    rename to note_silos_log_edits;

comment on table public.note_silos is
    'Which silos each jot sits in. Both foreign keys in the primary key is what lets PostgREST embed the many-to-many; placement is also what members'' visibility hangs off.';

alter table public.doc_note_types rename to doc_silos;
alter table public.doc_silos rename column note_type_id to silo_id;
alter table public.doc_silos rename constraint doc_note_types_pkey to doc_silos_pkey;
alter table public.doc_silos
    rename constraint doc_note_types_doc_id_note_type_id_key to doc_silos_doc_id_silo_id_key;
alter table public.doc_silos
    rename constraint doc_note_types_doc_id_fkey to doc_silos_doc_id_fkey;
alter table public.doc_silos
    rename constraint doc_note_types_note_type_id_fkey to doc_silos_silo_id_fkey;
alter index public.doc_note_types_type_doc_idx rename to doc_silos_silo_doc_idx;
alter trigger doc_note_types_log_edits on public.doc_silos
    rename to doc_silos_log_edits;

comment on table public.doc_silos is
    'Which silos each doc sits in. Placement organizes the docs and decides member visibility. Changes land in row_edits by the auto-attached trigger.';

-- The vetting stamp follows the vocabulary it vets against.
alter table public.manual_notes rename column tags_vetted_at to silos_vetted_at;

comment on column public.manual_notes.silos_vetted_at is
    'When the siloing routine last read this jot against the silo vocabulary. Stale when null or older than max(silos.created_at); set even when no silo fit.';

-- ---------------------------------------------------------------------------
-- Direct member grants: doc_guests renamed, and jots gain the same
-- ---------------------------------------------------------------------------

alter table public.doc_guests rename to doc_members;
alter table public.doc_members rename column guest_id to member_id;
alter table public.doc_members rename constraint doc_guests_pkey to doc_members_pkey;
alter table public.doc_members
    rename constraint doc_guests_doc_id_guest_id_key to doc_members_doc_id_member_id_key;
alter table public.doc_members
    rename constraint doc_guests_doc_id_fkey to doc_members_doc_id_fkey;
alter table public.doc_members
    rename constraint doc_guests_guest_id_fkey to doc_members_member_id_fkey;
alter index public.doc_guests_guest_doc_idx rename to doc_members_member_doc_idx;
alter trigger doc_guests_log_edits on public.doc_members
    rename to doc_members_log_edits;

comment on table public.doc_members is
    'Members named directly on a doc. A listed member reads the doc whatever the silo placements say — the owner''s explicit per-person grant. Changes land in row_edits by the auto-attached trigger.';

-- Jots get the twin junction: every row can relate to members as well.
-- The event trigger from 20260831010000 attaches row_edits logging here
-- the moment the table exists.
create table public.note_members (
    id         uuid primary key default gen_random_uuid(),
    note_id    uuid not null references public.manual_notes (id) on delete cascade,
    member_id  uuid not null references public.members (id) on delete cascade,
    unique (note_id, member_id)
);

comment on table public.note_members is
    'Members named directly on a jot — the per-person grant, like doc_members for docs. Changes land in row_edits by the auto-attached trigger.';

create index note_members_member_note_idx
    on public.note_members (member_id, note_id);

alter table public.note_members enable row level security;

-- ---------------------------------------------------------------------------
-- The request queues follow their people
-- ---------------------------------------------------------------------------

alter table public.guest_prompt_requests rename to member_prompt_requests;
alter table public.member_prompt_requests rename column guest_id to member_id;
alter table public.member_prompt_requests
    rename constraint guest_prompt_requests_pkey to member_prompt_requests_pkey;
alter table public.member_prompt_requests
    rename constraint guest_prompt_requests_guest_id_fkey to member_prompt_requests_member_id_fkey;
alter trigger guest_prompt_requests_log_edits on public.member_prompt_requests
    rename to member_prompt_requests_log_edits;

comment on table public.member_prompt_requests is
    'Free-text prompts queued by members whose silos allow them. The owner runs each one and writes the output into response; members read their own rows back through member_rq.';

alter table public.guest_edit_requests rename to member_edit_requests;
alter table public.member_edit_requests rename column guest_id to member_id;
alter table public.member_edit_requests
    rename constraint guest_edit_requests_pkey to member_edit_requests_pkey;
alter table public.member_edit_requests
    rename constraint guest_edit_requests_guest_id_fkey to member_edit_requests_member_id_fkey;
alter trigger guest_edit_requests_log_edits on public.member_edit_requests
    rename to member_edit_requests_log_edits;

comment on table public.member_edit_requests is
    'Free-text edit proposals queued by members whose silos allow them. The owner applies or declines each one personally; members read the outcome back through member_rq. Proposals never write data by themselves.';

-- ---------------------------------------------------------------------------
-- Materialize yesterday's visibility as today's placements
-- ---------------------------------------------------------------------------
--
-- The old rule, per record and group: visible when the record carried at
-- least one allowed tag and none of the denied ones. Wherever that was true
-- the record now simply sits in the group's silo. (note_silos still holds
-- exactly the old tag links at this point, so the tag joins below read
-- through it under its new name.)

insert into public.note_silos (note_id, silo_id)
select distinct j.note_id, map.silo_id
from public.note_silos j
join public.guest_group_tags a on a.note_type_id = j.silo_id
join _group_silo map on map.group_id = a.group_id
where not exists (
    select 1
    from public.note_silos j2
    join public.guest_group_denied_tags d
      on d.note_type_id = j2.silo_id and d.group_id = a.group_id
    where j2.note_id = j.note_id
)
on conflict do nothing;

insert into public.doc_silos (doc_id, silo_id)
select distinct j.doc_id, map.silo_id
from public.doc_silos j
join public.guest_group_tags a on a.note_type_id = j.silo_id
join _group_silo map on map.group_id = a.group_id
where not exists (
    select 1
    from public.doc_silos j2
    join public.guest_group_denied_tags d
      on d.note_type_id = j2.silo_id and d.group_id = a.group_id
    where j2.doc_id = j.doc_id
)
on conflict do nothing;

-- Per-doc group grants become placements too — deny still wins one last
-- time, exactly as the old docs policy applied it to direct group grants.
insert into public.doc_silos (doc_id, silo_id)
select dgg.doc_id, map.silo_id
from public.doc_guest_groups dgg
join _group_silo map on map.group_id = dgg.group_id
where not exists (
    select 1
    from public.doc_silos j
    join public.guest_group_denied_tags d
      on d.note_type_id = j.silo_id and d.group_id = dgg.group_id
    where j.doc_id = dgg.doc_id
)
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Tear down the old rulebook
-- ---------------------------------------------------------------------------
--
-- Policies drop before the tables and functions they read; the guest-role
-- policies that survive in spirit are recreated below on the new names.

drop policy "Guests read notes their groups allow and none deny" on public.manual_notes;
drop policy "Guests read docs granted by tag, name, or group" on public.docs;
drop policy "Guests read tag links in their groups" on public.note_silos;
drop policy "Guests read doc tag links in their groups" on public.doc_silos;
drop policy "Guests read their groups' types" on public.silos;
drop policy "A guest reads their own row" on public.members;
drop policy "A guest reads their own memberships" on public.silo_members;
drop policy "A guest reads their own doc grants" on public.doc_members;
drop policy "A guest reads their own prompt requests" on public.member_prompt_requests;
drop policy "A member reads their own edit proposals" on public.member_edit_requests;

drop function public.note_denied_for_group(uuid, uuid);
drop function public.doc_denied_for_group(uuid, uuid);

drop table public.doc_guest_groups;
drop table public.guest_group_tags;
drop table public.guest_group_denied_tags;
drop table public.guest_groups;

-- ---------------------------------------------------------------------------
-- The role, the GUC, and the identity helpers
-- ---------------------------------------------------------------------------

alter role guest rename to member;

drop function public.current_guest_id();

create function public.current_member_id()
returns uuid
language sql
stable
as $$
    select nullif(current_setting('app.member_id', true), '')::uuid
$$;

comment on function public.current_member_id() is
    'The member id member_rq stamped on this transaction, or null. Member RLS policies scope through this.';

-- current_actor_id reads the renamed GUC; contract otherwise unchanged.
create or replace function public.current_actor_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
    select coalesce(
        nullif(current_setting('app.member_id', true), '')::uuid,
        auth.uid()
    )
$$;

comment on function public.current_actor_id() is
    'The specific actor behind current_user: the member (app.member_id, set by member_rq and the submit RPCs) or the signed-in user (auth.uid()). Null when the role itself is the whole identity, e.g. the claude role until per-agent ids exist. Security definer only so roles without auth-schema access can be logged.';

-- ---------------------------------------------------------------------------
-- The member entry points (old names kept as thin wrappers)
-- ---------------------------------------------------------------------------

drop function public.guest_rq(text, text);
drop function public.guest_submit_prompt(text, text);
drop function public.guest_submit_edit(text, text);
drop function public.authenticate_guest(text);
drop function public.claim_guest_token();

create function public.authenticate_member(_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    m record;
begin
    if _token is null or char_length(_token) < 32 then
        raise exception 'missing or malformed member token' using errcode = '28000';
    end if;

    select id, claimed_at, token_ttl_days, blocked into m
    from public.members
    where token_hash = encode(extensions.digest(_token, 'sha256'), 'hex');

    if m.id is null then
        raise exception 'invalid member token' using errcode = '28000';
    end if;

    if m.blocked then
        raise exception 'member access is blocked' using errcode = '28000';
    end if;

    if m.token_ttl_days is not null
       and m.claimed_at is not null
       and m.claimed_at + make_interval(days => m.token_ttl_days) <= now() then
        raise exception 'member token expired — verify your email again to claim a fresh key'
            using errcode = '28000';
    end if;

    update public.members set last_seen_at = now() where id = m.id;

    return m.id;
end;
$$;

comment on function public.authenticate_member(text) is
    'Resolves a member bearer token to the member id, enforcing block and expiry and touching last_seen_at. Raises 28000 on any mismatch.';

revoke all on function public.authenticate_member(text) from public;
grant execute on function public.authenticate_member(text) to anon;

create function public.claim_member_token()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    em  text := lower(coalesce((select auth.email()), ''));
    mid uuid;
    tok text;
begin
    if em = '' then
        raise exception 'no verified email on this session' using errcode = '28000';
    end if;

    select id into mid from public.members where lower(email) = em;
    if mid is null then
        raise exception 'this email has not been invited' using errcode = '28000';
    end if;

    tok := encode(extensions.gen_random_bytes(32), 'hex');

    update public.members
    set token_hash = encode(extensions.digest(tok, 'sha256'), 'hex'),
        claimed_at = now()
    where id = mid;

    return jsonb_build_object('token', tok, 'member_id', mid);
end;
$$;

comment on function public.claim_member_token() is
    'Issues (or rotates) the calling session''s member key, matching on its verified email. The returned token is shown once and stored only as a hash.';

revoke all on function public.claim_member_token() from public;
grant execute on function public.claim_member_token() to authenticated;

create function public.member_rq(_token text, q text)
returns jsonb
language plpgsql
security invoker
as $$
declare
    mid    uuid;
    result jsonb;
begin
    mid := public.authenticate_member(_token);

    if q is null or btrim(q) = '' then
        raise exception 'empty query';
    end if;
    if btrim(q) like '%;' then
        raise exception 'send one statement without a trailing semicolon';
    end if;

    perform set_config('app.member_id', mid::text, true);

    set local statement_timeout = '15s';
    set local role member;
    set local transaction_read_only = on;

    execute format(
        'select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from (%s) t', q)
    into result;

    return result;
end;
$$;

comment on function public.member_rq(text, text) is
    'Runs one read-only SQL statement as the member role, scoped by the token''s member and their sql-allowing silos. Returns rows as a JSON array.';

revoke all on function public.member_rq(text, text) from public;
grant execute on function public.member_rq(text, text) to anon;

create function public.member_submit_prompt(_token text, _prompt text)
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
        join public.silos s on s.id = sm.silo_id
        where sm.member_id = mid
          and s.allows_prompts
    ) then
        raise exception 'your silos do not accept prompt requests'
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
    'Queues one free-text prompt for the owner, if any of the token''s member''s silos allows prompts. Returns the request id; the member polls it back through member_rq.';

revoke all on function public.member_submit_prompt(text, text) from public;
grant execute on function public.member_submit_prompt(text, text) to anon;

create function public.member_submit_edit(_token text, _proposal text)
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
        join public.silos s on s.id = sm.silo_id
        where sm.member_id = mid
          and s.allows_edits
    ) then
        raise exception 'your silos do not accept edit proposals'
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
    'Queues one free-text edit proposal for the owner, if any of the token''s member''s silos allows edits. Returns the proposal id; the member polls it back through member_rq.';

revoke all on function public.member_submit_edit(text, text) from public;
grant execute on function public.member_submit_edit(text, text) to anon;

-- Wrappers: keys and commands already in the wild keep working. Same
-- grants as the functions they forward to.

create function public.guest_rq(_token text, q text)
returns jsonb
language sql
security invoker
as $$ select public.member_rq(_token, q) $$;

comment on function public.guest_rq(text, text) is
    'Deprecated name — forwards to member_rq.';

revoke all on function public.guest_rq(text, text) from public;
grant execute on function public.guest_rq(text, text) to anon;

create function public.guest_submit_prompt(_token text, _prompt text)
returns jsonb
language sql
security invoker
as $$ select public.member_submit_prompt(_token, _prompt) $$;

comment on function public.guest_submit_prompt(text, text) is
    'Deprecated name — forwards to member_submit_prompt.';

revoke all on function public.guest_submit_prompt(text, text) from public;
grant execute on function public.guest_submit_prompt(text, text) to anon;

create function public.guest_submit_edit(_token text, _proposal text)
returns jsonb
language sql
security invoker
as $$ select public.member_submit_edit(_token, _proposal) $$;

comment on function public.guest_submit_edit(text, text) is
    'Deprecated name — forwards to member_submit_edit.';

revoke all on function public.guest_submit_edit(text, text) from public;
grant execute on function public.guest_submit_edit(text, text) to anon;

create function public.claim_guest_token()
returns jsonb
language sql
security invoker
as $$ select public.claim_member_token() $$;

comment on function public.claim_guest_token() is
    'Deprecated name — forwards to claim_member_token.';

revoke all on function public.claim_guest_token() from public;
grant execute on function public.claim_guest_token() to authenticated;

-- ---------------------------------------------------------------------------
-- The claude role's write RPCs: tagging becomes siloing
-- ---------------------------------------------------------------------------

drop function public.tag_note(uuid, uuid[]);
drop function public.tag_doc(text, uuid[]);

create function public.set_note_silos(_note_id uuid, _silo_ids uuid[])
returns jsonb
language plpgsql
security invoker
as $$
declare
    removed integer;
    added   integer;
begin
    perform public.assert_claude_rq_key();

    if _silo_ids is null then
        raise exception 'silo_ids must be an array (possibly empty), not null';
    end if;

    set local statement_timeout = '30s';
    set local role claude;

    if not exists (select 1 from public.manual_notes where id = _note_id) then
        raise exception 'no such note: %', _note_id;
    end if;

    delete from public.note_silos
    where note_id = _note_id
      and silo_id <> all (_silo_ids);
    get diagnostics removed = row_count;

    insert into public.note_silos (note_id, silo_id)
    select _note_id, unnest(_silo_ids)
    on conflict do nothing;
    get diagnostics added = row_count;

    update public.manual_notes
    set silos_vetted_at = now()
    where id = _note_id;

    return jsonb_build_object(
        'note_id', _note_id,
        'silos',   coalesce(array_length(_silo_ids, 1), 0),
        'added',   added,
        'removed', removed
    );
end;
$$;

comment on function public.set_note_silos(uuid, uuid[]) is
    'Sets one jot''s silo set and stamps silos_vetted_at, as the claude role. Gated by assert_claude_rq_key().';

revoke all on function public.set_note_silos(uuid, uuid[]) from public;
grant execute on function public.set_note_silos(uuid, uuid[]) to anon;

create function public.set_doc_silos(_path text, _silo_ids uuid[])
returns jsonb
language plpgsql
security invoker
as $$
declare
    _doc_id uuid;
    removed integer;
    added   integer;
begin
    perform public.assert_claude_rq_key();

    if _silo_ids is null then
        raise exception 'silo_ids must be an array (possibly empty), not null';
    end if;

    set local statement_timeout = '30s';
    set local role claude;

    select id into _doc_id from public.docs where path = _path;
    if _doc_id is null then
        raise exception 'no doc at %', _path;
    end if;

    delete from public.doc_silos
    where doc_id = _doc_id
      and silo_id <> all (_silo_ids);
    get diagnostics removed = row_count;

    insert into public.doc_silos (doc_id, silo_id)
    select _doc_id, unnest(_silo_ids)
    on conflict do nothing;
    get diagnostics added = row_count;

    return jsonb_build_object(
        'doc_id',  _doc_id,
        'path',    _path,
        'silos',   coalesce(array_length(_silo_ids, 1), 0),
        'added',   added,
        'removed', removed
    );
end;
$$;

comment on function public.set_doc_silos(text, uuid[]) is
    'Sets one doc''s silo set to exactly the given silos, as the claude role. Gated by assert_claude_rq_key().';

revoke all on function public.set_doc_silos(text, uuid[]) from public;
grant execute on function public.set_doc_silos(text, uuid[]) to anon;

-- Old names forward, so instruction docs written before this migration
-- keep working until they're reworded.
create function public.tag_note(_note_id uuid, _type_ids uuid[])
returns jsonb
language sql
security invoker
as $$ select public.set_note_silos(_note_id, _type_ids) $$;

comment on function public.tag_note(uuid, uuid[]) is
    'Deprecated name — forwards to set_note_silos.';

revoke all on function public.tag_note(uuid, uuid[]) from public;
grant execute on function public.tag_note(uuid, uuid[]) to anon;

create function public.tag_doc(_path text, _type_ids uuid[])
returns jsonb
language sql
security invoker
as $$ select public.set_doc_silos(_path, _type_ids) $$;

comment on function public.tag_doc(text, uuid[]) is
    'Deprecated name — forwards to set_doc_silos.';

revoke all on function public.tag_doc(text, uuid[]) from public;
grant execute on function public.tag_doc(text, uuid[]) to anon;

-- split_note keeps its name; the body speaks the new table names and each
-- sub-note names its silos as "silo_ids" ("type_ids" still accepted, so
-- instruction docs written before this migration keep working).
create or replace function public.split_note(_note_id uuid, _subnotes jsonb)
returns jsonb
language plpgsql
security invoker
as $$
declare
    parent   record;
    sub      record;
    sub_ids  jsonb;
    new_id   uuid;
    ids      uuid[] := '{}';
begin
    perform public.assert_claude_rq_key();

    if _subnotes is null or jsonb_typeof(_subnotes) <> 'array' then
        raise exception 'subnotes must be a JSON array';
    end if;
    if jsonb_array_length(_subnotes) = 1 then
        raise exception 'a split needs at least two sub-notes; send [] to record that none was possible';
    end if;

    set local statement_timeout = '30s';
    set local role claude;

    select id, profile_id, created_at, parent_note_id
    into parent
    from public.manual_notes
    where id = _note_id;

    if parent.id is null then
        raise exception 'no such note: %', _note_id;
    end if;

    if jsonb_array_length(_subnotes) > 0 then
        -- Splits never chain and never stack: a sub-note stays a leaf, and a
        -- parent that has been split is finished.
        if parent.parent_note_id is not null then
            raise exception 'refusing to split a sub-note: %', _note_id;
        end if;
        if exists (select 1 from public.manual_notes where parent_note_id = _note_id) then
            raise exception 'note % already has sub-notes', _note_id;
        end if;

        for sub in select value from jsonb_array_elements(_subnotes) loop
            sub_ids := coalesce(sub.value -> 'silo_ids', sub.value -> 'type_ids');
            if jsonb_typeof(sub.value -> 'body') <> 'string'
               or jsonb_typeof(sub_ids) <> 'array'
               or jsonb_array_length(sub_ids) < 1 then
                raise exception 'each sub-note needs a "body" string and a non-empty "silo_ids" array';
            end if;

            insert into public.manual_notes
                (profile_id, body, parent_note_id, created_at, silos_vetted_at)
            values
                (parent.profile_id, sub.value ->> 'body', _note_id, parent.created_at, now())
            returning id into new_id;

            insert into public.note_silos (note_id, silo_id)
            select new_id, t.value::uuid
            from jsonb_array_elements_text(sub_ids) t;

            ids := ids || new_id;
        end loop;
    end if;

    update public.manual_notes
    set split_attempted_at = now()
    where id = _note_id;

    return jsonb_build_object(
        'note_id',      _note_id,
        'created',      coalesce(array_length(ids, 1), 0),
        'sub_note_ids', to_jsonb(ids)
    );
end;
$$;

comment on function public.split_note(uuid, jsonb) is
    'Splits one multi-silo jot into siloed sub-notes (or records that no split was possible), as the claude role. Gated by assert_claude_rq_key().';

-- ---------------------------------------------------------------------------
-- Policy names follow the tables they belong to
-- ---------------------------------------------------------------------------

alter policy "Note types are viewable by signed-in users" on public.silos
    rename to "Silos are viewable by the owner";
alter policy "Note types are insertable by signed-in users" on public.silos
    rename to "Silos are insertable by the owner";
alter policy "Note types are updatable by signed-in users" on public.silos
    rename to "Silos are updatable by the owner";

alter policy "Guests are viewable by the owner" on public.members
    rename to "Members are viewable by the owner";
alter policy "Guests are insertable by the owner" on public.members
    rename to "Members are insertable by the owner";
alter policy "Guests are updatable by the owner" on public.members
    rename to "Members are updatable by the owner";
alter policy "Guests are deletable by the owner" on public.members
    rename to "Members are deletable by the owner";

alter policy "Group members are viewable by the owner" on public.silo_members
    rename to "Silo memberships are viewable by the owner";
alter policy "Group members are insertable by the owner" on public.silo_members
    rename to "Silo memberships are insertable by the owner";
alter policy "Group members are deletable by the owner" on public.silo_members
    rename to "Silo memberships are deletable by the owner";

alter policy "Note type links are viewable by the note's owner" on public.note_silos
    rename to "Note silo links are viewable by the note's owner";
alter policy "Note type links are insertable by the note's owner" on public.note_silos
    rename to "Note silo links are insertable by the note's owner";
alter policy "Note type links are deletable by the note's owner" on public.note_silos
    rename to "Note silo links are deletable by the note's owner";
alter policy "claude tags notes" on public.note_silos
    rename to "claude silos notes";
alter policy "claude untags notes" on public.note_silos
    rename to "claude unsilos notes";

alter policy "Doc tags are viewable by the owner" on public.doc_silos
    rename to "Doc silo links are viewable by the owner";
alter policy "Doc tags are insertable by the owner" on public.doc_silos
    rename to "Doc silo links are insertable by the owner";
alter policy "Doc tags are deletable by the owner" on public.doc_silos
    rename to "Doc silo links are deletable by the owner";
alter policy "claude tags docs" on public.doc_silos
    rename to "claude silos docs";
alter policy "claude untags docs" on public.doc_silos
    rename to "claude unsilos docs";

-- ---------------------------------------------------------------------------
-- Grants: the new levers, plus the new junction
-- ---------------------------------------------------------------------------

-- The owner flips a silo's request toggles and may delete a silo outright
-- (its junction rows cascade; records and members survive). Tags could
-- never be deleted from the client, but a silo is also the old group, and
-- groups always could.
grant update (allows_sql, allows_prompts, allows_edits) on public.silos to authenticated;
grant delete on public.silos to authenticated;

create policy "Silos are deletable by the owner"
    on public.silos for delete
    to authenticated
    using (public.is_owner());

-- Members may read their silos' toggles, so a refusal is explainable.
grant select (allows_sql, allows_prompts, allows_edits) on public.silos to member;

-- note_members: the owner names people on jots, like on docs.
grant select, insert, delete on public.note_members to authenticated;

create policy "Note person grants are viewable by the owner"
    on public.note_members for select
    to authenticated
    using (public.is_owner());

create policy "Note person grants are insertable by the owner"
    on public.note_members for insert
    to authenticated
    with check (public.is_owner());

create policy "Note person grants are deletable by the owner"
    on public.note_members for delete
    to authenticated
    using (public.is_owner());

create policy "claude reads everything"
    on public.note_members for select
    to claude
    using (true);

grant select on public.note_members to member;

-- ---------------------------------------------------------------------------
-- The member-role policies: one rule, two paths
-- ---------------------------------------------------------------------------
--
-- Whoami first: a member sees their own row, memberships, silos (with
-- toggles) and grants — so any refusal is explainable — then the records:
-- in one of my sql-allowing silos, or naming me directly.

create policy "A member reads their own row"
    on public.members for select
    to member
    using (id = public.current_member_id());

create policy "A member reads their own silo memberships"
    on public.silo_members for select
    to member
    using (member_id = public.current_member_id());

create policy "A member reads their silos"
    on public.silos for select
    to member
    using (exists (
        select 1 from public.silo_members sm
        where sm.silo_id = silos.id
          and sm.member_id = public.current_member_id()
    ));

create policy "A member reads their own doc grants"
    on public.doc_members for select
    to member
    using (member_id = public.current_member_id());

create policy "A member reads their own note grants"
    on public.note_members for select
    to member
    using (member_id = public.current_member_id());

create policy "A member reads their own prompt requests"
    on public.member_prompt_requests for select
    to member
    using (member_id = public.current_member_id());

create policy "A member reads their own edit proposals"
    on public.member_edit_requests for select
    to member
    using (member_id = public.current_member_id());

create policy "A member reads silo links in their silos"
    on public.note_silos for select
    to member
    using (exists (
        select 1 from public.silo_members sm
        where sm.silo_id = note_silos.silo_id
          and sm.member_id = public.current_member_id()
    ));

create policy "A member reads doc silo links in their silos"
    on public.doc_silos for select
    to member
    using (exists (
        select 1 from public.silo_members sm
        where sm.silo_id = doc_silos.silo_id
          and sm.member_id = public.current_member_id()
    ));

create policy "Members read notes in their silos or naming them"
    on public.manual_notes for select
    to member
    using (
        exists (
            select 1
            from public.note_silos j
            join public.silo_members sm on sm.silo_id = j.silo_id
            join public.silos s on s.id = j.silo_id
            where j.note_id = manual_notes.id
              and sm.member_id = public.current_member_id()
              and s.allows_sql
        )
        or exists (
            select 1 from public.note_members nm
            where nm.note_id = manual_notes.id
              and nm.member_id = public.current_member_id()
        )
    );

create policy "Members read docs in their silos or naming them"
    on public.docs for select
    to member
    using (
        exists (
            select 1
            from public.doc_silos j
            join public.silo_members sm on sm.silo_id = j.silo_id
            join public.silos s on s.id = j.silo_id
            where j.doc_id = docs.id
              and sm.member_id = public.current_member_id()
              and s.allows_sql
        )
        or exists (
            select 1 from public.doc_members dm
            where dm.doc_id = docs.id
              and dm.member_id = public.current_member_id()
        )
    );
