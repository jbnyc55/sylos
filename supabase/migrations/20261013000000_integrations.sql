-- Integrations: a database-driven registry the app renders, plus what the
-- first entry (Google Calendar) needs — PKCE connections without per-owner
-- Google Cloud setup, and a cron-synced mirror.
--
-- The point of the registry is that WEB integrations never require an app
-- update. The Integrations page lists rows from public.integrations; each
-- row names an edge function slug, and the app drives it through four
-- conventional routes (/status, /connect, /sync, /disconnect) plus, for
-- kind 'oauth_pkce', a consent flow described entirely by the row's config.
-- So adding an integration is Syla's kind of work: write the edge function
-- (and a cron migration if it syncs), register the row through
-- save_integration — and it appears in the app. Only integrations that need
-- native code (location sharing) ship with the app itself.
--
-- Google Calendar's own plumbing here:
--
-- 1. PKCE connections. The app connects Google natively: an iOS-type OAuth
--    client has NO client secret (the flow is PKCE, and the client id is
--    public by design), so one client registered by the starter's author
--    serves every install — owners don't create their own Google Cloud app
--    or set GOOGLE_CLIENT_* secrets. Token refresh happens server-side and
--    needs the client id the grant was made with, so it's stored on the
--    connection row.
--
-- 2. Scheduled sync. A pg_cron job asks the edge function to refresh the
--    mirror every ten minutes, so gcal_event stays fresh for the Today grid
--    and for Syla's jobs without the app having to be open. The database
--    cannot know its own project's functions URL, so the edge function
--    registers it here (Vault secret gcal_sync_url) whenever a calendar
--    connects — service-role-only, and pinned to a /gcal/sync-due path so
--    the dispatcher can never be pointed anywhere else.

-- ---------------------------------------------------------------------------
-- integrations — the registry the app's Integrations page renders
-- ---------------------------------------------------------------------------

create table public.integrations (
    slug       text primary key check (slug ~ '^[a-z0-9-]{1,40}$'),
    title      text not null check (char_length(title) between 1 and 80),
    blurb      text not null default '' check (char_length(blurb) <= 500),
    -- How the app runs the connect step. 'oauth_pkce' is the one kind the
    -- app knows today; rows with a kind it doesn't recognize still list,
    -- with connect disabled, so new kinds can ship data-first.
    kind       text not null check (char_length(kind) between 1 and 40),
    -- Everything the connect flow needs, by kind. For oauth_pkce:
    -- auth_url, client_id, scope, callback_scheme, redirect_uri, and
    -- optional extra_params (an object of fixed query params).
    config     jsonb not null default '{}'::jsonb check (jsonb_typeof(config) = 'object'),
    sort       integer not null default 0,
    created_at timestamptz not null default now()
);

comment on table public.integrations is
    'The Integrations page''s registry: one row per web integration, each an edge function the app drives through conventional /status /connect /sync /disconnect routes, with the connect flow described by kind + config. Rows are added by Syla through save_integration — a new integration needs no app update.';

alter table public.integrations enable row level security;

grant select on public.integrations to authenticated;

create policy "Integrations are listed for every signed-in user"
    on public.integrations for select
    to authenticated
    using (true);

grant select on public.integrations to claude;

create policy "claude reads everything"
    on public.integrations for select
    to claude
    using (true);

-- ---------------------------------------------------------------------------
-- save_integration — Syla registers or updates an integration
-- ---------------------------------------------------------------------------
-- Gated by the rq key like her other structured writes; the row_edits
-- trigger logs every change with full before/after images, so a bad edit
-- is one undo away.

