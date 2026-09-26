-- A live answer to "what can the claude role actually do right now?".
--
-- The claude role's rights accumulate across many migrations — a broad select
-- by default privilege, column-scoped writes here and there, RLS policies with
-- real conditions — and reading migrations top to bottom is the wrong way to
-- learn the current state: a later migration can revoke what an earlier one
-- granted, and production can drift from the files (see 20260828020000, which
-- exists because it did). So this function reads the catalogs at call time.
-- The app's "Claude access" tab calls it on every visit, which is what makes
-- that page always current rather than a hand-maintained document.
--
-- It returns raw facts (grants, policies, memberships) as jsonb. Turning them
-- into English happens deterministically in the client
-- (web/src/lib/claudeAccess.ts), so wording can improve without a migration.
--
-- SECURITY INVOKER on purpose: everything read here — pg_roles, pg_class,
-- pg_attribute, pg_policy, pg_auth_members, pg_default_acl — is world-readable
-- catalog data, so the caller's own rights suffice and there is no definer
-- privilege to leak.

create or replace function public.claude_role_permissions()
returns jsonb
language sql
stable
security invoker
set search_path = pg_catalog
as $$
with claude_role as (
    select oid, rolcanlogin, rolsuper, rolbypassrls
    from pg_roles
    where rolname = 'claude'
),

-- Grants to PUBLIC (grantee oid 0) apply to every role, claude included, so
-- both must be checked or the picture understates what claude can do.
grantees as (
    select oid, false as via_public from claude_role
    union all
    select 0::oid, true
),

-- Application-level schemas: everything except the system catalogs. Ones
-- where claude lacks USAGE still appear, flagged, so the page can say which
-- schemas are sealed off entirely.
app_schemas as (
    select n.oid, n.nspname as schema_name,
           exists (
               select 1
               from aclexplode(n.nspacl) a
               join grantees g on g.oid = a.grantee
               where a.privilege_type = 'USAGE'
           ) as has_usage
    from pg_namespace n
    where n.nspname not like 'pg\_%'
      and n.nspname <> 'information_schema'
),

-- Relations claude could conceivably reach: those in schemas it can enter.
-- A table grant without schema USAGE is dead, so there is no point listing
-- tables in sealed schemas.
rels as (
    select c.oid, s.schema_name, c.relname, c.relrowsecurity, c.relacl
    from pg_class c
    join app_schemas s on s.oid = c.relnamespace
    where s.has_usage
      and c.relkind in ('r', 'p', 'v', 'm', 'f')
),

-- Table-wide privileges (columns: null) and column-scoped ones (columns:
-- the list), in one shape. via_public is true only when every path to the
-- privilege runs through PUBLIC rather than a grant naming claude.
priv_rows as (
    select r.oid as reloid,
           a.privilege_type as privilege,
           null::jsonb as columns,
           bool_and(g.via_public) as via_public
    from rels r
    cross join lateral aclexplode(r.relacl) a
    join grantees g on g.oid = a.grantee
    group by r.oid, a.privilege_type

    union all

    select r.oid,
           a.privilege_type,
           to_jsonb(array_agg(distinct att.attname order by att.attname)),
           bool_and(g.via_public)
    from rels r
    join pg_attribute att
        on att.attrelid = r.oid and att.attnum > 0 and not att.attisdropped
    cross join lateral aclexplode(att.attacl) a
    join grantees g on g.oid = a.grantee
    group by r.oid, a.privilege_type
),

privs_json as (
    select reloid,
           jsonb_agg(
               jsonb_build_object(
                   'privilege', privilege,
                   'columns', columns,
                   'via_public', via_public)
               order by privilege, columns) as privileges
    from priv_rows
    group by reloid
),

-- Row-security policies that apply to claude: ones naming it, or ones for
-- PUBLIC (polroles = {0}), which bind every role.
pols_json as (
    select p.polrelid as reloid,
           jsonb_agg(
               jsonb_build_object(
                   'name', p.polname,
                   'command', case p.polcmd
                       when 'r' then 'SELECT'
                       when 'a' then 'INSERT'
                       when 'w' then 'UPDATE'
                       when 'd' then 'DELETE'
                       else 'ALL'
                   end,
                   'permissive', p.polpermissive,
                   'via_public', coalesce(
                       not (p.polroles && (select array_agg(oid) from claude_role)),
                       true),
                   'using', pg_get_expr(p.polqual, p.polrelid),
                   'check', pg_get_expr(p.polwithcheck, p.polrelid))
               order by p.polname) as policies
    from pg_policy p
    where p.polroles && (select array_agg(oid) from grantees)
    group by p.polrelid
),

