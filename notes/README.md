# notes

Operating notes for this system: how it fits together, how a merge reaches
production, how the agent's access is bounded, and how to run it.

**No secret values live here.** These notes record *where* each credential
comes from and *where* it is stored. If you ever find an actual token,
password, or key checked into this repo, rotate it immediately.

| File | What it covers |
| ---- | -------------- |
| [`01-architecture.md`](01-architecture.md) | Repo layout, runtime data flow, and the design principles everything else hangs off. Read this first. |
| [`02-setup.md`](02-setup.md) | First-time setup, step by step — the same flow the iOS onboarding walks through: GitHub, the owner account, Supabase, agent access, Syla's schedule. |
| [`03-agent-access.md`](03-agent-access.md) | The `claude` database role — read anything, write through narrow gated RPCs — and the `rq` HTTPS transport. |
| [`04-syla-jobs.md`](04-syla-jobs.md) | Syla jobs — the app-owned schedule: pg_cron → webhook → one generic routine, instructions in editable docs. |
| [`05-members.md`](05-members.md) | Silos, members, and the invite flow: sharing scoped by silo, enforced by the database. |
| [`06-integrations.md`](06-integrations.md) | Integrations: the database-driven registry (new web integrations without an app update), Google Calendar's shared PKCE OAuth client and cron-synced mirror, and the phone-native ones — location, contacts, Apple Calendar & Reminders, Health, and push notifications. |
| [`07-user-tables.md`](07-user-tables.md) | User tables: the owner's own tables ("put this CSV into a table"), proposed by Syla, approved in the app, created by a sandboxed role — no fork, no merge. |
| [`08-provisioning.md`](08-provisioning.md) | One-tap provisioning: the user creates only a Supabase account; the app creates the project, applies migrations from the fork, and stores Syla's key — via the Management API and a tiny OAuth relay. |
| [`09-hosted-trial.md`](09-hosted-trial.md) | The hosted trial: onboarding's "try hosted Syla" — one account on a Sylos-run starter install, marked Trial everywhere, the move to your own, and the one schema knob (`hosted_trial`) that lets trials ask Syla. |
| [`10-apps-and-chat.md`](10-apps-and-chat.md) | Apps and chat: every app a vibe hosted in your own database, the `default_app` setting, the two stock apps (Mash and Todos), and chat as the one deliberately centralized piece — Syla as a conversation, invites as messages, `chat_settings`, and what is deliberately not built yet. |

## The thirty-second version

- The system lives in this public starter — `supabase/` (database),
  `scripts/`, `notes/` — which Syla's sessions clone and the app reads;
  the iOS client is a separate private repo. A GitHub account of your
  own is optional (fork the starter only if you want git owning your
  schema).
- Merging to `main` migrates production Postgres: the app applies
  `supabase/migrations/` over the Management API (on provisioning and
  every launch), or Supabase's GitHub integration does it on a fork.
  No CI runners, no GitHub secrets.
- The app talks straight to Supabase with the public anon key, so
  **row level security is the entire authorization layer**.
- Claude reads the database as the `claude` role over HTTPS (`scripts/rq`)
  and writes only through structured, Vault-gated RPCs; everything that
  matters is captured in the trigger-written `row_edits` undo log.
- Syla's recurring work is scheduled as events assigned to her (edited
  from the app's Today tab) and instructed by the docs attached to each
  event (edited from the Docs side of Notes); what she knows how to do
  is docs under `skills/` — no merge needed to change any of it.
