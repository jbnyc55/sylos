-- A message from Syla becomes a push.
--
-- Seen in the field: Syla answers in the Syla conversation, the owner
-- isn't looking at the chat, and the phone stays silent. The whole
-- delivery pipeline existed (20261025: push_devices, push_queue, the
-- insert poke, the push edge function) but nothing connected a chat
-- message to it — syla_chat_say just inserts the row, and skills/push
-- steers Syla away from narration pushes, so replies arrived silently
-- unless Syla independently thought to run scripts/push-send.
--
-- This is the trigger 20261025 anticipated ("future triggers can insert
-- directly"): AFTER INSERT on chat_messages, when the author is 'syla'
-- and the kind is 'text' — Syla speaking TO the owner — queue a push
-- for the owner. The existing poke-and-sweep then delivers it within
-- seconds, through whatever signing arrangement the project already
-- uses (own APNs key or the developer's relay).
--
-- Deliberately narrow:
--   * kind 'text' only. auto_reply is Syla answering a peer on the
--     owner's behalf, ask_human is the travelling flag for the peer's
--     client, syla_status is narration — none are addressed to the
--     owner's pocket. A peer's own messages never land in this
--     database at all (the distributed-chat rule), so they cannot be
--     pushed from here either.
--   * Pushes coalesce per chat. While a push for this chat is still
--     undelivered, further messages ride it — the owner opens the
--     thread and reads them all. The url column is the dedup key.
--   * The url is the chat deep link, sylos://chat/<chat_id>: today it
--     only identifies the chat for coalescing; when the app learns to
--     open pushes it is the tap target.

-- ── The trigger ──────────────────────────────────────────────────────────

-- SECURITY DEFINER because the inserting role is `claude` (every Syla
-- message arrives through the gated RPCs under `set local role claude`),
-- and claude holds no insert on push_queue — the queue stays reachable
-- only through queue_push and this trigger.
create function public.chat_message_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    _owner uuid;
    _title text;
    _url   text := 'sylos://chat/' || new.chat_id;
begin
    select id into _owner from public.profiles where is_owner limit 1;
    if _owner is null then
        return null;
    end if;

    -- Coalesce: one undelivered push per chat is enough of a knock.
    if exists (
        select 1 from public.push_queue
        where url = _url and sent_at is null and failed_at is null
    ) then
        return null;
    end if;

    select coalesce(nullif(title, ''), 'Syla') into _title
    from public.chats where id = new.chat_id;

    -- The body is the notification preview, truncated to banner size —
    -- the full message is in the app, and the preview is what transits
    -- APNs (and the default relay hop).
    insert into public.push_queue (profile_id, title, body, url)
    values (_owner, coalesce(_title, 'Syla'), left(new.body, 300), _url);

    return null;
end;
$$;

comment on function public.chat_message_push() is
    'AFTER INSERT row trigger on chat_messages for author = syla, kind = text: queues a push to the owner so a message from Syla reaches the phone when the chat is not open. Coalesces on the chat''s deep link url while a push is undelivered; delivery is the push edge function''s job as always.';

revoke all on function public.chat_message_push() from public;

create trigger chat_messages_syla_push
    after insert on public.chat_messages
    for each row
    when (new.author = 'syla' and new.kind = 'text')
    execute function public.chat_message_push();

-- ── The skill learns the ring is automatic ───────────────────────────────
-- House pattern: targeted, guarded text swap. Without this, a dutiful
-- Syla following skills/push would pair a chat-say with a push-send and
-- ring the phone twice for one reply.

update public.docs
set html = replace(html,
    'One clear push beats three noisy ones.</p>',
    'One clear push beats three noisy ones.</p>'
    || '<p>Chat replies ring on their own: a database trigger queues a push for every <code>chat_messages</code> row with author <code>syla</code>, kind <code>text</code> (coalescing while one is undelivered). Never follow a <code>scripts/chat-say</code> with a <code>push-send</code> about the same reply — that rings the phone twice. Reserve <code>push-send</code> for what has no chat message: a finished job, a proposal in the Inbox.</p>')
where path = 'skills/push';
