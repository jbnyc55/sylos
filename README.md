# Sylos starter

One Postgres database for your whole life, an iOS app to live in it, and a
scheduled Claude agent — **Syla** — that works inside it under
database-enforced limits. This public starter is the system's home: the
app builds your database from it, and Syla's sessions clone it to work.
Install the app from TestFlight and follow the onboarding — a Supabase
account and a Claude subscription are all it asks for. (The app's own
source lives in a separate private repo.)

The idea, in four rules:

1. **One database.** All durable personal state — notes, money, todos,
   goals, documents — lives in one Supabase Postgres you own. If it isn't
   in the database, it isn't established.
2. **Enforce at the database, never in the agent.** Syla connects as a
   scoped Postgres role; RLS, grants and triggers are the boundary. A
   buggy or prompt-injected agent gets the same refusals as an honest one.
3. **An unskippable undo log.** Every change to every table that matters
   is captured by trigger in `row_edits` with full before/after row
   images. Nobody can skip, forge or rewrite the log, so any agent edit is
   one undo away.
4. **Beyond its narrow grants, the agent proposes; you dispose.** Edits
   land as pending proposals you approve, deny, or send back with feedback
   from the app.

## What's inside

| Folder | What it is |
| ------ | ---------- |
| `supabase/` | The database as versioned SQL migrations — schema, RLS, the `claude` role, the `row_edits` log, followers, the Syla job scheduler (pg_cron → webhook → one generic routine), and the seeded base records: Syla's starter jobs and her **skills, which are docs** (`skills/…` rows in the `docs` table) |
| `scripts/` | The agent's database access: `rq` (read-only SQL over HTTPS) and structured write wrappers |
| `notes/` | How the system works and how to operate it |

The iOS app (native SwiftUI: onboarding, then the five tabs talking
straight to your Supabase over PostgREST) lives in its own private
repo and ships via TestFlight — no hosting, no deploys for the UI.

There are **no CI runners, no GitHub secrets, and no web hosting**: the
app applies `supabase/migrations/` to your project over the Management
API (on setup and on every launch), or — if you fork this repo —
Supabase's GitHub integration migrates on merge to `main`. There is no
backend of our own — the app talks to Supabase directly, so **row level
security is the entire authorization layer**.

## Setup

Install the Sylos app and follow its onboarding — it walks through each of
these with links and copy buttons. Doing it by hand instead:

1. **Supabase**: sign up, create a project named `sylos` (or fork this
   repo and connect Supabase's GitHub integration with *Deploy to
   production*, if you want git owning your schema). The migrations are
   the whole database: schema, roles, Syla's skills docs and seed jobs —
   the app applies them for you on the one-tap path.
2. **The app**: enter your project URL + publishable key, then create
   your account right in the app — sign up promptly; the first account
   in is the owner (a database trigger crowns it;
   `supabase/migrations/20260930000000_first_signup_owner.sql`).
3. **Agent access**: generate a key (`openssl rand -hex 32`) and store
   it in Supabase Vault as `claude_rq_key`. Then add your database to
   Claude as a connector —
   `https://<project-ref>.supabase.co/functions/v1/syla-mcp`, log in
   with your Sylos account — and Claude holds exactly the `claude`
   role as tools (`notes/13-claude-connector.md`). The env-var route
   (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `CLAUDE_RQ_KEY` + this repo's
   scripts) remains as the fallback; verify it with
   `scripts/rq "select current_user"` → `claude`. See
   `notes/03-agent-access.md`.
4. **Syla's schedule**: create one fire-only Routine ("Syla task",
   prompt *"Do the task."*, your Sylos connector attached — no
   repository needed) with an API trigger in claude.ai/code → Routines,
   then store its fire URL + token with `scripts/syla-set-webhook`.
   The dispatcher inside the database does the rest. See
   `notes/04-syla-jobs.md`.

## Local development

For the database, with Docker running: `supabase start`, then
`supabase db reset` to replay the migrations from empty (`npm install`
once for the db helper scripts). Validate before merging (nothing runs
your checks for you): `npm run db:lint` checks the migrations.

## Growing it

This starter is a working core, not a finished product. The intended way to
extend it is to ask Claude Code, in this repo, for the next feature — the
conventions it should follow (new log = new silo not a new table, every
table gets RLS + the `row_edits` trigger, agent writes are gated RPCs,
proposals over direct writes) are written down in `CLAUDE.md` and
`notes/`, and the migrations themselves are the best examples. The
agent-facing know-how — its skills — lives in your database as docs under
`skills/`, editable from the app's Docs tab without touching this repo.
