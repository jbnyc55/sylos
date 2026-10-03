// follower-file — a shared chat attachment, delivered by signed URL.
//
// A chat attachment travels to a peer as a reference: the message row
// they read over follower_rq carries upload_id, while the bytes stay
// in this owner's PRIVATE uploads bucket (20261211000000). This
// function is the delivery half: a peer posts their follower token and
// the upload id and gets back a short-lived signed URL to download the
// file — exactly when a chat message in a chat whose roster names them
// carries that upload, decided fresh on every call by
// follower_file_target() (which also answers the object's path, to
// service_role only; claude-file's arrangement with the follower token
// as the gate).
//
// Who calls it: a peer's client directly — their following row already
// holds this project's URL, anon key and their token — and a peer's
// Syla through her own project's following-relay, which fetches the
// signed URL and relays the bytes (her sessions can't reach this
// host). A wrong token, an unknown upload and one no shared message
// carries all refuse without saying which. The URL expires in minutes;
// the bucket itself stays private.
//
// POST { token, upload_id } → { url, mime, bytes, name, expires_in }

import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

/** How long the signed link lives — long enough for one download. */
const SIGNED_URL_SECONDS = 600

function json(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json(405, { error: 'POST only' })

  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return json(400, { error: 'a JSON body is required' })
  }
  const token = typeof body.token === 'string' ? body.token.trim() : ''
  const uploadId = typeof body.upload_id === 'string' ? body.upload_id.trim() : ''
  if (!token) return json(401, { error: 'token (your follower key) is required' })
  if (!uploadId) return json(400, { error: 'upload_id is required' })

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  // The gate and the lookup in one: a bad token, an unknown id and an
  // unshared file all raise, and no answer says which.
  const { data, error } = await admin.rpc('follower_file_target', {
    _token: token,
    _upload_id: uploadId,
  })
  if (error) return json(403, { error: error.message })
  const target = data as { path: string; mime: string; bytes: number; name: string | null } | null
  if (!target?.path) return json(404, { error: 'no shared message carries that file' })

  const { data: signed, error: signError } = await admin.storage
    .from('uploads')
    .createSignedUrl(target.path, SIGNED_URL_SECONDS)
  if (signError || !signed?.signedUrl) {
    return json(500, { error: signError?.message ?? 'could not sign the URL' })
  }

  return json(200, {
    url: signed.signedUrl,
    mime: target.mime,
    bytes: target.bytes,
    name: target.name,
    expires_in: SIGNED_URL_SECONDS,
  })
})
