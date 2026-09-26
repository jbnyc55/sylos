-- Starter seeds: Syla's job-instruction docs, and the jobs that run them.
--
-- The earlier job seeds (20260920000000, 20260924000000) join on docs by
-- path and deliberately no-op when the docs don't exist yet — in the
-- original system the docs were data, saved through scripts/doc-save. A
-- starter should come up working, so this migration seeds generic versions
-- of the four docs, places them in the `syla` silo (the job editor's
-- picker), and then seeds the four jobs against the owner profile.
--
-- Everything here is idempotent (guarded by path / name), and the docs are
-- ordinary rows: edit them from the app's Docs tab (or scripts/doc-save)
-- and the job behaves differently on its next run — no migration, no merge.
-- Fire times are UTC; edit them from the Calendar tab's job editor.

-- ---------------------------------------------------------------------------
-- The docs
-- ---------------------------------------------------------------------------

insert into public.docs (path, title, html)
select 'syla/daily-summary', 'Daily summary', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Daily summary</title></head>
<body style="font-family: system-ui, sans-serif; max-width: 42rem; margin: 2rem auto; line-height: 1.5; color: #222;">
<h1 style="font-size: 1.4rem;">Daily summary</h1>
<p style="background: #f6f3ee; padding: .75rem; border-radius: .5rem;"><em>This doc is the instructions for a scheduled Syla job (the Calendar tab decides when it runs). The session that picks the job up has already claimed its run with <code>scripts/syla-claim</code>; it follows this doc exactly, then reports the outcome with <code>scripts/syla-finish</code>. Editing this doc changes what the job does on its next run.</em></p>
<p>Roll up one finished day into <code>public.day_summary</code> — the table behind the stats on the calendar's past-day cells, including a traffic-light read on every goal in the goal map — and file the goal-map and todo edits the day's data argues for as pending proposals in <code>public.agent_map_proposals</code> and <code>public.agent_todo_proposals</code> (the owner approves or denies each one in the app). Reads run as the claude role via <code>scripts/rq</code>; writes go only through <code>scripts/day-summary</code>, <code>scripts/propose-map-edit</code> and <code>scripts/propose-todo-edit</code>. Re-running a day replaces its stats (upsert) and dedupes proposals against the pending queues, so this is safe to repeat and to backfill.</p>
<h2 style="font-size: 1.1rem;">The stats contract</h2>
<p>One JSON object per day. <code>insights</code> is the only top-level string and <code>goals</code> the only top-level array; every other key is a metric object with a numeric <code>value</code> and a <code>description</code> saying what it measures and how it was computed. New metrics are new keys — never change the shape of existing ones. <code>goals</code> has one entry per live top-level goal, in rank order: <code>{"id": "&lt;cell uuid&gt;", "title", "status": "green"|"yellow"|"red", "why", "map_suggestions": [...], "todo_suggestions": [...]}</code> — the suggestion arrays are optional; omit them rather than writing empty ones.</p>
<h2 style="font-size: 1.1rem;">Instructions</h2>
<ol>
<li><strong>Pick the target day</strong> — default yesterday, in the owner's local timezone (UTC until the owner edits this doc to name one).</li>
<li><strong>Read the day's data</strong> with <code>scripts/rq</code>: notes with their silos, card purchases, todos done and skipped, and the live goal map (<code>goal_method_cells</code> where <code>deleted_at is null</code>).</li>
<li><strong>Compute the metrics</strong> the data supports (spend, calories if a calories silo exists, whatever else the notes carry) plus 1–2 sentences of insights grounded in the data.</li>
<li><strong>Judge each top-level goal</strong> green / yellow / red with evidence from this and recent days.</li>
<li><strong>Upsert</strong> with <code>scripts/day-summary</code>.</li>
<li><strong>File proposals</strong> for each concrete, data-backed map or todo edit — dedupe against pending rows first. Suggestions in the JSON are advisory text; this job never edits the map or the todo list itself.</li>
<li><strong>Report</strong> the run with <code>scripts/syla-finish</code> — a run that found nothing still gets reported; the record proves the job looked.</li>
</ol>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'syla/daily-summary');

