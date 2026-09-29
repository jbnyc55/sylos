-- Follow: public silos, and members who invited themselves.
--
-- Until now every member arrived through the owner's own hands — an
-- invite minted on the Manage page, carried person-to-person, burned on
-- claim (20261027000000). That is the right shape for a friend reading
-- your notes; it is the wrong shape for distribution. The company's own
-- Sylos wants to publish — stock apps, starter docs — and every new
-- install wants to read that shelf without the company minting an
-- invite per person. Two small ideas make that work, both inside the
-- member machinery that already exists:
--
--   * A PUBLIC SILO (silos.is_public). The owner flips one flag on a
--     silo, and whatever sits in it — vibe code apps and docs, the two
--     published record types — becomes readable by EVERY member of this
--     database, follower or invited, with no per-member silo_members row.
--     Public is a property of the silo, not of any membership: placement
--     in a public silo IS the grant, to everyone who holds a key.
--   * A FOLLOWER (members.follower). follow(_name) is self-service
--     membership: anyone may call it (anon, like every member entry
--     point) while the owner has opted in with the vault flag
--     open_follow = 'on'. It creates an ordinary members row, marked
--     follower, and mints the same bearer token the claim path mints —
--     so member_rq, the whoami policies, blocking, and last_seen_at all
--     work on a follower with zero new plumbing. A follower belongs to
--     no silo, so their entire read surface is the public silos; an
--     invited member keeps every grant they had, plus the public shelf
--     like everyone else.
--
-- This is how stock apps stop being seeded into each new database: the
-- new install follows the company's Sylos and reads the company's
-- public silo instead. The gate is deliberate — a personal install that
-- never sets open_follow refuses followers outright — and the brake on
-- the anon-callable write copies register_sylos_install's: a coarse
-- per-hour cap, errcode 53400.
--
-- What this deliberately does NOT do: widen any other record type
-- (notes, todos, events, goal cells and whole tables keep needing a
-- membership with allows_sql), let followers submit prompts or edits
-- (they hold no silo_members row, so both submit RPCs refuse them), or
-- give anyone a write path. RLS stays the entire authorization layer:
-- every new reach below is one more permissive select policy on the
-- member role, so nothing existing can narrow.

-- ---------------------------------------------------------------------------
-- Public silos
-- ---------------------------------------------------------------------------

alter table public.silos
    add column is_public boolean not null default false;

comment on column public.silos.is_public is
    'Everything placed in this silo (vibe code apps and docs) is readable by every member — follower or invited — with no silo_members row. Placement in a public silo is the grant; the owner flips this from the silo''s manage screen.';

-- Silos updates are column-scoped (20260830040000 lineage), so the new
-- column needs its own lever; the owner-only update policy already
-- covers the row. Members may read the flag, so what they see is
-- explainable in their whoami.
grant update (is_public) on public.silos to authenticated;
grant select (is_public) on public.silos to member;

-- ---------------------------------------------------------------------------
-- Followers on the roster
-- ---------------------------------------------------------------------------

alter table public.members
    add column follower boolean not null default false;

comment on column public.members.follower is
    'True for members who admitted themselves through follow() rather than an owner-minted invite. Same key machinery, but no silo memberships: a follower reads the public silos and nothing else. Also the unit the follow() rate brake counts.';

-- A follower can see what kind of member they are, like their name.
grant select (follower) on public.members to member;

