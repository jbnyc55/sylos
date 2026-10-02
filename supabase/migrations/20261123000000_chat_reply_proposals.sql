-- Chat reply proposals: Syla's drafts in the thread.
--
-- In propose mode (every connection's starting rung) Syla never sends —
-- she drafts. A draft is a pending chat_reply_proposals row the thread
-- renders as a card; approving it is the OWNER'S act, in two owner-session
-- writes: insert the chat_messages row (author 'me' — an approved draft
-- sends as the human; only rule-gated auto mode ever sends as 'syla') and
-- flip the proposal to 'approved'. After an approval the SAME card
-- advances to offer exactly one reply rule — offered_rule_id points at the
-- status-'suggested' reply_rules row Syla created alongside the draft
-- (suggest_reply_rule's one-pending cap holds the "exactly one"). Nothing
-- here is a write to the conversation: a dismissed or superseded draft
-- never existed as far as the peer can tell, and everything is
-- row_edits-logged like every table.

create table public.chat_reply_proposals (
    id              uuid primary key default gen_random_uuid(),
    chat_id         uuid not null references public.chats (id) on delete cascade,
    body            text not null check (char_length(body) between 1 and 8000),
    -- Shown under the draft: 'Answered from your calendar'.
    rationale       text check (rationale is null or char_length(rationale) <= 500),
    status          text not null default 'pending'
                    check (status in ('pending', 'approved', 'dismissed',
                                      'superseded', 'withdrawn')),
    offered_rule_id uuid references public.reply_rules (id) on delete set null,
    created_at      timestamptz not null default now(),
    resolved_at     timestamptz
);

comment on table public.chat_reply_proposals is
    'Syla''s drafted replies, one pending card per chat (a newer draft supersedes the older). Approving is client-side as the owner: insert the chat_messages row (author ''me'') and flip status — the agent''s role only ever inserts pending drafts through propose_chat_reply(). offered_rule_id is the one reply rule the card offers after a yes.';
comment on column public.chat_reply_proposals.status is
    'pending: on the card. approved / dismissed: the owner''s ruling. superseded: a newer draft replaced it. withdrawn: Syla took it back (e.g. the thread moved on before the owner saw it).';
comment on column public.chat_reply_proposals.offered_rule_id is
    'The status-''suggested'' reply_rules row created alongside the draft: after approval the same card advances to offer exactly this one rule. Accepting = the owner flips that rule suggested → active; declining = draft, or delete.';

create index chat_reply_proposals_pending_idx
    on public.chat_reply_proposals (chat_id, status, created_at);

alter table public.chat_reply_proposals enable row level security;
select public.declare_table_siloing('chat_reply_proposals', 'system');

-- The owner reads the cards, rules on them, prunes old ones. Drafts are
-- strictly local: no follower ever reads a proposal, whatever the chat's
-- roster says — their client only ever sees messages.
create policy "Reply proposals are viewable by the owner"
    on public.chat_reply_proposals for select to authenticated
    using (public.is_owner());
create policy "Reply proposals are resolvable by the owner"
    on public.chat_reply_proposals for update to authenticated
    using (public.is_owner()) with check (public.is_owner());
create policy "Reply proposals are deletable by the owner"
    on public.chat_reply_proposals for delete to authenticated
    using (public.is_owner());

create policy "claude reads reply proposals"
    on public.chat_reply_proposals for select to claude using (true);
create policy "claude drafts pending proposals"
    on public.chat_reply_proposals for insert to claude
    with check (status = 'pending');
-- The one state change the agent may make to its own drafts: pending →
-- superseded (a newer draft replacing it) or withdrawn.
create policy "claude retires its own pending drafts"
    on public.chat_reply_proposals for update to claude
    using (status = 'pending')
    with check (status in ('superseded', 'withdrawn'));

grant select, delete on public.chat_reply_proposals to authenticated;
grant update (status, resolved_at) on public.chat_reply_proposals to authenticated;
grant select on public.chat_reply_proposals to claude;
grant insert (chat_id, body, rationale, offered_rule_id)
    on public.chat_reply_proposals to claude;
grant update (status, resolved_at) on public.chat_reply_proposals to claude;

-- ── The draft RPC ────────────────────────────────────────────────────────

create function public.propose_chat_reply(
    _chat_id         uuid,
    _body            text,
    _rationale       text default null,
    _offered_rule_id uuid default null
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _id uuid;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    if _body is null or char_length(btrim(_body)) not between 1 and 8000 then
        raise exception 'the draft must be 1–8000 characters';
    end if;
    if _rationale is not null and char_length(_rationale) > 500 then
        raise exception 'the rationale is longer than 500 characters';
    end if;
    if not exists (select 1 from public.chats c where c.id = _chat_id) then
        raise exception 'no chat with id %', _chat_id;
    end if;
    if _offered_rule_id is not null and not exists (
        select 1 from public.reply_rules r
        where r.id = _offered_rule_id and r.status = 'suggested'
    ) then
        raise exception 'the offered rule must be a pending (suggested) reply_rules row';
    end if;

    -- A newer draft replaces the older: one card per chat.
    update public.chat_reply_proposals
    set status = 'superseded', resolved_at = now()
    where chat_id = _chat_id and status = 'pending';

    -- Belt and braces behind the supersede: never more than 3 pending.
    if (select count(*) from public.chat_reply_proposals
        where chat_id = _chat_id and status = 'pending') >= 3 then
        raise exception 'this chat already has 3 pending drafts — wait for the owner';
    end if;

    insert into public.chat_reply_proposals (chat_id, body, rationale, offered_rule_id)
    values (_chat_id, btrim(_body), _rationale, _offered_rule_id)
    returning id into _id;

    return jsonb_build_object('id', _id, 'chat_id', _chat_id, 'status', 'pending');
end;
$$;

comment on function public.propose_chat_reply(uuid, text, text, uuid) is
    'Files one pending drafted reply for a chat as the claude role, superseding any older pending draft there (one card per chat; hard cap 3). The owner approves from the thread — their session inserts the message as ''me'' and flips the status. Gated by assert_claude_rq_key().';

revoke all on function public.propose_chat_reply(uuid, text, text, uuid) from public;
grant execute on function public.propose_chat_reply(uuid, text, text, uuid) to anon;

-- ── The skill that binds the procedure ───────────────────────────────────
--
-- The preflight, the platform guarantees, and which RPC carries which act
-- — seeded once; the owner's later edits are theirs (insert-if-absent,
-- the house pattern for doc seeds).

insert into public.docs (path, title, html)
select 'skills/chat-replies', 'Chat replies: drafting, the preflight, auto-replies', $doc$<!doctype html>
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
<p>Only in mode <code>auto</code> or <code>syla_syla</code>, and only through <code>send_auto_reply(_chat_id, _body, _rule_id)</code> — cite the active REPLY rule that covers the message. The send is always attributed (the peer sees "signed as Syla"); the function refuses anything but a dm whose counterparty's mode allows it. Never send as the owner: approved drafts are inserted by <em>their</em> session, not yours.</p>
<h2>Suggesting a rule</h2>
<p>At most ONE pending suggestion per connection, and only after an approval showed you what the owner wants: <code>suggest_reply_rule(_follower_id, _verdict, _body, _rationale, _needs_integration)</code>. Write the sentence so the owner can edit it; if the rule needs an integration you don't have (say, location), name its slug in <code>_needs_integration</code> and disclose it in the body ("needs your iPhone's location — connecting it is the next step"). Offer the next suggestion only after a yes.</p>
<h2>What goes to the Inbox instead</h2>
<p>Syla × Syla conclusions, calendar adds you infer from a chat, and anything else that changes the owner's records go through <code>propose_approval</code> (<code>syla_approvals</code>) — never applied by you. Your reports and receipts in the Syla conversation go through <code>syla_chat_say</code>.</p>
<p>Done looks like: every chat that needed the owner wears the blue dot, every draft is a card with its rationale, every sent auto-reply cites its rule, and nothing was sent that a rule did not cover.</p>
<footer>doc <code>skills/chat-replies</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'skills/chat-replies');

-- Into the skills silo, where the rest of the library sits (guarded like
-- 20260929000000's placements).
insert into public.doc_silos (doc_id, silo_id)
select d.id, s.id
from public.docs d
join public.silos s on s.name = 'skills'
where d.path = 'skills/chat-replies'
  and not exists (select 1 from public.doc_silos j
                  where j.doc_id = d.id and j.silo_id = s.id);
