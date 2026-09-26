-- Syla jobs: the app takes over scheduling the agent's routines.
--
-- Until now each routine lived in Anthropic's scheduler (claude.ai/code
-- Routines), one cron per routine, with its instructions checked into this
-- repo under .claude/skills/. This migration moves the schedule into the
-- database, where the owner controls it from the app's Syla jobs tab:
--
--   syla_jobs      one row per job: a name, a daily fire time (UTC), and
--                   the doc (tagged `syla`) that holds the instructions.
--                   Owner-managed in the app; claude reads only.
--   syla_job_runs  the queue and the history. A pg_cron dispatcher inserts
--                   a queued row when a job comes due, then fires ONE
--                   generic Anthropic routine over HTTPS (pg_net) whose
--                   whole prompt is "claim your queued runs and do what
--                   each run's doc says". The session claims runs through
--                   claim_syla_runs() and reports back through
--                   finish_syla_run().
--
-- The webhook credential (the routine's fire URL and its sk-ant-oat01
-- bearer token) lives in Vault, never in this repo. set_syla_webhook()
-- stores it, gated by the same rq key as every other claude write path;
-- the URL is constrained to the Anthropic routines endpoint so the rq key
-- can never redirect the bearer token to a foreign host.
--
-- Failure modes are chosen to be visible rather than silent: a missing
-- Vault secret leaves runs sitting 'queued' in the tab; an unclaimed run
-- is re-fired at most twice more, 20 minutes apart, then marked failed; a
-- claimed run that never finishes is failed after two hours.

-- ---------------------------------------------------------------------------
-- Extensions: pg_cron (the every-minute dispatcher) and pg_net (async HTTPS)
-- ---------------------------------------------------------------------------
-- Both ship with Supabase (hosted and the local dev image); this only
-- switches them on for this database.

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Neither extension is for clients. pg_net especially: an app role that can
-- call net.http_post can make the database issue arbitrary requests. Only
-- the dispatcher (below, running as the migration owner via pg_cron) needs
-- it. Revokes are no-ops for grants that don't exist, so this is cheap
-- insurance across pg_net versions with different defaults.
revoke usage on schema net from public, anon, authenticated;
revoke all on all functions in schema net from public, anon, authenticated;
revoke usage on schema cron from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- syla_jobs
-- ---------------------------------------------------------------------------

