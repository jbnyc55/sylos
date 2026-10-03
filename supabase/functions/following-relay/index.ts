// following-relay — Syla's way to a friend's database, through her own.
//
// A follow is a friend's Sylos database where this owner holds a
// follower token (the following table — skills/following). Syla's
// sessions run in a Claude Code environment that reaches only the hosts
// its owner allowed, and a friend's project is never one of them; nor
// should the owner have to allow a host for every friend. So she never
// talks to a friend's project herself: she posts here — her own project,
// already allowed — naming the follow and the call, and this
// function looks the credentials up and makes the call for her.
//
// Auth is the same gate every agent write path has: the x-claude-rq-key
// header, checked against the vault by following_relay_target() (which
// also answers the credentials, to service_role only). The token never
// reaches the session. The target is always a stored follow's own
// project_url — this is not an open proxy.
//
// POST { name, kind, q? | prompt? | proposal? | chat_key? | upload_id? }
//   kind "rq"      → their follower_rq(_token, q)            read-only SQL
//   kind "prompt"  → their follower_submit_prompt(_token, _prompt)
//   kind "edit"    → their follower_submit_edit(_token, _proposal)
//   kind "poke"    → their follower_poke_chat(_token, _chat_key)
//   kind "file"    → their follower-file edge function, then the file
// The friend's answer comes back as it is, status included — except
// "file": there the friend answers a signed URL into THEIR storage
// host, which Syla's sessions can no more reach than the project
// itself, so this relay downloads it and answers the BYTES (mime as
// Content-Type, size and display name in X-Upload-* headers).

import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-claude-rq-key',
}

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

const CALLS: Record<string, { rpc: string; field: string; arg: string }> = {
  rq: { rpc: 'follower_rq', field: 'q', arg: 'q' },
  prompt: { rpc: 'follower_submit_prompt', field: 'prompt', arg: '_prompt' },
  edit: { rpc: 'follower_submit_edit', field: 'proposal', arg: '_proposal' },
  poke: { rpc: 'follower_poke_chat', field: 'chat_key', arg: '_chat_key' },
  file: { rpc: '', field: 'upload_id', arg: '' }, // its own path below
}

/** kind "file": ask the friend's follower-file for a signed URL, then
 *  download it and relay the bytes — the one kind whose answer Syla
 *  couldn't open herself (a URL into the friend's host). */
async function relayFile(
  target: { project_url: string; anon_key: string; follower_token: string },
  name: string,
  uploadId: string,
): Promise<Response> {
  let upstream: Response
  try {
    upstream = await fetch(`${target.project_url.replace(/\/$/, '')}/functions/v1/follower-file`, {
      method: 'POST',
      headers: {
        apikey: target.anon_key,
        Authorization: `Bearer ${target.anon_key}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ token: target.follower_token, upload_id: uploadId }),
    })
  } catch (e) {
    return json(502, { error: `couldn't reach ${name}'s database: ${(e as Error).message}` })
  }
  if (!upstream.ok) {
    // Their refusal (or a database that predates follower-file), as it is.
    const text = await upstream.text()
    return new Response(text, {
      status: upstream.status,
      headers: { ...corsHeaders, 'Content-Type': upstream.headers.get('content-type') ?? 'application/json' },
    })
  }

  let signed: { url?: string; mime?: string; bytes?: number; name?: string | null }
  try {
    signed = await upstream.json()
  } catch {
    return json(502, { error: `${name}'s follower-file answered something that isn't JSON` })
  }
  if (!signed.url) return json(502, { error: `${name}'s follower-file answered no URL` })

  let file: Response
  try {
    file = await fetch(signed.url)
  } catch (e) {
    return json(502, { error: `couldn't download the file from ${name}'s storage: ${(e as Error).message}` })
  }
  if (!file.ok) {
    return json(502, { error: `${name}'s storage refused the signed URL (HTTP ${file.status})` })
  }

  const headers: Record<string, string> = {
    ...corsHeaders,
    'Content-Type': signed.mime ?? file.headers.get('content-type') ?? 'application/octet-stream',
  }
  if (typeof signed.bytes === 'number') headers['X-Upload-Bytes'] = String(signed.bytes)
  if (signed.name) headers['X-Upload-Name'] = encodeURIComponent(signed.name)
  return new Response(file.body, { status: 200, headers })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json(405, { error: 'POST only' })

  const key = req.headers.get('x-claude-rq-key') ?? ''
  if (!key) return json(401, { error: 'x-claude-rq-key header required' })

  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return json(400, { error: 'a JSON body is required' })
  }
  const name = typeof body.name === 'string' ? body.name.trim() : ''
  const kind = typeof body.kind === 'string' ? body.kind : ''
  const call = CALLS[kind]
  if (!name) return json(400, { error: 'name (the follow) is required' })
  if (!call) return json(400, { error: 'kind must be rq, prompt, edit, poke or file' })
  const value = body[call.field]
  if (typeof value !== 'string' || !value.trim()) {
    return json(400, { error: `${call.field} is required for kind ${kind}` })
  }

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  // The gate and the lookup in one: a wrong key or an unknown name both
  // raise, and neither answer says which.
  const { data, error } = await admin.rpc('following_relay_target', { _key: key, _name: name })
  if (error) return json(403, { error: error.message })
  const target = data as { project_url: string; anon_key: string; follower_token: string } | null
  if (!target?.project_url || !target.anon_key || !target.follower_token) {
    return json(404, { error: `no follow named ${name}` })
  }

  if (kind === 'file') return relayFile(target, name, (value as string).trim())

  const payload: Record<string, string> = { _token: target.follower_token }
  payload[call.arg] = kind === 'rq' ? value.replace(/[\s;]+$/, '') : value

  let upstream: Response
  try {
    upstream = await fetch(`${target.project_url.replace(/\/$/, '')}/rest/v1/rpc/${call.rpc}`, {
      method: 'POST',
      headers: { apikey: target.anon_key, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    })
  } catch (e) {
    return json(502, { error: `couldn't reach ${name}'s database: ${(e as Error).message}` })
  }

  // Their answer, as it is — rows, a refusal, a queued request's id.
  const text = await upstream.text()
  return new Response(text, {
    status: upstream.status,
    headers: { ...corsHeaders, 'Content-Type': upstream.headers.get('content-type') ?? 'application/json' },
  })
})
