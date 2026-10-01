-- The hosted trial retires; send_to_syla writes the thread.
--
-- Setup is own-Claude only now (the desktop web flow at getsylos.com/setup
-- — notes/02-setup.md), so the hosted-trial machinery leaves the schema:
-- send_to_syla goes back to owner-only, the "Trial message from" titling
-- goes with it, and hosted_trial() is dropped. The vault flag was never
-- set anywhere but the long-gone shared trial project; on every personal
-- install this changes nothing observable.
--
-- One addition while the function is open: the Syla conversation (chats
-- kind 'syla', 20261121000000) is the record of talking to her, so the
-- send itself now lands there too — the owner's message as a chat_messages
-- row (author 'me', kind 'text') pointing at the queued run through
-- syla_run_id. That link is what the thread's receipt ladder
-- (20261126000000) hangs off; her reply arrives through syla_chat_say
-- pointing at the same run. The event + child todo stay exactly as they
-- were (the todo's complete-proposal loop is unchanged); the thread is a
-- second, immediate view of the same send. Body otherwise 20261107000000's.

create or replace function public.send_to_syla(_about text, _text text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _profile    uuid;
    _local_date date := (now() at time zone 'America/New_York')::date;
    _start      time := date_trunc('minute', now() at time zone 'America/New_York')::time;
    _end        time;
    _event_id   uuid;
    _todo_id    uuid;
    _run_id     uuid;
    _chat_id    uuid;
    _url        text;
    _token      text;
    _req        bigint;
    _fired      boolean := false;
begin
    if not public.is_owner() then
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

    -- The waking, on her calendar. Pre-latched (last_fired_on) so the
    -- dispatcher's due-scan never queues it a second time; the time
    -- block starts on the minute (a clock time, not a timestamp) and is
    -- clamped at midnight to keep end_time > start_time.
    if _start >= time '23:45' then
        _end := time '23:59:59';
    else
        _end := _start + interval '15 minutes';
    end if;

    insert into public.events
        (profile_id, title, start_date, start_time, end_time,
         assignee, last_fired_on)
    values
        (_profile, left(btrim(_about), 2000), _local_date, _start, _end,
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

    -- The thread's record of the send: the message in the Syla
    -- conversation, linked to its run for the receipt ladder. A database
    -- without the seeded chat (it should not exist) just skips this.
    select id into _chat_id from public.chats where kind = 'syla' limit 1;
    if _chat_id is not null then
        insert into public.chat_messages (chat_id, body, author, kind, syla_run_id)
        values (_chat_id, btrim(_text), 'me', 'text', _run_id);
    end if;

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
                'text', 'The owner just sent you a task ("' || btrim(_about)
                        || '"). Claim as usual — the run''s event has one '
                        || 'child todo, and that todo''s details column '
                        || 'holds the full message. Do the task, then file '
                        || 'a complete proposal on the todo with your '
                        || 'report in after.details (scripts/propose-todo-edit '
                        || '--kind complete), and answer in the Syla '
                        || 'conversation with syla_chat_say, citing the run.'),
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
    'The app''s send-to-Syla: a pre-latched one-off Syla event (the waking, on her calendar) with one child todo (the task — subject as title, message in details), the message mirrored into the Syla conversation linked to its run (the thread''s receipt ladder), the run queued and the routine webhook fired inline with the Vault credential — the client never holds the token. Owner only. Without a stored credential the run waits for the every-minute dispatcher. She closes the loop with a complete proposal carrying her report in after.details, and a syla_chat_say reply citing the run.';

revoke all on function public.send_to_syla(text, text) from public;
revoke all on function public.send_to_syla(text, text) from anon;
grant execute on function public.send_to_syla(text, text) to authenticated;

-- The trial's one schema knob goes with the trial.
drop function public.hosted_trial();
