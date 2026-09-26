-- Send to Syla, immediately: one RPC turns the app's "send to Syla"
-- into a fired session instead of a note that waits for her next
-- scheduled run.
--
-- Before this, sendToSyla wrote a "For Syla — …" manual note that only
-- a scheduled event's run would ever read. Now the app calls
-- send_to_syla(), which does the whole thing server-side:
--
--   1. writes the same "For Syla — …" manual note (the message itself),
--   2. creates a one-off event assigned to Syla, pre-latched so the
--      dispatcher never re-queues it — the calendar shows the send as a
--      block on her day, and the claim hands her a title that says
--      where to look,
--   3. queues the syla_job_runs row, and
--   4. fires the routine webhook inline, exactly as the dispatcher
--      does, with the credential from Vault.
--
-- The client never holds the fire token: it lives in Vault, and this
-- SECURITY DEFINER function is the only extra reader. Owner-gated —
-- members and guests hold authenticated sessions too, and poking the
-- agent is not theirs to do. If the webhook credential isn't stored
-- yet, the run stays queued and the every-minute dispatcher delivers
-- it as soon as the credential lands.

create or replace function public.send_to_syla(_about text, _text text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _profile    uuid;
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
         'Owner message — read the latest ''For Syla'' note: ' || btrim(_about),
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
                'text', 'The owner just sent you a message ("' || btrim(_about)
                        || '"). The syla_job_runs queue is the source of '
                        || 'truth: claim it as usual — the run''s event and '
                        || 'the newest ''For Syla'' manual note carry the '
                        || 'message.'),
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
    'The app''s send-to-Syla, delivered immediately: writes the For-Syla note, creates a pre-latched one-off Syla event, queues its run, and fires the routine webhook inline from the Vault credential — the client never holds the token. Owner-only; without a stored credential the run waits for the every-minute dispatcher.';

revoke all on function public.send_to_syla(text, text) from public;
revoke all on function public.send_to_syla(text, text) from anon;
grant execute on function public.send_to_syla(text, text) to authenticated;
