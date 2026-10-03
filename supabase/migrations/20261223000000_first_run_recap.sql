-- The walkthrough's day two: the recap card, approved in the chat.
--
-- The first-run walkthrough (20261222000000) ends on the payoff — an
-- app on the Home screen. This adds the beat after it: before the
-- payoff message, Syla files ONE approvable card — a next-morning
-- "health recap" event, assigned to her — and because the card rides
-- syla_approvals with its chat_id pointing at the Syla conversation,
-- the clients render Approve/Dismiss inline in the thread (the iOS and
-- web repos, same stroke). The owner never leaves the conversation to
-- say yes; the Inbox still shows the card too, as every approval.
--
-- Two small contract widenings carry it, no schema change — the payload
-- is jsonb, the clients decide what they honor:
--
--   * calendar_add payload learns `assignee` ('me'|'syla', default
--     'me'): a 'syla' event is HER event — the dispatcher queues her a
--     run at start time, and the event's title is that run's
--     instruction. The agent still only ever inserts a pending card;
--     what turns it into a firing event is the owner's approval,
--     applied client-side as the owner, exactly the house pattern.
--   * ...and `freq` ('daily'|'weekly'|'monthly'|'yearly', default
--     one-shot, interval 1): the "want this every morning?" yes needs
--     a repeating event, and the card should say what it repeats.
--
-- scripts/propose-event (this repo, same commit) is the wrapper — the
-- chat-scripts lesson (20261217000000): every write path gets a
-- scripts/ wrapper, or sessions improvise curls the permission layer
-- refuses. Doc edits are the house pattern: targeted, guarded swaps.

comment on column public.syla_approvals.payload is
    'What approving applies, by kind — calendar_add: {title, start_date, start_time, end_time, assignee, freq} for the events insert (assignee ''syla'' makes it her event, fired by the dispatcher at start time; freq makes it repeat at interval 1; both optional — ''me'' and one-shot are the defaults); silo_membership: {silo_id, action, subject}; silo_edit: {silo_id | silo_name, description, default_allows_*, rules, tables, remove_tables, followers, remove_followers} — the structured silo change the owner''s client builds on approve. The client applies nothing beyond its kind''s documented fields.';

-- ── skills/first-run: the payoff files the recap card first ─────────────

update public.docs
set html = replace(html,
    '<p>A new app lands on the owner''s Home screen by itself. Then the payoff, short:</p>
<blockquote>Done ✨ Open <strong>Home</strong> — your new app is there. Tap it.<br>
Want anything changed — colors, more data, a goal line? Just tell me. That''s how this works: you ask, I build.</blockquote>',
    '<p>A new app lands on the owner''s Home screen by itself. Before the payoff message, file the day-two card — a next-morning recap event, assigned to you, linked to the Syla conversation so Approve sits right there in the thread:</p>
<pre>scripts/rq "select id from chats where kind = ''syla''"
scripts/propose-event --chat &lt;that id&gt; --assignee syla \
    --date &lt;tomorrow&gt; --start 08:30 \
    --title "Health recap: read the last day of health_samples and send a short summary in the Syla conversation" \
    --detail "Tomorrow morning I''ll check your new data and send you a recap here."</pre>
<p>Then the payoff, short:</p>
<blockquote>Done ✨ Open <strong>Home</strong> — your new app is there. Tap it.<br>
One more thing: approve the card below and tomorrow morning I''ll check your new data and send you a recap.<br>
Want anything changed — colors, more data, a goal line? Just tell me. That''s how this works: you ask, I build.</blockquote>')
where path = 'skills/first-run'
  and html not like '%the day-two card%';

-- ── skills/first-run: what to do when the recap event fires ─────────────

update public.docs
set html = replace(html,
    '<h2>Housekeeping</h2>',
    '<h2>Day two — when the recap event fires</h2>
<p>The approved card becomes an event assigned to you: the dispatcher queues a run at its start time, and the claim''s event title is the instruction. Keep the walkthrough voice — short, one thing. First the staleness guard:</p>
<pre>scripts/rq "select max(starts_at) from health_samples"</pre>
<p>Older than a day means the phone hasn''t synced; don''t recap stale numbers — "Open Sylos for a second so your health data syncs — I''ll catch it next time." and finish the run. Fresh data earns a real recap: two or three sentences, actual numbers, and ONE comparison that means something (against the day before, or the week''s average). End by offering the habit: "Want this every morning? Reply <em>yes</em>." A later <em>yes</em> arrives as a message run — file one more card with <code>scripts/propose-event</code>, this time <code>--freq daily</code>, starting the next day. A dismissed card is an answer: never re-file it unasked.</p>
<h2>Housekeeping</h2>')
where path = 'skills/first-run'
  and html not like '%when the recap event fires%';

-- ── skills/first-run: "done" now includes the approved card ─────────────

update public.docs
set html = replace(html,
    'Done looks like: the owner tapped through Integrations, answered one question, and is looking at a chart app on their Home screen they watched you make.',
    'Done looks like: the owner tapped through Integrations, answered one question, is looking at a chart app on their Home screen they watched you make — and approved tomorrow''s recap without ever leaving the conversation.')
where path = 'skills/first-run';
