// Google Calendar server side, as one edge function. Four of its routes are
// the convention every entry in the integrations registry follows — the
// app's Integrations page drives any integration through exactly these:
//
//   POST /gcal/status      → { connected, account?, last_synced_at? }
//   POST /gcal/connect     → PKCE code from the iOS app → tokens, stored
//   POST /gcal/sync        → mirror the caller's calendar into gcal_event
//   POST /gcal/disconnect  → revoke + delete the connection and its events
//
// Plus three of its own:
//
//   POST /gcal/sync-due    → cron: sync every connection gone stale
//   POST /gcal/auth-url    → the Google OAuth consent URL (web-client flow)
//   GET  /gcal/callback    → Google's redirect for the web-client flow
//
// This exists because the clients are keyless: per-user refresh tokens must
// never reach an app binary or a browser bundle, so every Google call
// happens here. Two OAuth flows land in the same gcal_connection row:
//
// • PKCE (the iOS app, the normal path): the app runs Google's consent in
//   ASWebAuthenticationSession against an iOS-type OAuth client — which has
//   NO secret, its client id is public and ships in the app — and hands the
//   authorization code here. Exchange and refresh take just that client id,
//   so this path needs no edge function secrets at all: one client
//   registered by the starter's author serves every install.
//
// • Web client (optional): auth-url/callback as before, for a deployment
//   with its own web OAuth client. Its secrets live in the Supabase
//   dashboard (Edge Functions → Secrets), never in this repo:
//     GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET / APP_URL
//
// Auth: verify_jwt is OFF for this function — Google's callback and the
// cron's sync-due arrive with no user JWT — so the per-user POST routes
// resolve the caller themselves through the Authorization header + RLS (no
// valid JWT, no profile, 401), the callback authenticates by the one-time
// state row, and sync-due needs no caller identity: it only refreshes
// mirrors already stale (see the cooldown), which the cron would do minutes
// later anyway. The service role — auto-injected, never in the client — is
// the only reader and writer of the token rows.

import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

/** How far the sync mirrors: a week back, two months ahead. */
const SYNC_PAST_DAYS = 7
const SYNC_FUTURE_DAYS = 62

/** sync-due refreshes only mirrors older than this — the same cooldown the
 * pg_cron dispatcher checks, making anonymous calls to it harmless. */
const SYNC_DUE_COOLDOWN_MINUTES = 8

const SCOPE = 'https://www.googleapis.com/auth/calendar.readonly'

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

function appUrl(): string {
  const url = Deno.env.get('APP_URL')
  if (!url) throw new Error('APP_URL secret is not set (Edge Functions → Secrets)')
  return url.replace(/\/$/, '')
}

function redirectUri(): string {
  return `${Deno.env.get('SUPABASE_URL')}/functions/v1/gcal/callback`
}

/**
 * Exchange at Google's token endpoint — the code grant and refreshes alike.
 * With `clientId` (a PKCE / iOS-type client) no secret is sent: installed-app
 * clients don't have one. Without it, the web client's env pair is used.
 */
async function tokenRequest(params: Record<string, string>, clientId?: string) {
  const auth = clientId
    ? { client_id: clientId }
    : {
        client_id: Deno.env.get('GOOGLE_CLIENT_ID') ?? '',
        client_secret: Deno.env.get('GOOGLE_CLIENT_SECRET') ?? '',
      }
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ ...auth, ...params }),
  })
  const body = await res.json()
  if (!res.ok) {
    throw new Error(body.error_description ?? body.error ?? `Google token request failed (${res.status})`)
  }
  return body as { access_token: string; expires_in: number; refresh_token?: string; id_token?: string }
}

/** The connected account's email, from the id_token payload — display
 * only, so a malformed token just leaves it blank. */
function emailFromIdToken(idToken?: string): string | null {
  try {
    const payload = idToken?.split('.')[1]
    if (!payload) return null
    return JSON.parse(atob(payload.replace(/-/g, '+').replace(/_/g, '/'))).email ?? null
  } catch {
    return null
  }
}

type Admin = ReturnType<typeof createClient>

