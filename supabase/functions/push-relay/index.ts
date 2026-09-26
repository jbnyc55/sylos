// The push relay — DEVELOPER infrastructure, like supabase-oauth: deployed
// only on the Sylos developer's own project, never on a user's (the app's
// function deployer skips it by name). One route:
//
//   POST /push-relay/send  → { device_token, environment, title, body?, url? }
//                          → signs with the APNs key and delivers
//
// Why it exists: APNs signing keys are bound to the app's bundle id, so
// only the developer can hold one — and it must never ship in the app
// binary or land in a user's project secrets, where the project owner
// could read it. Each install's own push function drains its own
// push_queue and, holding no key of its own, hands the final signed hop
// to this relay. An owner who prefers fully self-sovereign delivery sets
// APNS_* secrets on their own project instead, and their push function
// then never calls here.
//
// Trust model: the route is unauthenticated — installs share no secret
// that could gate it — so what bounds abuse is what the relay can do at
// all: send a notification dressed as this app (the topic is pinned) to a
// device token the caller already has. Tokens live behind each owner's
// RLS; the relay keeps no state and logs nothing about content.
//
// Secrets (Edge Functions → Secrets, on the developer's project only):
//   APNS_TEAM_ID, APNS_KEY_ID, APNS_PRIVATE_KEY (.p8 contents),
//   APNS_TOPIC optional (default com.sylos.Sylos).

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

const APNS_HOSTS = {
  production: 'https://api.push.apple.com',
  sandbox: 'https://api.sandbox.push.apple.com',
} as const

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json(405, { error: 'POST only' })

  const route = new URL(req.url).pathname.split('/').filter(Boolean).pop()
  if (route !== 'send') return json(404, { error: `Unknown route: ${route}` })

  if (!Deno.env.get('APNS_TEAM_ID') || !Deno.env.get('APNS_KEY_ID') || !Deno.env.get('APNS_PRIVATE_KEY')) {
    return json(500, { reason: 'relay not configured (APNS_* secrets missing)' })
  }

  try {
    const body = await req.json().catch(() => ({}))
    const { device_token, environment, title, body: text, url } = body as Record<string, string>
    if (!device_token || !/^[0-9a-f]+$/.test(device_token) || device_token.length > 400) {
      return json(400, { reason: 'malformed device_token' })
    }
    const host = APNS_HOSTS[environment === 'sandbox' ? 'sandbox' : 'production']
    if (!title || title.length > 200 || (text ?? '').length > 2000) {
      return json(400, { reason: 'title required; title/body length limits exceeded' })
    }

    const payload: Record<string, unknown> = {
      aps: { alert: { title, body: text || undefined }, sound: 'default' },
    }
    if (url && url.length <= 500) payload.url = url

    const res = await fetch(`${host}/3/device/${device_token}`, {
      method: 'POST',
      headers: {
        authorization: `bearer ${await apnsToken()}`,
        // Pinned: this relay only ever sends as this app.
        'apns-topic': Deno.env.get('APNS_TOPIC') ?? 'com.sylos.Sylos',
        'apns-push-type': 'alert',
        'apns-priority': '10',
      },
      body: JSON.stringify(payload),
    })
    if (res.ok) return json(200, { delivered: true })

    const apns = await res.json().catch(() => ({}))
    return json(502, {
      reason: (apns as { reason?: string }).reason ?? `HTTP ${res.status}`,
      status: res.status,
    })
  } catch (err) {
    return json(500, { reason: err instanceof Error ? err.message : String(err) })
  }
})
