# Running Syla on Daytona (the cloud fallback, or instead of a Claude Cloud routine)

**With the Mac app this is the fallback, not the default.** When the
owner runs the Mac worker (`sylos_mac`), the Mac heartbeats
`worker_presence` every tick and `syla-fire` stands down on any fire
that arrives while that heartbeat is fresh (90 s by default;
`WORKER_FRESH_SECONDS` overrides). Only a closed or absent Mac lets a
fire reach Daytona — so the setup below arms "cloud when my computer
is closed", and the Mac app's Settings → Cloud fallback does these
same steps for you. Every claim records where it ran
(`syla_job_runs.claimed_by`), so the apps can say "on your Mac" vs
"in the cloud". Turning the fallback off is `clear_syla_webhook()`
(runs then simply wait for the Mac); the rest of this page is
unchanged either way.

The dispatcher doesn't care what answers its webhook — it POSTs a
bearer-token fire and watches the `syla_job_runs` queue
(`notes/04-syla-jobs.md`). This directory plus the `syla-fire` edge
function make that webhook spawn a **Daytona sandbox running an
open-weights model** instead of an Anthropic routine session. Every
other part of the system — the queue, claims, receipts, re-fires, the
2-hour failsafe, the Postgres-enforced write boundary — is unchanged.

```
pg_cron / send_to_syla / Sort now …
        │  POST  Authorization: Bearer <token>
        ▼
https://<ref>.supabase.co/functions/v1/syla-fire      (this project)
        │  Daytona API: create sandbox + start worker, then 200
        ▼
Daytona sandbox ── daytona/run-syla.sh
        clone the starter → opencode run "Do the task"
        → syla-claim → the events' docs → syla-finish
```

## One-time setup

1. **Keys.** You need a Daytona API key (app.daytona.io → API Keys) and
   an OpenRouter API key (openrouter.ai → Settings → API Keys; set a
   spend limit on it). Mint the fire token yourself:

   ```bash
   openssl rand -hex 32 > /tmp/fire-token
   ```

2. **Edge function secrets** (dashboard → Edge Functions → Secrets, or
   `supabase secrets set` with the CLI linked to your project):

   | Secret | Value |
   | ------ | ----- |
   | `SYLA_FIRE_TOKEN` | the minted token |
   | `DAYTONA_API_KEY` | from app.daytona.io — stays in the function, never enters a sandbox |
   | `OPENROUTER_API_KEY` | from openrouter.ai |
   | `CLAUDE_RQ_KEY` | Syla's existing rq key (the same one in your agent env) |
   | `SYLA_MODEL` *(optional)* | opencode model id; default `openrouter/z-ai/glm-5.3` — check the exact id on openrouter.ai and override if it differs |
   | `DAYTONA_SNAPSHOT` *(optional)* | prebaked snapshot name (step 3) |

   The function deploys like every other one in `supabase/functions/`
   (the app's launch sync ships it automatically).

3. **Snapshot (optional but recommended).** Without one, each fire
   installs opencode from npm before working (roughly a minute). Bake
   it once with the Daytona CLI — check `daytona snapshot create --help`
   for your CLI version's exact flags:

   ```bash
   daytona snapshot create syla-worker:1 --dockerfile daytona/Dockerfile
   ```

   then set `DAYTONA_SNAPSHOT=syla-worker:1`.

4. **Point the webhook here.** The setter pins URLs; your project's own
   `syla-fire` function is an allowed target (the pin check compares
   against the host you're calling through, so run this with the same
   `SUPABASE_URL` the key belongs to):

   ```bash
   scripts/syla-set-webhook \
     --url "${SUPABASE_URL%/}/functions/v1/syla-fire" \
     --token-file /tmp/fire-token
   rm /tmp/fire-token
   ```

5. **Test.** Send Syla a message in the app (or `send_to_syla` from
   /setup's test step). The receipt ladder tells you where things
   stand: *Delivered* = this function answered 2xx; *Syla's reading* =
   the worker claimed the run. No claim after three fires → the run
   fails visibly in the app; look at the `syla-fire` function logs,
   then the sandbox's own logs on app.daytona.io.

## Costs, lifetime, model choice

- Sandboxes auto-stop after 60 idle minutes and auto-delete 30 minutes
  later (constants at the top of the function). The dispatcher already
  fails any run that stays claimed past 2 hours, so a hung model wastes
  at most about an hour of small-instance compute.
- Duplicate fires are harmless by design: an extra worker finds an
  empty queue (`syla-claim` returns `[]`) and exits.
- Switching models is `SYLA_MODEL` — any OpenRouter-hosted model
  opencode can drive (`openrouter/<provider>/<model>`). Open-weights
  models vary most on long tool-call loops; after switching, watch one
  real run end-to-end and confirm `syla-finish` landed.
- If you'd rather not have your data transit a model vendor's own API,
  use OpenRouter's provider routing to pin inference to hosts in your
  preferred jurisdiction — same model id, different server.

## Going back

Point the webhook back at an Anthropic routine fire URL with
`scripts/syla-set-webhook` — the setter still accepts those — and the
Cloud routine takes over on the next fire. Nothing else to undo.