type Connection = {
  profile_id: string
  refresh_token: string
  access_token: string | null
  token_expires_at: string | null
  google_client_id: string | null
  last_synced_at?: string | null
}

const CONNECTION_COLUMNS =
  'profile_id, refresh_token, access_token, token_expires_at, google_client_id, last_synced_at'

/**
 * Tell the database where this function's sync-due endpoint lives, so the
 * pg_cron dispatcher can post to it. Registered on every successful
 * connect — best effort, since a failed registration only costs background
 * sync, not the connection.
 */
async function registerSyncUrl(admin: Admin) {
  await admin
    .rpc('set_gcal_sync_url', { _url: `${Deno.env.get('SUPABASE_URL')}/functions/v1/gcal/sync-due` })
    .then(({ error }) => {
      if (error) console.error(`set_gcal_sync_url failed: ${error.message}`)
    })
}

/** A currently-valid access token for this profile, refreshing if stale. */
async function freshAccessToken(admin: Admin, conn: Connection): Promise<string> {
  if (
    conn.access_token &&
    conn.token_expires_at &&
    new Date(conn.token_expires_at).getTime() - Date.now() > 60_000
  ) {
    return conn.access_token
  }
  const t = await tokenRequest(
    { grant_type: 'refresh_token', refresh_token: conn.refresh_token },
    conn.google_client_id ?? undefined,
  )
  await admin
    .from('gcal_connection')
    .update({
      access_token: t.access_token,
      token_expires_at: new Date(Date.now() + t.expires_in * 1000).toISOString(),
    })
    .eq('profile_id', conn.profile_id)
  return t.access_token
}

