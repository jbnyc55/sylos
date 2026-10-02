// claude-file — Syla's eyes on a stored file.
//
// Media drops land as objects in the PRIVATE uploads bucket with an
// uploads metadata row; Syla's sessions reach the database only over
// read-only SQL (scripts/rq), which carries metadata, never bytes. This
// function closes that gap without widening her standing access: she
// posts an upload id here — her own project, already an allowed host —
// and gets back a short-lived signed URL to download and actually look
// at the file (an image, a PDF, a document).
//
// Auth is the same gate every agent path has: the x-claude-rq-key
// header, checked against the vault by claude_file_target() (which also
// answers the object's path, to service_role only). A wrong key and an
// unknown id both raise, and neither answer says which. The URL expires
// in minutes; the bucket itself stays private.
//
// POST { upload_id } → { url, path, mime, bytes }

import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-claude-rq-key',
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

  const key = req.headers.get('x-claude-rq-key') ?? ''
  if (!key) return json(401, { error: 'x-claude-rq-key header required' })

  let body: Record<string, unknown>
  try {
    body = await req.json()
  } catch {
    return json(400, { error: 'a JSON body is required' })
  }
  const uploadId = typeof body.upload_id === 'string' ? body.upload_id.trim() : ''
  if (!uploadId) return json(400, { error: 'upload_id is required' })

  const admin = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  )

  // The gate and the lookup in one: a wrong key or an unknown id both
  // raise, and neither answer says which.
  const { data, error } = await admin.rpc('claude_file_target', {
    _key: key,
    _upload_id: uploadId,
  })
  if (error) return json(403, { error: error.message })
  const target = data as { path: string; mime: string; bytes: number } | null
  if (!target?.path) return json(404, { error: 'no such upload' })

  const { data: signed, error: signError } = await admin.storage
    .from('uploads')
    .createSignedUrl(target.path, SIGNED_URL_SECONDS)
  if (signError || !signed?.signedUrl) {
    return json(500, { error: signError?.message ?? 'could not sign the URL' })
  }

  return json(200, {
    url: signed.signedUrl,
    path: target.path,
    mime: target.mime,
    bytes: target.bytes,
    expires_in: SIGNED_URL_SECONDS,
  })
})
