// Push delivery, as one edge function — the only place the APNs signing
// key exists. Routes:
//
//   POST /push/send-due  → drain push_queue: deliver every undelivered row
//                          to its profile's push_devices over APNs
//   POST /push/status    → { enabled, devices, configured } for the caller
//   POST /push/test      → queue a test notification for the caller and
//                          deliver immediately (end-to-end check from the
//                          app's Notifications page)
//
// Rows land in push_queue (Syla's queue_push, future triggers); a
// statement trigger pokes send-due the moment one is queued, and the
// every-minute push-send cron sweeps anything the poke raced past —
// the same Vault-pinned-URL arrangement as gcal's sync-due.
//
// Auth: verify_jwt is OFF because the trigger's and cron's pokes carry no
// user JWT. send-due needs no caller identity — it only delivers rows
// already queued, which the cron would do within the minute anyway — and
// status/test resolve the caller through the Authorization header + RLS
// like gcal's per-user routes.
//
// The signed hop: APNs keys are bound to the app's bundle id, so only the
// app's developer holds one — a fresh install has no key and cannot mint
// one. By default, delivery therefore hands the final signed send to the
// developer's push relay (supabase/functions/push-relay/, deployed only
// on the developer's project), which is what makes push work on every
// TestFlight install with zero setup. An owner who prefers fully
// self-sovereign delivery sets the APNS_* secrets on their OWN project
// (Edge Functions → Secrets) and this function then signs and sends
// directly, never touching the relay:
//   APNS_TEAM_ID      the Apple Developer team id
//   APNS_KEY_ID       the APNs auth key's id
//   APNS_PRIVATE_KEY  the .p8 file's contents (PEM, PKCS8)
//   APNS_TOPIC        optional; the app's bundle id, default com.sylos.Sylos
//   PUSH_RELAY_URL    optional; overrides the default relay
//
// Which APNs host a token gets is the device row's environment column:
// 'sandbox' for Xcode builds, 'production' for TestFlight/App Store.

import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

/** Give up on a queue row after this many failed delivery rounds. */
const MAX_ATTEMPTS = 5

const APNS_HOSTS = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
} as const

/** The developer's push relay — the default signed hop for installs that
 * hold no APNs key of their own (which is all of them, out of the box). */
function relayURL(): string {
  return (
    Deno.env.get('PUSH_RELAY_URL') ??
    'https://sxejvymsisfheqzmofcj.supabase.co/functions/v1/push-relay'
  )
}

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

function configured(): boolean {
  return Boolean(
    Deno.env.get('APNS_TEAM_ID') && Deno.env.get('APNS_KEY_ID') && Deno.env.get('APNS_PRIVATE_KEY'),
  )
}

// ---------------------------------------------------------------------------
// APNs provider token (ES256 JWT), cached — Apple asks for one per 20–60
// minutes, not one per delivery.
// ---------------------------------------------------------------------------

let cachedToken: { value: string; madeAt: number } | null = null

function base64URL(bytes: Uint8Array): string {
  let raw = ''
  for (const b of bytes) raw += String.fromCharCode(b)
  return btoa(raw).replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '')
}

async function apnsToken(): Promise<string> {
  if (cachedToken && Date.now() - cachedToken.madeAt < 40 * 60_000) return cachedToken.value

  const pem = Deno.env.get('APNS_PRIVATE_KEY') ?? ''
  const der = Uint8Array.from(
    atob(pem.replace(/-----[A-Z ]+-----/g, '').replace(/\s/g, '')),
    (c) => c.charCodeAt(0),
  )
  const key = await crypto.subtle.importKey(
    'pkcs8',
    der,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  )

  const header = base64URL(
    new TextEncoder().encode(JSON.stringify({ alg: 'ES256', kid: Deno.env.get('APNS_KEY_ID') })),
  )
  const payload = base64URL(
    new TextEncoder().encode(
      JSON.stringify({ iss: Deno.env.get('APNS_TEAM_ID'), iat: Math.floor(Date.now() / 1000) }),
    ),
  )
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    new TextEncoder().encode(`${header}.${payload}`),
  )
  const token = `${header}.${payload}.${base64URL(new Uint8Array(signature))}`
  cachedToken = { value: token, madeAt: Date.now() }
  return token
}