-- ---------------------------------------------------------------------------
-- follow — self-service membership, gated by the owner's vault flag
-- ---------------------------------------------------------------------------
--
-- SECURITY DEFINER for the same reasons as claim_member_invite: reading
-- vault.decrypted_secrets and writing members, which anon can do neither
-- of; the plaintext token exists exactly once, in the response, and is
-- stored only as the sha256 hex that authenticate_member already looks
-- up — a follower's key IS a member key, resolved by the same path.
-- The gate is the vault secret open_follow with the exact value 'on'
-- (the hosted_trial flag's pattern): unset or anything else refuses, so
-- a personal install takes no followers unless its owner opted in.

create function public.follow(_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _trimmed text := btrim(coalesce(_name, ''));
    _final   text;
    _n       integer := 1;
    _recent  bigint;
    mid      uuid;
    tok      text;
begin
    if not exists (
        select 1 from vault.decrypted_secrets
        where name = 'open_follow' and decrypted_secret = 'on'
    ) then
        raise exception 'this Sylos does not take followers' using errcode = '42501';
    end if;

    if char_length(_trimmed) not between 1 and 100 then
        raise exception 'the name must be 1-100 characters';
    end if;

    -- A coarse brake on an anon-callable write, register_sylos_install's
    -- style: following happens once per install, so a flood is someone
    -- else.
    select count(*) into _recent
    from public.members
    where follower and created_at > now() - interval '1 hour';
    if _recent > 100 then
        raise exception 'too many new followers right now — try again later'
            using errcode = '53400';
    end if;

    -- The roster is unique on lower(name) (20261031000000): keep the
    -- asked-for name when it is free, else number it in arrival order —
    -- "Maya", "Maya 2", "Maya 3" — up to a sane cap.
    _final := _trimmed;
    while exists (select 1 from public.members where lower(name) = lower(_final)) loop
        _n := _n + 1;
        if _n > 50 or char_length(_trimmed || ' ' || _n::text) > 100 then
            raise exception 'that name is taken — try a different one';
        end if;
        _final := _trimmed || ' ' || _n::text;
    end loop;

    tok := encode(extensions.gen_random_bytes(32), 'hex');

    insert into public.members (name, follower, token_hash, claimed_at)
    values (_final, true, encode(extensions.digest(tok, 'sha256'), 'hex'), now())
    returning id into mid;

    return jsonb_build_object('member_id', mid, 'name', _final, 'token', tok);
end;
$$;

comment on function public.follow(text) is
    'Self-service membership: creates a follower-grade members row and returns its bearer token, shown once and stored only as a hash — the same key member_rq resolves. Open only while the vault secret open_follow is ''on''; refuses otherwise (42501) and brakes at 100 new followers an hour (53400).';

revoke all on function public.follow(text) from public;
grant execute on function public.follow(text) to anon;

-- ---------------------------------------------------------------------------
-- The read reach: what sits in a public silo is every member's to read
-- ---------------------------------------------------------------------------
--
-- There is no shared visibility helper to extend — each member read
-- policy inlines its own silo-intersection subquery — so the reach is
-- added exactly where the published types are read: one more PERMISSIVE
-- select policy per table, OR-ed with the existing ones, which is why
-- an invited member's access can only ever widen. The junction and silo
-- policies come first because the app and doc policies run their
-- subqueries under those tables' own RLS (the same backing 20261008000000
-- gave the silo'd paths).

create policy "Every member reads public silos"
    on public.silos for select
    to member
    using (is_public);

create policy "A member reads app silo links into public silos"
    on public.vibe_code_app_silos for select
    to member
    using (exists (
        select 1 from public.silos s
        where s.id = vibe_code_app_silos.silo_id
          and s.is_public
    ));

create policy "A member reads doc silo links into public silos"
    on public.doc_silos for select
    to member
    using (exists (
        select 1 from public.silos s
        where s.id = doc_silos.silo_id
          and s.is_public
    ));

create policy "Members read vibe code apps in public silos"
    on public.vibe_code_apps for select
    to member
    using (exists (
        select 1
        from public.vibe_code_app_silos j
        join public.silos s on s.id = j.silo_id
        where j.app_id = vibe_code_apps.id
          and s.is_public
    ));

create policy "Members read docs in public silos"
    on public.docs for select
    to member
    using (exists (
        select 1
        from public.doc_silos j
        join public.silos s on s.id = j.silo_id
        where j.doc_id = docs.id
          and s.is_public
    ));
