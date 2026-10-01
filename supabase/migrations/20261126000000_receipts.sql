-- Receipts: the Syla thread tells the truth about delivery.
--
-- The Syla conversation shows a receipt ladder for each send, and every
-- rung is a recorded fact, never an inference:
--
--   Sent           syla_job_runs.queued_at    — the run exists
--   Delivered      syla_job_runs.delivered_at — the fire webhook answered 2xx
--   Syla's reading syla_job_runs.started_at   — a session claimed the run
--   (reply)        a chat_messages row with syla_run_id = the run
--
-- "Delivered" is new. pg_net answers asynchronously — net.http_post only
-- returns a request id — so the dispatcher could never know the result in
-- the tick that fired. The response does land, though, in
-- net._http_response under that id. This migration stores the id's
-- outcome: each tick, runs whose fire request has a 2xx response get
-- delivered_at stamped. The dispatcher runs every minute, so delivery
-- confirmation lags a fire by at most about a minute; pg_net prunes its
-- response table after a few hours, so a response that was never seen in
-- that window simply leaves delivered_at null — the ladder shows Sent,
-- which is the truth available. "Reading" is NEVER inferred from the
-- webhook (a 2xx means the routine service took the request, nothing
-- more); only a claim moves the ladder past Delivered — the
-- syla_job_runs queue is the source of truth, as everywhere.
--
-- send_to_syla's inline fire needs no change: it stamps fired_at and
-- fire_request_id the dispatcher's own way, so the next tick's marking
-- pass covers its runs exactly like dispatcher-fired ones.

alter table public.syla_job_runs
    add column delivered_at timestamptz;

comment on column public.syla_job_runs.delivered_at is
    'When the fire webhook''s 2xx response was observed (stamped by the dispatcher from net._http_response, so it can lag the fire by a tick). The Delivered rung of the Syla-thread receipt ladder; null means no 2xx was seen. Says nothing about a session reading the run — started_at is that.';

-- The dispatcher, 20261124000000's body plus the delivery-marking pass.

create or replace function public.syla_dispatch()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    _now        timestamptz := now();
    _local_time time := (now() at time zone 'America/New_York')::time;
    _local_date date := (now() at time zone 'America/New_York')::date;
    _to_fire    uuid[];
    _names      text;
    _url        text;
    _token      text;
    _req        bigint;
    _cs         record;
    _due        boolean;
    _slot       time;
begin
    -- Mark fires the webhook acknowledged since the last tick: a 2xx on
    -- the stored request id is Delivered.
    update public.syla_job_runs r
    set delivered_at = coalesce(resp.created, _now)
    from net._http_response resp
    where r.fired_at is not null
      and r.delivered_at is null
      and r.fire_request_id = resp.id
      and resp.status_code between 200 and 299;

    -- Queue newly due events, latching last_fired_on in the same statement.
    with due as (
        update public.events e
        set last_fired_on = _local_date
        where e.assignee = 'syla'
          and e.start_time <= _local_time
          and (e.last_fired_on is null or e.last_fired_on < _local_date)
          and (e.until_date is null or e.until_date >= _local_date)
          and case
                when e.freq is null then e.start_date = _local_date
                when e.freq = 'daily' and e.interval_n = 1
                  then e.start_date <= _local_date
                when e.freq = 'weekly' and e.interval_n = 1
                  then e.start_date <= _local_date
                   and extract(dow from _local_date)::smallint
                       = any (coalesce(e.byweekday, array[]::smallint[]))
                else false
              end
          and not exists (
              select 1 from public.event_exclusion x
              where x.event_id = e.id and x.day = _local_date
          )
        returning e.id
    )
    insert into public.syla_job_runs (event_id)
    select id from due;

    -- The chute branch: a due cadence with raw items queues a run of the
    -- (forever-pre-latched) Chute sort event and stamps the latch.
    for _cs in
        select cs.profile_id, cs.cadence, cs.daily_time, cs.last_sorted_at,
               e.id as event_id
        from public.chute_settings cs
        join public.events e
          on e.profile_id = cs.profile_id
         and e.assignee = 'syla'
         and e.title = 'Chute sort'
        where exists (select 1 from public.chute_items ci
                      where ci.profile_id = cs.profile_id
                        and ci.status = 'raw')
    loop
        if _cs.cadence = 'hourly' then
            _due := _cs.last_sorted_at is null
                    or _cs.last_sorted_at <= _now - interval '1 hour';
        elsif _cs.cadence = 'thrice' then
            select max(t) into _slot
            from unnest(array[time '09:00', time '13:00', time '18:00']) as t
            where t <= _local_time;
            _due := _slot is not null
                    and (_cs.last_sorted_at is null
                         or (_cs.last_sorted_at at time zone 'America/New_York')
                            < _local_date + _slot);
        else
            _due := _local_time >= _cs.daily_time
                    and (_cs.last_sorted_at is null
                         or (_cs.last_sorted_at at time zone 'America/New_York')
                            < _local_date + _cs.daily_time);
        end if;

        if _due then
            insert into public.syla_job_runs (event_id)
            values (_cs.event_id);
            update public.chute_settings
            set last_sorted_at = _now
            where profile_id = _cs.profile_id;
        end if;
    end loop;

    -- A claimed run that never reported back: fail it so it shows in the app.
    update public.syla_job_runs
    set status = 'failed', finished_at = _now,
        summary = 'Timed out: a session claimed this run but never finished it.'
    where status = 'running' and started_at < _now - interval '2 hours';

    -- A queued run the webhook could not get claimed after three fires.
    update public.syla_job_runs
    set status = 'failed', finished_at = _now,
        summary = 'The webhook fired three times but no session claimed the run.'
    where status = 'queued' and fire_count >= 3
      and fired_at < _now - interval '20 minutes';

    -- Fire the routine once for everything still queued that has not been
    -- fired recently. One session handles the whole batch.
    select array_agg(r.id), string_agg(distinct e.title, ', ')
    into _to_fire, _names
    from public.syla_job_runs r
    join public.events e on e.id = r.event_id
    where r.status = 'queued'
      and (r.fired_at is null or r.fired_at < _now - interval '20 minutes');

    if _to_fire is null then
        return;
    end if;

    select decrypted_secret into _url
    from vault.decrypted_secrets where name = 'syla_webhook_url';
    select decrypted_secret into _token
    from vault.decrypted_secrets where name = 'syla_webhook_token';

    -- No credential yet: leave the runs queued, where the tab shows them.
    if _url is null or _token is null then
        return;
    end if;

    _req := net.http_post(
        url := _url,
        headers := jsonb_build_object(
            'Authorization',     'Bearer ' || _token,
            'anthropic-version', '2023-06-01',
            'anthropic-beta',    'experimental-cc-routine-2026-04-01',
            'Content-Type',      'application/json'),
        body := jsonb_build_object(
            'text', 'Queued Syla events: ' || _names
                    || '. The syla_job_runs queue is the source of truth. '
                    || 'Each run points at an events row assigned to you: do '
                    || 'what the event says — the row, its child todos '
                    || '(todo.event_id) and its attached docs (event_docs -> '
                    || 'docs) together are the instructions.'),
        timeout_milliseconds := 15000);

    update public.syla_job_runs
    set fired_at = _now, fire_count = fire_count + 1, fire_request_id = _req
    where id = any (_to_fire);
end;
$$;
