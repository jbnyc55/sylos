-- The hosted trial: a starter install that Sylos runs for many people.
--
-- The app's onboarding now opens on a choice — set up your own Sylos, or
-- try hosted Syla. The hosted side is nothing new in the schema: it is
-- an ordinary install of this starter that the Sylos company owns, with
-- Syla wired to the company's Claude, on which each trial is one more
-- profile (its own todos, notes, goals — the per-profile RLS every table
-- already has). One thing in the starter assumes a single person,
-- though: send_to_syla() is owner-only, because on a personal install
-- members and guests hold sessions too and poking the agent is not
-- theirs to do. On the hosted project every profile IS the person the
-- trial is for, and "ask Syla things" is the trial's whole point.
--
-- So: a vault flag, hosted_trial, set only on the hosted project
-- (select vault.create_secret('on', 'hosted_trial');), and send_to_syla
-- lets any signed-in profile through while it is on. Every other
-- personal install leaves the flag unset and behaves exactly as before.
-- The event Syla claims says who sent the message, so the company's
-- Syla answers the right person.

create function public.hosted_trial()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1 from vault.decrypted_secrets
        where name = 'hosted_trial' and decrypted_secret = 'on'
    )
$$;

comment on function public.hosted_trial() is
    'True on the Sylos-run hosted-trial project only (vault secret hosted_trial = on). Personal installs never set it; it widens send_to_syla to every signed-in profile, nothing else.';

revoke all on function public.hosted_trial() from public;
grant execute on function public.hosted_trial() to authenticated;

create or replace function public.send_to_syla(_about text, _text text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _profile    uuid;
    _owner      boolean := public.is_owner();
    _who        text;
    _local_date date := (now() at time zone 'America/New_York')::date;
    _start      time := (now() at time zone 'America/New_York')::time;
    _end        time;
    _event_id   uuid;
    _run_id     uuid;
    _url        text;
    _token      text;
    _req        bigint;
    _fired      boolean := false;
begin
    if not _owner and not public.hosted_trial() then
        raise exception 'only the owner can send to Syla';
    end if;
    if _about is null or char_length(btrim(_about)) not between 1 and 200 then
        raise exception 'the subject must be 1–200 characters';
    end if;
    if _text is null or char_length(btrim(_text)) not between 1 and 4000 then
        raise exception 'the message must be 1–4000 characters';
    end if;

    _profile := public.current_profile_id();
    if _profile is null then
        raise exception 'no profile for this session';
    end if;

    -- Who the message is from, for the event title: the owner on a
    -- personal install; on the hosted project, the trial account.
    if _owner then
        _who := 'Owner message';
    else
        select 'Trial message from ' || coalesce(nullif(email, ''), id::text)
        into _who
        from public.profiles where id = _profile;
    end if;

    -- 1. The message itself, in the shape her runs already read.
    insert into public.manual_notes (profile_id, body)
    values (_profile, 'For Syla — ' || btrim(_about) || E':\n' || btrim(_text));

    -- 2. The one-off event: her calendar's record of the send, and the
    -- instructions the claim hands her. Pre-latched (last_fired_on) so
    -- the dispatcher's due-scan never queues it a second time; the time
    -- block is clamped at midnight to keep end_time > start_time.
    if _start >= time '23:45' then
        _end := time '23:59:59';
    else
        _end := _start + interval '15 minutes';
    end if;

    insert into public.events
        (profile_id, title, start_date, start_time, end_time,
         assignee, last_fired_on)
    values
        (_profile,
         _who || ' — read the latest ''For Syla'' note: ' || btrim(_about),
         _local_date, _start, _end, 'syla', _local_date)
    returning id into _event_id;

    -- 3. The run she will claim.
    insert into public.syla_job_runs (event_id)
    values (_event_id)
    returning id into _run_id;

    -- 4. Fire now, the dispatcher's own way. Missing credential: leave
    -- the run queued for the every-minute dispatcher.
    select decrypted_secret into _url
    from vault.decrypted_secrets where name = 'syla_webhook_url';
    select decrypted_secret into _token
    from vault.decrypted_secrets where name = 'syla_webhook_token';

    if _url is not null and _token is not null then
        _req := net.http_post(
            url := _url,
            headers := jsonb_build_object(
                'Authorization',     'Bearer ' || _token,
                'anthropic-version', '2023-06-01',
                'anthropic-beta',    'experimental-cc-routine-2026-04-01',
                'Content-Type',      'application/json'),
            body := jsonb_build_object(
                'text', 'Someone just sent you a message ("' || btrim(_about)
                        || '"). The syla_job_runs queue is the source of '
                        || 'truth: claim it as usual — the run''s event and '
                        || 'the newest ''For Syla'' manual note carry the '
                        || 'message, and the event''s profile says whose it is.'),
            timeout_milliseconds := 15000);

        update public.syla_job_runs
        set fired_at = now(), fire_count = fire_count + 1, fire_request_id = _req
        where id = _run_id;
        _fired := true;
    end if;

    return jsonb_build_object('run_id', _run_id, 'event_id', _event_id,
                              'fired', _fired);
end;
$$;

comment on function public.send_to_syla(text, text) is
    'The app''s send-to-Syla, delivered immediately: writes the For-Syla note, creates a pre-latched one-off Syla event, queues its run, and fires the routine webhook inline from the Vault credential — the client never holds the token. Owner-only on a personal install; every signed-in profile on the hosted-trial project (vault flag hosted_trial). Without a stored credential the run waits for the every-minute dispatcher.';
