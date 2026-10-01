# Architecture

## Repo layout

```
sylos-starter/
├── supabase/             Database as versioned SQL
│   ├── config.toml            local stack config
│   ├── migrations/            timestamped, append-only migrations
│   └── functions/             edge functions: gcal, plaid, push (deployed to every
│                              install) and the developer-only relays supabase-oauth,
│                              push-relay (never deployed to a user's project)
├── scripts/              The agent's database access wrappers
├── notes/                This folder
└── package.json          db helper scripts (supabase CLI wrappers)
```

The clients live elsewhere. Most UX is the **web shell** at
getsylos.com/app — login, provisioning, the app switcher, the iframe
host — and the apps it opens, which are **vibe code apps hosted in this
database**: whole client-side apps stored one row each in
`vibe_code_apps` and served over PostgREST like any other row. One of
them is the one the shell boots straight into (`profiles.default_app`);
two stock apps ship with every install — **Chat**, the chat app and the
default, and **Todos**, the classic tabs, quietly second in the
switcher — and chat is the one deliberately centralized piece, living
on the company's project rather than yours. `notes/10-apps-and-chat.md`
is the whole story. The iOS app — now a thin wrapper around the shell
plus what the web cannot do (push, Health/Location/Contacts, Keychain)
— lives in its own **private** repository, `sylos_ios`. Everything here
still describes the whole system; every client is bound by the same
rules.

There is deliberately no `.github/workflows/` in this repo. Merging
to `main` migrates production either way, by one of two runners: on
one-tap installs the client itself applies `supabase/migrations/` and
deploys `supabase/functions/` from the fork over the Management API (on
provisioning and on every launch — `notes/08-provisioning.md`); on manual
installs Supabase's GitHub integration watches the repo and applies
migrations on merge (edge functions are deployed with
`supabase functions deploy <slug>` there, or by any launch of a
one-tap-connected app).
This repo itself still hosts nothing: the shell is the company's site
to run, and the apps you actually use are rows in your own database,
deployed by writing the row. A change to `notes/` costs zero deploys.

## Runtime data flow

```
   The web shell (getsylos.com/app), the vibe apps it runs in iframes,
   and the iOS shell wrapped around it
      │  fetch → PostgREST, authorized by the publishable key
      │  + the user's session token (GoTrue password/signup grant,
      │    refreshed automatically; handed into each app by postMessage)
      ▼
   Supabase  (PostgREST → Postgres)
      │
      └── every query is evaluated against Row Level Security policies
          defined in supabase/migrations/
```

There is **no backend of our own**. The client talks to Supabase
directly using the public (publishable/anon) key from onboarding.
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
because followers and guests can hold auth sessions too.

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
6. **Every table is siloed or unsiloed.** Six record types are placed
   row by row; every other table in `public` is placed as a whole, and a
   registry (`data_tables`) kept by an event trigger holds one row per
   table saying which — or that it is system machinery, declared so by
   its migration. A new table, product or user-created, starts unsiloed
   in the backlog and invisible to followers; there is no third state
   (`notes/05-followers.md`).
7. **The agent's knowledge is data.** Syla's skills are docs (rows under
   `skills/` in the `docs` table, seeded by migration), and her job
   instructions are the docs attached to her scheduled events through
   `event_docs` (seeded under the `syla/` folder). Teaching the agent
   something new is a doc edit — logged, undoable, visible in the app —
   never a repo change.

## Why these choices

**A credential-free shell over a backend** — this section used to argue
for a native client and no web hosting at all. That doctrine is
overturned: most UX is now the web shell at getsylos.com/app plus vibe
apps hosted in your own database. But the argument's core survives in
the new shape, and it is worth restating honestly: the shell is static
pages that ship no credentials, working against whichever Supabase
project its owner configured, and there is still no server runtime of
ours — so there is still no place for a privileged key to live. What
the site's operator hosts is HTML; what authorizes anything is your
own database's RLS.
**No CI runners** — Supabase already watches GitHub; dropping runners
removes the whole secret surface. The trade is that pre-merge checks are
on you: the app builds clean in Xcode, `npm run db:lint` for the
migrations. **Migrations applied
on merge, never by hand** — the migration history in git *is* the
production schema. **SQL over an ORM** — RLS policies, triggers and
indexes stay reviewable in a pull request diff.