/** Mirror one connection's primary calendar into gcal_event. */
async function syncConnection(admin: Admin, conn: Connection): Promise<number> {
  const accessToken = await freshAccessToken(admin, conn)

  const timeMin = new Date(Date.now() - SYNC_PAST_DAYS * 86_400_000)
  const timeMax = new Date(Date.now() + SYNC_FUTURE_DAYS * 86_400_000)

  // singleEvents expands recurring series into concrete occurrences —
  // exactly what a mirror wants; no rule math on our side.
  type GEvent = {
    id: string
    status: string
    summary?: string
    start?: { dateTime?: string; date?: string }
    end?: { dateTime?: string; date?: string }
  }
  const events: GEvent[] = []
  let pageToken: string | undefined
  do {
    const list = new URL('https://www.googleapis.com/calendar/v3/calendars/primary/events')
    list.searchParams.set('singleEvents', 'true')
    list.searchParams.set('orderBy', 'startTime')
    list.searchParams.set('timeMin', timeMin.toISOString())
    list.searchParams.set('timeMax', timeMax.toISOString())
    list.searchParams.set('maxResults', '250')
    if (pageToken) list.searchParams.set('pageToken', pageToken)
    const res = await fetch(list, { headers: { Authorization: `Bearer ${accessToken}` } })
    const body = await res.json()
    if (!res.ok) {
      throw new Error(body.error?.message ?? `Google Calendar list failed (${res.status})`)
    }
    events.push(...((body.items ?? []) as GEvent[]))
    pageToken = body.nextPageToken
  } while (pageToken)

  const rows = events
    .filter((e) => e.status !== 'cancelled' && e.start && e.end)
    .map((e) => ({
      profile_id: conn.profile_id,
      google_event_id: e.id,
      calendar_id: 'primary',
      summary: e.summary ?? null,
      starts_at: e.start!.dateTime ?? null,
      ends_at: e.end!.dateTime ?? null,
      start_day: e.start!.date ?? null,
      end_day: e.end!.date ?? null,
    }))
    .filter((r) => (r.starts_at && r.ends_at) || (r.start_day && r.end_day))

  // Replace the window wholesale: deletions and moves on Google's side
  // fall out for free, and the mirror never accretes stale rows.
  const { error: clearError } = await admin
    .from('gcal_event')
    .delete()
    .eq('profile_id', conn.profile_id)
  if (clearError) throw new Error(clearError.message)
  if (rows.length) {
    const { error: insertError } = await admin.from('gcal_event').insert(rows)
    if (insertError) throw new Error(insertError.message)
  }

  await admin
    .from('gcal_connection')
    .update({ last_synced_at: new Date().toISOString() })
    .eq('profile_id', conn.profile_id)

  return rows.length
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  const url = new URL(req.url)
  const route = url.pathname.split('/').filter(Boolean).pop()

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  try {
    // -----------------------------------------------------------------------
    // Google's redirect (web-client flow). No JWT here — the one-time state
    // row is the auth.
    // -----------------------------------------------------------------------
    if (req.method === 'GET' && route === 'callback') {
      const back = (suffix: string) =>
        new Response(null, { status: 302, headers: { Location: `${appUrl()}/?gcal=${suffix}` } })

      const state = url.searchParams.get('state') ?? ''
      const code = url.searchParams.get('code')
      const { data: stateRow } = await admin
        .from('gcal_oauth_state')
        .select('profile_id, created_at')
        .eq('state', state)
        .maybeSingle()
      if (stateRow) await admin.from('gcal_oauth_state').delete().eq('state', state)
      // Unknown, replayed, or stale (>15 min) state: not our flow.
      if (!stateRow || Date.now() - new Date(stateRow.created_at).getTime() > 15 * 60_000) {
        return back('error')
      }
      if (!code) return back('denied')

      const t = await tokenRequest({
        grant_type: 'authorization_code',
        code,
        redirect_uri: redirectUri(),
      })
      if (!t.refresh_token) return back('error')

      const { error } = await admin.from('gcal_connection').upsert(
        {
          profile_id: stateRow.profile_id,
          google_email: emailFromIdToken(t.id_token),
          refresh_token: t.refresh_token,
          access_token: t.access_token,
          token_expires_at: new Date(Date.now() + t.expires_in * 1000).toISOString(),
          google_client_id: null,
        },
        { onConflict: 'profile_id' },
      )
      if (error) return back('error')

      await registerSyncUrl(admin)
      return back('connected')
    }

    if (req.method !== 'POST') return json(405, { error: 'POST only' })

    // -----------------------------------------------------------------------
    // The cron's poke: sync every connection whose mirror has gone stale.
    // Unauthenticated by design — the cooldown makes it a no-op for anyone
    // the dispatcher wouldn't have served minutes later anyway.
    // -----------------------------------------------------------------------
    if (route === 'sync-due') {
      const cutoff = new Date(Date.now() - SYNC_DUE_COOLDOWN_MINUTES * 60_000).toISOString()
      const { data: conns, error } = await admin
        .from('gcal_connection')
        .select(CONNECTION_COLUMNS)
        .or(`last_synced_at.is.null,last_synced_at.lt.${cutoff}`)
      if (error) return json(500, { error: error.message })

      let synced = 0
      let failed = 0
      for (const conn of (conns ?? []) as Connection[]) {
        try {
          await syncConnection(admin, conn)
          synced++
        } catch (err) {
          // One broken grant (revoked, expired) must not starve the rest.
          console.error(`sync-due failed for ${conn.profile_id}: ${err}`)
          failed++
        }
      }
      return json(200, { synced, failed })
    }

    // Who is calling? The user's own JWT + RLS resolve the profile, so this
    // function cannot be talked into acting for someone else.
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

    // -----------------------------------------------------------------------
    // The registry convention's status: connected as whom, synced when.
    // -----------------------------------------------------------------------
    if (route === 'status') {
      const { data: conn, error } = await admin
        .from('gcal_connection')
        .select('google_email, last_synced_at')
        .eq('profile_id', profile.id)
        .maybeSingle()
      if (error) return json(500, { error: error.message })
      if (!conn) return json(200, { connected: false })
      return json(200, {
        connected: true,
        account: conn.google_email,
        last_synced_at: conn.last_synced_at,
      })
    }

    // -----------------------------------------------------------------------
    // PKCE connect: the iOS app ran Google's consent itself (iOS-type
    // client, no secret) and hands over the authorization code.
    // -----------------------------------------------------------------------
    if (route === 'connect') {
      const body = await req.json().catch(() => ({}))
      const { code, code_verifier, redirect_uri, client_id } = body as Record<string, string>
      if (!code || !code_verifier || !redirect_uri || !client_id) {
        return json(400, { error: 'code, code_verifier, redirect_uri and client_id are all required.' })
      }
      // Only Google-issued client ids, and only their own scheme redirect:
      // this route exchanges codes, it is not a general token proxy.
      if (!client_id.endsWith('.apps.googleusercontent.com')) {
        return json(400, { error: 'client_id must be a Google OAuth client id.' })
      }

      const t = await tokenRequest(
        { grant_type: 'authorization_code', code, code_verifier, redirect_uri },
        client_id,
      )
      if (!t.refresh_token) {
        return json(502, { error: 'Google returned no refresh token — try connecting again.' })
      }

      const { error } = await admin.from('gcal_connection').upsert(
        {
          profile_id: profile.id,
          google_email: emailFromIdToken(t.id_token),
          refresh_token: t.refresh_token,
          access_token: t.access_token,
          token_expires_at: new Date(Date.now() + t.expires_in * 1000).toISOString(),
          google_client_id: client_id,
        },
        { onConflict: 'profile_id' },
      )
      if (error) return json(500, { error: error.message })

      await registerSyncUrl(admin)
      return json(200, { connected: true })
    }

    if (route === 'auth-url') {
      if (!Deno.env.get('GOOGLE_CLIENT_ID') || !Deno.env.get('GOOGLE_CLIENT_SECRET')) {
        return json(500, {
          error: 'Google OAuth is not configured — set GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in Edge Function secrets.',
        })
      }
      const state = crypto.randomUUID()
      const { error } = await admin
        .from('gcal_oauth_state')
        .insert({ state, profile_id: profile.id })
      if (error) return json(500, { error: error.message })

      const consent = new URL('https://accounts.google.com/o/oauth2/v2/auth')
      consent.searchParams.set('client_id', Deno.env.get('GOOGLE_CLIENT_ID')!)
      consent.searchParams.set('redirect_uri', redirectUri())
      consent.searchParams.set('response_type', 'code')
      consent.searchParams.set('scope', `${SCOPE} email`)
      // offline + consent is what makes Google hand over a refresh token,
      // reconnects included.
      consent.searchParams.set('access_type', 'offline')
      consent.searchParams.set('prompt', 'consent')
      consent.searchParams.set('state', state)
      return json(200, { url: consent.toString() })
    }

    if (route === 'sync') {
      const { data: conn, error: connError } = await admin
        .from('gcal_connection')
        .select(CONNECTION_COLUMNS)
        .eq('profile_id', profile.id)
        .maybeSingle()
      if (connError) return json(500, { error: connError.message })
      if (!conn) return json(400, { error: 'No Google Calendar connected yet.' })

      // The app calls this on view loads with if_stale_minutes, so a mirror
      // the cron just refreshed doesn't hit Google again.
      const body = await req.json().catch(() => ({}))
      const staleMinutes = Number((body as Record<string, unknown>).if_stale_minutes)
      const last = (conn as Connection).last_synced_at
      if (staleMinutes > 0 && last && Date.now() - new Date(last).getTime() < staleMinutes * 60_000) {
        return json(200, { skipped: true })
      }

      const synced = await syncConnection(admin, conn as Connection)
      return json(200, { synced })
    }

    if (route === 'disconnect') {
      const { data: conn } = await admin
        .from('gcal_connection')
        .select('refresh_token')
        .eq('profile_id', profile.id)
        .maybeSingle()
      // Best-effort revoke at Google; the local delete is the disconnect.
      if (conn?.refresh_token) {
        await fetch('https://oauth2.googleapis.com/revoke', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: new URLSearchParams({ token: conn.refresh_token }),
        }).catch(() => {})
      }
      const { error: eventsError } = await admin
        .from('gcal_event')
        .delete()
        .eq('profile_id', profile.id)
      if (eventsError) return json(500, { error: eventsError.message })
      const { error } = await admin
        .from('gcal_connection')
        .delete()
        .eq('profile_id', profile.id)
      if (error) return json(500, { error: error.message })
      return json(200, { ok: true })
    }

    return json(404, { error: `Unknown route: ${route}` })
  } catch (err) {
    return json(500, { error: err instanceof Error ? err.message : String(err) })
  }
})
