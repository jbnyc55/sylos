-- The connection brings its chat.
--
-- Connecting and chatting were two gestures: the invite connected the
-- pair, and then somebody had to remember to start the dm — and if BOTH
-- sides started one (or the inviter started one off the still-pending
-- invite), each minted its own random chat_key, the mirror copied both,
-- and the pair ended up with two chats for the same person.
--
-- Now the claim itself creates the inviter's copy of the dm, and the
-- key is DERIVED, not minted: 'dm-' plus the first 40 hex characters of
-- the invite code's sha256 — the same value invite_code_hash is built
-- from, computed while the code is still in hand (the claim clears the
-- hash a statement earlier). The acceptor's app derives the identical
-- key from the code it holds and inserts its own copy, so the two
-- databases agree on the conversation without ever coordinating. The
-- app additionally converges historical duplicates client-side (both
-- sides pick the same canonical copy and fold the rest in).
--
-- Function body otherwise 20261227000000's (the claim wake).

create or replace function public.claim_follower_invite(_code text, _peer jsonb default null)
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
    _run  uuid;
    _name text;
    _whurl text;
    _whtok text;
    _req  bigint;
begin
    if _code is null or char_length(_code) < 32 then
        raise exception 'missing or malformed invite code' using errcode = '28000';
    end if;

    -- The offer is validated before the code is even looked up, so a
    -- malformed one never burns the invite. The column checks are the
    -- same bounds; failing here answers a clear error while the claim
    -- is still retryable without the offer.
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

    -- The chat is part of the connection. The claim creates the
    -- inviter's copy of the dm, keyed off the invite code both sides
    -- hold at exactly this moment — the acceptor's app derives the same
    -- chat_key ('dm-' plus the first 40 hex of the code's sha256), so
    -- the two copies are one conversation from the first message, and a
    -- re-claim or an already-minted key lands on conflict-do-nothing.
    insert into public.chats (chat_key, kind, title)
    values ('dm-' || left(encode(extensions.digest(_code, 'sha256'), 'hex'), 40), 'dm', '')
    on conflict (chat_key) do nothing;

    insert into public.chat_followers (chat_id, follower_id)
    select c.id, m.id
    from public.chats c
    where c.chat_key = 'dm-' || left(encode(extensions.digest(_code, 'sha256'), 'hex'), 40)
    on conflict do nothing;

    -- The wake: queue an event-less run, log the claim on it, and fire
    -- the routine webhook the dispatcher's own way. Missing credential:
    -- the run stays queued for the every-minute dispatcher.
    insert into public.syla_job_runs (event_id)
    values (null)
    returning id into _run;

    insert into public.follower_claims (follower_id, run_id)
    values (m.id, _run);

    select f.name into _name from public.followers f where f.id = m.id;

    select decrypted_secret into _whurl
    from vault.decrypted_secrets where name = 'syla_webhook_url';
    select decrypted_secret into _whtok
    from vault.decrypted_secrets where name = 'syla_webhook_token';

    if _whurl is not null and _whtok is not null then
        _req := net.http_post(
            url := _whurl,
            headers := jsonb_build_object(
                'Authorization',     'Bearer ' || _whtok,
                'anthropic-version', '2023-06-01',
                'anthropic-beta',    'experimental-cc-routine-2026-04-01',
                'Content-Type',      'application/json'),
            body := jsonb_build_object(
                'text', coalesce(_name, 'Someone')
                        || ' just accepted the owner''s invite and is now '
                        || 'a connection. Claim as usual — this run has no '
                        || 'event; the claim entry''s claim field names who '
                        || 'joined and whether they connected back. If the '
                        || 'first-run walkthrough''s race stage is underway '
                        || '(skills/first-run), follow it; otherwise one '
                        || 'short line in the Syla conversation '
                        || '(syla_chat_say) telling the owner is enough. '
                        || 'Then finish the run.'),
            timeout_milliseconds := 15000);

        update public.syla_job_runs
        set fired_at = now(), fire_count = fire_count + 1, fire_request_id = _req
        where id = _run;
    end if;

    return jsonb_build_object('token', tok, 'follower_id', m.id);
end;
$$;

comment on function public.claim_follower_invite(text, jsonb) is
    'Burns a single-use invite code and issues (or rotates) that follower''s personal key; raises 28000 on any miss. _peer, optional, is the claimer''s connect-back offer ({project_url, anon_key, invite_code}) — stored on the row for the owner''s client to redeem, so one invite and one accept connect both ways. The claim also creates the dm chat for the new connection (chat_key derived from the code, so the acceptor''s copy matches), queues an event-less syla_job_runs row (logged in follower_claims) and fires the routine webhook inline, so the owner''s Syla learns a connection just landed.';
