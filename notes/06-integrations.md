# Integrations

Outside services wired into the database, managed in the app under
profile → **Integrations**. The page has two halves:

- **Web integrations** — rows in `public.integrations`, not app code. The
  app renders whatever the registry holds, so a new one needs **no app
  update**: ask Syla, she builds it, it appears.
- **This phone** — integrations that need native code (location sharing,
  contacts, Apple Calendar & Reminders, Health, notifications), which
  ship with the app.

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

## The other phone mirrors (contacts, Apple Calendar & Reminders, Health)

Three more sources locked to the device — CNContactStore, EventKit and
HealthKit have no server APIs — so the app is the sync engine for each,
and they all generalize location's device-key model through one shared
table (`phone_devices`, migration `20261021000000`): enabling an
integration trades the session once for a key scoped to exactly that
mirror (`register_phone_device`), uploads authenticate with the key alone
(so background batches never touch the rotating session), and turning the
integration off or signing out retires it (`forget_phone_device`). Every
mirror is read-only — nothing ever writes back to the phone's frameworks —
and follows the user_locations visibility sentence: each person reads
their own rows, the owner reads everyone's, Syla reads everything.

- **Contacts** (`device_contacts`, scope `contacts`) — the whole address
  book (names, org, labeled phones/emails/addresses, birthdays; never
  notes or photos), wholesale-replaced by `record_contacts` when iOS
  posts a contacts-changed notification or the mirror has gone stale.
  What lets Syla resolve "dinner with Sam" and see birthdays coming.
- **Apple Calendar & Reminders** (`apple_event` + `apple_reminder`, one
  scope `eventkit`) — everything the phone's Calendar app fronts (iCloud,
  Exchange, CalDAV, subscribed) over the same −7/+62-day window as gcal,
  in `gcal_event`'s exact shape so the Today grid and Syla's plans treat
  both sources alike; plus Reminders (incomplete + recently completed).
  Wholesale-replaced on `EKEventStoreChanged` and stale foregrounds by
  `record_apple_events` / `record_apple_reminders`.
- **Health** (`health_samples`, scope `health`) — steps, heart rate,
  weight, sleep stages, workouts, energy, distance as append-only rows
  keyed by HealthKit's own sample UUID, so `record_health_samples` is
  idempotent. HealthKit background delivery wakes the app when new data
  lands; anchored queries make each upload the delta since the last.
  Rollups stay Syla's job — raw samples now, aggregation later.

## Notifications (`push`)

The one integration that is a delivery channel rather than a data source:
Syla (and later, database triggers) can reach the owner's pocket.

- **The phone registers itself**: enabling notifications in the app
  (profile → Integrations → Notifications) registers the APNs device
  token through `register_push_device` — a foreground write, so the JWT
  suffices and no device key is involved. Tokens are addresses, not
  credentials: delivering to one requires the APNs signing key, which
  only the push edge function's secrets hold.
- **`push_queue` is the outbox**: Syla appends through the rq-gated
  `queue_push` (`scripts/push-send`, skill doc `skills/push`); the row's
  `sent_at`/`failed_at` is the delivery receipt.
- **Delivery is `supabase/functions/push/`**: an insert trigger pokes its
  `/push/send-due` route the moment a row is queued (Vault-pinned URL,
  gcal's arrangement) and an every-minute pg_cron sweeper retries what
  the poke raced past. Dead tokens (APNs 410) delete their device row;
  a row with no devices fails fast with "notifications are not enabled".
- **Setup is three secrets**, set once by the owner in the dashboard
  (Edge Functions → Secrets): `APNS_TEAM_ID`, `APNS_KEY_ID`,
  `APNS_PRIVATE_KEY` (the `.p8` contents; `APNS_TOPIC` optional, default
  `com.sylos.Sylos`). They come from an APNs Auth Key created in the
  app author's Apple Developer account (Certificates → Keys) — APNs
  keys are bound to the app's bundle id, so owners cannot mint their
  own. Until they're set, queued rows simply wait — nothing fails
  permanently.
- **A deliberate trade**: the signing key sits in each install's own
  project, next to the queue it signs for, so notification content
  never transits anyone else's infrastructure — the self-sovereign
  reading, chosen over a central relay on the author's project. The
  cost is that every project owner holding the secrets holds the app's
  APNs key (project owners can read their own Edge Function secrets),
  so the key is treated as semi-public: its worst abuse is sending
  pushes dressed as the app to tokens the abuser can obtain (each
  owner's tokens live behind their own RLS), and the remedy is
  revoking and rotating the key in the Apple Developer account.

The app-side permission strings for all of these live in the app repo's
`Info.plist`; push and HealthKit also need their entitlements
(`aps-environment`, `com.apple.developer.healthkit`) in the app target.
