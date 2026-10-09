-- Notify me when the draft is ready — not when the message lands.
--
-- In propose mode the knock and the work are out of order: the owner
-- hears about a message (Syla's own push-send judgment under
-- skills/push), opens the chat, and finds Syla still mid-draft — so
-- they wait, or answer by hand and waste the draft. Auto mode has no
-- such gap: the reply sends without the owner.
--
-- This migration gives each connection an opt-in that re-times the
-- knock: followers.notify_after_draft. With it set, the arrival stays
-- silent and the phone rings exactly once, deterministically, the
-- moment Syla's draft lands — an AFTER INSERT trigger on
-- chat_reply_proposals queues the push, so the timing never depends on
-- the session remembering. The flag only means anything on the propose
-- rung; it is the owner's setting (the app's reply-mode sheet shows it
-- under Propose), and claude keeps read-only on it.

alter table public.followers
    add column notify_after_draft boolean not null default false;

comment on column public.followers.notify_after_draft is
    'Propose mode only: the owner wants ONE knock per exchange, timed to the draft — no push when this person''s message arrives; the reply_proposal_push trigger rings the phone when Syla''s draft lands. The owner''s setting (the reply-mode sheet); Syla reads it to stay quiet on arrival and never double-push.';

-- The owner edits it from the app, like the ladder (20261120's grant
-- pattern — the owner policies on followers govern row access).
grant update (notify_after_draft) on public.followers to authenticated;

-- ── The draft-ready push ─────────────────────────────────────────────────
--
-- SECURITY DEFINER because proposals arrive through propose_chat_reply
-- under `set local role claude`, and claude holds no insert on
-- push_queue — the queue stays reachable only through queue_push and
-- the push triggers (20261221's arrangement). Fires only for a dm
-- whose one connection opted in; everyone else keeps skills/push.

create function public.reply_proposal_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    _owner uuid;
    _peer  record;
    _url   text := 'sylos://chat/' || new.chat_id;
begin
    select id into _owner from public.profiles where is_owner limit 1;
    if _owner is null then
        return null;
    end if;

    -- The opted-in dm: exactly one roster row, carrying the flag.
    select f.name, f.notify_after_draft into _peer
    from public.chats c
    join public.chat_followers cf on cf.chat_id = c.id
    join public.followers f on f.id = cf.follower_id
    where c.id = new.chat_id and c.kind = 'dm';
    if _peer is null or not coalesce(_peer.notify_after_draft, false) then
        return null;
    end if;

    -- Coalesce: one undelivered push per chat is enough of a knock
    -- (the url is the dedup key, as on every chat push).
    if exists (
        select 1 from public.push_queue
        where url = _url and sent_at is null and failed_at is null
    ) then
        return null;
    end if;

    insert into public.push_queue (profile_id, title, body, url)
    values (_owner,
            coalesce(_peer.name, 'A connection') || ' — Syla drafted a reply',
            left(new.body, 300),
            _url);

    return null;
end;
$$;

comment on function public.reply_proposal_push() is
    'AFTER INSERT row trigger on chat_reply_proposals (pending rows): when the dm''s connection has notify_after_draft set, queues the one deterministic push — the draft is the notification. Coalesces on the chat''s deep link url while a push is undelivered; delivery is the push edge function''s job as always.';

revoke all on function public.reply_proposal_push() from public;

create trigger chat_reply_proposals_draft_push
    after insert on public.chat_reply_proposals
    for each row
    when (new.status = 'pending')
    execute function public.reply_proposal_push();

-- ── The skill learns to stay quiet on arrival ────────────────────────────
--
-- Doc edits are the house pattern: a targeted append before the footer,
-- guarded so an owner's own edits survive and a re-run no-ops.

update public.docs
set html = replace(html,
    '<footer>doc <code>skills/chat-replies</code></footer>',
    '<h2>The quiet-until-drafted connections</h2>
<p>A connection whose row carries <code>notify_after_draft</code> asked for ONE knock per exchange, timed to your draft: never push about their message''s arrival, and never push "drafted a reply" yourself either — filing the proposal IS the notification (the database rings the phone the moment your <code>propose_chat_reply</code> lands). For every other connection, <code>skills/push</code> stands as written. The flag only means anything on the propose rung; auto replies never wait on the owner.</p>
<footer>doc <code>skills/chat-replies</code></footer>')
where path = 'skills/chat-replies'
  and html not like '%The quiet-until-drafted connections%';
