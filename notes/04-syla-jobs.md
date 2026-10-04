# Syla's schedule — events assigned to her

Syla's recurring work is not a pile of crons in Anthropic's scheduler.
Her schedule is the calendar itself: an **event** with
`assignee = 'syla'` fires her routine when its start time arrives, and
the event — its row, its child todos, its attached docs — is the
instructions. Changing when she works is an event edit; changing what
she does is a doc edit; neither needs a merge.

## The shape of it

```
The app ──► events (title, start/end times, gcal-shaped recurrence,
                 │   assignee 'me' or 'syla', docs via event_docs)
     every minute▼
   pg_cron ──► syla_dispatch() ──► inserts syla_job_runs (status 'queued')
                 │
                 ▼
   pg_net POST <routine fire URL>  (bearer token from Vault)
   — fires ONE generic "Syla task" routine
                 │
                 ▼
   The session claims every queued run (scripts/syla-claim) — each with
   its event title, times, attached docs and child todos — does what the
   event says, and reports back (scripts/syla-finish).
```

One generic routine replaces per-job crons. Its prompt never changes
("Do the task" — see `CLAUDE.md`): claim the queue, follow each event,
report. What Syla actually does is decided entirely by rows the owner
controls (`events`) and docs either party can edit.

| Table | Who writes it | What it is |
| ----- | ------------- | ---------- |
| `events` | The owner, in the app | Calendar events; the ones with `assignee='syla'` are her schedule. `event_docs` attaches the instruction docs |
| `syla_job_runs` | The dispatcher inserts; `claude` advances via RPCs | The queue and the history: queued → running → done/failed, with a summary, one row per firing of a Syla event |

Both carry the standard `row_edits` audit trigger; the agent cannot
create, retime, or delete an event — that is the owner's calendar.

## The dispatcher

`syla_dispatch()` runs every minute under pg_cron. Each tick it:

- marks **deliveries** — runs whose stored `fire_request_id` has a 2xx
  row in `net._http_response` get `delivered_at` stamped (pg_net
  answers asynchronously, so this lags a fire by at most a tick);
- queues a run for every due Syla event (one-offs, daily and weekly
  rules; `until_date` and `event_exclusion` honored; `last_fired_on` is
  the once-a-day latch, reset by the event trigger so a rescheduled
  event never fires retroactively);
- runs the **chute branch**: per profile, when the cadence in
  `chute_settings` says a sort is due (vs `last_sorted_at`, same latch
  style) *and* raw `chute_items` are waiting, it queues a run of the
  seeded Chute sort event — which is pre-latched forever, so only this
  branch ever fires it (`notes/12-chute.md`);
- runs the **sweep branch**, the chute branch's twin for siloing: when
  the cadence in `silo_settings` (hourly / thrice / nightly at a time /
  weekly — stock is nightly at 02:00) says a sweep is due (vs
  `last_swept_at`) *and* something waits — an unvetted top-level jot,
  an unplaced unshared doc (neither carrying an open silo ask), or a
  silo stamped `resweep_requested_at` by a retroactive rulebook change
  — it queues a run of the seeded, likewise pre-latched Silo sweep
  event (its doc `syla/silo-sweep` is the procedure);
- fails runs that were claimed but never finished within 2 hours or
  that three webhook fires couldn't get claimed;
- POSTs the routine's fire endpoint once for everything still queued.

Event times are the owner's local wall clock — the zone is pinned in
the dispatcher and the latch trigger (`America/New_York` in the
starter; edit both if yours differs).

Failure is designed to be visible, never silent: no Vault credential →
runs sit `queued`; webhook lost → re-fired up to 3 times, then `failed`
with a reason; session died → `failed` after 2 hours.

Five paths skip the tick entirely, all queue-and-fire-inline with the
same Vault credential: the chute's **Sort now** (`sort_chute_now()`),
the Silos app's **Silo now** (`sweep_silos_now()`, the same pattern),
the Syla thread's send, a flagged proposal's **edit feedback**
(`proposal_feedback_wakes_syla()` — the owner marking an agent edit
proposal `changes_requested` queues a run of the pre-latched Edit
feedback event, so the revision happens now instead of on a daily
cron; flips coalesce onto a still-queued run), and a connection's
**chat poke**
(`follower_poke_chat()` — a connected peer's client, or their Syla
through the relay's `poke` kind, knocks after posting in a shared chat;
the queued run's claim entry carries a `poke` field naming the chat,
and Syla reads the thread and acts by the reply ladder —
`notes/11-connections-and-reply-rules.md`). **send to Syla** calls `send_to_syla()`
(owner-only, SECURITY DEFINER), which writes the owner's message into
the Syla conversation (`chats.kind='syla'`) linked to a queued run
with NO event (`syla_job_runs.event_id` null — the message is the
run's instruction, returned by the claim as `message`; a file attached
to the message rides as `chat_messages.upload_id` and the claim names
it as `message_upload_id`, for `scripts/file-url`), and fires the
webhook inline, so she wakes immediately. Nothing lands on the
calendar or the todo list at send time: not every message is a task,
so SYLA decides what it deserves — real work becomes a
`propose_todo_edit` 'add' proposal (a todo, or a timed event for the
calendar) the owner approves in the Inbox; a question or a passing
thought gets only her reply in the thread via `syla_chat_say(_body,
_run_id)`. Without a stored credential the run just waits for the
next dispatcher tick, like everything else.

