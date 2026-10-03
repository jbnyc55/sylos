-- The integration moment: ask before you draft.
--
-- Seen in the field: "where are you right now?" landed in a chat, and
-- Syla drafted around the hole — "I don't share where you are on my
-- own, so finish that part yourself." A half-draft that punts is a
-- failed ask: she needs that data to make the proposal, and the app
-- already has the whole connect flow waiting behind a needs-integration
-- rule suggestion (the card opens the connect sheet; connecting turns
-- the integration on). What forbade it was one sentence in the seeded
-- skill — suggestions only after an approval. This migration carves out
-- the exception and teaches the order: suggestion first, flag the chat,
-- draft only once the data exists.
--
-- Doc edits are the house pattern: targeted text swaps, guarded so an
-- owner's own edits survive and a re-run no-ops.

update public.docs
set html = replace(html,
    'At most ONE pending suggestion per connection, and only after an approval showed you what the owner wants:',
    'At most ONE pending suggestion per connection, and — the integration moment below aside — only after an approval showed you what the owner wants:')
where path = 'skills/chat-replies';

update public.docs
set html = replace(html,
    '<footer>doc <code>skills/chat-replies</code></footer>',
    '<h2>The integration moment — ask before you draft</h2>
<p>A message that needs data an integration you don''t have would provide — "where are you?" with no location, "am I free Tuesday?" with no calendar — is NOT something to draft around: you need that data to make the proposal, so a half-draft that punts ("finish that part yourself") is a failed ask. Skip the draft. File the rule suggestion immediately (no prior approval needed): <code>suggest_reply_rule</code> with <code>_needs_integration</code> naming the slug, the body a sentence the owner can keep ("Where-are-you questions — answer from my iPhone''s location"), the rationale naming the message it would answer. Then <code>set_chat_waiting(_chat_id, true)</code> and stop. In the app that suggestion wears the connect flow — accepting it turns the integration on and wakes you. On that waking, with the integration connected and the rule active, answer the waiting message with the real data: a draft in propose mode, a rule-covered <code>send_auto_reply</code> in auto.</p>
<footer>doc <code>skills/chat-replies</code></footer>')
where path = 'skills/chat-replies'
  and html like '%<footer>doc <code>skills/chat-replies</code></footer>%'
  and html not like '%The integration moment%';
