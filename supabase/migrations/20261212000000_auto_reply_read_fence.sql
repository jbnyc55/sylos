-- The auto-reply read fence: a send must stand on a just-made read.
--
-- send_auto_reply's gate has been structural (a dm, the counterparty's
-- mode, an active REPLY rule to cite) while the thread itself was only as
-- fresh as the agent's last look — a message landing between that look and
-- the send could ship a stale reply the gate had no way to see. The window
-- was the agent's whole think time: read the thread, run the preflight,
-- compose, send, with nothing re-checked but mode and rule.
--
-- This migration bounds that window by the clock. send_auto_reply now
-- requires _thread_read_at — the moment of a final re-read of the thread,
-- taken as now() FROM THE RE-READ QUERY ITSELF so it is this database's
-- clock — and refuses:
--
--   * a read older than 90 seconds (or in the future): the send must
--     follow the re-read at once, not another round of thinking;
--   * any message on this side of the chat newer than the read: the owner
--     replying themselves, or a concurrent run, after the read.
--
-- What SQL cannot check it still cannot check: the PEER's side of the
-- thread lives in their database, read over the following relay. Re-reading
-- it in the same breath — and restarting the preflight when anything new
-- appeared, stopping entirely when the new message asks for the human —
-- stays agent procedure, bound in skills/chat-replies (updated below)
-- exactly like sentence coverage, and attributable the same way. The fence
-- makes skipping the re-read impossible to hide: there is no send without
-- a fresh attested read behind it.
--
-- The old three-argument signature survives as a teaching stub, so a
-- session still on the old procedure fails with the new contract spelled
-- out instead of a bare "function does not exist".

-- ── The stub: the old signature teaches the new contract ────────────────

create or replace function public.send_auto_reply(_chat_id uuid, _body text, _rule_id uuid)
returns jsonb
language plpgsql
security invoker
as $$
begin
    perform public.assert_claude_rq_key();

    raise exception 'send_auto_reply now requires _thread_read_at: re-read the thread (both sides), take now() from the re-read query, and send within 90 seconds — re-load skills/chat-replies';
end;
$$;

comment on function public.send_auto_reply(uuid, text, uuid) is
    'Retired signature, kept as a teaching stub: always refuses, naming the read fence. The real send is send_auto_reply(uuid, text, uuid, timestamptz).';

-- ── The send, fenced ─────────────────────────────────────────────────────

