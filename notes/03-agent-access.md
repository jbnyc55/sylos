# Agent database access

Claude reads the production database and writes through a handful of
narrow, structured paths. This page covers how that boundary is drawn.

## The role

A dedicated Postgres role, `claude`:

| | |
| --- | --- |
| **Read** | Every table in `public`, including ones added by later migrations — with a few deliberate exceptions (e.g. OAuth token tables) |
| **Write** | Narrow, structured paths only: `agent_edits` (insert-only self-reporting); `day_summary` upserts; note silo placement and splits; `docs` in full — insert, update *and* delete — every change captured by trigger in the write-protected `row_edits` log; proposal-queue inserts and feedback-flagged revisions; auto-approve rule *requests*; Syla run claims and finishes |
| **Cannot** | Write any other table or column, update or delete its own log rows, read the `auth` schema, create or drop anything, or switch to another role |

The asymmetry is the point: reads are broad so the agent can answer
questions about real data; writes are structured so the worst it can do
is add rows nobody has to trust — or edit docs, where the undo log makes
any change one write to revert.

**Enforcement is in Postgres, not in the tooling.** The scripts below only
produce nicer error messages; bypassing them gets exactly the same
refusals.

## The transport: `rq` over HTTPS

Agent environments often cannot open port 5432, so the agent ships SQL to
PostgREST RPCs over HTTPS. Both client scripts POST one statement to
`{SUPABASE_URL}/rest/v1/rpc/<fn>` with two headers: `apikey` (the
client-public anon key) and `x-claude-rq-key` (the proof, compared
server-side against Vault secret `claude_rq_key`).

Three server-side pieces (`supabase/migrations/20260820000000_*.sql`):

1. `grant claude to authenticator` — makes `set local role claude` legal
   from PostgREST's session.
2. `assert_claude_rq_key()` — SECURITY DEFINER solely to read
   `vault.decrypted_secrets`; raises on any mismatch, including the
   secret not existing. Fails closed, no fallbacks.
3. `run_readonly_sql(q)` — SECURITY INVOKER, granted to `anon` only:
   calls the gate, sets role `claude`, `transaction_read_only = on`, a
   30s statement timeout, then wraps and executes
   `select coalesce(jsonb_agg(to_jsonb(t)), '[]') from (<your sql>) t`.

That wrap is the SQL contract: **one statement, no trailing semicolon,
valid inside a FROM subquery.** The result is always a JSON array. Writes
fail twice over — the transaction is read-only, and the wrap makes
non-SELECT statements a syntax error.

```bash
scripts/rq "select count(*) from manual_notes"

scripts/rq - <<'SQL'                 # stdin form avoids shell-quoting pain
select relname as table, n_live_tup as approx_rows
from pg_stat_user_tables where schemaname = 'public' order by relname
SQL
```

## The structured writes

Every agent write is its own script → its own gated RPC that takes
arguments, never SQL, and is idempotent where re-running matters:

| Script | Does |
| ------ | ---- |
| `scripts/agent-log` | Append a self-report row to `agent_edits` |
| `scripts/day-summary` | Upsert one day's stats JSON |
| `scripts/silo-note`, `scripts/split-note` | Place a note in silos / split one into sub-notes |
| `scripts/doc-save`, `doc-move`, `doc-delete`, `doc-silo` | Edit the docs library (all trigger-logged in `row_edits`) |
| `scripts/propose-map-edit`, `propose-todo-edit` | File pending proposals for the owner |
| `scripts/revise-map-edit`, `revise-todo-edit` | Rework proposals the owner flagged with feedback |
| `scripts/propose-auto-approve-rule` | Request (never enact) an auto-approve rule |
| `scripts/link-goal-cells` | Annotate same-concept goal cells as a synergy group |
| `scripts/log-lift` | Append weight-lift rows parsed from notes |
| `scripts/syla-claim`, `syla-finish`, `syla-set-webhook` | The job queue — see [`04-syla-jobs.md`](04-syla-jobs.md) |
| `scripts/chat-say`, `chat-propose`, `chat-auto-reply`, `chat-waiting`, `suggest-reply-rule` | The chat surface: the receipt into the Syla conversation, reply drafts, rule-covered auto-replies, the blue dot, and reply-rule suggestions — the `skills/chat-replies` doc is the semantic preflight |
| `scripts/file-url` | A read, not a write: a short-lived signed link for an `uploads` row (the claude-file edge function; rq is SQL and cannot carry bytes), so Syla can look at a dropped photo or document before filing it |

This is also the pattern for anything you add later: a new agent
capability is a new structured script over a new gated RPC, with RLS and
grants doing the enforcement.

## Revoking access

Any one of these is sufficient:

```sql
select vault.update_secret(
    (select id from vault.secrets where name = 'claude_rq_key'),
    encode(gen_random_bytes(32), 'hex'));       -- rotate: old key stops working
delete from vault.secrets where name = 'claude_rq_key';  -- gate fails closed
drop function public.run_readonly_sql(text);             -- remove the endpoint
```
