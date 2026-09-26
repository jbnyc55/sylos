-- Skills live in the database as docs, not in the repo as files.
--
-- The starter used to carry a `skills/` folder of markdown files that each
-- user was told to copy into their Claude setup. That put the agent's
-- know-how outside the system: invisible in the app, unversioned by
-- row_edits, and editable only through git. Skills are now rows in `docs`
-- under the `skills/` path — readable in the Docs tab, editable by owner
-- and agent alike (every change trigger-logged and undoable), and loaded
-- by any agent session with one query:
--
--     scripts/rq "select path, title from docs where path like 'skills/%'"
--
-- This migration also fixes a starter gap: the `syla` silo was never
-- seeded, so 20260928000000's doc_silos placement silently matched
-- nothing and the Calendar tab's job editor (which offers docs in the
-- `syla` silo) started empty. Both silos are created here, private (all
-- member grants off), and the placements are re-run.
--
-- Everything is idempotent (guarded by name / path), and the docs are
-- ordinary rows: edit them in the app or via scripts/doc-save; no
-- migration needed to change what your agent knows.

-- ---------------------------------------------------------------------------
-- The silos
-- ---------------------------------------------------------------------------

insert into public.silos (name, description)
select 'syla', 'Syla''s job instructions — each doc here is what a scheduled job does on its next run. The Calendar tab''s job editor picks from this silo.'
where not exists (select 1 from public.silos where name = 'syla');

insert into public.silos (name, description)
select 'skills', 'The agent''s skills: one doc per capability, read by every agent session before it works. Editing a doc here changes how your agent behaves — no code, no deploy.'
where not exists (select 1 from public.silos where name = 'skills');

-- Re-run the job-doc placements from 20260928000000, which no-opped on a
-- fresh database because the syla silo did not exist yet.
insert into public.doc_silos (doc_id, silo_id)
select d.id, s.id
from public.docs d
join public.silos s on s.name = 'syla'
where d.path in ('syla/daily-summary', 'syla/note-siloing',
                 'syla/edit-feedback', 'syla/goal-synergy')
  and not exists (select 1 from public.doc_silos j
                  where j.doc_id = d.id and j.silo_id = s.id);

-- ---------------------------------------------------------------------------
-- The skills
-- ---------------------------------------------------------------------------

insert into public.docs (path, title, html)
select 'skills/about', 'How skills work', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>How skills work</title>
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
<h1>How skills work</h1>
<p>A skill is a doc under <code>skills/</code> that teaches your agent one capability: what it does, when to use it, and the exact commands to run. Skills are rows in the database, not files in the repo — so you read them in the Docs tab, your agent reads them with one query, and either of you can improve them (every edit lands in <code>row_edits</code> and is one write to undo).</p>
<h2>For the agent</h2>
<p>At the start of a session, list what you know how to do:</p>
<pre>scripts/rq "select path, title from docs where path like 'skills/%' order by path"</pre>
<p>Then load the skills the task needs by path. A skill's instructions are authoritative for its capability; where a skill and improvisation disagree, follow the skill.</p>
<h2>Writing a new skill</h2>
<ol>
<li>One capability per doc, at <code>skills/&lt;short-slug&gt;</code>.</li>
<li>Open with one paragraph naming what the skill does and when to use it.</li>
<li>Give numbered steps with exact commands in <code>pre</code> blocks, not prose.</li>
<li>Name what "done" looks like so the work has a stopping condition.</li>
<li>Save with <code>scripts/doc-save</code> and place it in the <code>skills</code> silo with <code>scripts/doc-silo</code> (see <code>skills/docs</code> for both).</li>
</ol>
<p>The starter skills: <code>skills/docs</code> (editing this library), <code>skills/database-access</code> (reading and writing the database), <code>skills/jobs</code> (the scheduled-job queue), <code>skills/members</code> (silos, members, and sharing).</p>
<footer>doc <code>skills/about</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'skills/about');