create function public.save_integration(
    _slug text, _title text, _blurb text default '',
    _kind text default 'oauth_pkce', _config jsonb default '{}'::jsonb,
    _sort integer default 0
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.assert_claude_rq_key();

    insert into public.integrations as i (slug, title, blurb, kind, config, sort)
    values (_slug, _title, coalesce(_blurb, ''), _kind, coalesce(_config, '{}'::jsonb), coalesce(_sort, 0))
    on conflict (slug) do update
        set title = excluded.title, blurb = excluded.blurb,
            kind = excluded.kind, config = excluded.config, sort = excluded.sort;

    return jsonb_build_object('ok', true, 'slug', _slug);
end;
$$;

comment on function public.save_integration(text, text, text, text, jsonb, integer) is
    'Upserts one integrations row — how Syla (or anyone holding the rq key) adds a web integration to the app''s Integrations page. Trigger-logged in row_edits like every table write.';

revoke all on function public.save_integration(text, text, text, text, jsonb, integer) from public;
grant execute on function public.save_integration(text, text, text, text, jsonb, integer) to anon;

-- ---------------------------------------------------------------------------
-- The first registry row: Google Calendar
-- ---------------------------------------------------------------------------
-- The client id is an iOS-type OAuth client's — public by design, no
-- secret exists for it. callback_scheme is Google's reversed-client-id
-- convention.

insert into public.integrations (slug, title, blurb, kind, config, sort)
values (
    'gcal',
    'Google Calendar',
    'Your calendar on the Today grid, read-only, where Syla can plan around it.',
    'oauth_pkce',
    jsonb_build_object(
        'auth_url',        'https://accounts.google.com/o/oauth2/v2/auth',
        'client_id',       '293558966621-op7ldv2vl8iq3idt3ltpp5hg4u69jqvp.apps.googleusercontent.com',
        'scope',           'https://www.googleapis.com/auth/calendar.readonly email',
        'callback_scheme', 'com.googleusercontent.apps.293558966621-op7ldv2vl8iq3idt3ltpp5hg4u69jqvp',
        'redirect_uri',    'com.googleusercontent.apps.293558966621-op7ldv2vl8iq3idt3ltpp5hg4u69jqvp:/oauth2redirect',
        -- consent even on reconnect, so Google always re-issues a refresh
        -- token.
        'extra_params',    jsonb_build_object('prompt', 'consent')
    ),
    0
);

-- ---------------------------------------------------------------------------
-- The gcal connection remembers which OAuth client it was granted through
-- ---------------------------------------------------------------------------

alter table public.gcal_connection add column google_client_id text;

comment on column public.gcal_connection.google_client_id is
    'The Google OAuth client id this grant was made with. Set for PKCE (iOS-type client) connections, whose token refresh takes no client secret; null for web-client connections, which refresh with the GOOGLE_CLIENT_ID/SECRET edge function secrets.';

-- ---------------------------------------------------------------------------
-- set_gcal_sync_url — the edge function registers its own sync endpoint
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER solely for Vault access, like set_syla_webhook. Only the
-- service role (the edge function) may call it, and the URL must be a
-- /functions/v1/gcal/sync-due path on a *.supabase.co project, so even the
-- service role cannot point the dispatcher at an arbitrary host.

create function public.set_gcal_sync_url(_url text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _existing uuid;
begin
    if _url !~ '^https://[a-z0-9-]+\.supabase\.co/functions/v1/gcal/sync-due$' then
        raise exception 'url must be a supabase.co /functions/v1/gcal/sync-due endpoint';
    end if;

    select id into _existing from vault.secrets where name = 'gcal_sync_url';
    if _existing is null then
        perform vault.create_secret(_url, 'gcal_sync_url');
    else
        perform vault.update_secret(_existing, _url);
    end if;

    return jsonb_build_object('ok', true);
end;
$$;

comment on function public.set_gcal_sync_url(text) is
    'Stores the gcal edge function''s sync-due URL as Vault secret gcal_sync_url, called by the function itself (service role) when a calendar connects. The gcal-sync cron job posts to it every ten minutes.';

revoke all on function public.set_gcal_sync_url(text) from public;
grant execute on function public.set_gcal_sync_url(text) to service_role;

-- ---------------------------------------------------------------------------
-- The dispatcher: every ten minutes, ask the function to sync stale mirrors
-- ---------------------------------------------------------------------------
-- The endpoint itself is unauthenticated but harmless: sync-due only
-- refreshes connections whose last sync is older than its cooldown, so the
-- worst an outsider can trigger is work this cron would do minutes later
-- anyway. No connections (or no URL registered yet) means no request.

create function public.gcal_sync_dispatch()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    _url text;
begin
    if not exists (
        select 1 from public.gcal_connection
        where last_synced_at is null
           or last_synced_at < now() - interval '8 minutes'
    ) then
        return;
    end if;

    select decrypted_secret into _url
    from vault.decrypted_secrets where name = 'gcal_sync_url';
    if _url is null then
        return;
    end if;

    perform net.http_post(
        url := _url,
        headers := jsonb_build_object('Content-Type', 'application/json'),
        body := '{}'::jsonb,
        timeout_milliseconds := 15000);
end;
$$;

comment on function public.gcal_sync_dispatch() is
    'Every-ten-minutes cron: posts to the gcal edge function''s sync-due endpoint (Vault secret gcal_sync_url) when any connected calendar''s mirror has gone stale. Skips quietly when nothing is connected or the URL is not registered yet.';

revoke all on function public.gcal_sync_dispatch() from public;

select cron.schedule('gcal-sync', '*/10 * * * *', 'select public.gcal_sync_dispatch()');

-- ---------------------------------------------------------------------------
-- The skill: how Syla builds a web integration
-- ---------------------------------------------------------------------------
-- Like every skill, a doc — readable in the app, editable without a
-- migration; this is only the seed.

insert into public.docs (path, title, html)
select 'skills/integrations', 'Building a web integration', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Building a web integration</title>
<style>
  body { margin: 0 auto; max-width: 42rem; padding: 2rem 1.25rem 4rem;
         font: 16px/1.6 system-ui, sans-serif; color: #1a1a1a; background: #fdfdfc; }
  h1 { font-size: 1.6rem; } h2 { font-size: 1.2rem; margin-top: 2rem; }
  code, pre { font-family: ui-monospace, monospace; background: #f0efec; border-radius: 4px; }
  code { padding: 0.1em 0.3em; } pre { padding: 0.75rem; overflow-x: auto; }
  @media (prefers-color-scheme: dark) {
    body { color: #e8e6e3; background: #16181a; }
    code, pre { background: #24272b; }
  }
</style></head>
<body>
<h1>Building a web integration</h1>
<p>The app's Integrations page renders rows from the <code>integrations</code> table — an integration is an edge function plus a registry row, never app code. When the owner asks for a new one (a service mirrored into the database), build it in this shape. The full contract with the app is in the repo: <code>notes/06-integrations.md</code>; the model to copy is <code>supabase/functions/gcal/</code> with migration <code>20261013000000_integrations.sql</code>.</p>
<h2>The shape</h2>
<ol>
<li><strong>Edge function</strong> <code>supabase/functions/&lt;slug&gt;/index.ts</code> with the four conventional POST routes the app drives: <code>/status</code> (<code>{connected, account?, last_synced_at?}</code>), <code>/connect</code>, <code>/sync</code> (honor <code>{if_stale_minutes}</code> with <code>{skipped: true}</code>), <code>/disconnect</code>. Resolve the caller from their JWT through RLS; keep tokens in a service-role-only table. Add a <code>[functions.&lt;slug&gt;]</code> entry in <code>supabase/config.toml</code>.</li>
<li><strong>Migration</strong>: the connection and mirror tables — RLS on everything, tokens unreadable by clients and revoked from the <code>claude</code> role, the mirror readable by the owner and by you. Add a pg_cron dispatcher if it should stay synced in the background (copy <code>gcal_sync_dispatch</code>).</li>
<li><strong>Register it</strong>: <code>scripts/integration-save --slug &lt;slug&gt; --title "…" --config-file config.json</code>. For kind <code>oauth_pkce</code> the config carries <code>auth_url</code>, <code>client_id</code> (a public/PKCE client — never a secret), <code>scope</code>, <code>callback_scheme</code>, <code>redirect_uri</code>, optional <code>extra_params</code>.</li>
</ol>
<h2>Boundaries</h2>
<ul>
<li>Function code and migrations only reach production by merge to <code>main</code> — put them on a branch for the owner to merge. The registry row you can save directly; the app shows it once the function is live.</li>
<li>No secret may land in the repo, the registry config, or any client-readable row. A provider that offers no PKCE/public client needs its secret in Edge Function secrets, set by the owner in the dashboard — say so instead of improvising.</li>
<li>Mirrors are read-only copies of the outside service: never write back to the provider, and never make the client compute rollups.</li>
</ul>
<p>Done looks like: the row lists on the Integrations page, connect completes from the phone, <code>/status</code> reports the account, and the mirror table fills — with every table RLS-covered and the tokens invisible to everyone but the service role.</p>
<footer>doc <code>skills/integrations</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'skills/integrations');

insert into public.doc_silos (doc_id, silo_id)
select d.id, s.id
from public.docs d
join public.silos s on s.name = 'skills'
where d.path = 'skills/integrations'
  and not exists (select 1 from public.doc_silos j
                  where j.doc_id = d.id and j.silo_id = s.id);
