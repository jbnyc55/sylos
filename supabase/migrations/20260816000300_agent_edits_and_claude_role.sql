-- An agent_edits log, and a `claude` role that can read everything but only
-- append to that log.
--
-- The asymmetry is the point: read access is broad so the agent can answer
-- questions about real data, and write access is a single append-only table so
-- the worst it can do is add rows nobody has to trust. Enforcement is in
-- Postgres, not in the client — the tool that uses this role cannot grant
-- itself more than the role has.
--
-- ⚠️  This migration deliberately sets NO PASSWORD. A password here would be
--     committed to git, which is the mistake already made once in this repo
--     (see 20260816000100_seed_first_user.sql). Set it once, by hand:
--
--         alter role claude with password '<generated>';
--
--     from the Supabase SQL editor, and keep the value only in the environment
--     that connects. See notes/06-agent-db-access.md.

-- ---------------------------------------------------------------------------
-- agent_edits
-- ---------------------------------------------------------------------------

create table public.agent_edits (
    id          uuid primary key default gen_random_uuid(),
    agent       text not null default 'claude',
    action      text not null check (char_length(action) between 1 and 100),
    target      text,
    summary     text not null check (char_length(summary) between 1 and 2000),
    details     jsonb,
    created_at  timestamptz not null default now()
);

comment on table public.agent_edits is
    'Append-only log of agent activity. The only table the claude role may write to.';

create index agent_edits_created_at_idx on public.agent_edits (created_at desc);
create index agent_edits_agent_action_idx on public.agent_edits (agent, action);

alter table public.agent_edits enable row level security;

-- ---------------------------------------------------------------------------
-- The claude role
-- ---------------------------------------------------------------------------

do $$
begin
    if not exists (select from pg_roles where rolname = 'claude') then
        -- login, but no password: unusable until one is set by hand.
        create role claude with login;
    end if;
end
$$;

-- Read: everything in public, including tables added by later migrations.
grant usage on schema public to claude;
grant select on all tables in schema public to claude;
alter default privileges in schema public grant select on tables to claude;

-- Write: agent_edits and nothing else. No update or delete — the log is
-- append-only, so a mistaken or malicious entry can be read and disregarded but
-- never quietly rewritten.
grant insert on public.agent_edits to claude;

-- Deliberately NOT granted: the auth, storage and vault schemas. "Read any
-- table" is scoped to application data on purpose — auth.users holds password
-- hashes and refresh tokens, and handing those to an agent is a different
-- decision than letting it read your notes. To include them anyway:
--
--     grant usage on schema auth to claude;
--     grant select on all tables in schema auth to claude;

-- ---------------------------------------------------------------------------
-- Row level security for the claude role
-- ---------------------------------------------------------------------------
--
-- A grant alone is not enough on an RLS-protected table: with no policy
-- matching this role, claude would hold SELECT and still read zero rows. Every
-- current table in public gets an explicit read-everything policy.
--
-- New tables need one too. Add this alongside the table in its own migration:
--
--     create policy "claude reads everything" on public.<table>
--         for select to claude using (true);

do $$
declare
    t record;
begin
    for t in
        select tablename from pg_tables where schemaname = 'public'
    loop
        execute format(
            'drop policy if exists "claude reads everything" on public.%I', t.tablename);
        execute format(
            'create policy "claude reads everything" on public.%I for select to claude using (true)',
            t.tablename);
    end loop;
end
$$;

-- claude appends to the log.
create policy "claude appends to the log"
    on public.agent_edits for insert
    to claude
    with check (true);

-- Signed-in users can read the log, so agent activity is reviewable in the app
-- rather than only in the dashboard. They cannot write to it.
grant select on public.agent_edits to authenticated;

create policy "Agent edits are readable by signed-in users"
    on public.agent_edits for select
    to authenticated
    using (true);
