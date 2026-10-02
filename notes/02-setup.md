# First-time setup

Setup lives on **desktop web**: getsylos.com/setup walks all seven
steps in one tab, and the page persists afterwards at
getsylos.com/devices (re-summoning its powers by silent OAuth
re-consent when needed). The iPhone app opens on a camera — "Sign up on
your computer" — and joins by scanning the QR code the last step shows.
This note is the same flow written down, for doing it by hand or
unsticking a step. Budget under an hour. No GitHub secrets, no CI
configuration, no backend.

## The seven steps

1. **Sign-in held in-tab** — your getsylos.com sign-in, kept open while
   the rest runs.
2. **Supabase account** — the one thing created by hand: sign up at
   supabase.com (Continue with GitHub is fine). The project lives under
   your account, not ours.
3. **Authorize** — one OAuth consent (PKCE, state prefix `setup:`)
   through the developer's relay (`notes/08-provisioning.md`). The
   resulting Management API tokens live in the tab, nowhere else.
4. **Create database** — the tab is the provisioner: organization,
   project, every migration from this starter in filename order,
   edge functions, Syla's rq key into the Vault, the app keys —
   `notes/08-provisioning.md` mechanics, run from the browser.
5. **Claude environment** — create the environment on *your* Claude
   Code account with `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
   `CLAUDE_RQ_KEY`, network allowance for your project host and
   github.com. (Hosted Syla is gone; it's your Claude or nothing —
   `notes/09-hosted-trial.md` is historical.)
6. **Create routine** — one fire-only Routine named **Syla task** —
   prompt: *"Clone https://github.com/jbnyc55/sylos (the public Sylos
   starter), read its CLAUDE.md, and do the task."* — with an API
   trigger. The page stores the fire URL and token in your project's
   Vault through `set_syla_webhook` (`scripts/syla-set-webhook` is the
   by-hand route); the in-database dispatcher does the rest
   (`notes/04-syla-jobs.md`).
7. **QR handoff** — the page shows a QR code; the phone scans it and is
   in. Details below, because this is where the powerful credential
   changes hands.

## The QR handoff, and who holds what

The QR encodes one JSON object: project name and ref, URL, publishable
key — all client-public — plus the one secret in the whole flow, a
**one-time management update key**: the OAuth *refresh token*.
Properties, all deliberate:

- **Burn-on-redeem.** The phone redeems the refresh token immediately
  on scan (the exchange rotates it), so the displayed code dies the
  moment it is used. An unscanned code expires after 10 minutes — the
  page then rotates the token itself (invalidating the shown code) and
  renders a fresh one; leaving the page discards the in-tab copy, and
  the person can revoke the OAuth grant any time.
- **"Code already used" is an app-side state only** (the redeem fails
  with `invalid_grant`): the phone says so and points at
  revoke-and-reauthorize. The website never shows that copy.
- **The iPhone Keychain is the standing home of the management
  credential** — which makes the iPhone the migration and
  edge-function runner from then on (`notes/08-provisioning.md`). The
  management token is never at rest in any database; the web tab
  discards its copy after setup; **Syla never holds management
  power**. The Vault holds only her scoped credentials.
- After the scan: the phone shows the verified project card (name +
  host, verified against the project's auth settings with the anon
  key), then password sign-in. **Sign-up is not offered on the phone**
  — the owner account was created on the web; the first account in was
  crowned owner by trigger (`20260930000000_first_signup_owner.sql`).

Clients notice drift with `schema_version()` (the newest applied
migration + deployed-function count); when it disagrees with what the
client shipped, the iPhone runs its launch sync.

## Agent access, by hand

The web flow does this for you; the manual route:

1. Generate a key: `openssl rand -hex 32`.
2. Supabase → SQL editor:
   `select vault.create_secret('<value>', 'claude_rq_key');`
3. In Claude Code's environment settings, set:

   ```
   SUPABASE_URL=https://<project-ref>.supabase.co
   SUPABASE_ANON_KEY=<the anon key>
   CLAUDE_RQ_KEY=<the same value as the Vault secret>
   ```

4. Verify from a Claude Code session:
   `scripts/rq "select current_user"` → `claude`.

Details and the security model: [`03-agent-access.md`](03-agent-access.md).

## The manual route, end to end

Everything the setup page does can be done by hand: create the Supabase
org and project in the dashboard; connect a fork with the GitHub
integration (Deploy to production on) or apply `supabase/migrations/`
yourself; note Project URL and publishable key; create the owner
account first; store the rq key as above; wire the routine with
`scripts/syla-set-webhook`. A fork is optional either way — the
provisioner reads the public starter when you have none.

## Rotating and revoking

- **Management credential**: revoke the Supabase OAuth grant (dashboard
  → your account's authorized apps); re-authorize from
  getsylos.com/devices and re-scan to re-arm a phone.
- **rq key**: create a new value and `vault.update_secret`; the old key
  stops working immediately. Deleting the secret fails the gate closed.
- **Webhook token**: regenerate the API trigger token in the Claude Code
  UI, re-run `scripts/syla-set-webhook`.
- **A follower's key**: block or delete their row — see
  [`05-followers.md`](05-followers.md).
- **Owner password**: Supabase → Authentication → Users.