insert into public.docs (path, title, html)
select 'syla/note-siloing', 'Note siloing', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Note siloing</title></head>
<body style="font-family: system-ui, sans-serif; max-width: 42rem; margin: 2rem auto; line-height: 1.5; color: #222;">
<h1 style="font-size: 1.4rem;">Note siloing</h1>
<p style="background: #f6f3ee; padding: .75rem; border-radius: .5rem;"><em>This doc is the instructions for a scheduled Syla job (the Calendar tab decides when it runs). The session that picks the job up has already claimed its run with <code>scripts/syla-claim</code>; it follows this doc exactly, then reports the outcome with <code>scripts/syla-finish</code>. Editing this doc changes what the job does on its next run.</em></p>
<p>Read every manual note whose placement is stale, decide which silos fit it, and record the vetting — then try to split multi-silo notes into single-focus sub-notes. Reads run as the claude role via <code>scripts/rq</code>; writes go only through <code>scripts/silo-note</code> and <code>scripts/split-note</code>. Both are idempotent per note, so re-running is always safe.</p>
<h2 style="font-size: 1.1rem;">The staleness contract</h2>
<p>The vocabulary watermark is <code>max(silos.created_at)</code>. A note's placement is stale when <code>silos_vetted_at</code> is null or older than the watermark — adding a new silo automatically makes every earlier vetting stale, because no note has been read with that silo in mind. <code>silos_vetted_at</code> is stamped by <code>scripts/silo-note</code> even when no silo fits (<code>--silos ""</code>), so an unplaced-but-vetted note is provably different from a never-tried one.</p>
<h2 style="font-size: 1.1rem;">Instructions</h2>
<ol>
<li><strong>Read the vocabulary</strong> — <code>select id, name, description, created_at from silos order by name</code>. A silo's description says what belongs in it and is the placement rubric.</li>
<li><strong>Find the stale notes</strong> (sub-notes included) with their current placements: notes where <code>silos_vetted_at</code> is null or older than the watermark.</li>
<li><strong>Place each note</strong> in the silos its content fits — or none — with <code>scripts/silo-note</code>. When one note plainly covers several unrelated topics, split it with <code>scripts/split-note</code> and place the parts.</li>
<li><strong>Report</strong> with <code>scripts/syla-finish</code>, counting notes vetted — a run that vetted 0 still gets reported; the record proves the job looked.</li>
</ol>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'syla/note-siloing');

insert into public.docs (path, title, html)
select 'syla/edit-feedback', 'Edit feedback', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Edit feedback</title></head>
<body style="font-family: system-ui, sans-serif; max-width: 42rem; margin: 2rem auto; line-height: 1.5; color: #222;">
<h1 style="font-size: 1.4rem;">Edit feedback</h1>
<p style="background: #f6f3ee; padding: .75rem; border-radius: .5rem;"><em>This doc is the instructions for a scheduled Syla job (the Calendar tab decides when it runs). The session that picks the job up has already claimed its run with <code>scripts/syla-claim</code>; it follows this doc exactly, then reports the outcome with <code>scripts/syla-finish</code>. Editing this doc changes what the job does on its next run.</em></p>
<p>The owner has three answers to an agent edit proposal in the app: approve, deny, or typing what should change instead — which parks the row in <code>status = 'changes_requested'</code> with their words in <code>feedback</code>. This job closes the loop: read each flagged row in <code>public.agent_map_proposals</code> and <code>public.agent_todo_proposals</code>, revise the edit so it does exactly what the feedback asks, and file the revision through <code>scripts/revise-map-edit</code> / <code>scripts/revise-todo-edit</code>, which send the row back to pending for the owner to judge again.</p>
<h2 style="font-size: 1.1rem;">Rules</h2>
<ul>
<li>The feedback is the owner's instruction — follow it precisely, even where it disagrees with the original rationale; the owner has the context.</li>
<li>The revise scripts are the only write path, and they can only move rows the owner flagged. Nothing in this loop ever writes <code>goal_method_cells</code>, <code>todo</code>, or the owner's <code>feedback</code> text — a revision is still just a proposal.</li>
<li>A flagged edit whose target row no longer exists can't be revised into anything applyable — withdraw it and say why in the run summary.</li>
<li>Nothing flagged → report a run that revised 0 and stop.</li>
</ul>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'syla/edit-feedback');

