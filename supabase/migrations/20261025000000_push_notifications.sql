-- Push notifications: the phone as a delivery channel, not a data source.
--
-- Everything else the system does becomes more useful when it can reach
-- the owner's pocket: Syla finishing a job, a proposal landing in the
-- Inbox, a morning brief. The shape:
--
--   push_devices  — where to deliver: APNs device tokens, registered by a
--                   signed-in session (foreground work, so no device key
--                   needed — the JWT is fine here).
--   push_queue    — what to deliver: an outbox anyone with a narrow grant
--                   may append to. Syla queues through queue_push (rq-key
--                   gated, scripts/push-send); future triggers can insert
--                   directly.
--   push function — the only holder of the APNs signing key
--                   (supabase/functions/push/, secrets in the dashboard:
--                   APNS_TEAM_ID, APNS_KEY_ID, APNS_PRIVATE_KEY). Its
--                   send-due route drains the queue; a statement trigger
--                   pokes it the moment a row is queued, and a pg_cron
--                   sweeper retries anything the poke raced past —
--                   the same Vault-pinned-URL arrangement as gcal.
--
-- An APNs device token is an address, not a credential: sending to it
-- requires the APNs key, which only the edge function's secrets hold. So
-- the tokens stay claude-readable like ordinary rows; there is nothing
-- here worth the gcal_connection treatment.

-- ---------------------------------------------------------------------------
-- push_devices — where pushes go
-- ---------------------------------------------------------------------------

create table public.push_devices (
    id           uuid primary key default gen_random_uuid(),
    profile_id   uuid not null references public.profiles (id) on delete cascade,
    -- APNs device token, hex, as the app receives it. Opaque and can
    -- rotate; re-registration upserts on it.
    apns_token   text not null unique check (apns_token ~ '^[0-9a-f]{1,400}$'),
    -- Which APNs host serves this token: 'sandbox' for Xcode builds,
    -- 'production' for TestFlight/App Store.
    environment  text not null default 'production' check (environment in ('production', 'sandbox')),
    name         text not null default '' check (char_length(name) <= 200),
    created_at   timestamptz not null default now(),
    last_seen_at timestamptz not null default now()
);

comment on table public.push_devices is
    'Phones registered for push, one row per APNs device token, upserted by register_push_device from a signed-in session. The token is an address, not a credential — delivery requires the APNs key only the push edge function holds.';

create index push_devices_profile_id_idx on public.push_devices (profile_id);

alter table public.push_devices enable row level security;

create policy "Push devices are viewable by their profile or the owner"
    on public.push_devices for select to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());
create policy "Push devices are deletable by their profile or the owner"
    on public.push_devices for delete to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());

create policy "claude reads push devices"
    on public.push_devices for select to claude using (true);

grant select, delete on public.push_devices to authenticated;
grant select on public.push_devices to claude;
-- The edge function reads tokens to deliver and deletes the ones APNs
-- reports dead. BYPASSRLS does not bypass table privileges (see
-- 20260828020000).
grant select, delete on public.push_devices to service_role;

-- ---------------------------------------------------------------------------
-- register_push_device / forget_push_device — the app's enable/disable
-- ---------------------------------------------------------------------------

