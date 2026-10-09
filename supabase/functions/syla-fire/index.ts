// syla-fire — the self-hosted fire receiver: a Daytona worker per wake.
//
// The dispatcher's webhook normally points at an Anthropic routine fire
// endpoint. This function is the drop-in alternative for owners who run
// Syla on their own Daytona account instead: point syla_webhook_url at
//     https://<project-ref>.supabase.co/functions/v1/syla-fire
// (scripts/syla-set-webhook accepts the project's own syla-fire URL) and
// every fire — dispatcher tick, send to Syla, Sort now, a chat poke —
// lands here instead. The contract is identical: the POST carries the
// Vault bearer token, the body's text is advisory, and a 2xx means only
// "the request was taken" (the Delivered rung); the syla_job_runs queue
// stays the source of truth, claims make duplicate workers no-ops, and
// unclaimed runs re-fire from the dispatcher exactly as before.
//
// On each accepted fire this creates one Daytona sandbox and starts the
// worker (daytona/run-syla.sh in this repo): clone the starter, run an
// open-weights coding agent on the standard "Do the task" loop. The
// response is sent before provisioning (EdgeRuntime.waitUntil), because
// pg_net gives the fire 15 seconds and a cold sandbox can take longer;
// provisioning failures go to the function logs and surface in the app
// as the dispatcher's own "fired three times, never claimed" failure.
//
// Secrets (Edge Function secrets, set once by the owner — see
// daytona/README.md; none of these ever land in a row or a repo):
//   SYLA_FIRE_TOKEN     what the Authorization bearer must equal — the
//                       same value stored in Vault by syla-set-webhook
//   DAYTONA_API_KEY     creates sandboxes; stays here, NEVER in a sandbox
//   OPENROUTER_API_KEY  the model provider key, passed into the sandbox
//   CLAUDE_RQ_KEY       Syla's own database credential, passed in
// Optional:
//   SYLA_MODEL          opencode model id (default below)
//   DAYTONA_SNAPSHOT    override the prebaked snapshot by name; unset,
//                       the function manages its own (AUTO_SNAPSHOT
//                       below): looks it up, builds it once when the
//                       account lacks it, boots from it when active
//   SYLA_REPO_URL       the starter clone URL (default: the public starter)
// SUPABASE_URL and SUPABASE_ANON_KEY are injected by the platform.

import { Daytona } from 'npm:@daytonaio/sdk'

const DEFAULT_MODEL = 'openrouter/z-ai/glm-5.3'
const DEFAULT_REPO = 'https://github.com/jbnyc55/sylos'

// The prebaked worker snapshot, managed by this function itself: each
// provision looks it up by name on the owner's Daytona account, kicks
// off the one-time build when it is missing, and boots sandboxes from
// it once it is active. Fires that arrive before then use the stock
// image — slower, never blocked. The recipe mirrors daytona/Dockerfile
// (the manual-build path); bump the name suffix whenever it changes so
// existing accounts rebuild.
const AUTO_SNAPSHOT = 'syla-worker:1'
const SNAPSHOT_DOCKERFILE = `FROM node:22-slim
RUN apt-get update \\
    && apt-get install -y --no-install-recommends \\
       git curl ca-certificates jq \\
    && rm -rf /var/lib/apt/lists/*
RUN npm install -g opencode-ai@latest
`
const SNAPSHOT_RESOURCES = { cpu: 2, memory: 4, disk: 10 }
const DAYTONA_API = 'https://app.daytona.io/api'

// Minutes of Daytona-visible inactivity before the sandbox auto-stops.
// The worker makes no Daytona API calls while running, so this is in
// practice a hard cap on a worker's lifetime — keep it at or below the
// dispatcher's own 2-hour claimed-but-never-finished failsafe.
const AUTO_STOP_MINUTES = 60
// Minutes after stopping before Daytona deletes the sandbox.
const AUTO_DELETE_MINUTES = 30

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  })
}

/** Constant-time equality via digest comparison — the bearer check. */
async function tokenMatches(presented: string, expected: string) {
  const enc = new TextEncoder()
  const [a, b] = await Promise.all([
    crypto.subtle.digest('SHA-256', enc.encode(presented)),
    crypto.subtle.digest('SHA-256', enc.encode(expected)),
  ])
  const xa = new Uint8Array(a)
  const xb = new Uint8Array(b)
  let diff = 0
  for (let i = 0; i < xa.length; i++) diff |= xa[i] ^ xb[i]
  return diff === 0
}

/** The snapshot to boot this fire's sandbox from: DAYTONA_SNAPSHOT
 * when the owner set one, else the auto-managed AUTO_SNAPSHOT — by
 * name over the raw Daytona API (the SDK's snapshot service would do,
 * but plain fetch keeps the failure modes visible). Null means "stock
 * image this fire": the build is still running, was just kicked off,
 * or cannot happen (a sandbox-only API key gets 403 on create — then
 * either widen the key's permissions or build manually per
 * daytona/README.md and set DAYTONA_SNAPSHOT). Every branch logs. */
