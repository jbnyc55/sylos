-- The Mac is the default worker; the cloud takes over when it sleeps.
--
-- With the Mac app (sylos_mac) the agent loop runs on the owner's own
-- hardware: the app polls syla_job_runs and claims through the gated
-- RPCs. That leaves one hole — a closed laptop. This migration gives
-- the system what it needs to fall back to the Daytona cloud worker
-- (daytona/README.md) exactly and only while the Mac is away:
--
--   worker_presence      the Mac's heartbeat — a single row per device,
--                        stamped every poll tick through worker_heartbeat().
--                        The syla-fire edge function reads it on every
--                        webhook fire and spawns a Daytona sandbox ONLY
--                        when no local worker has been seen recently.
--                        Presence is cosmetic state in the status_note
--                        tradition (20261230000000): narration the owner
--                        watches, never a recorded fact of a run — so no
--                        row_edits trigger (it would log a row every 20s).
--
--   syla_job_runs.claimed_by   the recorded fact: which kind of worker
--                        actually claimed a run ('mac' | 'cloud' |
--                        'routine'). This is what the apps' receipt
--                        ladder shows as "on your Mac" / "in the cloud" —
--                        stamped at claim time, never inferred.
--
--   clear_syla_webhook() the off switch for the fallback: removes the
--                        Vault webhook credential, so queued runs simply
--                        wait for the Mac again (the dispatcher already
--                        treats a missing credential as "leave them
--                        queued").
--
-- The dispatcher itself does not change: it keeps firing the webhook
-- for anything queued, and the syla-fire receiver makes the Mac-or-cloud
-- call at the edge. Duplicate workers stay harmless — claims are
-- atomic and an extra worker finds an empty queue.

-- ── worker_presence ──────────────────────────────────────────────────────

create table public.worker_presence (
    device_id    text primary key,
    device_name  text,
    last_seen_at timestamptz not null default now()
);

comment on table public.worker_presence is
    'Local worker heartbeats, one row per device (the Mac app stamps its row every poll tick via worker_heartbeat()). The syla-fire edge function reads the freshest row to decide Mac vs cloud; the apps read it to show "on your Mac" / "in the cloud". Cosmetic presence, not audited — the claim stamp (syla_job_runs.claimed_by) is the recorded fact.';
comment on column public.worker_presence.device_id is
    'A stable id the device mints for itself (the Mac app keeps a UUID).';
comment on column public.worker_presence.last_seen_at is
    'The last heartbeat. Fresh (within syla-fire''s window, default 90s) means a local worker is alive and the cloud stands down.';

alter table public.worker_presence enable row level security;

create policy "The owner sees worker presence"
    on public.worker_presence for select to authenticated using (true);

create policy "claude reads worker presence"
    on public.worker_presence for select to claude using (true);
create policy "claude stamps worker presence"
    on public.worker_presence for insert to claude with check (true);
create policy "claude refreshes worker presence"
    on public.worker_presence for update to claude using (true) with check (true);

grant select on public.worker_presence to authenticated;
grant select, insert on public.worker_presence to claude;
grant update (device_name, last_seen_at) on public.worker_presence to claude;

-- ── worker_heartbeat ─────────────────────────────────────────────────────
-- The Mac app's one call per tick: stamp presence AND peek at the queue,
-- so the 20-second loop costs a single request. Gated like every claude
-- write (notes/03-agent-access.md).

create function public.worker_heartbeat(_device text, _name text default null)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _queued int;
begin
    perform public.assert_claude_rq_key();

    if _device is null or btrim(_device) = '' then
        raise exception 'a device id is required';
    end if;

    set local role claude;

    insert into public.worker_presence as wp (device_id, device_name, last_seen_at)
    values (left(btrim(_device), 64), nullif(left(btrim(coalesce(_name, '')), 80), ''), now())
    on conflict (device_id) do update
    set last_seen_at = now(),
        device_name  = coalesce(excluded.device_name, wp.device_name);

    select count(*)::int into _queued
    from public.syla_job_runs where status = 'queued';

    return jsonb_build_object('queued', _queued, 'now', now());
end;
$$;

comment on function public.worker_heartbeat(text, text) is
    'The local worker''s tick: upserts this device''s worker_presence row and returns {queued, now} so presence and the queue peek are one call. Gated by assert_claude_rq_key().';

revoke all on function public.worker_heartbeat(text, text) from public;
grant execute on function public.worker_heartbeat(text, text) to anon;

-- ── claimed_by: where a run actually ran ─────────────────────────────────

alter table public.syla_job_runs
    add column claimed_by text
        check (claimed_by in ('mac', 'cloud', 'routine'));

comment on column public.syla_job_runs.claimed_by is
    'Which kind of worker claimed this run: mac (the owner''s Mac app), cloud (a Daytona sandbox), routine (an Anthropic routine session), or null when the claimer did not say. Stamped by claim_syla_runs at claim time — the receipt ladder''s "on your Mac" / "in the cloud" is this column, never an inference.';

grant update (claimed_by) on public.syla_job_runs to claude;

-- claim_syla_runs gains an optional _worker argument. The signature
-- changes, so the old zero-argument shape goes away (two overloads
-- would make PostgREST's bare {} call ambiguous); the new default
-- keeps every existing caller working unchanged. Body otherwise
-- 20261227000000's.

drop function public.claim_syla_runs();

create function public.claim_syla_runs(_worker text default null)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _by     text;
    result  jsonb;
begin
    perform public.assert_claude_rq_key();

    _by := case when _worker in ('mac', 'cloud', 'routine') then _worker end;

    set local statement_timeout = '30s';
    set local role claude;

    with claimed as (
        update public.syla_job_runs
        set status = 'running', started_at = now(), claimed_by = _by
        where status = 'queued'
        returning id, event_id
    )
    select coalesce(jsonb_agg(jsonb_build_object(
               'run_id',   c.id,
               'event_id', e.id,
               'event',    e.title,
               'starts',   e.start_time,
               'ends',     e.end_time,
               'message',  (
                   select m.body from public.chat_messages m
                   where m.syla_run_id = c.id and m.author = 'me'
                   order by m.created_at asc
                   limit 1),
               'message_upload_id', (
                   select m.upload_id from public.chat_messages m
                   where m.syla_run_id = c.id and m.author = 'me'
                   order by m.created_at asc
                   limit 1),
               'poke', (
                   select jsonb_build_object(
                              'chat_id',    ch.id,
                              'chat_key',   ch.chat_key,
                              'chat_title', ch.title,
                              'chat_kind',  ch.kind,
                              'from',       (
                                  select jsonb_agg(distinct f.name)
                                  from public.chat_pokes p2
                                  join public.followers f on f.id = p2.follower_id
                                  where p2.run_id = c.id))
                   from public.chat_pokes p
                   join public.chats ch on ch.id = p.chat_id
                   where p.run_id = c.id
                   limit 1),
               'claim', (
                   select jsonb_build_object(
                              'follower_id', f.id,
                              'name',        f.name,
                              'connected_back',
                                  f.peer_following_id is not null
                                  or f.peer_invite_code is not null)
                   from public.follower_claims fc
                   join public.followers f on f.id = fc.follower_id
                   where fc.run_id = c.id
                   limit 1),
               'docs',     coalesce((
                   select jsonb_agg(jsonb_build_object('path', d.path, 'title', d.title))
                   from public.event_docs ed
                   join public.docs d on d.id = ed.doc_id
                   where ed.event_id = e.id), '[]'::jsonb),
               'todos',    coalesce((
                   select jsonb_agg(child.title)
                   from public.todo child
                   where child.event_id = e.id), '[]'::jsonb))), '[]')
    into result
    from claimed c
    left join public.events e on e.id = c.event_id;

    return result;
end;
$$;

comment on function public.claim_syla_runs(text) is
    'Claims every queued syla_job_runs row for this session (queued -> running) and returns the claim entries. _worker (''mac'' | ''cloud'' | ''routine'', optional) stamps claimed_by so the apps can show where a run executed. Gated by assert_claude_rq_key().';

revoke all on function public.claim_syla_runs(text) from public;
grant execute on function public.claim_syla_runs(text) to anon;

-- ── clear_syla_webhook: turn the cloud fallback off ──────────────────────
-- The dispatcher already does the right thing with no credential: runs
-- stay queued and the Mac picks them up on its next poll. So "off" is
-- simply removing the Vault pair that set_syla_webhook stored.

create function public.clear_syla_webhook()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
    perform public.assert_claude_rq_key();

    delete from vault.secrets
    where name in ('syla_webhook_url', 'syla_webhook_token');

    return jsonb_build_object('ok', true);
end;
$$;

comment on function public.clear_syla_webhook() is
    'Removes the Vault webhook credential (syla_webhook_url / syla_webhook_token), disabling every fire path: queued runs then simply wait for a local worker''s poll. The undo is set_syla_webhook(). Gated by assert_claude_rq_key().';

revoke all on function public.clear_syla_webhook() from public;
grant execute on function public.clear_syla_webhook() to anon;
