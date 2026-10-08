-- The database is a Claude connector.
--
-- Until now Syla's sessions reached this project through environment
-- variables (SUPABASE_URL / SUPABASE_ANON_KEY / CLAUDE_RQ_KEY) that the
-- owner typed into a Claude Code environment by hand. This migration is
-- the database half of replacing that: the project itself becomes a
-- remote MCP server — a Claude connector the owner adds once and logs
-- into — served by the syla-mcp edge function and authorized by
-- Supabase Auth's built-in OAuth 2.1 server (notes/13-claude-connector.md).
--
-- Two pieces, and deliberately no new tables — GoTrue owns the OAuth
-- clients, codes and tokens, so there is nothing here for row_edits or
-- the silo registry to care about:
--
--   connector_rq_key()   lets the syla-mcp function (service_role, and
--                        ONLY service_role) read the rq key from Vault,
--                        so every tool call it serves goes through the
--                        exact gates the scripts use: assert_claude_rq_key,
--                        set local role claude, the structured RPCs.
--                        The connector is a second transport to the SAME
--                        role — it widens nothing.
--
--   assert_not_connector_token()   the containment: a connector login
--                        mints GoTrue access tokens that would otherwise
--                        work against PostgREST as the signed-in owner.
--                        Syla must never hold owner power, so this
--                        pre-request hook refuses any PostgREST request
--                        whose JWT carries an OAuth client_id claim —
--                        connector tokens open exactly one door, the
--                        syla-mcp function, which answers only the
--                        claude-tier tools. (GoTrue's own endpoints and
--                        the consent flow are untouched; they are not
--                        PostgREST.)
--
-- The credential-tier story (notes/01-architecture.md) stays intact:
-- what Anthropic stores for the connector is an OAuth grant the owner
-- can revoke any time (Supabase dashboard -> Authentication -> OAuth
-- Server, or rotate the rq key and the tools go dark), and what a
-- session can DO through it is exactly the claude role, nothing more.

-- ---------------------------------------------------------------------------
-- connector_rq_key — the syla-mcp function's read of the Vault secret
-- ---------------------------------------------------------------------------
--
-- SECURITY DEFINER for the same single reason as assert_claude_rq_key:
-- reading vault.decrypted_secrets. Granted to service_role alone — the
-- edge runtime's own credential — so no client role, including claude
-- itself, can pull the key out through PostgREST.

create function public.connector_rq_key()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
    expected text;
begin
    select decrypted_secret into expected
    from vault.decrypted_secrets
    where name = 'claude_rq_key';

    if expected is null or expected = '' then
        raise exception 'claude_rq_key is not configured in Vault; agent access is disabled'
            using errcode = '28000';
    end if;

    return expected;
end;
$$;

comment on function public.connector_rq_key() is
    'Hands the syla-mcp edge function (service_role only) the Vault claude_rq_key, so connector tool calls run through the same assert_claude_rq_key-gated RPCs as the scripts. Fails closed when the secret is absent. Rotating the Vault secret cuts the connector off with it.';

revoke all on function public.connector_rq_key() from public;
revoke all on function public.connector_rq_key() from anon, authenticated;
grant execute on function public.connector_rq_key() to service_role;

-- ---------------------------------------------------------------------------
-- The containment hook: connector tokens work only at the connector
-- ---------------------------------------------------------------------------
--
-- PostgREST runs this before every request (pgrst.db_pre_request). A
-- normal session token (the owner's app sign-in) carries no client_id
-- claim and passes untouched; a token minted for an OAuth client — a
-- connector login — is refused here, on the whole data plane, in one
-- place. The syla-mcp function never sends these tokens to PostgREST
-- (it proves them against GoTrue, then acts through the rq gates), so
-- nothing legitimate ever trips this.

create function public.assert_not_connector_token()
returns void
language plpgsql
stable
as $$
declare
    claims jsonb;
begin
    begin
        claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
    exception when others then
        claims := null;
    end;

    if claims ? 'client_id' then
        raise exception 'OAuth client tokens are not accepted here — the Sylos connector (syla-mcp) is their only door'
            using errcode = '42501';
    end if;
end;
$$;

comment on function public.assert_not_connector_token() is
    'PostgREST pre-request hook: refuses any request authorized by an OAuth-client token (a JWT with a client_id claim). Connector logins therefore reach only the syla-mcp function''s claude-tier tools, never the owner''s own data plane.';

grant execute on function public.assert_not_connector_token() to public;

alter role authenticator set pgrst.db_pre_request = 'public.assert_not_connector_token';

-- PostgREST re-reads its settings on this notify; until it lands (or the
-- pool recycles) the hook simply isn't called yet, which fails open only
-- for the window in which no OAuth client exists to mint a token anyway.
notify pgrst, 'reload config';
