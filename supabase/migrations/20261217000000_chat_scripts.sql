-- The chat writes get their scripts — and the skill names them.
--
-- Seen in the field: a receipt into the Syla conversation was blocked by
-- the session's permission layer. Every other agent write is a scripts/
-- wrapper, pre-approved as Bash(scripts/*) by the repo's settings; the
-- chat family (syla_chat_say, propose_chat_reply, send_auto_reply,
-- set_chat_waiting, suggest_reply_rule) had no wrappers, so each call was
-- an improvised raw curl the harness judged one by one — and a command
-- visibly carrying the owner's location to a URL looks like exfiltration
-- to a guard that cannot know the URL is the owner's own database.
--
-- The wrappers land in scripts/ (chat-say, chat-propose, chat-auto-reply,
-- chat-waiting, suggest-reply-rule — this repo, same commit); this
-- migration re-points the seeded skill at them. House pattern: targeted,
-- guarded text swaps.

update public.docs
set html = replace(html,
    'Everything below runs through your gated RPCs; you have no other write into a conversation.</p>',
    'Everything below runs through your gated RPCs, and every one has a <code>scripts/</code> wrapper — always call the script, never a raw curl: the wrappers are what your session''s permissions pre-approve, and an improvised curl can be refused mid-run.</p>')
where path = 'skills/chat-replies';

update public.docs
set html = replace(html,
    '<p>Draft with <code>propose_chat_reply(_chat_id, _body, _rationale, _offered_rule_id)</code>',
    '<p>Draft with <code>scripts/chat-propose --chat &lt;chat-id&gt; --body &lt;draft&gt; [--rationale &lt;why&gt;] [--offered-rule &lt;rule-id&gt;]</code>')
where path = 'skills/chat-replies';

update public.docs
set html = replace(html,
    '<code>set_chat_waiting(_chat_id, true)</code>',
    '<code>scripts/chat-waiting --chat &lt;chat-id&gt; --on</code>')
where path = 'skills/chat-replies';

update public.docs
set html = replace(html,
    'only through <code>send_auto_reply(_chat_id, _body, _rule_id)</code>',
    'only through <code>scripts/chat-auto-reply --chat &lt;chat-id&gt; --body &lt;reply&gt; --rule &lt;rule-id&gt;</code>')
where path = 'skills/chat-replies';

update public.docs
set html = replace(html,
    '<code>suggest_reply_rule(_follower_id, _verdict, _body, _rationale, _needs_integration)</code>',
    '<code>scripts/suggest-reply-rule --follower &lt;follower-id&gt; --verdict reply|dont_reply --body &lt;sentence&gt; [--rationale &lt;why&gt;] [--needs-integration &lt;slug&gt;]</code>')
where path = 'skills/chat-replies';

update public.docs
set html = replace(html,
    'go through <code>syla_chat_say</code>.',
    'go through <code>scripts/chat-say --body &lt;reply&gt; [--run &lt;run-id&gt;]</code>.')
where path = 'skills/chat-replies';

-- The poke section and the integration moment name the bare functions in
-- passing; the scripts are the same calls.
update public.docs
set html = replace(html,
    'a rule-covered <code>send_auto_reply</code> in auto',
    'a rule-covered <code>scripts/chat-auto-reply</code> in auto')
where path = 'skills/chat-replies';

update public.docs
set html = replace(html,
    'and <code>set_chat_waiting</code> when nothing covers it',
    'and <code>scripts/chat-waiting --on</code> when nothing covers it')
where path = 'skills/chat-replies';

update public.docs
set html = replace(html,
    '<code>suggest_reply_rule</code> with <code>_needs_integration</code> naming the slug',
    '<code>scripts/suggest-reply-rule</code> with <code>--needs-integration</code> naming the slug')
where path = 'skills/chat-replies';
