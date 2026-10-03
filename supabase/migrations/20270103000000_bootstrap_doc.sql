-- The bootstrap doc: the manual that travels with the credentials.
--
-- An agent session is three env vars — SUPABASE_URL, SUPABASE_ANON_KEY,
-- CLAUDE_RQ_KEY — but the knowledge of how to use them lived only in this
-- repo's notes and the seeded skills docs. A fresh environment (the
-- owner's laptop, a new machine, any Claude outside the usual session)
-- that gets the vars pasted in has the keys and no door. This migration
-- closes the loop with one self-referential move:
--
--   * `skills/bootstrap` is seeded below: the from-zero manual — the rq
--     transport and its contract, how to orient (list the skills docs),
--     where the scripts live (the public starter), and the write
--     boundary. It is fetched WITH the very credentials being explained,
--     so the manual can never be lost while the keys work.
--   * `scripts/env-pack` (in this commit) prints the whole paste block
--     from a configured environment: the three vars plus SYLOS_BOOTSTRAP,
--     a prose variable whose text is one paragraph saying exactly how to
--     make the first call and to read skills/bootstrap next. An agent
--     dropped into a bare shell finds it with `env | grep SYLOS`.
--
-- House pattern for doc seeds: insert-if-absent, then the skills silo —
-- the owner's later edits are theirs.

insert into public.docs (path, title, html)
select 'skills/bootstrap', 'Bootstrap: using this database from anywhere', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Bootstrap: using this database from anywhere</title>
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
<h1>Bootstrap: using this database from anywhere</h1>
<p>You are connected to one person's Sylos database, as their agent. Three environment variables are the whole credential: <code>SUPABASE_URL</code>, <code>SUPABASE_ANON_KEY</code> (client-public) and <code>CLAUDE_RQ_KEY</code> (the proof — treat the trio like a password). They map to the <code>claude</code> role: broad reads, and writes only through narrow, gated RPCs. Postgres enforces that boundary, not goodwill — a refusal is an answer, never something to work around.</p>
<h2>The read transport</h2>
<p>One HTTPS call runs one read-only statement:</p>
<pre>curl -s -X POST "$SUPABASE_URL/rest/v1/rpc/run_readonly_sql" \
  -H "apikey: $SUPABASE_ANON_KEY" \
  -H "x-claude-rq-key: $CLAUDE_RQ_KEY" \
  -H "content-type: application/json" \
  --data '{"q": "select count(*) from manual_notes"}'</pre>
<p>The contract: <strong>one statement, no trailing semicolon, valid inside a FROM subquery</strong> — the server wraps it as <code>select coalesce(jsonb_agg(to_jsonb(t)), '[]') from (&lt;q&gt;) t</code> and answers a JSON array. 30&nbsp;s timeout.</p>
<h2>Orient before acting</h2>
<p>The manual is in here with you. List it, then load what the task needs:</p>
<pre>{"q": "select path, title from docs where path like 'skills/%' order by path"}</pre>
<h2>The scripts</h2>
<p>Every capability has a ready-made wrapper in the public starter — clone it rather than hand-rolling curl:</p>
<pre>git clone https://github.com/jbnyc55/sylos
cd sylos &amp;&amp; cat notes/03-agent-access.md</pre>
<p><code>scripts/rq</code> is the read above; writes are one script per act (<code>agent-log</code>, <code>propose-user-table</code>, <code>chat-say</code>, …), each calling its own gated RPC. The scripts only add nicer errors — bypassing them earns the same refusals.</p>
<h2>Bulk data</h2>
<p>A big import (a CSV, an export, hundreds of MB) is the agent-tables path: propose the table with <code>scripts/propose-user-table --agent-writable</code>, the owner approves the card in their app, then load it in batches with <code>scripts/agent-write</code>. The whole recipe, including the silo rules and what to do when a write is refused, is the <code>skills/user-tables</code> doc — read it before any import.</p>
<h2>Boundaries that never move</h2>
<ul>
<li>The owner approves anything that changes their records: proposals, cards, approvals in the app. You file; they decide.</li>
<li>Silos are the owner's sharing vocabulary. You never place a table, doc or note in a silo on your own authority, and a table shared with followers refuses your bulk writes until it is private again.</li>
<li>Missing environment or an auth failure means stop and report — there are no fallbacks, by design.</li>
</ul>
<h2>Moving machines</h2>
<p>From any configured environment, <code>scripts/env-pack</code> prints the complete paste block for a new shell — the three variables plus <code>SYLOS_BOOTSTRAP</code>, whose text points back at this doc. Paste it into a file you <code>source</code> rather than straight into a prompt, so the credential stays out of shell history.</p>
<footer>doc <code>skills/bootstrap</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'skills/bootstrap');

insert into public.doc_silos (doc_id, silo_id)
select d.id, s.id
from public.docs d
join public.silos s on s.name = 'skills'
where d.path = 'skills/bootstrap'
  and not exists (select 1 from public.doc_silos j
                  where j.doc_id = d.id and j.silo_id = s.id);