insert into public.docs (path, title, html)
select 'syla/goal-synergy', 'Goal synergy linking', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Goal synergy linking</title></head>
<body style="font-family: system-ui, sans-serif; max-width: 42rem; margin: 2rem auto; line-height: 1.5; color: #222;">
<h1 style="font-size: 1.4rem;">Goal synergy linking</h1>
<p style="background: #f6f3ee; padding: .75rem; border-radius: .5rem;"><em>This doc is the instructions for a scheduled Syla job (the Calendar tab decides when it runs). The session that picks the job up has already claimed its run with <code>scripts/syla-claim</code>; it follows this doc exactly, then reports the outcome with <code>scripts/syla-finish</code>. Editing this doc changes what the job does on its next run.</em></p>
<p>Read the whole goal map, find cells on <strong>different top-level goals</strong> that name the same real-world thing — the same supplement on a fitness map and a cognition map is one idea, not two — and link each such set into one synergy group with <code>scripts/link-goal-cells</code>. The app computes a synergy score for the group from the live rankings and shows it on the Goal map tab. Links are annotation only: the cells themselves are never touched, and the owner can unlink any group. Idempotent — re-linking an existing group changes nothing — so re-running is always safe.</p>
<h2 style="font-size: 1.1rem;">Rules</h2>
<ul>
<li>Judge sameness strictly: two cells are the same when a reasonable person would say they are one action or one thing, even under different wording. Related, similar, or serving the same end is <em>not</em> the same — do not link them.</li>
<li>Use each cell's notes when the title alone is ambiguous, and skip anything uncertain — a missed link costs nothing, a wrong one pollutes the scores.</li>
<li>Only link cells under different top-level goals; duplicate phrasings inside one goal's tree are the owner's map-cleanup matter, not a synergy.</li>
<li>Read the existing groups first and extend rather than duplicate. Report the run with <code>scripts/syla-finish</code> either way.</li>
</ul>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'syla/goal-synergy');

-- ---------------------------------------------------------------------------
-- Silo placement: the job picker offers docs in the `syla` silo
-- ---------------------------------------------------------------------------

insert into public.doc_silos (doc_id, silo_id)
select d.id, s.id
from public.docs d
join public.silos s on s.name = 'syla'
where d.path in ('syla/daily-summary', 'syla/note-siloing',
                 'syla/edit-feedback', 'syla/goal-synergy')
  and not exists (select 1 from public.doc_silos j
                  where j.doc_id = d.id and j.silo_id = s.id);

-- ---------------------------------------------------------------------------
-- The jobs (times are UTC; edit them in the Calendar tab's job editor)
-- ---------------------------------------------------------------------------

insert into public.syla_jobs (profile_id, name, doc_id, fire_at)
select p.id, s.name, d.id, s.fire_at
from (values
        ('Morning day summary',  'syla/daily-summary', time '12:00'),
        ('Daily note siloing',   'syla/note-siloing',  time '11:15'),
        ('Daily edit feedback',  'syla/edit-feedback', time '11:30'),
        ('Goal synergy linking', 'syla/goal-synergy',  time '11:45')
     ) as s (name, doc_path, fire_at)
join public.profiles p on p.is_owner
join public.docs d on d.path = s.doc_path
where not exists (select 1 from public.syla_jobs e where e.name = s.name);