// ---------------------------------------------------------------------------
// Delivery
// ---------------------------------------------------------------------------

type Admin = ReturnType<typeof createClient>

type QueueRow = {
  id: string
  profile_id: string
  title: string
  body: string
  url: string | null
  attempts: number
}

type Device = { id: string; apns_token: string; environment: 'production' | 'sandbox' }

/** One APNs send — directly when this project holds its own APNs key,
 * through the developer's relay otherwise. Returns null on success, the
 * error string otherwise; 'gone' means the token is dead and its row
 * should be deleted. */
async function sendToDevice(device: Device, row: QueueRow): Promise<string | null> {
  if (!configured()) return await sendViaRelay(device, row)

  const payload: Record<string, unknown> = {
    aps: { alert: { title: row.title, body: row.body || undefined }, sound: 'default' },
  }
  if (row.url) payload.url = row.url

  const res = await fetch(`${APNS_HOSTS[device.environment]}/3/device/${device.apns_token}`, {
    method: 'POST',
    headers: {
      authorization: `bearer ${await apnsToken()}`,
      'apns-topic': Deno.env.get('APNS_TOPIC') ?? 'com.sylos.Sylos',
      'apns-push-type': 'alert',
      'apns-priority': '10',
    },
    body: JSON.stringify(payload),
  })
  if (res.ok) return null

  const body = await res.json().catch(() => ({}))
  const reason = (body as { reason?: string }).reason ?? `HTTP ${res.status}`
  // 410 Unregistered (and its 400 twin BadDeviceToken): the token is dead.
  if (res.status === 410 || reason === 'BadDeviceToken' || reason === 'Unregistered') {
    return 'gone'
  }
  return reason
}

/** The relay does the signing; this project never sees the key. */
async function sendViaRelay(device: Device, row: QueueRow): Promise<string | null> {
  const res = await fetch(`${relayURL()}/send`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      device_token: device.apns_token,
      environment: device.environment,
      title: row.title,
      body: row.body,
      url: row.url ?? undefined,
    }),
  })
  if (res.ok) return null

  const body = await res.json().catch(() => ({}))
  const reason =
    (body as { reason?: string }).reason ?? `relay HTTP ${res.status}`
  const status = (body as { status?: number }).status
  if (status === 410 || reason === 'BadDeviceToken' || reason === 'Unregistered') {
    return 'gone'
  }
  return reason
}

/** Deliver every undelivered queue row. One broken row or dead token must
 * not starve the rest. */
async function sendDue(admin: Admin): Promise<{ sent: number; failed: number }> {
  const { data: rows, error } = await admin
    .from('push_queue')
    .select('id, profile_id, title, body, url, attempts')
    .is('sent_at', null)
    .is('failed_at', null)
    .order('created_at', { ascending: true })
    .limit(100)
  if (error) throw new Error(error.message)

  let sent = 0
  let failed = 0
  for (const row of (rows ?? []) as QueueRow[]) {
    const outcome = await deliverRow(admin, row)
    if (outcome === 'sent') sent++
    if (outcome === 'failed') failed++
  }
  return { sent, failed }
}

