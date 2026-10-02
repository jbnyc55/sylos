-- Thrice shows as three events, not one long band.
--
-- 20261206000000 mirrored the cadence onto the single Chute sort
-- event, and for '3× a day' that meant one 09:00–18:00 block — honest
-- about the span, wrong about the shape. The mirror now keeps one
-- CANONICAL Chute sort event (the oldest — the one runs point at and
-- the dispatcher fires) plus display SATELLITES: thrice is three
-- 15-minute blocks at 09:00, 13:00 and 18:00; daily and hourly are
-- one block as before. Satellites are ordinary pre-latched-forever
-- Chute sort events the cadence trigger creates and deletes; they
-- never carry runs, and the dispatcher's chute branch now picks the
-- canonical row explicitly so extra same-titled events can never
-- double-queue a sort.

-- ── The mirror, as one helper both the trigger and backfills call ────────

create or replace function public.chute_mirror_events(_profile uuid)
returns void
language plpgsql
set search_path = ''
as $$
declare
    _cs     record;
    _canon  uuid;
    _start  time;
    _end    time;
begin
    select cadence, daily_time into _cs
    from public.chute_settings where profile_id = _profile;
    if _cs is null then return; end if;

    select id into _canon
    from public.events
    where profile_id = _profile and assignee = 'syla' and title = 'Chute sort'
    order by created_at asc
    limit 1;
    if _canon is null then return; end if;

    -- Satellites from the previous cadence go; thrice re-creates its two.
    delete from public.events
    where profile_id = _profile and assignee = 'syla' and title = 'Chute sort'
      and id <> _canon;

    if _cs.cadence = 'daily' then
        _start := coalesce(_cs.daily_time, time '15:00');
        if _start >= time '23:30' then
            _end := time '23:59:59';
        else
            _end := _start + interval '30 minutes';
        end if;
    elsif _cs.cadence = 'thrice' then
        _start := time '09:00';
        _end   := time '09:15';
        insert into public.events
            (profile_id, title, assignee, start_date, start_time, end_time,
             freq, interval_n)
        values
            (_profile, 'Chute sort', 'syla',
             (now() at time zone 'America/New_York')::date,
             time '13:00', time '13:15', 'daily', 1),
            (_profile, 'Chute sort', 'syla',
             (now() at time zone 'America/New_York')::date,
             time '18:00', time '18:15', 'daily', 1);
    else -- hourly
        _start := time '00:00';
        _end   := time '23:59:59';
    end if;

    update public.events
    set start_time = _start, end_time = _end
    where id = _canon
      and (start_time is distinct from _start or end_time is distinct from _end);

    -- Re-pin every Chute sort row's forever-latch (the reset-latch
    -- trigger fires on the retime and the inserts): the chute branch
    -- stays the only dispatcher, satellites included.
    update public.events
    set last_fired_on = date '9999-12-31'
    where profile_id = _profile and assignee = 'syla' and title = 'Chute sort'
      and last_fired_on is distinct from date '9999-12-31';
end;
$$;

comment on function public.chute_mirror_events(uuid) is
    'Syncs the Chute sort calendar display to chute_settings: the canonical (oldest) event wears the cadence''s first block, thrice adds two 15-minute satellites (13:00, 18:00), and every row is re-pinned to the forever-latch. Satellites are display only — runs and the dispatcher use the canonical row alone.';

-- The cadence trigger becomes a thin call to the helper.
create or replace function public.chute_settings_mirror_event()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    perform public.chute_mirror_events(new.profile_id);
    return new;
end;
$$;

-- ── The dispatcher pins the chute branch to the canonical event ──────────
--
-- 20261202000000's body; the one change is the chute loop's event
-- lookup — a scalar pick of the oldest Chute sort row instead of a
-- title join, so satellite events can never multiply the loop.

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
    -- (forever-pre-latched) CANONICAL Chute sort event and stamps the
    -- latch. The oldest row is the canonical one; satellites are display.
    for _cs in
        select cs.profile_id, cs.cadence, cs.daily_time, cs.last_sorted_at,
               (select e.id from public.events e
                where e.profile_id = cs.profile_id
                  and e.assignee = 'syla'
                  and e.title = 'Chute sort'
                order by e.created_at asc
                limit 1) as event_id
        from public.chute_settings cs
        where exists (select 1 from public.chute_items ci
                      where ci.profile_id = cs.profile_id
                        and ci.status = 'raw')
    loop
        if _cs.event_id is null then
            continue;
        end if;
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
    select array_agg(r.id),
           string_agg(distinct coalesce(e.title, 'a message from the owner'), ', ')
    into _to_fire, _names
    from public.syla_job_runs r
    left join public.events e on e.id = r.event_id
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
            'text', 'Queued Syla work: ' || _names
                    || '. The syla_job_runs queue is the source of truth. '
                    || 'A run with an event: do what the event says — the '
                    || 'row, its child todos (todo.event_id) and its '
                    || 'attached docs (event_docs -> docs) together are '
                    || 'the instructions. A run with no event is a '
                    || 'message from the owner: the claim''s message '
                    || 'field carries it — decide whether it deserves '
                    || 'calendar/todo entries (propose_todo_edit) or '
                    || 'only a reply (syla_chat_say).'),
        timeout_milliseconds := 15000);

    update public.syla_job_runs
    set fired_at = _now, fire_count = fire_count + 1, fire_request_id = _req
    where id = any (_to_fire);
end;
$$;

-- ── Backfill: every install's display catches up with its cadence ────────

select public.chute_mirror_events(profile_id) from public.chute_settings;
