-- The walkthrough's last act: the first connection, as a race.
--
-- The first-run walkthrough (20261222000000) ends on an app the owner
-- watched Syla build; the recap (20261223000000) carries it into day
-- two. This adds the closing beat: after the recap lands, Syla offers
-- to turn the steps chart into a TWO-PLAYER RACE with a friend — the
-- first connection, earned by a payoff instead of asked for as a favor.
--
-- The beats lean on two platform pieces shipped alongside:
--
--   * app_share messages (20261226000000) — the share card the owner
--     sends from the chat; one accept on the other side copies the app
--     home and grants the health silo back.
--   * the claim wake (20261227000000) — accepting the invite queues a
--     run here, so Syla can tell the owner "they're in" the moment it
--     happens.
--
-- Everything respects the boundary as always: Syla BUILDS the race app
-- (her gated deploy), but inviting, sharing and granting are the
-- owner's taps — sharing is a grant, and grants are the owner's alone.
-- Because chat messages live in the sender's database and a follower's
-- key is minted only at claim time, the whole race side of the chat can
-- be staged while the invite is still in flight: it delivers itself the
-- moment the friend accepts.
--
-- Doc edits are the house pattern: targeted, guarded swaps on the
-- seeded skills/first-run doc, so an owner's own edits survive and
-- re-runs no-op.

-- ── The stage-marker note learns the race has its own markers ────────────

update public.docs
set html = replace(html,
    $a$Once <code>app_done</code> is true the walkthrough is over forever; never restart it on your own.$a$,
    $b$Once <code>app_done</code> is true the chart walkthrough is over forever; never restart it on your own. One act remains after it — the first connection (the race sections below), read off its own markers the same way.$b$)
where path = 'skills/first-run'
  and html not like '%the race sections below%';

-- ── The day-two recap hands off to the race ──────────────────────────────

update public.docs
set html = replace(html,
    $a$A dismissed card is an answer: never re-file it unasked.</p>$a$,
    $b$A dismissed card is an answer: never re-file it unasked.</p>
<p>The owner's <em>yes</em> or <em>no</em> to the habit is also the race's cue: answer it, and — while <code>followers</code> is still empty — end that same reply with the race offer (the sections below). One ask per message still holds: the habit answer needs no question back, so the race question can close the reply.</p>$b$)
where path = 'skills/first-run'
  and html not like '%the race offer (the sections below)%';

-- ── The race stages, before Housekeeping ─────────────────────────────────

update public.docs
set html = replace(html,
    $a$<h2>Housekeeping</h2>$a$,
    $b$<h2>The race — the first connection</h2>
<p>After the chart and the recap, the walkthrough's last act is the owner's first connection, delivered as a two-player steps race. Stage from the database, as always:</p>
<pre>scripts/rq "select (select count(*)::int from followers) as connections,
       (select count(*)::int from followers where invite_code_hash is not null and claimed_at is null) as invited,
       exists(select 1 from vibe_code_apps where slug = 'steps-race') as race_built"</pre>
<p>Offer the race only while <code>connections</code> is zero, and only once: before offering, check your own recent lines in the Syla conversation — the database holds them — and never re-offer after a <em>no</em> ("Say <em>set up a race</em> whenever you want it" closes it). The offer, short:</p>
<blockquote>One more thing — steps are better with company 🏁 Want to turn your chart into a race with a friend? Reply <em>who with</em>.</blockquote>
<h2>Race stage one — they said yes: send the invite</h2>
<blockquote>Here's how to get them in:<br>
1. Tap <strong>Home</strong>, then <strong>Connections</strong><br>
2. Add them by name and send the invite link it hands you — iMessage is perfect<br>
3. Reply <em>sent</em> when it's away.<br>
That link is a personal key to just what you choose to share — nothing is shared until you say so.</blockquote>
<p>If they reply <em>sent</em> and <code>invited</code> is still zero, the link was never minted: give the two taps again, shorter, once.</p>
<h2>Race stage two — invited: build the race now</h2>
<p>Don't wait for the accept — build while the invite is in flight, so the chat the friend wakes up in already holds the payoff. Load <code>skills/vibe-apps</code> first, then build <code>steps-race</code> in the first app's visual language, and as beautiful:</p>
<ul>
<li>Today big at the top — both people's step counts side by side, the leader marked; a 14-day two-line chart under it.</li>
<li>Own steps from <code>health_samples</code> (kind steps, summed per day at display time); the friend's over <code>following</code> → each row's <code>follower_rq</code> (plain fetch, <code>Promise.allSettled</code>, per-peer failure states — the vibe-apps doc has the shape).</li>
<li>Graceful while half-empty: no <code>following</code> row yet means "Waiting for them 🏁"; a connected friend sharing nothing yet means "No steps from them yet". It may be solo for days, so solo must look good.</li>
<li>Ship a manifest (<code>sylos-manifest.json</code>, deployed with <code>--src-dir</code>): <code>requires.silos ["health"]</code>, <code>requires.peers true</code>, and the <code>health_samples</code> column intent — the share card on the friend's side reads it to know what to grant back.</li>
</ul>
<pre>scripts/vibe-save --slug steps-race --name "Steps Race" \
    --hint "daily steps, head to head" --icon "🏁" \
    --html-file app.html --src-dir src/</pre>
<p>Then the share — sharing is a grant, so it is the owner's taps, never your write:</p>
<blockquote>Built ✨ Now hand it over:<br>
1. Tap <strong>Chats</strong> and open your chat with them<br>
2. Tap <strong>+</strong>, choose <strong>Share an app</strong>, pick <strong>Steps Race</strong><br>
3. Send it.<br>
Sharing it shares your steps with them and asks for theirs back — the card does both. They'll see it all the moment they join.</blockquote>
<p>The chat with an invited person already works before they accept: messages wait in this database and deliver themselves when the claim mints their key. Write the thread to be read on arrival.</p>
<h2>Race stage three — the claim run: they joined</h2>
<p>An accepted invite queues a run whose claim entry carries a <code>claim</code> field — who joined, and <code>connected_back</code>. Tell the owner in the Syla conversation, short:</p>
<blockquote>They just joined 🎉 You're connected both ways. The race fills in the moment they accept the card in your chat and share their steps back.</blockquote>
<p>If <code>connected_back</code> is false they joined without a database of their own: say they can read what's shared and chat, and the race turns two-player when they finish their own setup. After this run the walkthrough — chart, recap, race — is over for good.</p>
<h2>Housekeeping</h2>$b$)
where path = 'skills/first-run'
  and html not like '%The race — the first connection%';

-- ── "Done" now includes the race ─────────────────────────────────────────

update public.docs
set html = replace(html,
    $a$and approved tomorrow's recap without ever leaving the conversation.$a$,
    $b$and approved tomorrow's recap without ever leaving the conversation — and, by the race's end, has their first connection with Steps Race waiting in the chat.$b$)
where path = 'skills/first-run'
  and html not like '%has their first connection with Steps Race%';