tables_json as (
    select jsonb_agg(
               jsonb_build_object(
                   'schema', r.schema_name,
                   'table', r.relname,
                   'rls_enabled', r.relrowsecurity,
                   'privileges', coalesce(pv.privileges, '[]'::jsonb),
                   'policies', coalesce(pl.policies, '[]'::jsonb))
               order by r.schema_name, r.relname) as tables
    from rels r
    left join privs_json pv on pv.reloid = r.oid
    left join pols_json pl on pl.reloid = r.oid
),

schemas_json as (
    select jsonb_agg(
               jsonb_build_object('schema', schema_name, 'has_usage', has_usage)
               order by schema_name) as schemas
    from app_schemas
),

-- Functions whose ACL names claude explicitly. Functions executable because
-- of the EXECUTE-to-PUBLIC default are deliberately not enumerated — that
-- would be every function in the database, and the page says so in prose.
funcs_json as (
    select jsonb_agg(
               jsonb_build_object('schema', schema_name, 'function', fn)
               order by schema_name, fn) as functions
    from (
        select s.schema_name,
               p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as fn
        from pg_proc p
        join app_schemas s on s.oid = p.pronamespace
        where exists (
            select 1
            from aclexplode(p.proacl) a
            where a.privilege_type = 'EXECUTE'
              and a.grantee in (select oid from claude_role))
    ) f
),

-- Default privileges: what claude will automatically receive on objects that
-- do not exist yet ("read any future table" from 20260816000300 lives here).
defaults_json as (
    select jsonb_agg(
               jsonb_build_object(
                   'schema', n.nspname,
                   'grantor', pg_get_userbyid(d.defaclrole),
                   'object_type', case d.defaclobjtype
                       when 'r' then 'tables'
                       when 'S' then 'sequences'
                       when 'f' then 'functions'
                       when 'T' then 'types'
                       when 'n' then 'schemas'
                       else d.defaclobjtype::text
                   end,
                   'privilege', a.privilege_type)
               order by n.nspname, d.defaclobjtype, a.privilege_type) as defaults
    from pg_default_acl d
    left join pg_namespace n on n.oid = d.defaclnamespace
    cross join lateral aclexplode(d.defaclacl) a
    where a.grantee in (select oid from claude_role)
),

role_json as (
    select jsonb_build_object(
               'can_login', r.rolcanlogin,
               'superuser', r.rolsuper,
               'bypasses_rls', r.rolbypassrls,
               'member_of', coalesce(
                   (select jsonb_agg(g.rolname order by g.rolname)
                    from pg_auth_members m
                    join pg_roles g on g.oid = m.roleid
                    where m.member = r.oid),
                   '[]'::jsonb),
               'granted_to', coalesce(
                   (select jsonb_agg(g.rolname order by g.rolname)
                    from pg_auth_members m
                    join pg_roles g on g.oid = m.member
                    where m.roleid = r.oid),
                   '[]'::jsonb)) as role
    from claude_role r
)

select jsonb_build_object(
    'queried_at', now(),
    'role', (select role from role_json),
    'schemas', coalesce((select schemas from schemas_json), '[]'::jsonb),
    'tables', coalesce((select tables from tables_json), '[]'::jsonb),
    'functions', coalesce((select functions from funcs_json), '[]'::jsonb),
    'default_privileges', coalesce((select defaults from defaults_json), '[]'::jsonb))
$$;

comment on function public.claude_role_permissions() is
    'The claude role''s current privileges — grants, RLS policies, memberships — read live from the catalogs. Backs the app''s Claude access tab.';

-- Owner-only: guests and anonymous visitors have no business reading the
-- access map, accurate though it is.
revoke all on function public.claude_role_permissions() from public;
grant execute on function public.claude_role_permissions() to authenticated;
