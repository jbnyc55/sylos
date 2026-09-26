# Integrations

Outside services wired into the database, managed in the app under
profile → **Integrations**. The page has two halves:

- **Web integrations** — rows in `public.integrations`, not app code. The
  app renders whatever the registry holds, so a new one needs **no app
  update**: ask Syla, she builds it, it appears.
- **This phone** — integrations that need native code (location sharing),
  which ship with the app.

## The pattern

Every web integration has the same shape, and it is the shape each new
one must take:

- **The edge function is the only server side.** Per-user OAuth grants
  and API tokens must never reach the app binary (it ships to phones) or
  any client, so every call to the outside service happens in
  `supabase/functions/<slug>/`, where the service role holds the tokens.
- **External data is mirrored into ordinary tables.** The app and Syla
  never talk to the provider — they read RLS-protected rows
  (`gcal_event`, …). From inside the system every integration is rows.
- **Tokens are service-role-only rows.** The connection table has no
  client read path and the `claude` role is revoked outright
  (`gcal_connection` is the model to copy).

### The registry contract

One row in `public.integrations` per integration: `slug`, `title`,
`blurb`, `kind`, `config` (jsonb), `sort`. The app drives the edge
function named by `slug` through four conventional routes, all POST,
authenticated by the user's JWT:

| Route | Returns |
| ----- | ------- |
| `/<slug>/status` | `{connected, account?, last_synced_at?}` |
| `/<slug>/connect` | stores the grant (see kinds below) |
| `/<slug>/sync` | refreshes the mirror; honors `{if_stale_minutes}` in the body by answering `{skipped: true}` when fresh |
| `/<slug>/disconnect` | revokes + deletes the grant and its mirrored rows |

Kinds the app knows:

- **`oauth_pkce`** — the app runs the provider's consent page in
  `ASWebAuthenticationSession` with a PKCE challenge and posts
  `{code, code_verifier, redirect_uri, client_id}` to `/connect`, which
  exchanges the code (public client — no secret anywhere) and stores the
  tokens. `config` must carry `auth_url`, `client_id`, `scope`,
  `callback_scheme`, `redirect_uri`, and optionally `extra_params` (fixed
  query params for the consent URL). No Info.plist registration is
  involved — the session owns the custom-scheme callback — which is
  exactly why a database row can define a whole new consent flow.

A row whose `kind` the app doesn't recognize still lists, with connect
disabled, so new kinds can ship data-first.

### Adding one (Syla's checklist)

1. **Edge function** `supabase/functions/<slug>/index.ts` implementing
   the four routes (copy `gcal`'s structure: JWT → profile via RLS,
   service role for the token rows). Add its `[functions.<slug>]` entry
   to `supabase/config.toml`.
2. **Migration**: the connection + mirror tables (RLS on everything,
   tokens service-role-only, mirror readable by owner and `claude`), and
   a pg_cron dispatcher if it should stay synced in the background
   (copy `gcal_sync_dispatch` and its Vault-pinned URL setter).
3. **Register it**: `scripts/integration-save --slug <slug> --title …
   --config-file <config.json>` (the `save_integration` RPC, rq-key
   gated, trigger-logged in `row_edits` like every write).
4. Function code and migrations reach production by merge to `main` —
   so Syla's part lands as a branch/PR for the owner to merge; the
   registry row she can save directly, and the app shows it once the
   function is live.

## Google Calendar (`gcal`)

### One OAuth client for every install

Owners do not create their own Google Cloud app. The starter's registry
row carries one **iOS-type OAuth client** (registered by the starter's
author), and iOS-type clients have **no client secret** — the flow is
PKCE, and the client id is public by design, like any Google-integrated
iOS app's. The id lives in the `gcal` row's config (seeded by migration,
editable with `scripts/integration-save`).

The scope is `calendar.readonly` — events flow in, nothing is ever
written back to Google.

For the author (or a fork that wants its own client), the Google Cloud
side is: create a project → enable the **Google Calendar API** →
configure the OAuth consent screen with the `calendar.readonly` scope →
create an **iOS** OAuth client with the app's bundle id → put its client
id (and reversed-id callback scheme) in the `gcal` registry row. Two
consent-screen states matter:

- **Testing**: capped at 100 test users, and **refresh tokens expire
  after 7 days** — connections silently die weekly. Fine for trying it
  out only.
- **In production**: tokens persist. `calendar.readonly` is a
  "sensitive" scope, so Google shows an unverified-app warning until the
  app passes its (free, one-time) verification review — publish and
  verify before sharing the app beyond yourself.

There is also a web-client flow (`auth-url`/`callback`) kept for
deployments that prefer their own web OAuth client; it needs
`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` and `APP_URL` in Edge
Function secrets, and its refreshes use that secret pair.

### Staying synced

The mirror (`gcal_event`, −7/+62 days of the primary calendar, replaced
wholesale each sync so deletions fall out for free) is refreshed from
three directions:

- **pg_cron, every 10 minutes** (`gcal-sync` job →
  `gcal_sync_dispatch()`): posts to the function's `POST /gcal/sync-due`,
  which refreshes every connection not synced in the last 8 minutes. The
  database cannot know its own project's functions URL, so the function
  registers it (Vault secret `gcal_sync_url`, via the service-role-only
  `set_gcal_sync_url`, pinned to a `/gcal/sync-due` path) whenever a
  calendar connects — no manual setup. `sync-due` is unauthenticated but
  cooldown-guarded: the worst an outsider can trigger is work the cron
  would do minutes later anyway, against mirrors they cannot read.
- **Opening Today**: the app calls `/gcal/sync` with `if_stale_minutes`,
  so the grid is fresh at the moment someone looks — and a no-op when
  the cron just ran.
- **Sync now** on the integration's page.

This also keeps `gcal_event` fresh for Syla's jobs — her plans see the
calendar without the app being open.

## Location (this phone)

Where each phone has been, streamed into `user_locations` — the schema,
the device-key model and the RPCs are documented in migration
`20261010000000_user_locations.sql`. The app side:

- **Start sharing** (Integrations → Location) asks for While Using then
  the Always upgrade, trades the session once for a device key
  (`register_location_device`), and starts `LocationTracker`. The key —
  Keychain-held, able only to append this profile's points — is what
  background batches upload with, so uploads never touch the session and
  its rotating refresh tokens.
- Fixes queue on disk and upload in batches (`record_locations`,
  idempotent), so offline stretches catch up later. With Always granted,
  significant-change monitoring keeps the trail alive after the app is
  killed.
- **Stop sharing** and sign-out retire the key (`forget_location_device`)
  and drop unsent fixes. Points already uploaded stay — deleting them is
  a normal RLS-scoped delete the owner can do any time.

The location permission strings and the `location` background mode live
in the app repo's `Info.plist`.
