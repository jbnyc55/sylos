-- HTTPS access for the `claude` role, via PostgREST RPC.
--
-- The role from 20260816000300 is the boundary; this migration adds a second
-- transport for it. Direct Postgres (port 5432) is raw TCP, which filtered
-- egress environments — including Claude Code cloud sessions — cannot open.
-- HTTPS they can. So: two SQL functions, exposed through PostgREST, that run a
-- caller-supplied statement *as the claude role*, so every grant, RLS policy
-- and denial from the role migration applies unchanged.
--
-- No privileged secret ever reaches the agent. The caller proves itself with a
-- header token that maps to at most what `claude` can already do, and the
-- expected value lives only in Vault. Everything fails closed: no Vault
-- secret → every call refused; no header → refused; wrong header → refused.
-- There are deliberately no fallbacks.
--
-- Ops required after this deploys (see notes/07-agent-rq-https.md):
--   1. Create Vault secret `claude_rq_key` (a generated random value).
--   2. Put the same value in the agent environment as CLAUDE_RQ_KEY, together
--      with SUPABASE_URL and SUPABASE_ANON_KEY.

-- ---------------------------------------------------------------------------
-- Let PostgREST switch into the claude role
-- ---------------------------------------------------------------------------
--
-- PostgREST connects as `authenticator`; SET ROLE only works for roles the
-- session user is a member of. Membership grants nothing by itself — it only
-- makes `set local role claude` legal inside the functions below.

do $$
begin
    if exists (select from pg_roles where rolname = 'authenticator') then
        grant claude to authenticator;
    end if;
end
$$;

-- ---------------------------------------------------------------------------
-- The key gate
-- ---------------------------------------------------------------------------
--
-- SECURITY DEFINER for exactly one reason: reading vault.decrypted_secrets,
-- which the calling role cannot and should not. It compares the request's
-- x-claude-rq-key header against Vault secret `claude_rq_key` and raises on
-- any mismatch, including the secret not existing at all — an unconfigured
-- project refuses everything rather than allowing anything.

create or replace function public.assert_claude_rq_key()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    expected text;
    provided text;
begin
    select decrypted_secret into expected
    from vault.decrypted_secrets
    where name = 'claude_rq_key';

    if expected is null or expected = '' then
        raise exception 'claude_rq_key is not configured in Vault; agent access is disabled'
            using errcode = '28000';
    end if;

    provided := coalesce(
        current_setting('request.headers', true)::jsonb ->> 'x-claude-rq-key', '');

    if provided = '' or provided is distinct from expected then
        raise exception 'missing or invalid x-claude-rq-key header'
            using errcode = '28000';
    end if;
end;
$$;

comment on function public.assert_claude_rq_key() is
    'Refuses the request unless the x-claude-rq-key header matches Vault secret claude_rq_key. Fails closed when the secret is absent.';

revoke all on function public.assert_claude_rq_key() from public;
grant execute on function public.assert_claude_rq_key() to anon;

-- ---------------------------------------------------------------------------
-- run_readonly_sql — the read path
-- ---------------------------------------------------------------------------
--
-- Contract with callers: one statement, no trailing semicolon, valid as a FROM
-- subquery — because the function wraps it as
--
--     select coalesce(jsonb_agg(to_jsonb(t)), '[]') from (<q>) t
--
-- and returns the JSON array. SECURITY INVOKER on purpose: after `set local
-- role claude` the dynamic statement runs with claude's grants and RLS, inside
-- a read-only transaction, so even a statement that slips past the wrap cannot
-- write. Granted to anon only — the gate above is the real admission check.

create or replace function public.run_readonly_sql(q text)
returns jsonb
language plpgsql
security invoker
as $$
declare
    result jsonb;
begin
    perform public.assert_claude_rq_key();

    if q is null or btrim(q) = '' then
        raise exception 'empty query';
    end if;
    if btrim(q) like '%;' then
        raise exception 'send one statement without a trailing semicolon';
    end if;

    set local statement_timeout = '30s';
    set local role claude;
    set local transaction_read_only = on;

    execute format(
        'select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from (%s) t', q)
    into result;

    return result;
end;
$$;

comment on function public.run_readonly_sql(text) is
    'Runs one read-only SQL statement as the claude role and returns rows as a JSON array. Gated by assert_claude_rq_key().';

revoke all on function public.run_readonly_sql(text) from public;
grant execute on function public.run_readonly_sql(text) to anon;

-- ---------------------------------------------------------------------------
-- log_agent_edit — the write path
-- ---------------------------------------------------------------------------
--
-- The role's only write is INSERT on agent_edits, and this function is that
-- write over HTTPS: gate, switch to claude, append one row. No dynamic SQL
-- here — the write path takes structured arguments, not statements.

create or replace function public.log_agent_edit(
    _action  text,
    _summary text,
    _target  text  default null,
    _details jsonb default null,
    _agent   text  default 'claude'
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    result jsonb;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    insert into public.agent_edits (agent, action, target, summary, details)
    values (coalesce(_agent, 'claude'), _action, _target, _summary, _details)
    returning jsonb_build_object('id', id, 'created_at', created_at)
    into result;

    return result;
end;
$$;

comment on function public.log_agent_edit(text, text, text, jsonb, text) is
    'Appends one row to agent_edits as the claude role. Gated by assert_claude_rq_key().';

revoke all on function public.log_agent_edit(text, text, text, jsonb, text) from public;
grant execute on function public.log_agent_edit(text, text, text, jsonb, text) to anon;