## Receipts in the Syla thread

Every rung of the thread's receipt ladder is a recorded fact on the
run, never an inference: **Sent** = `queued_at` (the run exists) ·
**Delivered** = `delivered_at` (the fire webhook answered 2xx — which
says the routine service took the request, nothing more) · **Syla's
reading** = `started_at` (a session claimed the run) · the reply = a
`chat_messages` row with `syla_run_id` pointing back. "Reading" is
never inferred from the webhook; the `syla_job_runs` queue is the
source of truth.

While a run is `running`, the top rung also narrates: the session
keeps `status_note` fresh through `set_syla_run_status()` (gated like
every claude write), and the thread shows it in place of "Syla's
reading…" — "Checking the calendar…", "Writing your reply…". The
notes cost nothing and invent nothing: `scripts/rq` derives one
deterministically from each query it ships (first table → a Syla-voiced
phrase, pure string matching, the raw SQL never shown; the only
query-derived fragment is an `ilike` search term), and
`scripts/syla-status` sets one by hand at milestones rq cannot see. No
realtime machinery is involved — the app's existing receipt polling
simply reads the two columns, a little faster while a run is live.
Status is cosmetic by design; the recorded facts stay the timestamps
and the reply row.

## The webhook credential

The generic routine is fired with its own bearer token, scoped to firing
that one routine — it reads nothing else. It lives in Vault as
`syla_webhook_token` alongside `syla_webhook_url`, written through
`scripts/syla-set-webhook` → `set_syla_webhook()`. The RPC is gated by
the usual rq key and **pins the URL**: it must be
`https://api.anthropic.com/v1/claude_code/routines/…/fire` or this
project's own `syla-fire` edge function (the self-hosted Daytona worker
path — `daytona/README.md`), so a leaked rq key could rotate or break
the webhook but never redirect the token to a host that would capture
it. `pg_net` and `pg_cron` are server-side only.

The dispatcher never knows which of the two answers: the fire is the
same bearer-token POST either way, Delivered still means only "the
endpoint answered 2xx", and the queue stays the source of truth. The
Daytona path spawns one sandbox per fire that runs the identical
claim → docs → finish loop on an open-weights model.

## The Mac default and the cloud fallback

With the Mac app (`sylos_mac`, private) the default worker is the
owner's own computer: the app polls the queue every ~20 seconds and
claims through the same gated RPCs. The cloud's job is then only the
closed-lid case, and the decision lives at the edge, not in the
dispatcher:

- the Mac stamps a heartbeat each tick — `worker_heartbeat()` upserts
  its `worker_presence` row and returns the queued count, so presence
  and the queue peek are one call. Presence is cosmetic state in the
  `status_note` tradition: watched, never audited.
- the webhook points at this project's own `syla-fire` function
  (`daytona/README.md`). On every fire it reads the freshest
  heartbeat: seen within the window (90 s, `WORKER_FRESH_SECONDS`) →
  it answers 2xx and stands down, the Mac has this; stale or absent →
  it spawns the Daytona sandbox. A lid closed moments after a fresh
  heartbeat costs only the dispatcher's normal re-fire (20 minutes,
  3 tries) before the cloud takes over; races are harmless because
  claims are atomic and an extra worker finds an empty queue.
- where a run actually ran is a recorded fact, not an inference:
  `claim_syla_runs(_worker)` stamps `syla_job_runs.claimed_by`
  (`mac` | `cloud` | `routine`; the Mac app and `daytona/run-syla.sh`
  each pass their own name via `SYLA_WORKER`). The apps' receipt
  ladder reads that column — and reads `worker_presence` — to say
  "on your Mac" / "in the cloud".
- off is `clear_syla_webhook()`: with no Vault credential the
  dispatcher leaves runs queued, which is exactly "wait for the Mac".

## The docs are the instructions

The starter seeds two Syla events the moment the owner's account is
crowned, each attached to its doc and each pre-latched forever, so the
generic due-scan serves only events the owner puts on the calendar
themself: the **Chute sort** (`syla/chute-sort`, dispatched by the
chute branch) and **Edit feedback** (`syla/edit-feedback`, dispatched
by the proposal-feedback trigger). The other instruction docs the
starter ships — `syla/note-siloing`, `syla/goal-synergy`,
`syla/daily-summary` — have no seeded event anymore: they fired daily
sessions that had nothing to do on a young install, so they wait as
docs until the owner puts an event on the calendar that attaches one.
Edit a doc in the app (or via `scripts/doc-save`) and the event behaves
differently on its next run; every edit is in `row_edits`, so a bad
instruction change is one restore away.
