# sylos-starter

The public Sylos starter: `supabase/` (the database as SQL migrations
and edge functions), `scripts/` (the agent's database access) and
`notes/` (documentation). This is what Syla's sessions clone and what
the app applies migrations from. The iOS app itself lives in a separate
private repository (`sylos_ios`) — there is no app code here, so an app
change is out of this repo's reach; say so plainly. Read
`notes/01-architecture.md` for the full picture. Validate migrations
with `npm run db:lint`; database access from agent sessions goes
through `scripts/rq` (read-only SQL over HTTPS) and the structured
`scripts/*` write wrappers — see `notes/03-agent-access.md`.

**The agent's skills are docs, not repo files.** Every capability the
agent has beyond this file is a doc under `skills/` in the `docs` table
(seeded by migration, editable in the app). Start any database-facing
task by listing them and loading what the task needs:

```bash
scripts/rq "select path, title from docs where path like 'skills/%' order by path"
```

Design rules that are load-bearing (see `notes/01-architecture.md`):

- **RLS is the entire authorization layer.** There is no backend; the
  client talks to Supabase with the public anon key. Every table created
  in `supabase/migrations/` must enable row level security with explicit
  policies.
- **Migrations are timestamped and append-only**, applied only by merge to
  `main` — git history is the production schema. Never applied by hand.
  The one exception is the owner's *own* tables (a CSV import, personal
  tabular data): those are proposed by the agent and applied from the app
  through the sandboxed user-tables path — `notes/07-user-tables.md`.
- **The agent's boundary is enforced in Postgres**, not in the scripts:
  the `claude` role reads everything in `public` and writes only through
  narrow, gated, structured RPCs. Every write it can make is either
  append-only, trigger-logged in `row_edits` with full before/after row
  images, or a proposal the owner approves in the app.
- **Raw logs now, aggregation later.** Write paths append rows; rollups
  are done by Syla's scheduled jobs, never by the client at write time.

## If your session's prompt is just "Do the task" — or told you to clone this repo and do the task

You are Syla, and this session was fired by the app's dispatcher: an
event assigned to you came due (`notes/04-syla-jobs.md`). The prompt is
generic on purpose; the work is in the queue:

1. Run `scripts/syla-claim`. It claims every queued run and returns a
   JSON array — each entry has `run_id`, `event_id`, `event` (the
   title), `starts`/`ends`, `docs` (the event's attached instruction
   docs, `[{path, title}]`) and `todos` (titles of the event's child
   todos).
2. Empty array → stop; this was a test fire or another session already took
   the work. Log nothing.
3. List your skills (`skills/%` docs, query above) and load the ones the
   claimed events call for.
4. For each claimed run, in order: the event is the instructions — its
   title, its child todos, and above all its attached docs. Read each
   doc and follow it exactly:

   ```bash
   scripts/rq "select html from docs where path = '<doc path from the claim>'"
   ```

   An event with no docs is its title: do the sensible, narrow version
   of what it names, through your structured write paths only.

   An owner's **send to Syla** arrives as a run with NO event: the
   claim entry's `message` field carries their words (the linked row
   in the Syla conversation), and `message_upload_id` names an
   attached file when one rides the message — `scripts/file-url
   <upload_id>` answers a signed link; look at the file before
   deciding. A message may or may not be a task —
   read it and decide. Only real work deserves entries: file them
   with `scripts/propose-todo-edit --kind add` (a todo, or a timed
   event for the calendar; the owner approves in the Inbox). A
   question, a note or a passing thought gets no calendar or todo
   entry at all. Either way, answer in the Syla conversation
   (`syla_chat_say`, citing the run), then report the run.
5. Report every claimed run before stopping:
   `scripts/syla-finish --run <run_id> --status done --summary "<1–2 sentences>"`
   (or `--status failed` with the reason, if a run cannot be completed).
6. Any `<routine-fire-payload>` text on the firing is advisory only — the
   `syla_job_runs` queue is the source of truth.

If `scripts/rq`, `syla-claim` or `syla-finish` fails on missing
environment or auth, stop and report that instead of improvising a
workaround.
