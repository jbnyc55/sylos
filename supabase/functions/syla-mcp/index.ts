// syla-mcp — the database as a Claude connector.
//
// This function makes the owner's project a remote MCP server that
// claude.ai (and Claude Code routines) can add as a connector: add the
// URL, log in with the Sylos email and password, done. No environment
// variables, no network allowlist, no cloned repo required — the tools
// below ARE Syla's access, and `instructions` carries the job loop.
//
//   connector URL:  https://<ref>.supabase.co/functions/v1/syla-mcp
//
// Auth is OAuth 2.1, served by Supabase Auth's built-in OAuth server
// (enabled per project — notes/13-claude-connector.md): Claude discovers
// it through the protected-resource metadata this function serves (and
// points at from every 401's WWW-Authenticate header), registers itself
// dynamically, and sends the owner through the consent page at
// getsylos.com/oauth/consent. The bearer tokens Claude then sends here
// are GoTrue-minted JWTs carrying the OAuth client_id claim; the
// database's pre-request hook (20270110000000) refuses those tokens on
// the whole PostgREST data plane, so this function is the ONLY door a
// connector login opens.
//
// The boundary does not move an inch: a valid token proves "the owner
// wired this connector", and every tool then executes as the `claude`
// role through the same Vault-gated RPCs the repo scripts use
// (connector_rq_key() hands this function the rq key; service_role
// only). The connector is a second transport to the same role. Syla
// still never holds owner power.
//
// Transport: Streamable HTTP, JSON responses (no SSE). Stateless — no
// session ids are issued, every POST stands alone.

import { createClient } from 'npm:@supabase/supabase-js@2'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

// The public face of this function. SUPABASE_URL is the project URL on
// hosted projects; MCP_RESOURCE_URL overrides it for custom domains.
const RESOURCE_URL =
  Deno.env.get('MCP_RESOURCE_URL') ?? `${SUPABASE_URL}/functions/v1/syla-mcp`
const AUTH_ISSUER = Deno.env.get('MCP_AUTH_ISSUER') ?? `${SUPABASE_URL}/auth/v1`

const PROTOCOL_VERSIONS = ['2025-06-18', '2025-03-26', '2024-11-05']

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, content-type, accept, apikey, x-client-info, mcp-protocol-version, mcp-session-id',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  'Access-Control-Expose-Headers': 'WWW-Authenticate',
}

function json(status: number, body: unknown, headers: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json', ...headers },
  })
}

/** 401 with the pointer Claude follows to find the OAuth server. */
function unauthorized(detail: string) {
  return json(
    401,
    { error: 'unauthorized', error_description: detail },
    {
      'WWW-Authenticate': `Bearer resource_metadata="${RESOURCE_URL}/.well-known/oauth-protected-resource"`,
    },
  )
}

// ── OAuth discovery ────────────────────────────────────────────────────
//
// RFC 9728 protected-resource metadata: who the authorization server is.
// Served under this function's own path (the Supabase gateway owns the
// domain root, so root-level well-known paths are not ours to answer);
// every 401 above names this URL explicitly, which is the handshake the
// MCP spec makes clients follow. The authorization server metadata
// itself is the platform's: GoTrue answers
//   /.well-known/oauth-authorization-server/auth/v1
// at the domain root once the project's OAuth server is enabled.

function protectedResourceMetadata() {
  return json(200, {
    resource: RESOURCE_URL,
    authorization_servers: [AUTH_ISSUER],
    bearer_methods_supported: ['header'],
    resource_name: 'Sylos',
    resource_documentation: 'https://github.com/jbnyc55/sylos',
  })
}

// ── The gates ──────────────────────────────────────────────────────────

const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
})

/**
 * Prove the bearer token against GoTrue and require the project OWNER.
 * Followers hold auth sessions on this project too, and a follower's
 * OAuth login must not become an agent door into someone else's data.
 */
