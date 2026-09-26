-- Todo details, and send-to-Syla as a task she checks off.
--
-- The model settles as: the EVENT represents the waking (why and when
-- her routine fired — every run subject is an event, on her calendar),
-- and TODOS are the tasks inside it. So:
--
-- 1. todo.details — a free text body under the title. The composer
--    edits it; a send to Syla carries the full message in it; and when
--    Syla finishes, her report is appended here (the app writes it as a
--    "— Syla:" section when the owner approves her complete proposal,
--    keeping the original ask above it).
--
-- 2. send_to_syla() creates work she checks off, not a note she reads:
--    the pre-latched one-off event on her calendar (the send's visible
--    record) gains a CHILD TODO whose title is the subject and whose
--    details hold the message. Today draws it as an unchecked item
--    inside her event block — so the Syla toggle shows and hides it
--    with the rest of hers — and closing the loop is her filing a
--    complete proposal with her report in after.details, which the
--    owner approves from the Inbox. The manual "For Syla" note is
--    gone: the todo IS the message.

alter table public.todo add column details text
    check (details is null or char_length(details) <= 8000);

comment on column public.todo.details is
    'Free text under the title: what the todo is really about. A send to Syla puts the owner''s message here; her completion report is appended as a "— Syla:" section when her complete proposal is approved.';

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
    _todo_id    uuid;
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
        (_profile, btrim(_about), _local_date, _start, _end,
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
                'text', 'The owner just sent you a task ("' || btrim(_about)
                        || '"). Claim as usual — the run''s event has one '
                        || 'child todo, and that todo''s details column '
                        || 'holds the full message. Do the task, then file '
                        || 'a complete proposal on the todo with your '
                        || 'report in after.details (scripts/'
                        || 'propose-todo-edit --kind complete); the owner '
                        || 'checks it off from the Inbox.'),
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
    'The app''s send-to-Syla: a pre-latched one-off Syla event (the waking, on her calendar) with one child todo (the task — subject as title, message in details), its run queued and the routine webhook fired inline with the Vault credential; the client never holds the token. Owner-only; without a stored credential the run waits for the every-minute dispatcher. She closes the loop with a complete proposal carrying her report in after.details.';

revoke all on function public.send_to_syla(text, text) from public;
revoke all on function public.send_to_syla(text, text) from anon;
grant execute on function public.send_to_syla(text, text) to authenticated;