create function public.register_push_device(
    _apns_token text, _environment text default 'production', _name text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _profile uuid := public.current_profile_id();
    _id      uuid;
begin
    if _profile is null then
        raise exception 'sign in before registering for push' using errcode = '28000';
    end if;
    if _apns_token is null or _apns_token !~ '^[0-9a-f]{1,400}$' then
        raise exception 'malformed APNs token';
    end if;
    if _environment not in ('production', 'sandbox') then
        raise exception 'environment must be production or sandbox (got %)', _environment;
    end if;

    -- Upsert on the token: iOS may hand the same token again (re-enable,
    -- new session) or after a restore hand it to a different account —
    -- either way the latest registration owns it.
    insert into public.push_devices as d (profile_id, apns_token, environment, name)
    values (_profile, _apns_token, _environment, left(coalesce(_name, ''), 200))
    on conflict (apns_token) do update
        set profile_id = excluded.profile_id,
            environment = excluded.environment,
            name = excluded.name,
            last_seen_at = now()
    returning id into _id;

    return jsonb_build_object('device_id', _id);
end;
$$;

comment on function public.register_push_device(text, text, text) is
    'Registers (or refreshes) the calling profile''s phone for push by its APNs device token. Called by the iOS app when notifications are enabled and on every launch after, since tokens can rotate.';

revoke all on function public.register_push_device(text, text, text) from public;
grant execute on function public.register_push_device(text, text, text) to authenticated;

create function public.forget_push_device(_apns_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _id uuid;
begin
    delete from public.push_devices
    where apns_token = _apns_token
      and profile_id = public.current_profile_id()
    returning id into _id;

    return jsonb_build_object('device_id', _id);
end;
$$;

comment on function public.forget_push_device(text) is
    'Deletes the calling profile''s registration for this APNs token — the app''s disable and sign-out path. Undelivered queue rows for the profile stay and simply have nowhere to go.';

revoke all on function public.forget_push_device(text) from public;
grant execute on function public.forget_push_device(text) to authenticated;

-- ---------------------------------------------------------------------------
-- push_queue — the outbox
-- ---------------------------------------------------------------------------

create table public.push_queue (
    id         uuid primary key default gen_random_uuid(),
    profile_id uuid not null references public.profiles (id) on delete cascade,
    title      text not null check (char_length(title) between 1 and 200),
    body       text not null default '' check (char_length(body) <= 2000),
    -- Optional deep link the app opens when the notification is tapped.
    url        text check (char_length(url) <= 500),
    created_at timestamptz not null default now(),
    attempts   integer not null default 0,
    sent_at    timestamptz,
    failed_at  timestamptz,
    last_error text
);

comment on table public.push_queue is
    'The push outbox: one row per notification to deliver, appended by queue_push (Syla, rq-key gated) and drained by the push edge function''s send-due route. sent_at/failed_at make it its own delivery log.';

create index push_queue_undelivered_idx on public.push_queue (created_at)
    where sent_at is null and failed_at is null;

alter table public.push_queue enable row level security;

create policy "Push queue rows are viewable by their profile or the owner"
    on public.push_queue for select to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());

create policy "claude reads the push queue"
    on public.push_queue for select to claude using (true);

grant select on public.push_queue to authenticated;
grant select on public.push_queue to claude;
grant select, insert, update on public.push_queue to service_role;

-- ---------------------------------------------------------------------------
-- queue_push — Syla's send (scripts/push-send)
-- ---------------------------------------------------------------------------

create function public.queue_push(
    _title text, _body text default '', _url text default null,
    _profile_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _to uuid := _profile_id;
    _id uuid;
begin
    perform public.assert_claude_rq_key();

    -- Unaddressed pushes go to the owner — the overwhelmingly common case.
    if _to is null then
        select id into _to from public.profiles where is_owner limit 1;
    end if;
    if _to is null then
        raise exception 'no recipient: pass _profile_id or crown an owner first';
    end if;

    insert into public.push_queue (profile_id, title, body, url)
    values (_to, left(_title, 200), left(coalesce(_body, ''), 2000), left(_url, 500))
    returning id into _id;

    return jsonb_build_object('queued', _id);
end;
$$;

comment on function public.queue_push(text, text, text, uuid) is
    'Queues one push notification (to the owner unless _profile_id says otherwise) — how Syla reaches the owner''s pocket. Gated by assert_claude_rq_key; delivery is the push edge function''s job, poked by trigger and swept by cron.';

revoke all on function public.queue_push(text, text, text, uuid) from public;
grant execute on function public.queue_push(text, text, text, uuid) to anon;

-- ---------------------------------------------------------------------------
-- set_push_send_url — the edge function registers its own send endpoint
-- ---------------------------------------------------------------------------
-- The gcal arrangement verbatim: service-role-only, Vault-stored, pinned
-- to a /functions/v1/push/send-due path so nothing can point the
-- dispatcher anywhere else. Registered by the function whenever its
-- status/test routes run.

create function public.set_push_send_url(_url text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _existing uuid;
begin
    if _url !~ '^https://[a-z0-9-]+\.supabase\.co/functions/v1/push/send-due$' then
        raise exception 'url must be a supabase.co /functions/v1/push/send-due endpoint';
    end if;

    select id into _existing from vault.secrets where name = 'push_send_url';
    if _existing is null then
        perform vault.create_secret(_url, 'push_send_url');
    else
        perform vault.update_secret(_existing, _url);
    end if;

    return jsonb_build_object('ok', true);
end;
$$;

comment on function public.set_push_send_url(text) is
    'Stores the push edge function''s send-due URL as Vault secret push_send_url, called by the function itself (service role). The queue trigger and the push-send cron post to it.';

revoke all on function public.set_push_send_url(text) from public;
grant execute on function public.set_push_send_url(text) to service_role;

-- ---------------------------------------------------------------------------
-- push_dispatch — poke the function while anything is undelivered
-- ---------------------------------------------------------------------------
-- send-due is unauthenticated but harmless, like gcal's: it only delivers
-- rows already queued, which the cron would do within the minute anyway.

create function public.push_dispatch()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    _url text;
begin
    if not exists (
        select 1 from public.push_queue
        where sent_at is null and failed_at is null
    ) then
        return;
    end if;

    select decrypted_secret into _url
    from vault.decrypted_secrets where name = 'push_send_url';
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

comment on function public.push_dispatch() is
    'Posts to the push edge function''s send-due endpoint (Vault secret push_send_url) while undelivered queue rows exist. Fired by the queue''s insert trigger for immediacy and by the every-minute push-send cron as the retry sweeper.';

revoke all on function public.push_dispatch() from public;

-- The poke: queued means "deliver now", not "within the minute". pg_net's
-- request goes out after commit, so the function sees the row it was
-- poked about; anything racing past is the cron's to sweep.
create function public.push_queue_poke()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.push_dispatch();
    return null;
end;
$$;

comment on function public.push_queue_poke() is
    'AFTER INSERT statement trigger on push_queue: one push_dispatch per append, so notifications go out in seconds instead of on the cron''s minute.';

revoke all on function public.push_queue_poke() from public;

create trigger push_queue_poke
    after insert on public.push_queue
    for each statement execute function public.push_queue_poke();

select cron.schedule('push-send', '* * * * *', 'select public.push_dispatch()');

-- ---------------------------------------------------------------------------
-- The skill: Syla learns to send a push
-- ---------------------------------------------------------------------------

insert into public.docs (path, title, html)
select 'skills/push', 'Sending a push notification', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Sending a push notification</title>
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
<h1>Sending a push notification</h1>
<p>You can reach the owner's phone. One command queues a notification; delivery is the push edge function's job and happens within seconds:</p>
<pre>scripts/push-send --title "Weekly review is ready" \
    --body "Three proposals are waiting in your Inbox."</pre>
<p>Optional flags: <code>--url</code> (a link the app opens when the notification is tapped) and <code>--profile</code> (a profile uuid; the owner when omitted).</p>
<h2>When to send one</h2>
<ul>
<li>A job finished with something the owner should act on — proposals filed, a report ready, a send-to-Syla answered.</li>
<li>Something time-sensitive surfaced that the owner would want interrupted for.</li>
</ul>
<p>Not for narration: routine job completions with nothing to act on need no push — the run summary already records them. One clear push beats three noisy ones.</p>
<h2>How it works, if asked</h2>
<p>Your write lands in <code>push_queue</code> (via the rq-key-gated <code>queue_push</code> RPC — trigger-logged like every write). A trigger pokes the push edge function, which signs the delivery with the APNs key only its secrets hold and sends to every phone in <code>push_devices</code> for that profile. <code>sent_at</code>/<code>failed_at</code> on the queue row tell you whether it landed; a <code>failed_at</code> with "no devices" means the owner hasn't enabled notifications in the app (profile → Integrations → Notifications).</p>
<footer>doc <code>skills/push</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'skills/push');

insert into public.doc_silos (doc_id, silo_id)
select d.id, s.id
from public.docs d
join public.silos s on s.name = 'skills'
where d.path = 'skills/push'
  and not exists (select 1 from public.doc_silos j
                  where j.doc_id = d.id and j.silo_id = s.id);
