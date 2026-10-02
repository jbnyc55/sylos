-- schema_version(): one call that says what this database is running.
--
-- The management credential lives on the iPhone now (the web setup hands
-- it over by QR — notes/02-setup.md), which makes the iPhone the
-- migration and edge-function runner. Every client, though, needs to
-- NOTICE drift: the web app comparing against the migrations it shipped
-- with, the phone deciding whether launchSync has work. This function is
-- that check, server-side and cheap:
--
--   {"schema":    <max applied_migrations.version, or null>,
--    "functions": <count of deployed_functions rows, or null>}
--
-- Both ledgers are APP-CREATED tables (the provisioning runner makes them
-- with RLS on and no policies, so they never serve through PostgREST with
-- a client key) — a manually provisioned database may not have them at
-- all. So: SECURITY DEFINER to read past the no-policy RLS (the function
-- runs as the migration owner, which owns nothing secret here — a
-- migration filename list's maximum and a count), and to_regclass guards
-- so a database without the ledgers answers nulls instead of erroring.
-- Null means "cannot say", and a client treats it as "sync to be sure".

create function public.schema_version()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
    _schema    text;
    _functions integer;
begin
    if to_regclass('public.applied_migrations') is not null then
        select max(version) into _schema from public.applied_migrations;
    end if;
    if to_regclass('public.deployed_functions') is not null then
        select count(*) into _functions from public.deployed_functions;
    end if;
    return jsonb_build_object('schema', _schema, 'functions', _functions);
end;
$$;

comment on function public.schema_version() is
    'The drift check: the newest applied migration (max applied_migrations.version) and how many edge functions the runner has deployed, nulls where the app-created ledgers do not exist. Clients compare against what they shipped with; drift means the iPhone — the holder of the management credential — runs launchSync.';

revoke all on function public.schema_version() from public;
grant execute on function public.schema_version() to authenticated;
grant execute on function public.schema_version() to claude;
