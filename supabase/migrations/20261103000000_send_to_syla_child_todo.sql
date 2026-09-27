-- send_to_syla: the child todo is back, and the hosted gate stays.
--
-- 20261019000000_todo_details.sql made send_to_syla file the task as one
-- child todo of the waking event — subject as the title, the full
-- message in todo.details — so Syla closes the loop with a complete
-- proposal carrying her report in after.details, which the owner checks
-- off from the Inbox. That is what CLAUDE.md, notes/04-syla-jobs.md and
-- scripts/propose-todo-edit describe. The later hosted_trial migration
-- then `create or replace`d the function with the older body — the
-- "For Syla" manual note and no todo — to add its one real change, the
-- hosted_trial() gate. Every install that applied both has the old
-- behaviour again. This file is the merge: the child-todo body, with
-- the gate. On the hosted project the event title says who wrote in.

create or replace function public.send_to_syla(_about text, _text text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _profile    uuid;
    _owner      boolean := public.is_owner();
    _title      text;
    _local_date date := (now() at time zone 'America/New_York')::date;
    _start      time := (now() at time zone 'America/New_York')::time;
    _end        time;
    _event_id   uuid;
    _todo_id    uuid;
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

    -- The subject is the title. On the hosted project, where every
    -- profile may write in, the event says whose message it is.
    _title := btrim(_about);
    if not _owner then
        select 'Trial message from ' || coalesce(nullif(email, ''), id::text)
               || ': ' || _title
        into _title
        from public.profiles where id = _profile;
    end if;

    -- The waking, on her calendar. Pre-latched (last_fired_on) so the
    -- dispatcher's due-scan never queues it a second time; the time
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
        (_profile, left(_title, 2000), _local_date, _start, _end,
         'syla', _local_date)
    returning id into _event_id;

    -- The task: a child todo she checks off. The subject is the title;
    -- the full message rides in details.
    insert into public.todo
        (profile_id, title, start_date, event_id, details)
    values
        (_profile, btrim(_about), _local_date, _event_id, btrim(_text))
    returning id into _todo_id;

    insert into public.syla_job_runs (event_id)
    values (_event_id)
    returning id into _run_id;

    -- Fire now, the dispatcher's own way. Missing credential: leave the
    -- run queued for the every-minute dispatcher.
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
                'text', 'Someone just sent you a task ("' || btrim(_about)
                        || '"). Claim as usual — the run''s event has one '
                        || 'child todo, and that todo''s details column '
                        || 'holds the full message; the event''s profile '
                        || 'says whose it is. Do the task, then file a '
                        || 'complete proposal on the todo with your report '
                        || 'in after.details (scripts/propose-todo-edit '
                        || '--kind complete); the owner checks it off from '
                        || 'the Inbox.'),
            timeout_milliseconds := 15000);

        update public.syla_job_runs
        set fired_at = now(), fire_count = fire_count + 1, fire_request_id = _req
        where id = _run_id;
        _fired := true;
    end if;

    return jsonb_build_object('run_id', _run_id, 'event_id', _event_id,
                              'todo_id', _todo_id, 'fired', _fired);
end;
$$;

comment on function public.send_to_syla(text, text) is
    'The app''s send-to-Syla: a pre-latched one-off Syla event (the waking, on her calendar) with one child todo (the task — subject as title, message in details), its run queued and the routine webhook fired inline with the Vault credential; the client never holds the token. Owner-only on a personal install; every signed-in profile on the hosted-trial project (vault flag hosted_trial), whose event title then names the sender. Without a stored credential the run waits for the every-minute dispatcher. She closes the loop with a complete proposal carrying her report in after.details.';

revoke all on function public.send_to_syla(text, text) from public;
revoke all on function public.send_to_syla(text, text) from anon;
grant execute on function public.send_to_syla(text, text) to authenticated;
