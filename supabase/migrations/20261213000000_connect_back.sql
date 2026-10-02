-- Connect back: one invite, one accept, both directions.
--
-- Until now reciprocity was two independent gestures: accepting an
-- invite made the acceptor a follower here and gave THEM a key, but the
-- inviter had to be invited back — a second mint, a second share, a
-- second claim — before the pair presented as connected. Nobody's
-- friends did that. The fix hangs off one observation: MINTING AN
-- INVITE IS CONSENT IN ADVANCE. The owner who minted has already said
-- "I want to be connected to this person, both ways", so the
-- acceptor's single claim may carry everything the inviter needs to
-- hold a key back — and the inviter's own client can finish the link
-- without asking again.
--
-- The mechanics stay person-to-person, no broker anywhere:
--
--   * The acceptor's app, before claiming, mints a follower invite in
--     its OWN database (a fresh followers row named for the inviter —
--     zero silos, so the key it buys reads nothing until the acceptor
--     shares). It attaches that offer — its project URL, publishable
--     key, and single-use code — to the claim it was already making.
--   * claim_follower_invite stores the offer on the inviter's follower
--     row (the peer_* columns below). Burn-on-redeem is untouched: the
--     offer is a CODE, not a token, so the acceptor's database still
--     only ever holds hashes, and the acceptor still sees the connect
--     when the code is redeemed (their row's claimed_at flips).
--   * The inviter's client, next time it loads connections, redeems
--     any pending offer against the acceptor's project, files the
--     token as a following row, sets peer_following_id, and clears the
--     offer. No tap: the invite was the approval.
--
-- Trust accounting. The offer is attacker-shaped data (anyone holding
-- a valid invite code can attach one), so it is bounded and validated
-- here, and it grants nothing by itself: redeeming it buys a key into
-- a database that shares zero silos until its owner says otherwise,
-- and the inviter only ever auto-redeems offers on rows they
-- personally minted invites for. An offer pointing somewhere
-- malicious is the same exposure as today's hand-pasted reverse
-- invite, now attributable on the row. Asymmetric trust stays
-- expressible: either side still shares, blocks, or deletes
-- independently, and a client without a database of its own simply
-- claims with no offer — the old one-way flow, still valid.

alter table public.followers
    add column peer_project_url text
        check (peer_project_url is null
               or (peer_project_url like 'https://%'
                   and char_length(peer_project_url) <= 200)),
    add column peer_anon_key text
        check (peer_anon_key is null
               or char_length(peer_anon_key) between 20 and 500),
    add column peer_invite_code text
        check (peer_invite_code is null
               or char_length(peer_invite_code) between 32 and 200),
    add column peer_offered_at timestamptz;

comment on column public.followers.peer_project_url is
    'The connect-back offer this person attached when they claimed: their own project''s URL. The owner''s client redeems the offer there, files the key as a following row, sets peer_following_id, and clears all four peer offer columns.';
comment on column public.followers.peer_anon_key is
    'The connect-back offer: their project''s client-public (publishable) key — public by design, like the key inside every invite link.';
comment on column public.followers.peer_invite_code is
    'The connect-back offer: a single-use invite code minted in THEIR database for this owner. A code, not a token — redeeming it burns it there and buys the personal key. Readable only by the owner this row belongs to (and their agent); worthless once redeemed or expired.';
comment on column public.followers.peer_offered_at is
    'When the connect-back offer landed (set by claim_follower_invite alongside the other peer_* columns). The offer expires on its own side''s invite TTL; a stale one simply fails to redeem and the client clears it.';

-- ---------------------------------------------------------------------------
-- claim_follower_invite grows the offer parameter
-- ---------------------------------------------------------------------------
--
-- Same contract as before — code in, personal key out, one opaque error
-- for every miss — plus an optional connect-back offer stored with the
-- claim. The old single-argument form is dropped rather than kept as an
-- overload so PostgREST dispatch stays unambiguous; _peer defaults to
-- null, so an older client's {"_code": …} call is unchanged.

drop function public.claim_follower_invite(text);

create function public.claim_follower_invite(_code text, _peer jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    m     record;
    tok   text;
    _url  text;
    _key  text;
    _back text;
begin
    if _code is null or char_length(_code) < 32 then
        raise exception 'missing or malformed invite code' using errcode = '28000';
    end if;

    -- The offer is validated before the code is even looked up, so a
    -- malformed one never burns the invite. The column checks above
    -- are the same bounds; failing here answers a clear error while
    -- the claim is still retryable without the offer.
    if _peer is not null then
        _url  := nullif(trim(_peer->>'project_url'), '');
        _key  := nullif(trim(_peer->>'anon_key'), '');
        _back := nullif(trim(_peer->>'invite_code'), '');
        if _url is null or _url not like 'https://%' or char_length(_url) > 200
           or _key is null or char_length(_key) not between 20 and 500
           or _back is null or char_length(_back) not between 32 and 200 then
            raise exception 'malformed connect-back offer' using errcode = '22023';
        end if;
    end if;

    select id, blocked, invite_expires_at into m
    from public.followers
    where invite_code_hash = encode(extensions.digest(_code, 'sha256'), 'hex');

    if m.id is null
       or m.blocked
       or m.invite_expires_at is null
       or m.invite_expires_at <= now() then
        raise exception 'invalid or expired invite' using errcode = '28000';
    end if;

    tok := encode(extensions.gen_random_bytes(32), 'hex');

    -- The claim is the authoritative moment for the offer: whatever
    -- this claim carried replaces whatever an earlier claim left, and
    -- a claim with no offer clears a stale one.
    update public.followers
    set token_hash        = encode(extensions.digest(tok, 'sha256'), 'hex'),
        claimed_at        = now(),
        invite_code_hash  = null,
        invite_expires_at = null,
        peer_project_url  = _url,
        peer_anon_key     = _key,
        peer_invite_code  = _back,
        peer_offered_at   = case when _back is null then null else now() end
    where id = m.id;

    return jsonb_build_object('token', tok, 'follower_id', m.id);
end;
$$;

comment on function public.claim_follower_invite(text, jsonb) is
    'Burns a single-use invite code and issues (or rotates) that follower''s personal key; raises 28000 on any miss. _peer, optional, is the claimer''s connect-back offer ({project_url, anon_key, invite_code}) — stored on the row for the owner''s client to redeem, so one invite and one accept connect both ways.';

revoke all on function public.claim_follower_invite(text, jsonb) from public;
grant execute on function public.claim_follower_invite(text, jsonb) to anon;

-- The owner's client finishes the link and clears the consumed offer.
-- (Grants are the outer gate — the owner policies on followers already
-- govern row access, exactly as with peer_following_id.)
grant update (peer_project_url, peer_anon_key, peer_invite_code, peer_offered_at)
    on public.followers to authenticated;