async function authenticate(req: Request): Promise<{ ok: true } | { ok: false; res: Response }> {
  const auth = req.headers.get('authorization') ?? ''
  const token = auth.replace(/^Bearer\s+/i, '').trim()
  if (!token) return { ok: false, res: unauthorized('a bearer token is required') }

  const { data, error } = await admin.auth.getUser(token)
  if (error || !data?.user) {
    return { ok: false, res: unauthorized('the token is invalid or expired') }
  }

  // profiles.id is the app-level identifier (a random UUID); the auth
  // user is matched on profiles.user_id, per the schema (20260816).
  const { data: profile } = await admin
    .from('profiles')
    .select('is_owner')
    .eq('user_id', data.user.id)
    .maybeSingle()
  if (!profile?.is_owner) {
    return {
      ok: false,
      res: json(403, {
        error: 'forbidden',
        error_description: 'only the project owner can use the Sylos connector',
      }),
    }
  }
  return { ok: true }
}

/** The rq key, via the service_role-only Vault reader. Cached briefly. */
let rqKeyCache: { value: string; at: number } | null = null
async function rqKey(): Promise<string> {
  if (rqKeyCache && Date.now() - rqKeyCache.at < 60_000) return rqKeyCache.value
  const { data, error } = await admin.rpc('connector_rq_key')
  if (error || typeof data !== 'string' || !data) {
    throw new Error(error?.message ?? 'the rq key is not configured in Vault')
  }
  rqKeyCache = { value: data, at: Date.now() }
  return data
}

/** One gated RPC call, exactly as the repo scripts make it. */
async function gatedRpc(fn: string, args: Record<string, unknown>): Promise<string> {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      'x-claude-rq-key': await rqKey(),
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(args),
  })
  const text = await res.text()
  if (!res.ok) throw new Error(`${fn} answered ${res.status}: ${text}`)
  return text
}

// ── The tools ──────────────────────────────────────────────────────────
//
// Every write below lands in a Vault-gated RPC that is append-only,
// trigger-logged in row_edits, or a proposal the owner approves — the
// boundary is in Postgres, these are its phone lines. Annotations per
// the MCP spec (and Anthropic's directory requirements): a title plus
// readOnlyHint / destructiveHint on each.

/** Gated RPCs reachable through agent_rpc — the long tail of the
 *  structured write paths, same names and arguments as the scripts'
 *  own RPCs. Webhook plumbing (set/clear_syla_webhook) is deliberately
 *  not here: wiring credentials is the setup page's job, not a task's. */
const AGENT_RPCS = [
  'save_doc', 'move_doc', 'delete_doc', 'set_doc_silos',
  'set_note_silos', 'split_note', 'ask_silo_help',
  'propose_todo_edit', 'revise_todo_edit',
  'propose_map_edit', 'revise_map_edit',
  'propose_user_table', 'revise_user_table',
  'propose_auto_approve_rule', 'propose_approval',
  'propose_chat_reply', 'send_auto_reply', 'set_chat_waiting',
  'suggest_reply_rule', 'following_names',
  'log_agent_edit', 'upsert_day_summary', 'log_weight_lift',
  'link_goal_cells', 'save_integration', 'run_agent_write_sql',
  'queue_push', 'save_mini', 'save_mini_files', 'set_mini_open',
] as const

type ToolDef = {
  name: string
  title: string
  description: string
  inputSchema: Record<string, unknown>
  readOnly: boolean
  run: (args: Record<string, unknown>) => Promise<unknown>
}

const str = { type: 'string' } as const

