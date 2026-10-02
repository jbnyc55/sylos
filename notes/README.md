# notes

Operating notes for this system: how it fits together, how a merge reaches
production, how the agent's access is bounded, and how to run it.

**No secret values live here.** These notes record *where* each credential
comes from and *where* it is stored. If you ever find an actual token,
password, or key checked into this repo, rotate it immediately.

| File | What it covers |
| ---- | -------------- |
| [`01-architecture.md`](01-architecture.md) | Repo layout, the chat-first shape (Chats \| Chute \| Home), runtime data flow, credential tiers, and the design principles everything else hangs off. Read this first. |
| [`02-setup.md`](02-setup.md) | First-time setup: the seven-step desktop web flow at getsylos.com/setup, the QR handoff that arms the iPhone, and the by-hand routes. |
| [`03-agent-access.md`](03-agent-access.md) | The `claude` database role — read anything, write through narrow gated RPCs — and the `rq` HTTPS transport. |
| [`04-syla-jobs.md`](04-syla-jobs.md) | Syla jobs — the app-owned schedule: pg_cron → webhook → one generic routine, instructions in editable docs; the chute branch, delivery marking, and the Syla-thread receipts. |
| [`05-followers.md`](05-followers.md) | Silos, followers, and the invite flow: sharing scoped by silo, enforced by the database — and how the Connections app presents it. |
| [`06-integrations.md`](06-integrations.md) | Integrations: the database-driven registry (new web integrations without an app update), Google Calendar's shared PKCE OAuth client and cron-synced mirror, and the phone-native ones — location, contacts, Apple Calendar & Reminders, Health, and push notifications. |
| [`07-user-tables.md`](07-user-tables.md) | User tables: the owner's own tables ("put this CSV into a table"), proposed by Syla, approved in the app, created by a sandboxed role — no fork, no merge. |
| [`08-provisioning.md`](08-provisioning.md) | Provisioning: the web setup tab builds the project over the Management API, then the iPhone — holder of the management credential — becomes the standing migration and function runner. |
| [`09-hosted-trial.md`](09-hosted-trial.md) | *(historical)* The hosted trial — removed by the chat-first rebuild (own Claude only); kept as the record of the design and its one schema knob. |
| [`10-apps-and-chat.md`](10-apps-and-chat.md) | Apps and chat: every app a vibe in your own database, chat personal all the way down (your words in your project, a DM a mutual follow), message authors and kinds, and Syla as a conversation with real receipts. |
| [`11-connections-and-reply-rules.md`](11-connections-and-reply-rules.md) | Connections: one lifecycle over the directional machinery, the reply ladder (propose → auto → Syla × Syla), reply rules as the per-person preflight, and one-sided visibility. |
| [`12-chute.md`](12-chute.md) | The chute: capture with no filing decision, Syla's scheduled sort, undo as row_edits, ambiguity as Inbox questions. |

## The thirty-second version

- The system lives in this public starter — `supabase/` (database),
  `scripts/`, `notes/` — which Syla's sessions clone and the clients
  read; the iOS client is a separate private repo. A GitHub account of
  your own is optional (fork the starter only if you want git owning
  your schema).
- Setup is desktop web (getsylos.com/setup); the phone joins by QR and
  its Keychain becomes the standing home of the management credential.
- Merging to `main` migrates production Postgres: the iPhone applies
  `supabase/migrations/` over the Management API (at setup, and
  quietly every launch), or Supabase's GitHub integration does it on a
  fork. No CI runners, no GitHub secrets.
- The app talks straight to Supabase with the public anon key, so
  **row level security is the entire authorization layer**.
- Claude reads the database as the `claude` role over HTTPS (`scripts/rq`)
  and writes only through structured, Vault-gated RPCs; everything that
  matters is captured in the trigger-written `row_edits` undo log.
- Syla's recurring work is scheduled as events assigned to her (edited
  from the app's Today tab) and instructed by the docs attached to each
  event (edited from the Docs side of Notes); what she knows how to do
  is docs under `skills/` — no merge needed to change any of it.