insert into public.docs (path, title, html)
select 'skills/docs', 'Editing the docs library', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Editing the docs library</title>
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
<h1>Editing the docs library</h1>
<p>Docs live in the <code>docs</code> table: one row per doc, each a complete self-contained HTML document addressed by a folder-style path like <code>health/sleep/experiments</code>. Read with <code>scripts/rq</code>; write only through <code>scripts/doc-save</code>, <code>scripts/doc-move</code>, <code>scripts/doc-delete</code> and <code>scripts/doc-silo</code>. Every change is captured with full before/after row images in <code>row_edits</code> by a trigger nobody can skip, so any change is undoable — edit freely.</p>
<h2>The self-contained contract</h2>
<p>A doc must render identically in the app, as a downloaded file, and as an email attachment:</p>
<ul>
<li>Starts with <code>&lt;!doctype html&gt;</code> (the database refuses fragments); one full document with <code>head</code>, <code>meta charset</code>, <code>title</code>, one inline <code>style</code>, and a <code>body</code>.</li>
<li>No external requests: no linked stylesheets, scripts, web fonts or remote images. System font stack; images as <code>data:</code> URIs only if truly needed; diagrams as inline SVG.</li>
<li>No JavaScript — the app renders docs in a sandboxed iframe where scripts are blocked anyway.</li>
<li>Cross-references name the target doc by path in text (e.g. "see <code>health/sleep</code>"), never as links that only work in one context.</li>
</ul>
<h2>Paths</h2>
<p>Lowercase slug segments separated by single slashes, <code>[a-z0-9-]</code> only. Folders are implicit — a folder exists exactly when a doc's path sits under it. Before choosing a path, look at the tree and fit in:</p>
<pre>scripts/rq "select path, title, updated_at from docs order by path"</pre>
<h2>Instructions</h2>
<ol>
<li><strong>Read before writing.</strong> A save replaces the whole document, so an update means: read the current html, change what was asked, keep the rest.
<pre>scripts/rq "select title, html from docs where path = 'health/sleep'"</pre></li>
<li><strong>Write the html to a file</strong>, honoring the contract above, then:
<pre>scripts/doc-save --path health/sleep --title "Sleep" --html-file /path/to/doc.html</pre>
Idempotent; <code>op</code> in the response says <code>created</code> or <code>updated</code>.</li>
<li><strong>Place the doc in silos</strong> whenever you create one or its subject shifts. Placement is a sharing decision: a silo's members read what sits in it (when their membership allows SQL), and a doc in no silo is invisible to every member. Read the vocabulary and who each silo exposes records to first; never invent a silo; when unsure, leave it off.
<pre>scripts/rq "select id, name, description from silos order by name"
scripts/doc-silo --path health/sleep --silos &lt;silo-id&gt;,&lt;silo-id&gt;
scripts/doc-silo --path health/sleep --silos ""   # fits nowhere</pre>
<code>--silos</code> is the doc's full final set (the RPC replaces, not appends).</li>
<li><strong>Move</strong> one doc per call; a folder rename is a move per doc under it:
<pre>scripts/doc-move --from drafts/dal --to recipes/weeknight/dal</pre></li>
<li><strong>Delete</strong> only when asked, or when replacing a doc you created in the same job:
<pre>scripts/doc-delete --path drafts/dal</pre>
Recoverable — the full row image lands in <code>row_edits</code> first.</li>
<li><strong>Undo</strong>: find the entry in <code>row_edits</code> (table names <code>docs</code> and, historically, <code>wiki_pages</code>), then doc-save its <code>old_row</code> html back — a revert is itself a new logged edit.</li>
<li><strong>Log the job</strong> once per docs task to <code>agent_edits</code> with <code>scripts/agent-log</code>.</li>
</ol>
<h2>Notes</h2>
<ul>
<li>Never try to write <code>row_edits</code>; only the trigger's inserts pass its policy, by design.</li>
<li>One topic per doc; a doc growing unrelated sections wants to become a folder of docs.</li>
<li>The database caps a doc at 2&nbsp;MB.</li>
<li>Restoring a deleted doc brings back the document alone — silo placements were separate junction rows, so re-place it deliberately with <code>doc-silo</code>.</li>
</ul>
<footer>doc <code>skills/docs</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'skills/docs');