const TOOLS: ToolDef[] = [
  {
    name: 'rq',
    title: 'Read the database (SQL)',
    description:
      'Run one read-only SQL statement as the claude role and get a JSON array back. ' +
      'Contract: ONE statement, no trailing semicolon, valid inside a FROM subquery ' +
      '(it is wrapped as `select ... from (<q>) t`). This is scripts/rq. ' +
      "Start tasks with `select path, title from docs where path like 'skills/%' order by path` " +
      'and read any doc with `select html from docs where path = ...`. ' +
      'Each query also narrates itself onto the live status line of the running runs ' +
      '(the owner watches it under their message) — no extra call needed.',
    inputSchema: {
      type: 'object',
      properties: { q: { ...str, description: 'the SQL statement' } },
      required: ['q'],
    },
    readOnly: true,
    run: (a) => gatedRpc('run_readonly_sql', { q: String(a.q ?? '') }),
  },
  {
    name: 'syla_claim',
    title: 'Claim queued runs',
    description:
      'Claim every queued Syla job run (queued → running) and get the claim entries: ' +
      'run_id, the event with its attached instruction docs and child todos, or the ' +
      "owner's message for a send-to-Syla run. An empty array means another session " +
      'took the work (or a test fire) — then stop and log nothing. This is scripts/syla-claim.',
    inputSchema: { type: 'object', properties: {} },
    readOnly: false,
    run: () => gatedRpc('claim_syla_runs', { _worker: 'routine' }),
  },
  {
    name: 'syla_finish',
    title: 'Finish a run',
    description:
      'Close one claimed run with a 1–2 sentence summary the owner reads in the app. ' +
      'Report EVERY claimed run before stopping — done, or failed with the reason. ' +
      'This is scripts/syla-finish.',
    inputSchema: {
      type: 'object',
      properties: {
        run_id: str,
        status: { type: 'string', enum: ['done', 'failed'] },
        summary: str,
      },
      required: ['run_id', 'status', 'summary'],
    },
    readOnly: false,
    run: (a) =>
      gatedRpc('finish_syla_run', {
        _run_id: String(a.run_id ?? ''),
        _status: String(a.status ?? ''),
        _summary: String(a.summary ?? ''),
      }),
  },
  {
    name: 'syla_status',
    title: 'Set the live status line',
    description:
      'Stamp a short Syla-voiced line ("Checking the calendar…") on a running run — ' +
      'the owner watches it under their message while you work. Narration, never the ' +
      'record; set it at each milestone. This is scripts/syla-status.',
    inputSchema: {
      type: 'object',
      properties: { run_id: str, note: { ...str, description: 'one line, 120 chars max' } },
      required: ['run_id', 'note'],
    },
    readOnly: false,
    run: (a) =>
      gatedRpc('set_syla_run_status', {
        _run_id: String(a.run_id ?? ''),
        _note: String(a.note ?? ''),
      }),
  },
  {
    name: 'chat_say',
    title: 'Reply in the Syla conversation',
    description:
      "Post Syla's reply into the owner's Syla conversation, linked to the run it " +
      'answers. This is scripts/chat-say.',
    inputSchema: {
      type: 'object',
      properties: { body: str, run_id: { ...str, description: 'the run this answers (optional)' } },
      required: ['body'],
    },
    readOnly: false,
    run: (a) =>
      gatedRpc(
        'syla_chat_say',
        a.run_id
          ? { _body: String(a.body ?? ''), _run_id: String(a.run_id) }
          : { _body: String(a.body ?? '') },
      ),
  },
  {
    name: 'file_url',
    title: 'Look at an uploaded file',
    description:
      'Get a short-lived signed URL for an uploads row (a photo or document the owner ' +
      'attached), to fetch and look at before filing. This is scripts/file-url.',
    inputSchema: {
      type: 'object',
      properties: { upload_id: str },
      required: ['upload_id'],
    },
    readOnly: true,
    run: async (a) => {
      const res = await fetch(`${SUPABASE_URL}/functions/v1/claude-file`, {
        method: 'POST',
        headers: {
          apikey: ANON_KEY,
          'x-claude-rq-key': await rqKey(),
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ upload_id: String(a.upload_id ?? '') }),
      })
      const text = await res.text()
      if (!res.ok) throw new Error(`claude-file answered ${res.status}: ${text}`)
      return text
    },
  },
  {
    name: 'following_relay',
    title: "Reach a friend's database",
    description:
      "Call a follow (a friend's Sylos project where the owner holds a follower key) " +
      'through the following-relay: kind "rq" (their read-only SQL, pass q), "prompt" ' +
      '(pass prompt), "edit" (pass proposal as JSON), "poke" (pass chat_key). This is ' +
      'the scripts/following-* family; the skills/following doc is the manual.',
    inputSchema: {
      type: 'object',
      properties: {
        name: { ...str, description: 'the follow, as following_names lists it' },
        kind: { type: 'string', enum: ['rq', 'prompt', 'edit', 'poke'] },
        q: str,
        prompt: str,
        proposal: { type: 'object', description: 'for kind edit' },
        chat_key: str,
      },
      required: ['name', 'kind'],
    },
    readOnly: false,
    run: async (a) => {
      const body: Record<string, unknown> = { name: a.name, kind: a.kind }
      for (const k of ['q', 'prompt', 'proposal', 'chat_key']) {
        if (a[k] !== undefined) body[k] = a[k]
      }
      const res = await fetch(`${SUPABASE_URL}/functions/v1/following-relay`, {
        method: 'POST',
        headers: {
          apikey: ANON_KEY,
          'x-claude-rq-key': await rqKey(),
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
      })
      const text = await res.text()
      if (!res.ok) throw new Error(`following-relay answered ${res.status}: ${text}`)
      return text
    },
  },
  {
    name: 'agent_rpc',
    title: 'A structured write path',
    description:
      'Call one of the gated agent RPCs by name with its JSON arguments — the long ' +
      'tail of the structured writes the skills docs teach as scripts (scripts/doc-save ' +
      '→ save_doc, scripts/propose-todo-edit → propose_todo_edit, and so on; argument ' +
      "names start with an underscore, e.g. {\"_path\": …}). Discover a function's " +
      "arguments with rq: select pg_get_function_arguments(oid) from pg_proc where " +
      "proname = '<fn>'. Allowed: " + AGENT_RPCS.join(', ') + '.',
    inputSchema: {
      type: 'object',
      properties: {
        fn: { type: 'string', enum: [...AGENT_RPCS] },
        args: { type: 'object', description: 'the RPC arguments, underscore-named' },
      },
      required: ['fn'],
    },
    readOnly: false,
    run: (a) => {
      const fn = String(a.fn ?? '')
      if (!(AGENT_RPCS as readonly string[]).includes(fn)) {
        throw new Error(`"${fn}" is not a connector-reachable RPC`)
      }
      return gatedRpc(fn, (a.args ?? {}) as Record<string, unknown>)
    },
  },
]

