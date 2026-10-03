-- A new connection becomes a push.
--
-- Seen in the field: someone accepts an invite (or follows outright),
-- their claim lands on the owner's followers row — and the owner finds
-- out whenever they next happen to open the app. The whole point of the
-- connect moment is reciprocity: the other side just said "I want in",
-- and the flow stalls until the owner notices. The delivery pipeline
-- has existed since 20261025 (push_devices, push_queue, the insert
-- poke, the push edge function) and 20261221 already rings the phone
-- for a chat message from Syla; this is the same trigger shape for the
-- roster.
--
-- When a connection "arrives" here, in data terms (20261120's
-- lifecycle): claimed_at flips on a followers row — claim_follower_invite,
-- whether the plain claim or the connect-back redeem — or a follow()
-- row is born with claimed_at already set. One trigger function, wired
-- to both events, covers every arrival; the body says what the owner
-- should do next, read off the row itself:
--
--   * peer_following_id already set — the reverse row the acceptor's
--     client pre-linked (20261213): the inviter just redeemed the
--     offer, the pair is connected both ways. Nothing to do but say hi.
--   * peer_invite_code set — they claimed WITH a connect-back offer:
--     the owner's client finishes the link by itself on next open, so
--     the push is "open the app".
--   * neither — a plain one-way arrival (a claim without an offer, or
--     a self-service follow()): the owner connects back by hand, which
--     is exactly what they'd want the nudge for.
--
-- Pushes coalesce on the Connections surface: while one is undelivered,
-- further arrivals ride it — the owner opens Connections and sees
-- everyone (the chat push's url-as-dedup-key pattern; the deep link,
-- sylos://connections, is the tap target when the app learns to open
-- pushes). The owner's own actions never ring their phone: minting,
-- linking (peer_following_id), and clearing a consumed offer touch
-- other columns, and a re-invite of an already-claimed person keeps
-- claimed_at set, so its re-claim stays silent.

-- ── The trigger ──────────────────────────────────────────────────────────

-- SECURITY DEFINER because the arrivals happen in definer RPCs called
-- by anon (claim_follower_invite, follow), and nothing on those paths
-- holds insert on push_queue — the queue stays reachable only through
-- queue_push and the push triggers.
create function public.follower_connect_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    _owner uuid;
    _title text;
    _body  text;
    _url   text := 'sylos://connections';
begin
    select id into _owner from public.profiles where is_owner limit 1;
    if _owner is null then
        return null;
    end if;

    -- Coalesce: one undelivered connections push is enough of a knock.
    if exists (
        select 1 from public.push_queue
        where url = _url and sent_at is null and failed_at is null
    ) then
        return null;
    end if;

    if new.peer_following_id is not null then
        _title := new.name || ' is now connected';
        _body  := 'You''re connected both ways — say hi in Chats.';
    elsif new.peer_invite_code is not null then
        _title := new.name || ' accepted your invite';
        _body  := 'They offered to connect back — open Sylos and the link finishes itself.';
    else
        _title := new.name || ' connected';
        _body  := 'Add them back from Connections to go both ways.';
    end if;

    insert into public.push_queue (profile_id, title, body, url)
    values (_owner, left(_title, 200), _body, _url);

    return null;
end;
$$;

comment on function public.follower_connect_push() is
    'AFTER INSERT/UPDATE row trigger on followers for the connect moment (claimed_at newly set): queues a push to the owner so a new connection reaches the phone — the nudge to follow back, or just to open the app and let the connect-back link finish. Coalesces on the Connections deep link url while a push is undelivered; delivery is the push edge function''s job as always.';

revoke all on function public.follower_connect_push() from public;

-- follow() rows are born claimed; invite claims and connect-back
-- redeems flip claimed_at on an existing row.
create trigger followers_connect_push_insert
    after insert on public.followers
    for each row
    when (new.claimed_at is not null)
    execute function public.follower_connect_push();

create trigger followers_connect_push_update
    after update on public.followers
    for each row
    when (old.claimed_at is null and new.claimed_at is not null)
    execute function public.follower_connect_push();
