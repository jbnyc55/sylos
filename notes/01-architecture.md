# Architecture

## Repo layout

```
sylos-starter/
├── supabase/             Database as versioned SQL
│   ├── config.toml            local stack config
│   ├── migrations/            timestamped, append-only migrations
│   └── functions/             edge functions (gcal, plaid) — optional integrations
├── scripts/              The agent's database access wrappers
├── notes/                This folder
└── package.json          db helper scripts (supabase CLI wrappers)
```

The iOS app (native SwiftUI: onboarding, the PostgREST data layer, the
five tabs) lives in its own **private** repository, `sylos_ios` — this
starter is public, the client is not. Everything here still describes
the whole system; the app is bound by the same rules.

There is deliberately no `.github/workflows/` and no web hosting. Merging
to `main` migrates production either way, by one of two runners: on
one-tap installs the app itself applies `supabase/migrations/` and
deploys `supabase/functions/` from the fork over the Management API (on
provisioning and on every launch — `notes/08-provisioning.md`); on manual
installs Supabase's GitHub integration watches the repo and applies
migrations on merge (edge functions are deployed with
`supabase functions deploy <slug>` there, or by any launch of a
one-tap-connected app).
The client is the iOS app: built in Xcode, distributed through
TestFlight/App Store, deployed nowhere. A change to `notes/` costs zero
deploys.

## Runtime data flow

```
   Sylos iOS app (SwiftUI)
      │  URLSession → PostgREST, authorized by the publishable key
      │  + the user's session token (GoTrue password/signup grant,
      │    refreshed automatically)
      ▼
   Supabase  (PostgREST → Postgres)
      │
      └── every query is evaluated against Row Level Security policies
          defined in supabase/migrations/
```

There is **no backend of our own**. The app talks to Supabase directly
using the public (publishable/anon) key the user typed into onboarding.
That is a deliberate trade, and it has one hard consequence:

> **Row level security is the entire authorization layer.** A table
> without RLS enabled is readable by anyone who holds the anon key. Every
> table created in `supabase/migrations/` must call
> `alter table ... enable row level security` and define explicit
> policies.

Every user has a `profiles` row created automatically by a database
trigger the moment their `auth.users` row is inserted, and **`profile_id`
is how users are referred to everywhere** — data belongs to a profile,
never directly to an auth user. The first profile created is crowned
`is_owner` by trigger — that's the account you create in the app right
after the first deploy (or the seeded user, if you customized the
optional seed migration); app-management policies check `is_owner()`,
because members and guests can hold auth sessions too.

## The principles

1. **One database for the whole life.** All durable personal state lives
   here, and every agent that works for you reads from and writes to this
   database. Anything worth remembering gets written back as a row.
2. **Enforce at the database, never in the agent.** Roles, RLS and
   triggers are the boundary. The scripts in `scripts/` only produce
   nicer error messages — bypassing them entirely gets the same refusals.
3. **The undo log is append-only and unskippable.** `row_edits` rows are
   written by an `AFTER INSERT OR UPDATE OR DELETE` trigger with full
   before/after row images; its only insert policy is
   `pg_trigger_depth() > 0` and nobody holds update or delete on it. The
   agent cannot skip an entry, forge one, or rewrite one — which is what
   makes its free edit rights on `docs` safe. Undo is always one write:
   put `old_row` back (the revert is itself a new logged edit).
4. **Beyond its narrow grants, the agent proposes.** Map and todo changes
   land in proposal queues the owner approves, denies, or flags with
   feedback in the app; even granted auto-approve rules are executed by
   the owner's own client, never by the agent's role.
5. **Raw logs now, aggregation later.** One `manual_notes` table for all
   free-text logging; categories are `silos` rows (created from the app —
   no migration), placement is a junction, and rollups are done by Syla's
   daily jobs into `day_summary`. Never make the client compute or store
   a rollup. When adding a new kind of log, prefer a new silo over a new
   table, and generic `body` text over structured columns until an
   aggregation actually needs structure. When a table IS warranted (a
   CSV import, genuinely tabular data an app needs), it does not need
   the fork: Syla proposes it and the owner applies it in the app — the
   user-tables path, `notes/07-user-tables.md`.
6. **The agent's knowledge is data.** Syla's skills are docs (rows under
   `skills/` in the `docs` table, seeded by migration), and her job
   instructions are the docs attached to her scheduled events through
   `event_docs` (seeded under the `syla/` folder). Teaching the agent
   something new is a doc edit — logged, undoable, visible in the app —
   never a repo change.

## Why these choices

**A native client over a hosted site** — one less account (no Vercel),
one less deploy pipeline, and no public URL to protect; the app works
against whichever Supabase project its owner configured, and there is no
server runtime, so there is no place for a privileged key to live.
**No CI runners** — Supabase already watches GitHub; dropping runners
removes the whole secret surface. The trade is that pre-merge checks are
on you: the app builds clean in Xcode, `npm run db:lint` for the
migrations. **Migrations applied
on merge, never by hand** — the migration history in git *is* the
production schema. **SQL over an ORM** — RLS policies, triggers and
indexes stay reviewable in a pull request diff.