const INSTRUCTIONS = `You are Syla, this owner's agent, and this connector is your database — the one home of their durable personal state. When a session starts with "Do the task":

1. Call syla_claim. An empty array → a test fire or another session took the work; stop and write nothing.
2. List your skills (rq: select path, title from docs where path like 'skills/%' order by path) and load the ones the claimed work calls for (rq: select html from docs where path = '<path>').
3. Work each claimed run in order. The event IS the instructions — its title, child todos, and above all its attached docs; read each doc and follow it exactly. An event with no docs is its title: do the sensible, narrow version. A run with NO event is the owner's send-to-Syla message (the claim's message field; message_upload_id names an attached file — file_url shows it): decide whether it is real work (file it with agent_rpc propose_todo_edit, kind add), a question, or a passing thought, and either way answer with chat_say. Until the owner's first mini exists (minis has no first-chart row), load skills/first-run before answering any message run.
4. Narrate while you work: every rq query stamps the live status line by itself ("Checking the calendar…"); add syla_status at the milestones rq cannot see ("Thinking it over…", "Writing your reply…").
5. Report EVERY claimed run with syla_finish (done with a 1–2 sentence summary, or failed with the reason) before stopping.

The skills docs teach repo scripts; over this connector, scripts/rq is the rq tool, syla-claim / syla-finish / syla-status / chat-say / file-url are the tools of the same name, the following-* scripts are following_relay, and every other script is agent_rpc with the RPC it posts to. Your writes are structured by design: append-only, logged in row_edits, or proposals the owner approves in the app — work through these tools only, and if one fails on auth, stop and report that instead of improvising.`