async function deliverRow(admin: Admin, row: QueueRow): Promise<'sent' | 'failed' | 'pending'> {
  const fail = async (message: string, final: boolean) => {
    await admin
      .from('push_queue')
      .update({
        last_error: message,
        ...(final ? { failed_at: new Date().toISOString() } : {}),
      })
      .eq('id', row.id)
    return final ? ('failed' as const) : ('pending' as const)
  }

  // Claim the row by bumping attempts, optimistically: the queue trigger's
  // poke and the cron sweeper can run concurrently, and a row must go out
  // once. Losing the claim means another invocation has it.
  const { data: claimed } = await admin
    .from('push_queue')
    .update({ attempts: row.attempts + 1 })
    .eq('id', row.id)
    .eq('attempts', row.attempts)
    .is('sent_at', null)
    .is('failed_at', null)
    .select('id')
  if (!claimed?.length) return 'pending'

  const { data: devices, error } = await admin
    .from('push_devices')
    .select('id, apns_token, environment')
    .eq('profile_id', row.profile_id)
  if (error) return await fail(error.message, false)
  if (!devices?.length) {
    // Nowhere to go and nothing a retry would change.
    return await fail('no devices: notifications are not enabled in the app', true)
  }

  const { delivered, lastError } = await sendToDevices(admin, devices as Device[], row)

  if (delivered > 0) {
    await admin
      .from('push_queue')
      .update({ sent_at: new Date().toISOString() })
      .eq('id', row.id)
    return 'sent'
  }
  return await fail(lastError || 'delivery failed', row.attempts + 1 >= MAX_ATTEMPTS)
}

/** Fan one notification out to a profile's devices, pruning dead tokens. */
async function sendToDevices(admin: Admin, devices: Device[], row: QueueRow) {
  let delivered = 0
  let lastError = ''
  for (const device of devices) {
    try {
      const err = await sendToDevice(device, row)
      if (err === null) {
        delivered++
      } else if (err === 'gone') {
        await admin.from('push_devices').delete().eq('id', device.id)
        lastError = 'device token no longer registered'
      } else {
        lastError = err
      }
    } catch (err) {
      lastError = err instanceof Error ? err.message : String(err)
    }
  }
  return { delivered, lastError }
}

/** Tell the database where send-due lives, so the queue trigger and the
 * cron can poke it. Best effort, like gcal's. */
async function registerSendUrl(admin: Admin) {
  await admin
    .rpc('set_push_send_url', { _url: `${Deno.env.get('SUPABASE_URL')}/functions/v1/push/send-due` })
    .then(({ error }) => {
      if (error) console.error(`set_push_send_url failed: ${error.message}`)
    })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json(405, { error: 'POST only' })

  const route = new URL(req.url).pathname.split('/').filter(Boolean).pop()

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  try {
    if (route === 'send-due') {
      const result = await sendDue(admin)
      return json(200, result)
    }

    // Who is calling? The user's own JWT + RLS resolve the profile, so
    // this function cannot be talked into acting for someone else.
    const userClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } },
    )
    const { data: profile, error: profileError } = await userClient
      .from('profiles')
      .select('id')
      .single()
    if (profileError || !profile) return json(401, { error: 'Could not resolve your profile.' })

    if (route === 'status') {
      await registerSendUrl(admin)
      const { count, error } = await admin
        .from('push_devices')
        .select('id', { count: 'exact', head: true })
        .eq('profile_id', profile.id)
      if (error) return json(500, { error: error.message })
      return json(200, {
        enabled: (count ?? 0) > 0,
        devices: count ?? 0,
        configured: configured(),
        // 'own-key' when this project signs its own sends; 'relay' when
        // the developer's relay does (the zero-setup default).
        mode: configured() ? 'own-key' : 'relay',
      })
    }

    if (route === 'test') {
      await registerSendUrl(admin)
      // Straight to APNs, no queue row: the answer should say whether THIS
      // phone got THIS push, not whether a row was enqueued.
      const { data: devices, error } = await admin
        .from('push_devices')
        .select('id, apns_token, environment')
        .eq('profile_id', profile.id)
      if (error) return json(500, { error: error.message })
      if (!devices?.length) {
        return json(400, { error: 'No device registered — enable notifications first.' })
      }

      const { delivered, lastError } = await sendToDevices(admin, devices as Device[], {
        id: 'test',
        profile_id: profile.id,
        title: 'Sylos',
        body: 'Push notifications are working.',
        url: null,
        attempts: 0,
      })
      if (delivered === 0) return json(502, { error: lastError || 'delivery failed' })
      return json(200, { delivered })
    }

    return json(404, { error: `Unknown route: ${route}` })
  } catch (err) {
    return json(500, { error: err instanceof Error ? err.message : String(err) })
  }
})
