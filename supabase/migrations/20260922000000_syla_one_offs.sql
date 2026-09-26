-- One-off Syla jobs: a job that runs once on a date, like a calendar event.
--
-- run_on null keeps today's behavior — the job repeats on days_of_week at
-- fire_at. run_on set makes the job a one-off: it fires exactly once, on
-- that UTC date at fire_at, and then sits inert (the last_fired_on latch
-- has fired, and a past run_on can never match the dispatcher again). The
-- app shows one-offs on their date in the Syla jobs calendar and lets the
-- owner reschedule or delete them like any event.

alter table public.syla_jobs add column run_on date;

comment on column public.syla_jobs.run_on is
    'Null: the job repeats on days_of_week. Set: a one-off that fires once on this UTC date at fire_at (days_of_week is ignored).';

-- Roughly how long the job takes, so the calendar can draw it as an event
-- block of about the right height. Advisory only — the dispatcher never
-- reads it; nothing enforces that a run finishes within it. The app clamps
-- the drawn height to a floor so short jobs stay legible.
alter table public.syla_jobs
    add column est_minutes integer not null default 15
        check (est_minutes between 1 and 1440);

comment on column public.syla_jobs.est_minutes is
    'Rough expected duration in minutes, for drawing the job as a calendar block. Advisory: the dispatcher ignores it.';

-- The latch also resets when a one-off is rescheduled.
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
                  or new.run_on is distinct from old.run_on
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

-- The dispatcher: a one-off is due only on its own date; a repeating job
-- on its selected days. Everything else is unchanged from 20260921.
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
          and case when run_on is not null
                   then run_on = _utc_date
                   else extract(dow from _utc_date)::integer = any (days_of_week)
              end
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