create function public.send_auto_reply(
    _chat_id        uuid,
    _body           text,
    _rule_id        uuid,
    _thread_read_at timestamptz
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _kind     text;
    _n        integer;
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

    -- The read fence: the send stands on a re-read made moments ago, its
    -- timestamp taken as now() from the re-read query (this database's
    -- clock, so the comparisons below are one clock talking to itself).
    if _thread_read_at is null then
        raise exception 'pass _thread_read_at: now() taken from the final re-read of the thread (skills/chat-replies)';
    end if;
    if _thread_read_at > now() then
        raise exception 'the thread read is in the future — take it as now() from the re-read query itself';
    end if;
    if _thread_read_at < now() - interval '90 seconds' then
        raise exception 'the thread read is % old — re-read the thread (both sides) and send within 90 seconds', age(now(), _thread_read_at);
    end if;

    select kind into _kind from public.chats where id = _chat_id;
    if _kind is null then
        raise exception 'no chat with id %', _chat_id;
    end if;
    if _kind <> 'dm' then
        raise exception 'auto-replies are for dms only (this chat is %)', _kind;
    end if;

    -- The half of the fence SQL can prove: nothing on this side of the
    -- thread postdates the read. The peer's side lives in THEIR database —
    -- re-reading it is the procedure the skills doc binds.
    if exists (
        select 1 from public.chat_messages m
        where m.chat_id = _chat_id and m.created_at > _thread_read_at
    ) then
        raise exception 'the thread moved after your read — restart the preflight against the new messages';
    end if;

    select count(*) into _n from public.chat_followers where chat_id = _chat_id;
    if _n <> 1 then
        raise exception 'auto-replies need exactly one counterparty (this chat names %)', _n;
    end if;
    select follower_id into _follower
    from public.chat_followers where chat_id = _chat_id;

    select syla_reply_mode into _mode
    from public.followers where id = _follower;
    if _mode not in ('auto', 'syla_syla') then
        raise exception 'this connection does not allow auto-replies (mode %)', _mode;
    end if;

    if not exists (
        select 1 from public.reply_rules r
        where r.id = _rule_id
          and r.follower_id = _follower
          and r.status = 'active'
          and r.verdict = 'reply'
    ) then
        raise exception 'the cited rule must be an active REPLY rule of this connection';
    end if;

    insert into public.chat_messages (chat_id, body, author, kind, rule_id)
    values (_chat_id, btrim(_body), 'syla', 'auto_reply', _rule_id)
    returning id into _id;

    return jsonb_build_object('id', _id, 'chat_id', _chat_id, 'rule_id', _rule_id);
end;
$$;

comment on function public.send_auto_reply(uuid, text, uuid, timestamptz) is
    'Sends one attributed auto-reply (author ''syla'', kind ''auto_reply'') into a dm as the claude role, citing the active REPLY rule that authorized it — refused unless the chat is a dm whose single counterparty''s syla_reply_mode is auto or syla_syla, the rule is theirs, active, verdict reply, AND the send stands on a fresh read: _thread_read_at (now() from the final re-read) within 90 seconds, with no own-side message newer than it. Re-reading the peer''s side is skills/chat-replies procedure; this gate is structural. Gated by assert_claude_rq_key().';

revoke all on function public.send_auto_reply(uuid, text, uuid, timestamptz) from public;
grant execute on function public.send_auto_reply(uuid, text, uuid, timestamptz) to anon;

-- ── The procedure, re-bound ──────────────────────────────────────────────
--
-- The skills doc must match the new contract or every auto-reply fails
-- closed on the stub's message, so this update runs wherever the doc does
-- not already teach _thread_read_at — an owner's edited copy included
-- (their version stays one restore away in row_edits, the house guarantee
-- for every doc edit). A doc already naming _thread_read_at is left alone.

update public.docs
set html = $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Chat replies: drafting, the preflight, auto-replies</title>
<style>
  body { margin: 0 auto; max-width: 42rem; padding: 2rem 1.25rem 4rem;
         font: 16px/1.6 system-ui, sans-serif; color: #1a1a1a; background: #fdfdfc; }
  h1 { font-size: 1.6rem; } h2 { font-size: 1.2rem; margin-top: 2rem; }
  code, pre { font-family: ui-monospace, monospace; background: #f0efec; border-radius: 4px; }
  code { padding: 0.1em 0.3em; } pre { padding: 0.75rem; overflow-x: auto; }
  @media (prefers-color-scheme: dark) {
    body { color: #e8e6e3; background: #16181a; }
    code, pre { background: #24272b; }
  }
</style></head>
<body>
<h1>Chat replies: drafting, the preflight, auto-replies</h1>
<p>Chats are the front door of the app, and your work in them is bounded by each connection's <strong>reply ladder</strong> (<code>followers.syla_reply_mode</code>): <code>propose</code> — you draft, the owner sends; <code>auto</code> — you may send where an <em>active reply rule</em> covers it; <code>syla_syla</code> — auto, plus the two agents may talk (only when <code>syla_syla_peer_ok</code> is true as well). You never change the mode. Everything below runs through your gated RPCs; you have no other write into a conversation.</p>
<h2>Finding the work</h2>
<pre>scripts/rq "select c.id, c.kind, c.title, c.waiting_on_human, f.name, f.syla_reply_mode
from chats c
left join chat_followers cf on cf.chat_id = c.id
left join followers f on f.id = cf.follower_id
order by c.updated_at desc"</pre>
<p>Your side's messages are in <code>chat_messages</code>; a peer's side is read over the following relay (<code>skills/following</code>) by the shared <code>chat_key</code>. A chat with <code>waiting_on_human</code> true is waiting on the owner — leave it alone.</p>
<h2>Drafting (every mode)</h2>
<p>Draft with <code>propose_chat_reply(_chat_id, _body, _rationale, _offered_rule_id)</code> — one pending card per chat; a newer draft supersedes the older. Write the draft in the owner's voice, ready to send; put the why in <code>_rationale</code> ("Answered from your calendar"). The owner approving sends it as <em>them</em> — so never draft anything they would not say.</p>
<h2>The preflight (before ANY auto-reply)</h2>
<ol>
<li>Load the connection's rules, top to bottom:
<pre>scripts/rq "select verdict, body, status, built_in from reply_rules
where follower_id = '&lt;follower-id&gt;' and status = 'active' order by rank"</pre></li>
<li>Check the incoming message against each sentence in order. A <strong>DON'T REPLY</strong> rule that covers it stops you. A <strong>REPLY</strong> rule that covers it authorizes exactly the covered answer.</li>
<li><strong>Anything uncovered waits for the human.</strong> Do not send — leave a draft, or nothing, and <code>set_chat_waiting(_chat_id, true)</code> so the chat shows the blue dot.</li>
</ol>
<p>Two guarantees sit above every rule, and no rule edit changes them: <strong>a message that asks for the human always stops you</strong> ("is this really you?", "can I talk to Maya?" — stop, flag the chat, never answer for them), and <strong>never agree to money, travel, or plans with other people</strong> (shipped as the built-in rule; honor it even where an owner has deleted the row).</p>
<h2>Sending under a rule</h2>
<p>Only in mode <code>auto</code> or <code>syla_syla</code>, and only through <code>send_auto_reply(_chat_id, _body, _rule_id, _thread_read_at)</code> — cite the active REPLY rule that covers the message. The send is always attributed (the peer sees "signed as Syla"); the function refuses anything but a dm whose counterparty's mode allows it. Never send as the owner: approved drafts are inserted by <em>their</em> session, not yours.</p>
<h2>The read fence (immediately before EVERY send)</h2>
<p>The thread can move while you think — the peer may say "never mind", or ask for the human, after your last look. So the very last thing you do before <code>send_auto_reply</code> is re-read, in this order:</p>
<ol>
<li>Re-read the <strong>peer's side</strong> over the following relay (<code>skills/following</code>, by the shared <code>chat_key</code>).</li>
<li>Re-read <strong>your side</strong> and take the clock from the same query:
<pre>scripts/rq "select now() as read_at, id, author, kind, body, created_at
from chat_messages where chat_id = '&lt;chat-id&gt;'
order by created_at desc limit 20"</pre></li>
<li>Anything new since the read your reply was built on <strong>restarts the preflight</strong> — and a new message asking for the human stops you entirely.</li>
<li>Nothing new → send at once, passing that <code>read_at</code> as <code>_thread_read_at</code>.</li>
</ol>
<p>The function holds you to the half it can see: it refuses a read older than 90 seconds, a read in the future, and any message on your side newer than the read. The peer's side lives in <em>their</em> database, out of its sight — step 1 is yours the way sentence coverage is yours, and skipping it is attributable after the fact.</p>
<h2>Suggesting a rule</h2>
<p>At most ONE pending suggestion per connection, and only after an approval showed you what the owner wants: <code>suggest_reply_rule(_follower_id, _verdict, _body, _rationale, _needs_integration)</code>. Write the sentence so the owner can edit it; if the rule needs an integration you don't have (say, location), name its slug in <code>_needs_integration</code> and disclose it in the body ("needs your iPhone's location — connecting it is the next step"). Offer the next suggestion only after a yes.</p>
<h2>What goes to the Inbox instead</h2>
<p>Syla × Syla conclusions, calendar adds you infer from a chat, and anything else that changes the owner's records go through <code>propose_approval</code> (<code>syla_approvals</code>) — never applied by you. Your reports and receipts in the Syla conversation go through <code>syla_chat_say</code>.</p>
<p>Done looks like: every chat that needed the owner wears the blue dot, every draft is a card with its rationale, every sent auto-reply cites its rule and stands on a read seconds old, and nothing was sent that a rule did not cover.</p>
<footer>doc <code>skills/chat-replies</code></footer>
</body></html>$doc$
where path = 'skills/chat-replies'
  and html not like '%\_thread\_read\_at%';
