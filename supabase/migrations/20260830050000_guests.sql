-- Guests: outside people who prove their email, receive a personal key, and
-- query the data behind specific tags — nothing else.
--
-- The flow: the owner defines guest groups ("besties", "family"), toggles
-- which tags each group may read (guest_group_tags), and invites guests by
-- email into groups (guest_group_members). The guest opens the app's Guest
-- access page, verifies that same email through Supabase's emailed one-time
-- code (proof it's really them), and claim_guest_token hands them a bearer
-- token — shown once, stored only as a sha256 hash. From then on they run
-- read-only SQL over HTTPS through guest_rq (the rq equivalent) and see
-- exactly the manual notes carrying at least one tag readable by at least
-- one of their groups.
--
-- The design copies the claude-role boundary (20260816000300 and
-- 20260820000000), narrowed hard:
--
--   * A `guest` role that PostgREST can SET ROLE into. Unlike claude it has
--     NO login, NO read-everything grant, and NO default privileges on
--     future tables: its entire surface is the column-scoped grants below.
--   * Who is asking travels as a transaction-local setting (app.guest_id),
--     stamped by guest_rq after the token check; every guest policy reads
--     it through current_guest_id(). No token, no identity, no rows.
--   * Claiming again rotates the token (the old hash is overwritten), and
--     the owner revokes by clearing token_hash or deleting the row.
--
-- Because the claim page signs the guest into Supabase auth for a moment,
-- `authenticated` no longer means "the owner". Every policy that used
-- signed-in as a stand-in for the owner is tightened here to is_owner();
-- the per-profile policies (notes, todos, purchases, …) already isolate by
-- profile and need no change.
--
-- Visibility is by tag, deny by default: untagged notes (and every untagged
-- table — todos, purchases, summaries) are invisible to guests. The
-- sharing_allowances layer (20260830040000) still governs what a reader may
-- do with content onward; this migration governs who reads.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- The owner flag
-- ---------------------------------------------------------------------------
--
-- One profile is the owner: the first one, the seeded user. Guests passing
-- through the claim page get ordinary profiles with is_owner false, so the
-- app-management policies below exclude them.

alter table public.profiles
    add column is_owner boolean not null default false;

comment on column public.profiles.is_owner is
    'True for the app''s owner. Guests verifying email on the claim page get ordinary rows with false.';

update public.profiles
set is_owner = true
where id = (select id from public.profiles order by created_at limit 1);

-- security definer like current_profile_id, and for the same reason: it must
-- read profiles regardless of that table's own policies.
create or replace function public.is_owner()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select coalesce(
        (select p.is_owner from public.profiles p where p.user_id = (select auth.uid())),
        false)
$$;

comment on function public.is_owner() is
    'True when the calling session belongs to the owner profile. Gates app-management policies now that guests can hold sessions.';

revoke all on function public.is_owner() from public;
grant execute on function public.is_owner() to authenticated;

-- Tighten every policy where signed-in stood in for the owner.
alter policy "Note types are viewable by signed-in users"
    on public.note_types using (public.is_owner());
alter policy "Note types are insertable by signed-in users"
    on public.note_types with check (public.is_owner());
alter policy "Note types are updatable by signed-in users"
    on public.note_types using (public.is_owner()) with check (public.is_owner());

alter policy "Sharing allowances are viewable by signed-in users"
    on public.sharing_allowances using (public.is_owner());
alter policy "Sharing allowances are insertable by signed-in users"
    on public.sharing_allowances with check (public.is_owner());

alter policy "Type allowances are viewable by signed-in users"
    on public.note_type_allowances using (public.is_owner());
alter policy "Type allowances are insertable by signed-in users"
    on public.note_type_allowances with check (public.is_owner());
alter policy "Type allowances are deletable by signed-in users"
    on public.note_type_allowances using (public.is_owner());

alter policy "Agent edits are readable by signed-in users"
    on public.agent_edits using (public.is_owner());

-- ---------------------------------------------------------------------------
-- The guest role
-- ---------------------------------------------------------------------------

do $$
begin
    if not exists (select from pg_roles where rolname = 'guest') then
        -- No login: this role is only ever entered via SET ROLE inside
        -- guest_rq, never connected to directly.
        create role guest;
    end if;
end
$$;

-- SET ROLE only works for roles the session user is a member of; PostgREST
-- connects as authenticator. Membership alone grants nothing.
do $$
begin
    if exists (select from pg_roles where rolname = 'authenticator') then
        grant guest to authenticator;
    end if;
end
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create table public.guests (
    id            uuid primary key default gen_random_uuid(),
    email         text not null unique check (char_length(email) between 3 and 320),
    -- sha256 of the guest's bearer token, hex. Null = not yet claimed, or
    -- revoked by the owner.
    token_hash    text check (char_length(token_hash) = 64),
    created_at    timestamptz not null default now(),
    claimed_at    timestamptz,
    last_seen_at  timestamptz
);

comment on table public.guests is
    'People invited to query tag-scoped data through guest_rq. Tokens are issued by claim_guest_token after email proof and live only as sha256 hashes; null token_hash means no access.';

create table public.guest_groups (
    id          uuid primary key default gen_random_uuid(),
    name        text not null unique check (char_length(name) between 1 and 50),
    created_at  timestamptz not null default now()
);

comment on table public.guest_groups is
    'Audiences guests belong to ("besties", "family"). Which tags a group may read lives in guest_group_tags; who is in it, in guest_group_members.';

create table public.guest_group_tags (
    group_id      uuid not null references public.guest_groups (id) on delete cascade,
    note_type_id  uuid not null references public.note_types (id) on delete cascade,
    primary key (group_id, note_type_id)
);

comment on table public.guest_group_tags is
    'Which tags each guest group may read. A group with no rows reads nothing.';

create table public.guest_group_members (
    guest_id  uuid not null references public.guests (id) on delete cascade,
    group_id  uuid not null references public.guest_groups (id) on delete cascade,
    primary key (guest_id, group_id)
);

comment on table public.guest_group_members is
    'Which groups each guest belongs to. A guest''s readable tags are the union over their groups.';

-- ---------------------------------------------------------------------------
-- Who is asking
-- ---------------------------------------------------------------------------

-- The guest identity for this transaction, stamped by guest_rq. Returns null
-- outside a guest_rq call, so every guest policy fails closed.
create or replace function public.current_guest_id()
returns uuid
language sql
stable
as $$
    select nullif(current_setting('app.guest_id', true), '')::uuid
$$;

comment on function public.current_guest_id() is
    'The guest id guest_rq stamped on this transaction, or null. Guest RLS policies scope through this.';

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.guests              enable row level security;
alter table public.guest_groups       enable row level security;
alter table public.guest_group_tags   enable row level security;
alter table public.guest_group_members enable row level security;

-- The owner manages the roster from the Guests tab. Owner-gated from the
-- start — a claiming guest holds a session too.
create policy "Guests are viewable by the owner"
    on public.guests for select
    to authenticated
    using (public.is_owner());

create policy "Guests are insertable by the owner"
    on public.guests for insert
    to authenticated
    with check (public.is_owner());

create policy "Guests are updatable by the owner"
    on public.guests for update
    to authenticated
    using (public.is_owner())
    with check (public.is_owner());

create policy "Guests are deletable by the owner"
    on public.guests for delete
    to authenticated
    using (public.is_owner());

create policy "Guest groups are viewable by the owner"
    on public.guest_groups for select
    to authenticated
    using (public.is_owner());

create policy "Guest groups are insertable by the owner"
    on public.guest_groups for insert
    to authenticated
    with check (public.is_owner());

create policy "Guest groups are deletable by the owner"
    on public.guest_groups for delete
    to authenticated
    using (public.is_owner());

create policy "Group tags are viewable by the owner"
    on public.guest_group_tags for select
    to authenticated
    using (public.is_owner());

create policy "Group tags are insertable by the owner"
    on public.guest_group_tags for insert
    to authenticated
    with check (public.is_owner());

create policy "Group tags are deletable by the owner"
    on public.guest_group_tags for delete
    to authenticated
    using (public.is_owner());

create policy "Group members are viewable by the owner"
    on public.guest_group_members for select
    to authenticated
    using (public.is_owner());

create policy "Group members are insertable by the owner"
    on public.guest_group_members for insert
    to authenticated
    with check (public.is_owner());

create policy "Group members are deletable by the owner"
    on public.guest_group_members for delete
    to authenticated
    using (public.is_owner());

-- A guest sees their own identity, memberships, groups and those groups'
-- tag grants — a whoami, nothing more.
create policy "A guest reads their own row"
    on public.guests for select
    to guest
    using (id = public.current_guest_id());

create policy "A guest reads their own memberships"
    on public.guest_group_members for select
    to guest
    using (guest_id = public.current_guest_id());

create policy "A guest reads their own groups"
    on public.guest_groups for select
    to guest
    using (exists (
        select 1 from public.guest_group_members m
        where m.group_id = guest_groups.id
          and m.guest_id = public.current_guest_id()
    ));

create policy "A guest reads their groups' tag grants"
    on public.guest_group_tags for select
    to guest
    using (exists (
        select 1 from public.guest_group_members m
        where m.group_id = guest_group_tags.group_id
          and m.guest_id = public.current_guest_id()
    ));

-- What a guest can read of the data: notes carrying at least one tag that
-- at least one of their groups may read, those tag links, and those types.
create policy "Guests read notes tagged for their groups"
    on public.manual_notes for select
    to guest
    using (exists (
        select 1
        from public.manual_note_types j
        join public.guest_group_tags ggt on ggt.note_type_id = j.note_type_id
        join public.guest_group_members m on m.group_id = ggt.group_id
        where j.note_id = manual_notes.id
          and m.guest_id = public.current_guest_id()
    ));

create policy "Guests read tag links in their groups"
    on public.manual_note_types for select
    to guest
    using (exists (
        select 1
        from public.guest_group_tags ggt
        join public.guest_group_members m on m.group_id = ggt.group_id
        where m.guest_id = public.current_guest_id()
          and ggt.note_type_id = manual_note_types.note_type_id
    ));

create policy "Guests read their groups' types"
    on public.note_types for select
    to guest
    using (exists (
        select 1
        from public.guest_group_tags ggt
        join public.guest_group_members m on m.group_id = ggt.group_id
        where m.guest_id = public.current_guest_id()
          and ggt.note_type_id = note_types.id
    ));

-- The claude role reads the roster like every application table (its select
-- grant arrives via default privileges from 20260816000300).
create policy "claude reads everything"
    on public.guests for select
    to claude
    using (true);

create policy "claude reads everything"
    on public.guest_groups for select
    to claude
    using (true);

create policy "claude reads everything"
    on public.guest_group_tags for select
    to claude
    using (true);

create policy "claude reads everything"
    on public.guest_group_members for select
    to claude
    using (true);

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

-- The owner's grants, column-scoped where a column matters: email is the
-- only thing the client creates, and clearing token_hash is the revoke.
grant select, delete on public.guests to authenticated;
grant insert (email) on public.guests to authenticated;
grant update (token_hash) on public.guests to authenticated;
grant select, delete on public.guest_groups to authenticated;
grant insert (name) on public.guest_groups to authenticated;
grant select, insert, delete on public.guest_group_tags to authenticated;
grant select, insert, delete on public.guest_group_members to authenticated;

-- The guest role's entire read surface. Column-scoped: no profile_id, no
-- vetting stamps, no token hashes — so `select *` fails for guests and
-- queries must name their columns.
grant usage on schema public to guest;
grant select (id, body, created_at, updated_at, parent_note_id)
    on public.manual_notes to guest;
grant select on public.manual_note_types to guest;
grant select (id, name, description) on public.note_types to guest;
grant select (id, email, created_at) on public.guests to guest;
grant select (id, name) on public.guest_groups to guest;
grant select on public.guest_group_tags to guest;
grant select on public.guest_group_members to guest;

-- ---------------------------------------------------------------------------
-- claim_guest_token — email proof to personal key
-- ---------------------------------------------------------------------------
--
-- Called from the Guest access page by a session that just verified its
-- email through Supabase's one-time code. If that email is on the roster,
-- mint a fresh token, store its hash, and return the token — the only time
-- it ever leaves the database. Claiming again rotates the token, which is
-- the recovery path for a lost key. SECURITY DEFINER to write guests from a
-- non-owner session; the auth.email() binding is what makes it safe.

create or replace function public.claim_guest_token()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    em  text := lower(coalesce((select auth.email()), ''));
    gid uuid;
    tok text;
begin
    if em = '' then
        raise exception 'no verified email on this session' using errcode = '28000';
    end if;

    select id into gid from public.guests where lower(email) = em;
    if gid is null then
        raise exception 'this email has not been invited' using errcode = '28000';
    end if;

    tok := encode(extensions.gen_random_bytes(32), 'hex');

    update public.guests
    set token_hash = encode(extensions.digest(tok, 'sha256'), 'hex'),
        claimed_at = now()
    where id = gid;

    return jsonb_build_object('token', tok, 'guest_id', gid);
end;
$$;

comment on function public.claim_guest_token() is
    'Issues (or rotates) the calling session''s guest token, matching on its verified email. The returned token is shown once and stored only as a hash.';

revoke all on function public.claim_guest_token() from public;
grant execute on function public.claim_guest_token() to authenticated;

-- ---------------------------------------------------------------------------
-- authenticate_guest — token to identity
-- ---------------------------------------------------------------------------
--
-- SECURITY DEFINER for exactly one reason: reading guests.token_hash, which
-- neither anon nor guest can. Raises on any miss — an unknown token learns
-- nothing about which part failed. The last_seen_at touch is the one write,
-- and happens before the transaction goes read-only in guest_rq.

create or replace function public.authenticate_guest(_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    gid uuid;
begin
    if _token is null or char_length(_token) < 32 then
        raise exception 'missing or malformed guest token' using errcode = '28000';
    end if;

    select id into gid
    from public.guests
    where token_hash = encode(extensions.digest(_token, 'sha256'), 'hex');

    if gid is null then
        raise exception 'invalid guest token' using errcode = '28000';
    end if;

    update public.guests set last_seen_at = now() where id = gid;

    return gid;
end;
$$;

comment on function public.authenticate_guest(text) is
    'Resolves a guest bearer token to the guest id, touching last_seen_at. Raises 28000 on any mismatch.';

revoke all on function public.authenticate_guest(text) from public;
grant execute on function public.authenticate_guest(text) to anon;

-- ---------------------------------------------------------------------------
-- guest_rq — the guests' read path
-- ---------------------------------------------------------------------------
--
-- Same contract as run_readonly_sql (20260820000000): one statement, no
-- trailing semicolon, valid as a FROM subquery; returns a JSON array.
-- SECURITY INVOKER on purpose: after `set local role guest` the dynamic
-- statement runs with guest's column grants and RLS inside a read-only
-- transaction, so even a statement that slips past the wrap cannot write,
-- and can only see what this guest's groups allow.

create or replace function public.guest_rq(_token text, q text)
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
    'Runs one read-only SQL statement as the guest role, scoped by the token''s guest and their groups. Returns rows as a JSON array.';

revoke all on function public.guest_rq(text, text) from public;
grant execute on function public.guest_rq(text, text) to anon;
