-- First run: the Health walkthrough.
--
-- Syla's first fire used to be a wiring test — "complete the todo with a
-- one-line hello" — so the owner's very first Syla message was a shrug.
-- The first minutes decide what people think Syla IS, so the setup
-- page's first fire becomes a walkthrough (the company repo changes the
-- fire text in the same stroke): Syla gets the owner's Apple Health
-- connected, asks one question about what they want to see, then builds
-- a chart app that lands on their Home screen — proof, inside their
-- first session, that they can ask her for apps.
--
-- The playbook is a skill doc, because that is where every capability
-- beyond CLAUDE.md lives (20260929000000_skills_as_docs.sql): seeded
-- here, editable in the app, listed by the skills query every session
-- starts with. The walkthrough spans several message runs (connect,
-- choose, build), and sessions share no memory — so the doc's one
-- structural rule is that the DATABASE is the stage marker: no
-- health_samples yet means stage one, samples but no first-chart app
-- means stage two, and the deployed app ends the walkthrough for good.
--
-- Guarded like every seeded doc: insert only where the path is absent,
-- so a re-run no-ops and an owner's own edits survive.

insert into public.docs (path, title, html)
select 'skills/first-run', 'First run: the Health walkthrough', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>First run: the Health walkthrough</title>
<style>
  body { margin: 0 auto; max-width: 42rem; padding: 2rem 1.25rem 4rem;
         font: 16px/1.6 system-ui, sans-serif; color: #1a1a1a; background: #fdfdfc; }
  h1 { font-size: 1.6rem; } h2 { font-size: 1.2rem; margin-top: 2rem; }
  code, pre { font-family: ui-monospace, monospace; background: #f0efec; border-radius: 4px; }
  code { padding: 0.1em 0.3em; } pre { padding: 0.75rem; overflow-x: auto; white-space: pre-wrap; }
  blockquote { margin: 0.75rem 0; padding: 0.6rem 0.9rem; border-left: 3px solid #c9c4ba;
               background: #f6f5f1; border-radius: 4px; }
  @media (prefers-color-scheme: dark) {
    body { color: #e8e6e3; background: #16181a; }
    code, pre { background: #24272b; }
    blockquote { background: #1d2024; border-left-color: #3a3f46; }
  }
</style></head>
<body>
<h1>First run: the Health walkthrough</h1>
<p>The owner's first minutes with you decide what they think you are. Their very first message — fired by the setup page as they finish — starts this walkthrough: get Apple Health connected, ask one question about what they want to see, then put a beautiful chart app on their Home screen. By the end they have watched you build them an app. That is the point; everything below serves it.</p>

<h2>How to tell you're in it</h2>
<p>The walkthrough is unfinished while the first app doesn't exist. Read the stage from the database every run — sessions share no memory, and the database never lies:</p>
<pre>scripts/rq "select exists(select 1 from vibe_code_apps where slug = 'first-chart') as app_done,
       (select count(*)::int from health_samples) as samples"</pre>
<p>While <code>app_done</code> is false, read every message run against this doc first. The kickoff is a message asking you to start (it mentions setup, a walkthrough, or a first app); after that, short replies in the Syla conversation — <em>done</em>, <em>ok</em>, a bare number, a data name — are walkthrough steps, answered from whatever stage the query says. Once <code>app_done</code> is true the walkthrough is over forever; never restart it on your own.</p>
<p>It is a welcome, not a cage: a message about anything else gets answered like any other message, and the walkthrough resumes on their next short reply. <em>Skip</em>, <em>stop</em> or <em>later</em> gets one line of acknowledgment ("No problem — say <em>build my first app</em> whenever you want it") and then you stop treating replies as steps until they ask.</p>

<h2>How to talk during it</h2>
<p>These rules are binding for every walkthrough message:</p>
<ul>
<li><strong>Short.</strong> Two or three sentences, or a numbered list of taps. Never a paragraph of explanation.</li>
<li><strong>One step per message.</strong> Never the whole plan, never two asks at once.</li>
<li><strong>Taps by their on-screen names</strong>, a few words each: Home, Integrations, Health, Start mirroring.</li>
<li><strong>No internals.</strong> No table names, SQL, slugs, scripts or file paths in anything the owner reads.</li>
<li><strong>End with the one thing to do next</strong> ("Then reply <em>done</em>.").</li>
</ul>

<h2>Stage one — no health samples yet</h2>
<p>Send the welcome and the connect steps. The owner may still be on the web finishing setup — the message simply waits in their chat, so write it to be read whenever they arrive:</p>
<blockquote>Hey, I'm Syla 👋 Let's build your first app — a live chart of your own health data.<br>
First, connect Apple Health:<br>
1. Tap <strong>Home</strong> (bottom right)<br>
2. Tap <strong>Integrations</strong><br>
3. Tap <strong>Health</strong>, then <strong>Start mirroring</strong><br>
4. Allow what you're happy to share<br>
Then come back here and reply <em>done</em>.</blockquote>
<p>If they reply <em>done</em> and the count is still zero, the first sync is probably mid-flight: "Almost — your data is still syncing. Give it a minute, then reply <em>done</em> again." If it's still zero after that, don't loop them: offer to build the app anyway ("It'll fill in as your data arrives — want that? Reply <em>yes</em>") or to chart something else they'd rather start with.</p>

<h2>Stage two — samples, but no app and no choice yet</h2>
<p>See what actually arrived, then ask the one question:</p>
<pre>scripts/rq "select kind, count(*)::int n from health_samples group by kind order by n desc"</pre>
<p>Offer only kinds that really have rows, at most four, as a numbered list:</p>
<blockquote>It's flowing — I can see your steps, sleep and heart rate 🎉<br>
What should your first app chart?<br>
1. Steps<br>
2. Sleep<br>
3. Heart rate<br>
Reply with a number.</blockquote>

<h2>Stage three — they chose: build it</h2>
<p>Load <code>skills/vibe-apps</code> first — it is the runtime contract (one self-contained HTML file, <code>window.SYLOS_CONFIG</code>, plain fetch against PostgREST, the 401 refresh). Then build the app. It must be <strong>beautiful</strong> — a plain table fails the walkthrough's whole point:</p>
<ul>
<li>One screen, no chrome: today's number big at the top, a 14-day chart under it, and a quieter longer-range line (say 90 days) when the data supports one.</li>
<li>Draw the chart yourself — inline SVG or canvas. No CDN, no chart library (the contract forbids external code anyway).</li>
<li>Light and dark via <code>prefers-color-scheme</code>, the system font stack, rounded cards, generous spacing, smooth without being busy.</li>
<li>Fetch raw rows (<code>health_samples</code>, filtered to the chosen <code>kind</code> and <code>starts_at=gte.</code>the window) and aggregate at <strong>display time</strong> in the page's own JS — sum steps per day, average heart rate, sleep hours from each stage row's <code>starts_at</code>→<code>ends_at</code>, last weight per day. Never store rollups.</li>
<li>Handle the empty day and the empty app gracefully — a quiet "no data yet" state, since the mirror may still be filling.</li>
</ul>
<p>Deploy it as the fixed slug the stage check looks for, named after the data, with a fitting emoji icon:</p>
<pre>scripts/vibe-save --slug first-chart --name "Steps" \
    --hint "your first app — steps, charted live" \
    --icon "👟" --html-file app.html</pre>
<p>A new app lands on the owner's Home screen by itself. Then the payoff, short:</p>
<blockquote>Done ✨ Open <strong>Home</strong> — your new app is there. Tap it.<br>
Want anything changed — colors, more data, a goal line? Just tell me. That's how this works: you ask, I build.</blockquote>

<h2>Housekeeping</h2>
<p>Every walkthrough reply goes through <code>scripts/chat-say --body … --run &lt;run_id&gt;</code>, and every claimed run is reported with <code>scripts/syla-finish</code>, exactly as CLAUDE.md says. The walkthrough files <strong>no todos and no events</strong> — none of these messages is a task for the calendar. Done looks like: the owner tapped through Integrations, answered one question, and is looking at a chart app on their Home screen they watched you make.</p>
<footer>doc <code>skills/first-run</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'skills/first-run');

-- No silo placement: skills load by path (the 'skills' silo was retired
-- in 20261012000000 — the agent and the app never looked for it).
