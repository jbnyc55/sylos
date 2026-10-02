# Provisioning — the client builds the database

Nobody walks the Supabase dashboard: the user creates a Supabase
**account** (that part stays — it's theirs, and the project lives under
it), consents once through OAuth, and the client does everything else
over the [Supabase Management
API](https://supabase.com/docs/guides/integrations/build-a-supabase-oauth-integration).
Two clients carry the power at different times (`notes/02-setup.md`):
the **web setup flow** at getsylos.com/setup provisions the project in
the browser tab, then hands the management credential to the phone by
QR and discards its copy; from then on the **iPhone is the standing
runner** — the refresh token lives in its Keychain, and it applies new
migrations and function deploys quietly on every launch. The machinery
is `SupabaseProvision.swift` in the app repo, the setup pages in
sylos-company `web/`, plus one edge function,
`supabase/functions/supabase-oauth/`.

## What the provisioner does after "Authorize"

1. **OAuth** — `api.supabase.com/v1/oauth/authorize` in an
   ASWebAuthenticationSession (PKCE). Supabase only registers HTTPS
   callback URLs, so the redirect lands on the relay's `GET /callback`,
   which immediately 302s the browser into `sylos://supabase-oauth` —
   the scheme the auth session completes on. The code→token exchange
   then goes through the relay (below); the resulting Management API
   tokens live only in the device Keychain.
2. **Organization** — first one on the account, or `POST
   /v1/organizations` when there is none (free tier).
3. **Project** — `POST /v1/projects` named `sylos` with a generated
   database password (kept in the Keychain; the dashboard can always
   reset it), then polls until the database is healthy. A project named
   `sylos` that already exists is reused, so a failed run retries clean.
   Auth is set to skip email confirmation on the owner sign-up.
4. **Schema** — the app is the migration runner: it lists
   `supabase/migrations/` on the owner's fork (falling back to the
   starter repo), applies each unapplied file in filename order through
   `POST /v1/projects/{ref}/database/query`, one transaction per file,
   and records it in `public.applied_migrations`.
5. **Edge functions** — the app is the function deployer too: each flat
   directory under `supabase/functions/` (skipping the developer-only
   relays `supabase-oauth` and `push-relay`, which never belong on a
   user project) goes up
   through `POST /v1/projects/{ref}/functions/deploy`, with `verify_jwt`
   read from `supabase/config.toml`. `public.deployed_functions` keeps
   each slug's source fingerprint, so unchanged functions cost nothing —
   and like migrations, this re-runs quietly on every launch, which is
   how a merged function change (gcal, push, one of Syla's) reaches
   projects already provisioned.
6. **Syla's key** — the same rq key the agent step shows is written to
   the vault (`claude_rq_key`) directly; the SQL-editor step disappears.
7. **App keys** — `GET /v1/projects/{ref}/api-keys` supplies the
   client (anon/publishable) key; the app configures itself.

The migration source is read anonymously from the GitHub API, so **the
fork (or the starter it falls back to) must be public** — a private fork
is invisible to the runner, and the provision step says so. Make the
fork public, or take the manual route (whose GitHub integration
authenticates on its own).

On every later launch the app runs the same migration catch-up quietly
(`SupabaseProvisioner.launchSync`): merge a migration to the fork's
`main` — a Syla integration, a starter update synced in — and it applies
next time the app opens. One-tap installs therefore don't use (or need)
the Supabase GitHub integration; git history is still the schema source
of truth, the runner just lives in the app. Manual-route installs keep
the GitHub integration exactly as before — the runner skips nothing it
didn't apply itself, and `applied_migrations` only tracks app-applied
files.

## The browser flows, and how each gets back

The web setup flow (getsylos.com/setup — where new installs are born)
and the web app (getsylos.com/app) are clients of the same OAuth app
and relay. A browser flow differs only in how it returns: it marks
itself in the OAuth `state` (`setup:<nonce>` from the setup flow,
`web:<nonce>` from the web app, `local:<nonce>` from a Vite dev
server) and the relay's `GET /callback` sends that browser to its
fixed return address — `https://getsylos.com/setup/oauth`
(`SETUP_CALLBACK_URL` overrides it), `https://getsylos.com/app/oauth`
(`WEB_CALLBACK_URL`), or `http://localhost:5173/app/oauth` — an
allow-list in the relay, never a URL taken from the request. The relay
also answers CORS preflights on its POST routes for the same reason.
The Management API calls themselves are made straight from the
browser, as on the phone; the tokens live only in that tab, and the
setup flow discards them after the QR handoff (re-summoning power
later, on /devices, by silent re-consent). The migration source is
read through GitHub's git-trees API (one call for the whole tree) plus
raw.githubusercontent.com. `applied_migrations` and
`deployed_functions` are the same ledgers everywhere — and
`schema_version()` serves them to any client — so a project set up on
the web keeps in step from the phone and back.

## The relay, and why it exists

OAuth token exchange requires the app's **client secret**, which cannot
ship inside an iOS binary. `supabase/functions/supabase-oauth/` is a
stateless relay that holds the secret as Edge Function secrets and does
exactly three things: exchange an authorization code (PKCE-bound,
single-use), refresh a token, and bounce the HTTPS OAuth callback back
into the app's custom scheme (`GET /callback`, no secrets involved). It
stores nothing and returns tokens only to the caller. It is **developer infrastructure**: deployed once on
the Sylos developer's own project, never on a user's — in user forks the
file is inert (no secrets → every call answers 500).

## Developer setup (once)

1. In your Supabase organization: Organization Settings → **OAuth Apps**
   → Add application. Authorization callback URL (HTTPS is required):
   `https://<your ref>.supabase.co/functions/v1/supabase-oauth/callback`.
   Scopes: Read-write on **Auth, Database, Edge Functions,
   Organizations, Projects, Secrets**; everything else No access. Note
   the client id and secret.
2. Deploy the relay to your own project and give it the credentials —
   either as Edge Function secrets:

   ```
   supabase functions deploy supabase-oauth --project-ref <your ref>
   supabase secrets set --project-ref <your ref> \
       SUPA_OAUTH_CLIENT_ID=<client id> SUPA_OAUTH_CLIENT_SECRET=<secret>
   ```

   or in the host project's Vault (`supa_oauth_client_id` /
   `supa_oauth_client_secret`) behind the service_role-only RPC
   `public.oauth_relay_creds()` the relay falls back to — handy when
   deploying through the Management API instead of the CLI.

