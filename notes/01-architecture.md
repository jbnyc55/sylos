# Architecture

## Repo layout

```
sylos-starter/
├── supabase/             Database as versioned SQL
│   ├── config.toml            local stack config
│   ├── functions/             edge functions: gcal, plaid, push, following-relay
│   │                          (deployed to every install) and the developer-only
│   │                          relays supabase-oauth, push-relay (never deployed
│   │                          to a user's project)
│   └── migrations/            timestamped, append-only migrations
├── scripts/              The agent's database access wrappers
├── notes/                This folder
└── package.json          db helper scripts (supabase CLI wrappers)
```

The clients live elsewhere: the native iOS app in its own **private**
repository (`sylos_ios`), and the web app at getsylos.com/app (the iOS
app's twin, in sylos-company `web/`) plus the desktop setup flow at
getsylos.com/setup. Everything here describes the whole system; every
client is bound by the same rules.

## The shape of the product

**Chat is the front door.** The client is three tabs — **Chats | Chute
| Home**:

- **Chats** — conversations with people (each a mutual follow, merged
  from both sides' databases — `notes/10-apps-and-chat.md`) and the one
  conversation with **Syla**, who is not a tab or an inbox but a chat
  (`chats.kind = 'syla'`, with real receipts — `notes/04-syla-jobs.md`).
  Per connection, a **reply ladder** says how your Syla may answer that
  person, gated by plain-English **reply rules**
  (`notes/11-connections-and-reply-rules.md`).
- **Chute** — the capture page: everything lands raw, Syla's scheduled
  sort files it, every filing is one logged, undoable write
  (`notes/12-chute.md`).
- **Home** — the plain app-tile launcher: the stock apps and every vibe
  in your database, among them **Connections** (the whole relationship
  lifecycle over the followers/following machinery —
  `notes/05-followers.md`) and the badged **Inbox**, the one approval
  surface — nothing Syla agrees to is final until approved there.

**The distributed-chat rule** binds every cross-person feature: it is an
*attributed message on the sender's side*. Drafts, reply rules and
Syla × Syla conclusions stay local; what travels is a message with a
kind (`auto_reply`, `ask_human`); there is no shared mutable chat state
anywhere, and Syla × Syla is 1:1.

## Runtime data flow

```
   The iOS app (Chats | Chute | Home), the web app at getsylos.com/app,
   and the vibe apps either one runs
      │  fetch → PostgREST, authorized by the publishable key
      │  + the user's session token (GoTrue password grant)
      ▼
   Supabase  (PostgREST → Postgres)
      │
      └── every query is evaluated against Row Level Security policies
          defined in supabase/migrations/
```

There is **no backend of our own**. The client talks to Supabase
directly using the public (publishable/anon) key. That is a deliberate
trade, and it has one hard consequence:

> **Row level security is the entire authorization layer.** A table
> without RLS enabled is readable by anyone who holds the anon key. Every
> table created in `supabase/migrations/` must call
> `alter table ... enable row level security` and define explicit
> policies.

Every user has a `profiles` row created automatically by a database
trigger the moment their `auth.users` row is inserted, and **`profile_id`
is how users are referred to everywhere** — data belongs to a profile,
never directly to an auth user. The first profile created is crowned
`is_owner` by trigger; app-management policies check `is_owner()`,
because followers can hold auth sessions too.

## Credential tiers

Three credentials, three homes, strictly ordered by power
(`notes/02-setup.md` has the flow that distributes them):

1. **The management credential** (a Supabase OAuth refresh token — full
   Management API power over the project) lives in the **iPhone's
   Keychain** and nowhere else at rest. The iPhone is therefore the
   migration and edge-function runner (`notes/08-provisioning.md`). It
   reaches the phone once, inside the setup QR code — burn-on-redeem —
   and the web can re-summon its own copy only through a silent OAuth
   re-consent. It is never in any database, and **Syla never holds it**.
2. **The owner's session** (GoTrue password grant) lives on the owner's
   devices; RLS gives it everything that is theirs.
3. **Syla's scoped credentials** (the rq key, webhook URL and token)
   live in the project's **Vault**: the `claude` role, narrow gated
   writes, nothing else (`notes/03-agent-access.md`).

Clients detect schema/function drift with `schema_version()` and the
holder of tier 1 — the iPhone — catches the database up.

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
   makes its free edit rights on `docs` safe, and what makes the chute's
   Undo a plain status flip. Undo is always one write: put `old_row`
   back (the revert is itself a new logged edit).
4. **Beyond its narrow grants, the agent proposes.** Chat replies are
   drafts the owner approves (or rule-gated, attributed auto-replies);
   map, todo and calendar changes land in proposal queues; the Inbox is
   the one approval surface, and approved changes are executed by the
   owner's own client, never by the agent's role.
5. **Raw logs now, aggregation later.** The chute and `manual_notes`
   take everything raw; categories are `silos` rows — pure data slices,
   with zero reply semantics (`silo_rules` are inclusion/exclusion
   sentences and nothing else); placement is a junction; rollups are
   Syla's scheduled jobs. Never make the client compute or store a
   rollup. When a table IS warranted (a CSV import, genuinely tabular
   data), it does not need the fork: the user-tables path,
   `notes/07-user-tables.md`.
6. **Every table is siloed or unsiloed.** Six record types are placed
   row by row; every other table in `public` is placed as a whole, and a
   registry (`data_tables`) kept by an event trigger holds one row per
   table saying which — or that it is system machinery, declared so by
   its migration (chats and the chute are system: secret by audience,
   never placeable). A new table starts unsiloed in the backlog and
   invisible to followers; there is no third state
   (`notes/05-followers.md`).
7. **The agent's knowledge is data.** Syla's skills are docs (rows under
   `skills/` in the `docs` table, seeded by migration), and her job
   instructions are the docs attached to her scheduled events through
   `event_docs` (seeded under `syla/`). Teaching the agent something new
   is a doc edit — logged, undoable, visible in the app — never a repo
   change.

## Why these choices

**No backend, no hosted credentials** — what the company hosts is HTML
(the web app and the setup flow are static pages that ship no
credentials); what authorizes anything is your own database's RLS. The
one powerful credential the system mints goes to hardware you hold (the
iPhone's Keychain), not to a server of ours. **No CI runners** —
merging to `main` migrates production anyway: the iPhone applies
`supabase/migrations/` and deploys `supabase/functions/` over the
Management API on provisioning and quietly on every launch
(`notes/08-provisioning.md`); manual installs can still use Supabase's
GitHub integration. Dropping runners removes the whole secret surface;
the trade is that pre-merge checks are on you (`npm run db:lint`, the
app building clean in Xcode). **Migrations applied on merge, never by
hand** — the migration history in git *is* the production schema.
**SQL over an ORM** — RLS policies, triggers and indexes stay
reviewable in a pull request diff.