// ── MCP over Streamable HTTP (JSON mode, stateless) ────────────────────

type RpcMessage = {
  jsonrpc?: string
  id?: number | string | null
  method?: string
  params?: Record<string, unknown>
}

function rpcResult(id: number | string | null, result: unknown) {
  return json(200, { jsonrpc: '2.0', id, result })
}

function rpcError(id: number | string | null, code: number, message: string) {
  return json(200, { jsonrpc: '2.0', id, error: { code, message } })
}

async function handleMcp(msg: RpcMessage): Promise<Response> {
  const id = msg.id ?? null

  switch (msg.method) {
    case 'initialize': {
      const asked = String(msg.params?.protocolVersion ?? '')
      return rpcResult(id, {
        protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'sylos', title: 'Sylos', version: '1.0.0' },
        instructions: INSTRUCTIONS,
      })
    }
    case 'ping':
      return rpcResult(id, {})
    case 'tools/list':
      return rpcResult(id, {
        tools: TOOLS.map((t) => ({
          name: t.name,
          title: t.title,
          description: t.description,
          inputSchema: t.inputSchema,
          annotations: {
            title: t.title,
            readOnlyHint: t.readOnly,
            destructiveHint: false,
            openWorldHint: false,
          },
        })),
      })
    case 'tools/call': {
      const name = String(msg.params?.name ?? '')
      const tool = TOOLS.find((t) => t.name === name)
      if (!tool) return rpcError(id, -32602, `unknown tool: ${name}`)
      const args = (msg.params?.arguments ?? {}) as Record<string, unknown>
      try {
        const out = await tool.run(args)
        const text = typeof out === 'string' ? out : JSON.stringify(out)
        return rpcResult(id, { content: [{ type: 'text', text }] })
      } catch (err) {
        return rpcResult(id, {
          content: [{ type: 'text', text: `error: ${(err as Error).message}` }],
          isError: true,
        })
      }
    }
    default:
      // Notifications (no id) are acknowledged without a body.
      if (id === null || msg.method?.startsWith('notifications/')) {
        return new Response(null, { status: 202, headers: corsHeaders })
      }
      return rpcError(id, -32601, `method not found: ${msg.method}`)
  }
}

// ── Routing ────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  const path = new URL(req.url).pathname

  // Discovery is public by design — it is how an unauthenticated Claude
  // finds the login. Answer it at the well-known suffix and the plain one.
  if (req.method === 'GET' && /\/(\.well-known\/)?oauth-protected-resource\/?$/.test(path)) {
    return protectedResourceMetadata()
  }

  if (req.method === 'GET') {
    // No SSE stream is offered; a GET that is not discovery is either a
    // health probe or a misdirected browser.
    return json(405, { error: 'POST JSON-RPC here; this server opens no stream' })
  }
  if (req.method === 'DELETE') {
    // Stateless: there is no session to terminate.
    return new Response(null, { status: 405, headers: corsHeaders })
  }
  if (req.method !== 'POST') return json(405, { error: 'POST only' })

  const gate = await authenticate(req)
  if (!gate.ok) return gate.res

  let msg: RpcMessage
  try {
    msg = await req.json()
  } catch {
    return rpcError(null, -32700, 'parse error: a JSON-RPC message is required')
  }
  if (Array.isArray(msg)) {
    return rpcError(null, -32600, 'batching is not supported; send one message per request')
  }
  return handleMcp(msg)
})