async function ensureSnapshot(apiKey: string): Promise<string | null> {
  const explicit = Deno.env.get('DAYTONA_SNAPSHOT')
  if (explicit) return explicit

  const headers = {
    Authorization: `Bearer ${apiKey}`,
    'Content-Type': 'application/json',
  }
  try {
    const lookup = await fetch(
      `${DAYTONA_API}/snapshots/${encodeURIComponent(AUTO_SNAPSHOT)}`,
      { headers },
    )
    if (lookup.ok) {
      const snap = await lookup.json()
      const state = String(snap?.state ?? '')
      if (state === 'active') return AUTO_SNAPSHOT
      if (state === 'error' || state === 'build_failed') {
        console.error(
          `syla-fire: snapshot ${AUTO_SNAPSHOT} failed to build (${snap?.errorReason ?? 'no reason recorded'}) — stock image; delete the snapshot on app.daytona.io to retry`,
        )
        return null
      }
      console.log(
        `syla-fire: snapshot ${AUTO_SNAPSHOT} is ${state || 'building'} — stock image this fire`,
      )
      return null
    }

    // Not there yet — kick off the one-time build. Daytona builds it
    // server-side, so this fire doesn't wait; the next one checks in.
    const create = await fetch(`${DAYTONA_API}/snapshots`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        name: AUTO_SNAPSHOT,
        buildInfo: { dockerfileContent: SNAPSHOT_DOCKERFILE },
        ...SNAPSHOT_RESOURCES,
      }),
    })
    if (create.ok) {
      console.log(
        `syla-fire: building snapshot ${AUTO_SNAPSHOT} (one-time) — fires boot from it once it is active`,
      )
    } else {
      console.error(
        `syla-fire: could not start the ${AUTO_SNAPSHOT} build (HTTP ${create.status}: ${(await create.text()).slice(0, 200)}) — stock image; the Daytona key may lack snapshot permissions`,
      )
    }
  } catch (e) {
    console.error(
      'syla-fire: snapshot check failed —',
      (e as Error)?.message ?? e,
    )
  }
  return null
}

async function provision() {
  const env = (name: string) => Deno.env.get(name) ?? ''
  const repo = env('SYLA_REPO_URL') || DEFAULT_REPO

  // Every accepted fire provisions: there is no local worker to defer
  // to anymore (the Mac heartbeat era — 20270111000000 retired it).
  // Races stay harmless — claims are atomic and a duplicate worker
  // finds an empty queue.
  const snapshot = await ensureSnapshot(env('DAYTONA_API_KEY'))
  const daytona = new Daytona({ apiKey: env('DAYTONA_API_KEY') })
  const sandbox = await daytona.create({
    ...(snapshot ? { snapshot } : {}),
    envVars: {
      SUPABASE_URL: env('SUPABASE_URL'),
      SUPABASE_ANON_KEY: env('SUPABASE_ANON_KEY'),
      CLAUDE_RQ_KEY: env('CLAUDE_RQ_KEY'),
      OPENROUTER_API_KEY: env('OPENROUTER_API_KEY'),
      SYLA_MODEL: env('SYLA_MODEL') || DEFAULT_MODEL,
      SYLA_REPO_URL: repo,
    },
    labels: { 'sylos.role': 'syla-worker' },
    autoStopInterval: AUTO_STOP_MINUTES,
    autoDeleteInterval: AUTO_DELETE_MINUTES,
  })

  // Fire-and-forget: the run outlives this function by design. The repo
  // is public, so the clone needs no credential.
  const sessionId = 'syla-run'
  await sandbox.process.createSession(sessionId)
  await sandbox.process.executeSessionCommand(sessionId, {
    command:
      `bash -lc 'set -e; rm -rf /tmp/syla; ` +
      `git clone --depth 1 "$SYLA_REPO_URL" /tmp/syla; ` +
      `bash /tmp/syla/daytona/run-syla.sh'`,
    runAsync: true,
  })
  console.log(`syla-fire: worker started in sandbox ${sandbox.id}`)
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json(405, { error: 'POST only' })

  const expected = Deno.env.get('SYLA_FIRE_TOKEN') ?? ''
  if (!expected) return json(500, { error: 'SYLA_FIRE_TOKEN is not configured' })

  const bearer = (req.headers.get('authorization') ?? '').replace(/^Bearer\s+/i, '')
  if (!bearer || !(await tokenMatches(bearer, expected))) {
    return json(401, { error: 'unauthorized' })
  }

  const missing = ['DAYTONA_API_KEY', 'OPENROUTER_API_KEY', 'CLAUDE_RQ_KEY']
    .filter((name) => !Deno.env.get(name))
  if (missing.length > 0) {
    return json(500, { error: `missing secrets: ${missing.join(', ')}` })
  }

  // Answer inside pg_net's 15s window; provision after the response.
  const work = provision().catch((e) => {
    console.error('syla-fire: provisioning failed —', e?.message ?? e)
  })
  // deno-lint-ignore no-explicit-any
  const runtime = (globalThis as any).EdgeRuntime
  if (runtime?.waitUntil) runtime.waitUntil(work)
  else await work

  return json(200, { ok: true })
})
