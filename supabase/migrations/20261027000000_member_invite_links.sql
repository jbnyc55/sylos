-- Invite links: claiming a membership stops depending on Supabase email.
--
-- The claim flow proved identity with Supabase's emailed one-time code —
-- which meant every install leaned on the built-in mail service (dev-grade,
-- rate-limited to a handful of sends per hour, templates pointing at a
-- localhost site_url nobody configured). The invite already travels
-- person-to-person through a channel the owner trusts (an iMessage to
-- someone they know), so the INVITE PAYLOAD ITSELF becomes the proof:
--
--   * mint_member_invite — the owner mints a single-use, expiring invite
--     code for a member row. The code is returned once and stored only as
--     a sha256 hash, exactly like the member token it will buy. The app
--     wraps it in a sylos://join deep link (project URL + publishable key
--     + code) and hands it to the share sheet; the owner's own device
--     sends it. Supabase sends nothing.
--   * claim_member_invite — anon-callable, like every member entry point:
--     the friend's app presents the code, and a matching, unexpired,
--     unblocked row burns it and receives the personal member token, the
--     same mint-and-hash dance claim_member_token does. No auth session,
--     no email round-trip.
--
-- What replaces email proof is possession of a secret the owner personally
-- handed over. The trade is a bearer secret in a chat thread; single-use,
-- a short TTL, and the fact that the code only buys what the silos grant
-- keep that honest — and the member row's claimed_at flips so the owner
-- sees when (and can block if it wasn't their friend).
--
-- claim_member_token (email proof) stays callable for compatibility, but
-- the invite path is the flow the app ships. Expiry re-verification
-- (token_ttl_days) becomes "ask the owner for a fresh invite" — one tap
-- on the Manage page — instead of self-service email OTP.

alter table public.members
    add column invite_code_hash text
        check (invite_code_hash is null or char_length(invite_code_hash) = 64),
    add column invite_expires_at timestamptz;

comment on column public.members.invite_code_hash is
    'sha256 of the outstanding single-use invite code, hex. Null = no invite outstanding. Set by mint_member_invite, cleared by claim_member_invite on success.';
comment on column public.members.invite_expires_at is
    'When the outstanding invite code stops working. Enforced live by claim_member_invite; minting again replaces both code and expiry.';

comment on table public.members is
    'People invited to read shared records through member_rq. Access is claimed with a single-use invite code the owner shares personally (claim_member_invite); tokens and codes live only as sha256 hashes. Null token_hash means no access.';

-- ---------------------------------------------------------------------------
-- mint_member_invite — the owner writes the secret that buys a key
-- ---------------------------------------------------------------------------
--
-- SECURITY DEFINER only to generate-and-hash server-side so the plaintext
-- code exists exactly once, in the response; the is_owner() gate keeps it
-- the owner's act (members and claiming guests hold sessions too).
-- Minting for an already-claimed member is the re-invite: it does not
-- touch their current token, it just opens a fresh claim (which rotates).

create function public.mint_member_invite(
    _member_id uuid, _ttl_minutes integer default 10080
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    code text;
    m record;
begin
    if not public.is_owner() then
        raise exception 'only the owner mints invites' using errcode = '42501';
    end if;

    if _ttl_minutes is null or _ttl_minutes not between 5 and 43200 then
        raise exception 'invite ttl must be between 5 minutes and 30 days';
    end if;

    code := encode(extensions.gen_random_bytes(32), 'hex');

    update public.members
    set invite_code_hash  = encode(extensions.digest(code, 'sha256'), 'hex'),
        invite_expires_at = now() + make_interval(mins => _ttl_minutes)
    where id = _member_id
    returning id, email, invite_expires_at into m;

    if m.id is null then
        raise exception 'no member with id %', _member_id;
    end if;

    return jsonb_build_object(
        'invite_code', code,
        'member_id',   m.id,
        'email',       m.email,
        'expires_at',  m.invite_expires_at
    );
end;
$$;

comment on function public.mint_member_invite(uuid, integer) is
    'Mints (or replaces) one member''s single-use invite code, owner only. The code is returned once and stored only as a hash; the app shares it as a sylos://join link.';

revoke all on function public.mint_member_invite(uuid, integer) from public;
grant execute on function public.mint_member_invite(uuid, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- claim_member_invite — code in, personal key out
-- ---------------------------------------------------------------------------
--
-- SECURITY DEFINER for the same reason as authenticate_member: reading
-- (and writing) hashes neither anon nor member can. One error for every
-- miss — unknown, expired, or blocked — so probing learns nothing about
-- which check failed or whether a code ever existed.

create function public.claim_member_invite(_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    m   record;
    tok text;
begin
    if _code is null or char_length(_code) < 32 then
        raise exception 'missing or malformed invite code' using errcode = '28000';
    end if;

    select id, blocked, invite_expires_at into m
    from public.members
    where invite_code_hash = encode(extensions.digest(_code, 'sha256'), 'hex');

    if m.id is null
       or m.blocked
       or m.invite_expires_at is null
       or m.invite_expires_at <= now() then
        raise exception 'invalid or expired invite' using errcode = '28000';
    end if;

    tok := encode(extensions.gen_random_bytes(32), 'hex');

    update public.members
    set token_hash        = encode(extensions.digest(tok, 'sha256'), 'hex'),
        claimed_at        = now(),
        invite_code_hash  = null,
        invite_expires_at = null
    where id = m.id;

    return jsonb_build_object('token', tok, 'member_id', m.id);
end;
$$;

comment on function public.claim_member_invite(text) is
    'Burns a single-use invite code and issues (or rotates) that member''s personal key. The returned token is shown once and stored only as a hash. Raises 28000 on any miss.';

revoke all on function public.claim_member_invite(text) from public;
grant execute on function public.claim_member_invite(text) to anon;

-- ---------------------------------------------------------------------------
-- The expiry message stops promising an email flow
-- ---------------------------------------------------------------------------
--
-- Same contract as 20260926000000 otherwise: SECURITY DEFINER only to read
-- members, 28000 on every failure, last_seen_at touched only on a pass.

create or replace function public.authenticate_member(_token text)
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
        raise exception 'member token expired — ask the owner for a fresh invite'
            using errcode = '28000';
    end if;

    update public.members set last_seen_at = now() where id = m.id;

    return m.id;
end;
$$;

comment on function public.claim_member_token() is
    'Legacy email-proof claim: issues (or rotates) the calling session''s member key, matching on its verified email. The shipping flow is claim_member_invite; this stays for keys claimed the old way.';