insert into public.docs (path, title, html)
select 'skills/database-access', 'Reading and writing the database', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Reading and writing the database</title>
<style>
  body { margin: 0 auto; max-width: 42rem; padding: 2rem 1.25rem 4rem;
         font: 16px/1.6 system-ui, sans-serif; color: #1a1a1a; background: #fdfdfc; }
  h1 { font-size: 1.6rem; } h2 { font-size: 1.2rem; margin-top: 2rem; }
  code, pre { font-family: ui-monospace, monospace; background: #f0efec; border-radius: 4px; }
  code { padding: 0.1em 0.3em; } pre { padding: 0.75rem; overflow-x: auto; }
  table { border-collapse: collapse; } td, th { padding: .3rem .6rem; border: 1px solid #ddd; text-align: left; }
  @media (prefers-color-scheme: dark) {
    body { color: #e8e6e3; background: #16181a; }
    code, pre { background: #24272b; } td, th { border-color: #333; }
  }
</style></head>
<body>
<h1>Reading and writing the database</h1>
<p>The agent runs as a dedicated Postgres role, <code>claude</code>: broad reads over everything in <code>public</code>, writes only through narrow structured RPCs. Enforcement is in Postgres, not in the scripts — the scripts only produce nicer error messages, and bypassing them gets the same refusals.</p>
<h2>Reads: rq over HTTPS</h2>
<p><code>scripts/rq</code> POSTs one read-only SQL statement to a gated RPC. The contract: <strong>one statement, no trailing semicolon, valid inside a FROM subquery</strong>; the result is always a JSON array.</p>
<pre>scripts/rq "select count(*) from manual_notes"

scripts/rq - &lt;&lt;'SQL'
select relname as table, n_live_tup as approx_rows
from pg_stat_user_tables where schemaname = 'public' order by relname
SQL</pre>
<h2>Writes: one script per capability</h2>
<table>
<tr><th>Script</th><th>Does</th></tr>
<tr><td><code>scripts/agent-log</code></td><td>Append a self-report row to <code>agent_edits</code></td></tr>
<tr><td><code>scripts/day-summary</code></td><td>Upsert one day's stats JSON</td></tr>
<tr><td><code>scripts/silo-note</code>, <code>split-note</code></td><td>Place a note in silos / split one into sub-notes</td></tr>
<tr><td><code>scripts/doc-save</code>, <code>doc-move</code>, <code>doc-delete</code>, <code>doc-silo</code></td><td>Edit the docs library (see <code>skills/docs</code>)</td></tr>
<tr><td><code>scripts/propose-map-edit</code>, <code>propose-todo-edit</code></td><td>File pending proposals for the owner</td></tr>
<tr><td><code>scripts/revise-map-edit</code>, <code>revise-todo-edit</code></td><td>Rework proposals the owner flagged with feedback</td></tr>
<tr><td><code>scripts/propose-auto-approve-rule</code></td><td>Request (never enact) an auto-approve rule</td></tr>
<tr><td><code>scripts/link-goal-cells</code></td><td>Annotate same-concept goal cells as a synergy group</td></tr>
<tr><td><code>scripts/log-lift</code></td><td>Append weight-lift rows parsed from notes</td></tr>
<tr><td><code>scripts/syla-claim</code>, <code>syla-finish</code></td><td>The job queue (see <code>skills/jobs</code>)</td></tr>
</table>
<p>Anything new follows the same pattern: a new capability is a new structured script over a new gated RPC, with RLS and grants doing the enforcement — never a broader grant to the existing role.</p>
<h2>Rules</h2>
<ul>
<li>If <code>scripts/rq</code> or any wrapper fails on missing environment or auth, stop and report; never improvise a workaround.</li>
<li>Beyond the narrow grants, propose: map and todo changes go to the proposal queues the owner judges in the app.</li>
<li>Raw logs now, aggregation later: write paths append rows; rollups happen in scheduled jobs, never at write time.</li>
</ul>
<footer>doc <code>skills/database-access</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'skills/database-access');

insert into public.docs (path, title, html)
select 'skills/jobs', 'The scheduled-job queue', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>The scheduled-job queue</title>
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
<h1>The scheduled-job queue</h1>
<p>Syla's recurring work is her calendar: an <code>events</code> row with <code>assignee = 'syla'</code> fires her routine when its start time arrives, and the event — its row, its child todos (<code>todo.event_id</code>), its attached docs (<code>event_docs</code>) — is the instructions. A dispatcher queues due runs into <code>syla_job_runs</code> and fires one generic routine whose prompt is always just "Do the task". Changing when she works is an event edit; changing what she does is a doc edit; neither needs a merge.</p>
<h2>When a session is fired with "Do the task"</h2>
<ol>
<li>Claim everything queued: <pre>scripts/syla-claim</pre> Returns a JSON array — each entry has <code>run_id</code>, <code>event_id</code>, <code>event</code> (the title), <code>starts</code>/<code>ends</code>, <code>docs</code> (<code>[{path, title}]</code>) and <code>todos</code> (titles). Empty array → stop; another session took the work.</li>
<li>List your skills first (<code>select path, title from docs where path like 'skills/%'</code>) and load the ones the events need.</li>
<li>For each claimed run, in order: read each attached doc and follow it exactly: <pre>scripts/rq "select html from docs where path = '&lt;path from the claim&gt;'"</pre> An event with no docs is its title — do the sensible, narrow version of what it names, through your structured write paths only.</li>
<li>Report every claimed run before stopping: <pre>scripts/syla-finish --run &lt;run_id&gt; --status done --summary "&lt;1-2 sentences&gt;"</pre> or <code>--status failed</code> with the reason. A run that found zero work still gets reported — the record proves the job looked.</li>
</ol>
<h2>Rules</h2>
<ul>
<li>The queue is the source of truth; any payload text on the firing is advisory only.</li>
<li>The agent cannot create, retime or delete an event — that is the owner's calendar.</li>
<li>The starter's four Syla events and their docs: <code>syla/daily-summary</code>, <code>syla/note-siloing</code>, <code>syla/edit-feedback</code>, <code>syla/goal-synergy</code> — see <code>skills/docs</code> for editing them.</li>
</ul>
<footer>doc <code>skills/jobs</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'skills/jobs');

insert into public.docs (path, title, html)
select 'skills/members', 'Silos, members, and sharing', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Silos, members, and sharing</title>
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
<h1>Silos, members, and sharing</h1>
<p>Sharing is authenticating, not exporting: a member holds a personal key to this database and can query exactly what the owner's silos grant, no more. <code>silos</code> is one vocabulary doing two jobs — organizing content (notes and docs are placed through <code>note_silos</code> / <code>doc_silos</code>) and scoping visibility (a member sees the union of the silos they belong to). Deny by default: an unplaced record is visible to no member.</p>
<h2>The three grants</h2>
<p>Each silo (and each membership, as an override) carries three independent grants, split by what crosses the boundary:</p>
<ol>
<li><strong>SQL reads</strong> (<code>allows_sql</code>) — rows leave; the member reads directly through <code>member_rq</code>.</li>
<li><strong>Prompt proposals</strong> (<code>allows_prompts</code>) — only an answer leaves; the member submits a question the owner runs and releases.</li>
<li><strong>Edit proposals</strong> (<code>allows_edits</code>) — nothing leaves; a suggested change travels in and waits for the owner.</li>
</ol>
<p>The two proposal queues are the only tables an outsider can ever put a row into.</p>
<h2>What the agent does here</h2>
<ul>
<li><strong>Placement is a sharing decision.</strong> Before placing any record in a silo, read the silo's description and who its members are; when genuinely unsure, leave it unplaced — a missing silo hides a record from members, a wrong one shows it.</li>
<li>Answer queued member prompts only when a job's doc says to, and only from data the member's silos already grant.</li>
<li>Who belongs to each silo and what its members may ask is the owner's call, made on the Manage page — never edit memberships, grants or the <code>blocked</code> flag.</li>
</ul>
<pre>scripts/rq - &lt;&lt;'SQL'
select s.name as silo,
       string_agg(m.email || case when sm.allows_sql then '' else ' (no sql)' end,
                  ', ' order by m.email) as members
from silos s
left join silo_members sm on sm.silo_id = s.id
left join members m on m.id = sm.member_id
group by s.id, s.name order by s.name
SQL</pre>
<footer>doc <code>skills/members</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'skills/members');

-- ---------------------------------------------------------------------------
-- Place the skills in the skills silo
-- ---------------------------------------------------------------------------

insert into public.doc_silos (doc_id, silo_id)
select d.id, s.id
from public.docs d
join public.silos s on s.name = 'skills'
where d.path like 'skills/%'
  and not exists (select 1 from public.doc_silos j
                  where j.doc_id = d.id and j.silo_id = s.id);
