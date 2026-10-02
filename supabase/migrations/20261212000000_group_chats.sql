-- Group chats: the same machinery, several people at once.
--
-- The schema has carried kind = 'group' since 20261116000000 ("a group
-- is a roster, locally copied"), but auto-replies still assumed a
-- single counterparty. This migration closes that, under one design
-- rule the client shares: THERE ARE NO GROUP RULES. Reply rules stay
-- per person (reply_rules.follower_id), whatever chat the message
-- arrived in — the group UI is only ever a convenience that edits
-- several individual lists at once. Nothing new is stored about "the
-- group's" reply behavior, so nothing new can drift from the
-- per-person truth.
--
-- send_auto_reply loses its dm-only gate. In a group Syla answers ONE
-- person's message under THAT person's active REPLY rule — the
-- structural proof becomes: the cited rule's person is named on the
-- chat, and their own syla_reply_mode allows sending. For a dm this is
-- the same gate as before (the one named follower is the only person
-- whose rules can qualify); for a group it binds the send to the person
-- being answered. The whole roster reads the reply — that is what a
-- group is — but the authorization is, as always, one connection's mode
-- and one connection's rule, attributable via rule_id.
--
-- What this deliberately does NOT add:
--
--   * A travelling rename. chats.title was always each side's own name
--     for the conversation; a group rename stays exactly that — one
--     UPDATE on your own row, visible only to you. No shared mutable
--     state appears anywhere.
--   * Any widening of a follower's read. A follower still reads only
--     the chats that name them, the messages of those chats, and their
--     own naming row — never the rest of the roster (who else the
--     owner talks to is the owner's record). A mirrored copy therefore
--     names the people its owner can identify; cross-database identity
--     for the full roster is its own future feature, not a policy
--     loosening.

create or replace function public.send_auto_reply(_chat_id uuid, _body text, _rule_id uuid)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _kind     text;
    _follower uuid;
    _mode     text;
    _id       uuid;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    if _body is null or char_length(btrim(_body)) not between 1 and 8000 then
        raise exception 'the message must be 1–8000 characters';
    end if;

    select kind into _kind from public.chats where id = _chat_id;
    if _kind is null then
        raise exception 'no chat with id %', _chat_id;
    end if;
    if _kind not in ('dm', 'group') then
        raise exception 'auto-replies are for dms and group chats only (this chat is %)', _kind;
    end if;

    -- The cited rule names the person being answered; everything hangs
    -- off them. Rules are per person — in a group exactly as in a dm.
    select r.follower_id into _follower
    from public.reply_rules r
    where r.id = _rule_id and r.status = 'active' and r.verdict = 'reply';
    if _follower is null then
        raise exception 'the cited rule must be an active REPLY rule';
    end if;

    if not exists (
        select 1 from public.chat_followers cf
        where cf.chat_id = _chat_id and cf.follower_id = _follower
    ) then
        raise exception 'the cited rule''s person is not named on this chat';
    end if;

    select syla_reply_mode into _mode
    from public.followers where id = _follower;
    if _mode not in ('auto', 'syla_syla') then
        raise exception 'this connection does not allow auto-replies (mode %)', _mode;
    end if;

    insert into public.chat_messages (chat_id, body, author, kind, rule_id)
    values (_chat_id, btrim(_body), 'syla', 'auto_reply', _rule_id)
    returning id into _id;

    return jsonb_build_object('id', _id, 'chat_id', _chat_id, 'rule_id', _rule_id);
end;
$$;

comment on function public.send_auto_reply(uuid, text, uuid) is
    'Sends one attributed auto-reply (author ''syla'', kind ''auto_reply'') into a dm or group chat as the claude role, citing the active REPLY rule that authorized it — refused unless the rule''s own person is named on the chat and their syla_reply_mode is auto or syla_syla. In a group this binds the send to the one person being answered; the roster reads it, the rule authorizes it. The semantic preflight is skills/chat-replies; this gate is structural. Gated by assert_claude_rq_key().';

comment on column public.chats.title is
    'This side''s own name for the conversation; '''' shows the roster''s names. Renaming — a group included — is each side''s own affair: one update here, visible only to this owner.';

-- ── The skill learns the group shape ─────────────────────────────────────
--
-- Docs are data: guarded replace, so an owner's edits are never
-- clobbered — the patch lands only while the seeded sentence is intact.

update public.docs
set html = replace(html,
    'the function refuses anything but a dm whose counterparty''s mode allows it',
    'the function refuses anything unless the chat is a dm or group, the cited rule''s own person is named on it, and that person''s mode allows it. In a group, answer ONE person''s message under THAT person''s rule — rules are per person; there are no group rules, and a draft answering nobody''s covered question waits for the owner')
where path = 'skills/chat-replies'
  and html like '%the function refuses anything but a dm whose counterparty''s mode allows it%';
