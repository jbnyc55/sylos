# The Claude connector — your database, added to Claude and logged into

Every Sylos database is also a **remote MCP server**: a Claude
connector the owner adds once (Settings → Connectors → Add custom
connector) and signs into with their Sylos email and password. From
then on a routine needs nothing but that connector — no Claude Code
environment, no environment variables, no network allowlist, no cloned
repo. This is what ended the Mac app requirement: with the routine
this easy to wire, the owner's own Claude account is the default
worker everywhere, and the Mac app (`sylos_mac`) is an optional
accelerator, not a prerequisite.

```
connector URL:   https://<project-ref>.supabase.co/functions/v1/syla-mcp
log in with:     the owner's Sylos email + password (the project's own GoTrue)
```

## The three pieces

1. **Supabase Auth's built-in OAuth 2.1 server** is the authorization
   server. It is a platform feature of the owner's own project —
   enabled by the provisioners over the Management API
   (`oauth_server_enabled`, `oauth_server_allow_dynamic_registration`,
   `oauth_server_authorization_path = '/oauth/consent'`,
   `site_url = 'https://getsylos.com'`, and `uri_allow_list` carrying
   the getsylos.com origins) and in `supabase/config.toml` for local
   stacks. Claude registers itself dynamically (RFC 7591), runs
   authorization-code + PKCE, and GoTrue mints and refreshes the
   tokens. Nothing of ours stores a credential.

   The `uri_allow_list` matters and is easy to miss: GoTrue validates
   the `Origin` header on the consent page's own calls
   (`/oauth/authorizations/{id}`) and answers **"unauthorized request
   origin"** unless the origin matches `site_url` or a glob in the
   list. `site_url` redirects consent to getsylos.com, but the origin
   check is separate, so the bare `https://getsylos.com` (and the www
   form) must be listed outright — a `…/**` pattern alone does not
   match a bare origin.
2. **The consent page** is the web app's `getsylos.com/oauth/consent`
   (static, bring-your-own-database like the rest of `/app`): GoTrue
   redirects there with an `authorization_id`, the signed-in owner sees
   what is asking, and approves or denies. The page talks only to the
   owner's own project.
3. **The `syla-mcp` edge function** is the resource server — the MCP
   endpoint itself. It serves its RFC 9728 protected-resource metadata
   under its own path (every 401 names it in `WWW-Authenticate`, which
   is the pointer the MCP spec makes clients follow — the domain root
   belongs to the Supabase gateway, not to us), proves each bearer
   token against GoTrue, requires the **project owner** (followers hold
   auth sessions too; their login is not an agent door), and then runs
   every tool through the same Vault-gated RPCs as the scripts.

## The boundary does not move

The tools are the claude role, full stop. A connector session can do
exactly what `scripts/rq` and the structured write wrappers can do —
read `public`, write through gated, logged, proposal-shaped RPCs — and
nothing else. The plumbing that keeps it that way:

- `connector_rq_key()` (migration `20270110000000`) hands the rq key
  from Vault to the edge function — **service_role only**, so no
  client role can pull the key out through PostgREST. Every tool call
  then passes `assert_claude_rq_key()` like any script would.
- A connector login mints GoTrue tokens that would otherwise work
  against PostgREST as the signed-in owner. The pre-request hook
  `assert_not_connector_token()` (same migration) refuses any
  PostgREST request whose JWT carries an OAuth `client_id` claim, so
  the syla-mcp function is the only door those tokens open. (GoTrue's
  own endpoints are not PostgREST and are unaffected; Storage and
  Realtime are outside the hook — the honest statement is that the
  hook contains the *data plane*, and revocation, below, contains the
  rest.)
- Webhook plumbing (`set_syla_webhook` / `clear_syla_webhook`) is
  deliberately not reachable as a tool: wiring credentials is the
  setup page's job, never a task's.

What Anthropic holds for a connected connector is an OAuth grant —
the same trust shape as any "Sign in with" app, strictly weaker than
the management credential (which stays in the iPhone's Keychain and
never meets this flow).

## The tool surface

`rq` (read-only SQL — scripts/rq), `syla_claim`, `syla_finish`,
`syla_status`, `chat_say`, `file_url`, `following_relay` (the
following-* scripts' kinds rq / prompt / edit / poke), and `agent_rpc`
— the allowlisted long tail of gated RPCs (`save_doc`,
`propose_todo_edit`, `run_agent_write_sql`, `save_mini`, …; the list
lives at the top of `supabase/functions/syla-mcp/index.ts`). Every
tool carries the MCP title and read-only/destructive annotations.

The server's `instructions` field carries the "Do the task" loop, so a
routine with only this connector — no repository at all — knows to
claim, read the event's docs, work, narrate, reply and finish. The
skills docs keep teaching the script names; the instructions carry the
script→tool mapping.

## Routines, after the change

Creating the routine is now: **add your Sylos connector (log in when
asked), name it Syla task, prompt "Do the task.", webhook trigger, no
schedule** — then paste the fire URL and bearer token back into the
setup page, which stores them in your Vault (`set_syla_webhook`,
unchanged). The dispatcher, the queue, the receipts, the claim
semantics: all exactly as `04-syla-jobs.md` describes. Connector
sessions stamp `claimed_by = 'routine'` like any routine session.

The repo-and-environment route still works and is still documented
(`02-setup.md`'s by-hand section): the env-var trio reaches the same
gates. It is now the fallback, not the path.

## Revoking

Any one of these is sufficient, worst first:

- Rotate or delete Vault secret `claude_rq_key` — every tool call
  fails closed immediately (`connector_rq_key()` and
  `assert_claude_rq_key()` read the same secret).
- Revoke the OAuth grant / delete the client: Supabase dashboard →
  Authentication → OAuth Server. Claude's stored tokens die with it.
- Remove the connector in Claude's settings.

## Testing a fresh install's connector

From any machine (all three should answer without auth):

```bash
curl -i https://<ref>.supabase.co/functions/v1/syla-mcp            # 405 (POST only)
curl -s https://<ref>.supabase.co/functions/v1/syla-mcp/.well-known/oauth-protected-resource
curl -s https://<ref>.supabase.co/.well-known/oauth-authorization-server/auth/v1
```

The second must name the third as its authorization server; the third
is GoTrue's own metadata and proves the OAuth server is enabled (a
`feature_disabled` error means the provisioner's auth PATCH has not
run). An unauthenticated `POST` to the function must answer `401`
with a `WWW-Authenticate: Bearer resource_metadata=…` header — that
header is the whole discovery handshake.

## Why this is not in Anthropic's connector directory

The directory lists a connector as **one fixed production URL**; a
Sylos connector is *per person* — the whole point is that the server
is your own database, at your own host. Listing "Sylos" centrally
would need one company-hosted MCP endpoint relaying every user's
traffic (and holding every user's rq key), which is precisely the
operator trust this architecture retired with the agent pool. So the
setup page plays the directory's role: it shows the person their own
connector URL and walks the add-and-log-in. If a directory presence
ever matters commercially, it is a separate, opt-in relay product —
not a change to this design.
