-- Syla jobs get day-of-week schedules.
--
-- 20260920000000 shipped jobs as strictly daily. This adds the other half
-- of a cron-style schedule the owner can edit in the app: which days of the
-- week the job fires. days_of_week uses JS getDay numbers (0=Sun … 6=Sat),
-- the same convention as todo.byweekday, and is judged against the UTC
-- date, matching the UTC fire_at — the app converts both to and from local
-- time together, rotating the day set when the conversion crosses midnight.

alter table public.syla_jobs
    add column days_of_week integer[] not null default '{0,1,2,3,4,5,6}'
        check (days_of_week <@ array[0,1,2,3,4,5,6]
               and cardinality(days_of_week) between 1 and 7);

comment on column public.syla_jobs.days_of_week is
    'Which days the job fires, as JS getDay numbers (0=Sun … 6=Sat) judged against the UTC date. Default: every day.';

-- The once-a-day latch also resets when the day set changes.
create or replace function public.syla_jobs_reset_latch()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    _reset boolean;
begin
    if tg_op = 'INSERT' then
        _reset := true;
    else
        _reset := new.fire_at is distinct from old.fire_at
                  or new.days_of_week is distinct from old.days_of_week
                  or (new.enabled and not old.enabled);
    end if;

    if _reset then
        new.last_fired_on := case
            when new.fire_at <= ((now() at time zone 'utc')::time)
            then (now() at time zone 'utc')::date
        end;
    end if;
    return new;
end;
$$;

-- The dispatcher queues a job only on its selected days. Everything else —
-- the retry, timeout and webhook mechanics — is unchanged from 20260920.
create or replace function public.syla_dispatch()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    _now      timestamptz := now();
    _utc_time time := (now() at time zone 'utc')::time;
    _utc_date date := (now() at time zone 'utc')::date;
    _to_fire  uuid[];
    _names    text;
    _url      text;
    _token    text;
    _req      bigint;
begin
    -- Queue newly due jobs, latching last_fired_on in the same statement.
    with due as (
        update public.syla_jobs
        set last_fired_on = _utc_date
        where enabled
          and extract(dow from _utc_date)::integer = any (days_of_week)
          and fire_at <= _utc_time
          and (last_fired_on is null or last_fired_on < _utc_date)
        returning id
    )
    insert into public.syla_job_runs (job_id)
    select id from due;

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
    select array_agg(r.id), string_agg(distinct j.name, ', ')
    into _to_fire, _names
    from public.syla_job_runs r
    join public.syla_jobs j on j.id = r.job_id
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
            'text', 'Queued Syla jobs: ' || _names
                    || '. The syla_job_runs queue is the source of truth.'),
        timeout_milliseconds := 15000);

    update public.syla_job_runs
    set fired_at = _now, fire_count = fire_count + 1, fire_request_id = _req
    where id = any (_to_fire);
end;
$$;
