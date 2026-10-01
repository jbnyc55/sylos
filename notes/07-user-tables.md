# User tables — new tables without a merge

The product's own schema arrives as migrations, merged to `main`. The
owner's *own* tables — "put this CSV into a table and make me an app" —
take a different road, because a GitHub merge is the wrong ceremony for
personal data: Syla **proposes** the table, the owner **applies** it from
a card in the app, and the database creates it on the spot. Migration
`20261017000000_user_tables.sql` is the whole mechanism; the skill Syla
follows is the `skills/user-tables` doc.

## The flow

1. Syla writes the schema change — `create table` with RLS enabled, owner
   policies, a read-only policy for herself — and files it with
   `scripts/propose-user-table` (title, plain-English summary, the DDL,
   optionally a `seed_sql` of plain INSERTs for the data). This calls the
   `propose_user_table` RPC: rq-key-gated, linted, inserted as a pending
   `user_table_proposals` row by the `claude` role. Nothing executes.
2. The card appears in the Syla tab's Inbox with the SQL behind a
   disclosure. The owner applies, rejects, or flags it with feedback,
   exactly like a todo or map proposal.
3. Apply calls `apply_user_table_proposal()`: the script (DDL, then seed,
   one transaction) executes as the sandboxed `user_tables_owner` role,
   the row is marked `applied`, and PostgREST reloads its schema — the
   table serves immediately. A failure rolls everything back and parks
   the row as `failed` with the database's error on it; Syla reads that
   and resubmits with `scripts/revise-user-table` (which also serves
   `changes_requested` rows).
4. Later changes are more proposals: `alter table`, `drop table`, a
   tightening of a `text` column once an aggregation needs a type.

Applied rows are never deleted by the flow — `user_table_proposals` is
the append-only schema history of every user table, the same role git
history plays for the product schema.

## The trust story

Three layers, from authority to backstop:

- **The owner approves everything.** A proposal is an inert row until the
  owner taps Apply with the SQL in front of them — the same
  owner-approves invariant as every other proposal queue.
- **A real privilege boundary.** Approved scripts run as
  `user_tables_owner`, a NOLOGIN role whose only power is `CREATE` on
  schema `public`. It owns the tables it creates and nothing else: it
  cannot read or alter product tables, reach other schemas, create
  functions with teeth, or mint roles. A bad script that survives review
  is boxed in by Postgres, not by promises.
- **Tripwires.** `assert_user_table_sql()` lints every script at propose,
  revise, and apply time: no `SECURITY DEFINER`, no role switching, no
  functions/triggers, no foreign schemas, no transaction control, RLS
  required in the same script as any `create table` — and no write path
  for `claude`, ever.

**User tables are the owner's.** That last rule is the invariant the
owner chose: Syla reads user tables like everything else in `public`
(default privileges grant her role `select` on them; the proposal script
adds her per-table read policy), and she never writes them — no grant,
no RPC, no trigger. Every row in a user table was written by the owner's
own authenticated session: the app, or a vibe app. If some future
integration must feed a user table, that is an edge function with its
own controlled path (see `notes/06-integrations.md`), proposed and
merged like any integration — still not Syla's role.

## Data

A seed rides the proposal as plain INSERTs (`seed_sql`, capped at 5 MB,
sensibly ~2 MB) and runs in the same transaction as the DDL, so a card
is one tap from "CSV in a note" to "table with the data in it". Bigger
datasets: propose the table alone and give the vibe app an import
screen — the data then enters under the owner's own session, RLS
applying to every row.

## Where a user table lands: siloed or unsiloed, never invisible

The moment the approved script creates the table, the siloing warden
(`20261101000000_every_table_siloed.sql`, `notes/05-followers.md`) registers
it in `data_tables` as a whole table, turns RLS on, and installs the
generic follower read policy. It starts *unsiloed*: readable by no follower,
listed under Silo Soon on the Syla tab next to unsiloed notes and docs.
From there the owner places the whole table in silos or names followers on
it (`table_silos` / `table_followers`) — the only way its rows ever reach a
follower, through `follower_rq` — or marks it siloed to keep it private. A
user table cannot be declared per-row or system; the sandbox role holds
no such power, and Syla has no write path into the placements. The same
apply also gets the two grants the sandbox role was missing (execute on
the log trigger function, trigger-context insert on `row_edits`), without
which an apply could not complete.

## What this is not

Not a bypass of the product schema: product tables still arrive only as
migrations merged to `main`, and the lint plus the sandbox role keep
user scripts out of them. Not an aggregation path either — rollups over
user tables are still Syla's scheduled jobs writing through her own
gated paths, never the client at write time.
