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

`syla_dispatch()` runs every minute under pg_cron. Each tick it queues a
run for every due Syla event (one-offs, daily and weekly rules;
`until_date` and `event_exclusion` honored; `last_fired_on` is the
once-a-day latch, reset by the event trigger so a rescheduled event
never fires retroactively), fails runs that were claimed but never
finished within 2 hours or that three webhook fires couldn't get
claimed, and POSTs the routine's fire endpoint once for everything
still queued. Event times are the owner's local wall clock — the zone
is pinned in the dispatcher and the latch trigger (`America/New_York`
in the starter; edit both if yours differs).

Failure is designed to be visible, never silent: no Vault credential →
runs sit `queued`; webhook lost → re-fired up to 3 times, then `failed`
with a reason; session died → `failed` after 2 hours.

## The webhook credential

The generic routine is fired with its own bearer token, scoped to firing
that one routine — it reads nothing else. It lives in Vault as
`syla_webhook_token` alongside `syla_webhook_url`, written through
`scripts/syla-set-webhook` → `set_syla_webhook()`. The RPC is gated by
the usual rq key and **pins the URL to
`https://api.anthropic.com/v1/claude_code/routines/…/fire`**, so a leaked
rq key could rotate or break the webhook but never redirect the token to
a host that would capture it. `pg_net` and `pg_cron` are server-side
only.

## The docs are the instructions

The starter seeds four Syla events the moment the owner's account is
crowned, each attached to its doc: `syla/note-siloing`,
`syla/edit-feedback`, `syla/goal-synergy`, `syla/daily-summary`. Edit a
doc in the app (or via `scripts/doc-save`) and the event behaves
differently on its next run; every edit is in `row_edits`, so a bad
instruction change is one restore away.