3. In the app repo's `SupabaseProvision.swift`, set
   `ProvisionConfig.oauthClientId` to the client id and
   `ProvisionConfig.tokenRelayURL` to the deployed function's URL, and
   ship the build. With `oauthClientId` empty, the app hides nothing but
   offers only the manual route — so an unconfigured build degrades
   gracefully.

For Sylos itself, both relays (`supabase-oauth` and `push-relay`) live
on the company's main project — `sxejvymsisfheqzmofcj`, the one behind
getsylos.com, in the same organization that publishes the OAuth app —
so they sit inside the account chain the company already guards
(sylos-company `notes/01-accounts.md`). Redeploying them from this
checkout:

```
supabase functions deploy supabase-oauth --project-ref sxejvymsisfheqzmofcj --no-verify-jwt
supabase functions deploy push-relay     --project-ref sxejvymsisfheqzmofcj --no-verify-jwt
supabase secrets set --project-ref sxejvymsisfheqzmofcj \
    SUPA_OAUTH_CLIENT_ID=<client id> SUPA_OAUTH_CLIENT_SECRET=<secret> \
    APNS_TEAM_ID=<team> APNS_KEY_ID=<key id> APNS_PRIVATE_KEY="$(cat AuthKey.p8)"
```

The `push` function every install runs defaults its relay hop to that
host too (`PUSH_RELAY_URL` overrides it).

## Trust story

- The Management API token acts **as the user**, on their own account —
  the same authority they'd exercise clicking the dashboard. Its one
  transfer is the setup QR (burn-on-redeem, 10-minute expiry —
  `notes/02-setup.md`); its standing home is the iPhone's Keychain; it
  is never at rest in any database, and Syla never holds it: her
  access remains the `claude` role behind the rq key, exactly as
  [`03-agent-access.md`](03-agent-access.md) describes.
- The relay holds the OAuth client secret and nothing else; possession
  of the relay URL grants nothing without a fresh, PKCE-bound
  authorization code from a user actively consenting.
- The database password is generated on the device and kept in the
  Keychain. The app connects through PostgREST like always — the
  password exists only so a direct Postgres connection is possible some
  day, and the dashboard can rotate it any time.
- Everything the provisioner creates is visible in the user's own
  dashboard afterward; nothing is hidden, only automated.
