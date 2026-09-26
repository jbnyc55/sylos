-- The vibe app runtime contract, documented where Syla can read it.
--
-- The vibe_code_apps table came over from the web era, whose comments
-- pointed at a postMessage contract in vibes/README.md — a file and a
-- mechanism that no longer exist. The iOS app runs a vibe app in a
-- WKWebView and injects `window.SYLOS_CONFIG` before any script runs.
-- Syla had no doc telling her that, so her first generated app waited
-- for a session that never arrived. This migration seeds the
-- skills/vibe-apps doc with the real contract and fixes the stale
-- column comment.

comment on column public.vibe_code_apps.html is
    'The whole app, scripts and styles inlined. The Sylos app runs it in a WKWebView with window.SYLOS_CONFIG (supabaseUrl, supabaseAnonKey, session) injected before any script executes — the skills/vibe-apps doc holds the contract.';

insert into public.docs (path, title, html)
select 'skills/vibe-apps', 'Building a vibe code app', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Building a vibe code app</title>
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
<h1>Building a vibe code app</h1>
<p>A vibe code app is one complete client-side app in a single self-contained HTML file (scripts and styles inlined, no external requests for code, 5&nbsp;MB cap), stored in the <code>vibe_code_apps</code> table and listed on the app's Apps tab. Deploy or update one with <code>scripts/vibe-save --slug &lt;slug&gt; --name "…" --html-file app.html</code>.</p>
<h2>The runtime contract</h2>
<p>The Sylos app runs your HTML in a WKWebView and injects this <strong>before any of your scripts execute</strong> — read it directly, never wait for a message or event:</p>
<pre>window.SYLOS_CONFIG = {
  supabaseUrl:     "https://&lt;ref&gt;.supabase.co",
  supabaseAnonKey: "…",                 // client-public
  session: {                            // null only if signed out
    access_token:  "…",                 // the owner's JWT
    refresh_token: "…"
  }
}</pre>
<p>Talk to the database with plain <code>fetch</code> against PostgREST — no client library needed, and none may be loaded from a CDN (self-containedness is the contract):</p>
<pre>const cfg = window.SYLOS_CONFIG;
const headers = {
  apikey: cfg.supabaseAnonKey,
  Authorization: `Bearer ${cfg.session?.access_token ?? cfg.supabaseAnonKey}`,
  "Content-Type": "application/json",
};
const rows = await fetch(
  `${cfg.supabaseUrl}/rest/v1/workouts?select=*&order=done_on.desc`,
  { headers }
).then(r => r.json());</pre>
<p>Writes are POST/PATCH/DELETE on the same endpoints (add <code>Prefer: return=representation</code> when you need the row back). Everything runs as the signed-in owner: <strong>RLS is the authorization layer</strong>, so the app can only ever see and touch what the owner can.</p>
<h2>Sessions expire</h2>
<p>The injected access token lasts about an hour. On a 401 mid-use, refresh it yourself and retry once:</p>
<pre>const r = await fetch(`${cfg.supabaseUrl}/auth/v1/token?grant_type=refresh_token`, {
  method: "POST",
  headers: { apikey: cfg.supabaseAnonKey, "Content-Type": "application/json" },
  body: JSON.stringify({ refresh_token: cfg.session.refresh_token }),
}).then(r => r.json());
cfg.session = { access_token: r.access_token, refresh_token: r.refresh_token };</pre>
<p>Show a "sign in from the Sylos app" state only when <code>window.SYLOS_CONFIG</code> is missing or its <code>session</code> is null — never because a message didn't arrive.</p>
<h2>Boundaries</h2>
<ul>
<li>Self-contained: no CDN scripts, no external code. Data requests go only to the owner's own Supabase.</li>
<li>Never compute or store rollups at write time — append raw rows; aggregation is your scheduled jobs' work.</li>
<li>An app over a user table pairs with the table the owner approved (skills/user-tables); the policies approved there are exactly what the app runs under.</li>
</ul>
<p>Done looks like: the app opens from the Apps tab, reads and writes its rows immediately with no sign-in ceremony, and survives an expired token via the refresh flow.</p>
<footer>doc <code>skills/vibe-apps</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'skills/vibe-apps');

insert into public.doc_silos (doc_id, silo_id)
select d.id, s.id
from public.docs d
join public.silos s on s.name = 'skills'
where d.path = 'skills/vibe-apps'
  and not exists (select 1 from public.doc_silos j
                  where j.doc_id = d.id and j.silo_id = s.id);
