# First-time setup

The Sylos iOS app walks through all of this — install it from TestFlight
and follow the onboarding; it opens each service in an in-app browser,
generates your agent key, and remembers which step you're on. This page is
the same flow written down, for doing it by hand or unsticking a step.
Budget under an hour. No GitHub secrets, no CI configuration, no web
hosting.

## 0. GitHub — optional

You do not need a GitHub account: Syla's sessions clone this public
starter, and the app applies its migrations to your project itself.
Fork the starter only if you want git owning your schema — your fork
then feeds both the Supabase GitHub integration (if you connect it) and
the app's migration runner (set the fork's URL in the app's Settings).

## 1. Your owner account: nothing to edit

The first account created in the app becomes the owner — a database
trigger crowns the first `profiles` row and seeds Syla's starter jobs for
it (`20260930000000_first_signup_owner.sql`). So there is no file to
edit before deploying; just **sign up promptly after the first deploy**:
between "migrations applied" and "you signed up," anyone who knew your
fresh project's URL and anon key could in principle sign up first (the
project ref is unguessable and the window is minutes; if it ever
happens, delete the minutes-old project and redeploy).

Prefer a pre-created account anyway? The legacy path still works:
customize `supabase/migrations/20260816000100_seed_first_user.sql`
(email + temporary password) before the first merge — it only runs when
its placeholder email was changed, and the trigger then finds an owner
already exists and stands down.

## 2. Supabase — create your database

The one thing you do by hand is create the account: sign up at
[supabase.com](https://supabase.com) — choose **Continue with GitHub**.
Then, on the onboarding's Create-your-database step, tap **Connect
Supabase** and sign in once. The app does the rest over the Management
API: finds (or creates) your organization, creates the project, applies
every migration from your fork — schema, RLS, the `claude` role, Syla's
skills docs — stores Syla's key in the vault, and fetches its own API
keys. Nothing to copy, no dashboard walkthrough, no database password to
save (the app generates one and keeps it in your phone's Keychain). How
this works, and what the developer sets up once to make it possible:
[`08-provisioning.md`](08-provisioning.md).

**The manual route** (if you prefer your hands on the dashboard, or the
build isn't configured for one-tap): create an organization (free tier)
and a project; Project Settings → Integrations → GitHub — connect your
fork and enable **Deploy to production**, directory at its default; then
Project Settings → API — note the **Project URL** and the **anon /
publishable key** (both client-public) for the app's Connect step, and
store Syla's key in the vault on the key step. Database → Migrations
shows the applied list.

## 3. The app

One-tap installs arrive here already connected. On the manual route,
enter the Project URL and publishable key in the app (onboarding's
Connect step, or Settings later — saved on the device only). Either way,
create your account on the Your account step — any email and password.
First account in becomes the owner. One-tap projects are set to skip
email confirmation; a manually created project may mail you a
confirmation link first (Supabase's default) — tap it, then log in.

## 4. Agent access (Claude reading your database)

The onboarding's last step generates the key and shows these with copy
buttons:

1. Generate a key: `openssl rand -hex 32`.
2. Supabase → SQL editor:
   `select vault.create_secret('<value>', 'claude_rq_key');`
3. In Claude Code's environment settings for your fork, set:

   ```
   SUPABASE_URL=https://<project-ref>.supabase.co
   SUPABASE_ANON_KEY=<the anon key>
   CLAUDE_RQ_KEY=<the same value as the Vault secret>
   ```

4. Verify from a Claude Code session:
   `scripts/rq "select current_user"` → `claude`.

Details and the security model: [`03-agent-access.md`](03-agent-access.md).

## 5. Syla's schedule

1. In claude.ai/code → Routines, create one fire-only Routine named
   **Syla task**, attach your fork of this repo as its **repository**,
   give it the prompt *"Do the task."*, and add an **API trigger** to it.
   Copy the fire URL and the `sk-ant-oat01-…` token. The routine's
   environment must allow your project host and `github.com`, and carry
   `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `CLAUDE_RQ_KEY`.

   The repository is not optional. Attached, the scripts are the
   session's own checkout and `.claude/settings.json` pre-approves
   `scripts/*`. Cloned mid-session instead (the old "clone the starter
   and do the task" prompt), they are code from an external source to
   the session's permission check, which refuses to run them — the
   run stops at `scripts/syla-claim`.
2. From a Claude Code session in that environment (clone the starter
   first): `scripts/syla-set-webhook --url <fire url> --token <token>`
3. The in-database dispatcher (pg_cron, every minute) now fires that one
   routine whenever a job is due. The seeded jobs are on the Calendar tab
   (toggle Syla's calendar on) — retime, pause or add jobs there, and
   edit what they do in the Docs tab (`syla/…` docs). What Syla knows how
   to do is also in the Docs tab, under `skills/`.

Details: [`04-syla-jobs.md`](04-syla-jobs.md).

## 6. Rotating and revoking

- **rq key**: create a new value and `vault.update_secret`; the old key
  stops working immediately. Deleting the secret fails the gate closed.
- **Webhook token**: regenerate the API trigger token in the Claude Code
  UI, re-run `scripts/syla-set-webhook`.
- **A member's key**: block or delete their row on the Manage page —
  see [`05-members.md`](05-members.md).
- **Owner password**: Supabase → Authentication → Users.