create table public.syla_jobs (
    id            uuid primary key default gen_random_uuid(),
    profile_id    uuid not null references public.profiles (id) on delete cascade,
    name          text not null check (char_length(name) between 1 and 120),
    -- The instructions. A doc in the app (tag it `syla` so it shows in the
    -- job picker and so Syla's sessions treat it as hers). No cascade:
    -- deleting a doc a job still points at is refused until the job goes.
    doc_id        uuid not null references public.docs (id),
    -- Daily schedule, stored as UTC time of day. The app converts to and
    -- from the owner's local time; DST shifts the local wall time by an
    -- hour until the row is edited, which is accepted for a personal app.
    fire_at       time not null,
    enabled       boolean not null default true,
    -- The date (UTC) the job last came due, set by the dispatcher in the
    -- same transaction that queues the run — the once-a-day latch.
    last_fired_on date,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

comment on table public.syla_jobs is
    'Syla''s scheduled jobs, owner-managed from the app. Each fires daily at fire_at (UTC): the dispatcher queues a syla_job_runs row and fires the generic Anthropic routine, whose session reads the job''s doc and does what it says.';

create trigger syla_jobs_set_updated_at
    before update on public.syla_jobs
    for each row execute function public.set_updated_at();

-- A job never fires for a time already past: on creation, and whenever the
-- owner changes the time or re-enables the job, a fire_at earlier than the
-- current UTC time latches to today so the first fire is tomorrow. The
-- dispatcher's own bump of last_fired_on changes neither fire_at nor
-- enabled, so it passes through untouched.
create function public.syla_jobs_reset_latch()
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

create trigger syla_jobs_reset_latch
    before insert or update on public.syla_jobs
    for each row execute function public.syla_jobs_reset_latch();

alter table public.syla_jobs enable row level security;

grant select, insert, update, delete on public.syla_jobs to authenticated;

create policy "Syla jobs are viewable by their owner"
    on public.syla_jobs for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Syla jobs are creatable by their owner"
    on public.syla_jobs for insert
    to authenticated
    with check (profile_id = (select public.current_profile_id()));

create policy "Syla jobs are editable by their owner"
    on public.syla_jobs for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Syla jobs are deletable by their owner"
    on public.syla_jobs for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

grant select on public.syla_jobs to claude;

create policy "claude reads syla jobs"
    on public.syla_jobs for select
    to claude
    using (true);

-- ---------------------------------------------------------------------------
-- syla_job_runs — the queue and the history
-- ---------------------------------------------------------------------------

create table public.syla_job_runs (
    id              uuid primary key default gen_random_uuid(),
    job_id          uuid not null references public.syla_jobs (id) on delete cascade,
    status          text not null default 'queued'
                        check (status in ('queued', 'running', 'done', 'failed')),
    queued_at       timestamptz not null default now(),
    -- Webhook bookkeeping: when the routine was last fired for this run,
    -- how many times, and pg_net's request id for debugging a silent fire.
    fired_at        timestamptz,
    fire_count      integer not null default 0,
    fire_request_id bigint,
    started_at      timestamptz,
    finished_at     timestamptz,
    summary         text check (summary is null or char_length(summary) <= 2000)
);

comment on table public.syla_job_runs is
    'One row per firing of a syla job. Inserted ''queued'' by the dispatcher; a Syla session moves it to ''running'' via claim_syla_runs() and to ''done''/''failed'' via finish_syla_run(). The dispatcher fails runs nobody claims (3 fires, 20 minutes apart) or nobody finishes (2 hours).';

create index syla_job_runs_job_idx on public.syla_job_runs (job_id, queued_at desc);
create index syla_job_runs_open_idx on public.syla_job_runs (status)
    where status in ('queued', 'running');

alter table public.syla_job_runs enable row level security;

grant select on public.syla_job_runs to authenticated;

create policy "Syla job runs are viewable by the job's owner"
    on public.syla_job_runs for select
    to authenticated
    using (exists (
        select 1 from public.syla_jobs j
        where j.id = syla_job_runs.job_id
          and j.profile_id = (select public.current_profile_id())
    ));

-- claude claims and finishes runs through the RPCs below; inserts are the
-- dispatcher's alone (it runs as the migration owner and bypasses RLS).
grant select on public.syla_job_runs to claude;
grant update (status, started_at, finished_at, summary)
    on public.syla_job_runs to claude;

create policy "claude reads syla job runs"
    on public.syla_job_runs for select
    to claude
    using (true);

create policy "claude advances syla job runs"
    on public.syla_job_runs for update
    to claude
    using (true)
    with check (status in ('running', 'done', 'failed'));

-- ---------------------------------------------------------------------------
-- The claude write path: claim_syla_runs / finish_syla_run
-- ---------------------------------------------------------------------------
-- Same contract as every other agent write (notes/07-agent-rq-https.md):
-- gate on the Vault rq key, `set local role claude`, structured arguments.

create function public.claim_syla_runs()
returns jsonb
language plpgsql
security invoker
as $$
declare
    result jsonb;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    with claimed as (
        update public.syla_job_runs
        set status = 'running', started_at = now()
        where status = 'queued'
        returning id, job_id
    )
    select coalesce(jsonb_agg(jsonb_build_object(
               'run_id',    c.id,
               'job',       j.name,
               'doc_path',  d.path,
               'doc_title', d.title)), '[]')
    into result
    from claimed c
    join public.syla_jobs j on j.id = c.job_id
    join public.docs d on d.id = j.doc_id;

    return result;
end;
$$;

comment on function public.claim_syla_runs() is
    'Claims every queued syla job run (queued → running) as the claude role and returns them with each job''s doc path — the doc holds the instructions. Gated by assert_claude_rq_key().';

create function public.finish_syla_run(_run_id uuid, _status text, _summary text)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _id uuid;
begin
    perform public.assert_claude_rq_key();

    if _status not in ('done', 'failed') then
        raise exception 'status must be done or failed, not %', _status;
    end if;

    set local statement_timeout = '30s';
    set local role claude;

    update public.syla_job_runs
    set status = _status, finished_at = now(), summary = _summary
    where id = _run_id and status = 'running'
    returning id into _id;

    if _id is null then
        raise exception 'no running syla job run with id %', _run_id;
    end if;

    return jsonb_build_object('run_id', _id, 'status', _status);
end;
$$;

comment on function public.finish_syla_run(uuid, text, text) is
    'Marks one claimed syla job run done or failed, with a short summary, as the claude role. Gated by assert_claude_rq_key().';

revoke all on function public.claim_syla_runs() from public;
revoke all on function public.finish_syla_run(uuid, text, text) from public;
grant execute on function public.claim_syla_runs() to anon;
grant execute on function public.finish_syla_run(uuid, text, text) to anon;

-- ---------------------------------------------------------------------------
-- set_syla_webhook — store the routine's fire URL and bearer token in Vault
-- ---------------------------------------------------------------------------
-- SECURITY DEFINER solely for Vault access, mirroring assert_claude_rq_key.
-- The rq key gates it, and the URL must be the Anthropic routines endpoint:
-- whoever holds the rq key can rotate the credential or break the webhook,
-- but can never point the bearer token at a host that would capture it.

create function public.set_syla_webhook(_url text, _token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _name text;
    _value text;
    _existing uuid;
begin
    perform public.assert_claude_rq_key();

    if _url is null or _token is null then
        raise exception 'url and token are both required';
    end if;

    if _url !~ '^https://api\.anthropic\.com/v1/claude_code/routines/[A-Za-z0-9_]+/fire$' then
        raise exception 'url must be an Anthropic routine fire endpoint';
    end if;

    for _name, _value in
        select * from (values ('syla_webhook_url', _url),
                              ('syla_webhook_token', _token)) as s (n, v)
    loop
        select id into _existing from vault.secrets where name = _name;
        if _existing is null then
            perform vault.create_secret(_value, _name);
        else
            perform vault.update_secret(_existing, _value);
        end if;
    end loop;

    return jsonb_build_object('ok', true);
end;
$$;

comment on function public.set_syla_webhook(text, text) is
    'Stores the generic Syla routine''s fire URL and bearer token as Vault secrets syla_webhook_url / syla_webhook_token. Gated by assert_claude_rq_key(); the URL is pinned to api.anthropic.com so the token cannot be redirected.';

revoke all on function public.set_syla_webhook(text, text) from public;
grant execute on function public.set_syla_webhook(text, text) to anon;

-- ---------------------------------------------------------------------------
-- The dispatcher
-- ---------------------------------------------------------------------------

create function public.syla_dispatch()
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

comment on function public.syla_dispatch() is
    'Every-minute dispatcher (pg_cron): queues runs for syla jobs that have come due, fails abandoned runs, and fires the generic Syla routine webhook (pg_net, credential from Vault) for anything queued.';

revoke all on function public.syla_dispatch() from public;

select cron.schedule('syla-dispatch', '* * * * *', 'select public.syla_dispatch()');

-- ---------------------------------------------------------------------------
-- Seeds: the syla tag, and the three routines the scheduler used to own
-- ---------------------------------------------------------------------------
-- note_types stays a by-migration vocabulary for renames and removals, so
-- the new tag is seeded here. The jobs join on the docs by path — the doc
-- for each routine is saved through scripts/doc-save (data, not schema), so
-- a database without them (a fresh local reset) simply seeds no jobs.

insert into public.note_types (name, description)
select 'syla',
       'Syla''s material — docs tagged syla are the instructions her scheduled jobs run from'
where not exists (select 1 from public.note_types where name = 'syla');

insert into public.syla_jobs (profile_id, name, doc_id, fire_at)
select p.id, s.name, d.id, s.fire_at
from (values
        ('Morning day summary', 'syla/daily-summary', time '12:00'),
        ('Daily note tagging',  'syla/note-tagging',  time '11:15'),
        ('Daily edit feedback', 'syla/edit-feedback', time '11:30')
     ) as s (name, doc_path, fire_at)
join public.profiles p on p.is_owner
join public.docs d on d.path = s.doc_path
where not exists (select 1 from public.syla_jobs e where e.name = s.name);
