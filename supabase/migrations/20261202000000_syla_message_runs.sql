-- Send to Syla: the message is the run, not an event and a todo.
--
-- Until now every send manufactured a pre-latched one-off event (the
-- waking, on her calendar) with a child todo carrying the message — so
-- every DM, task or not, landed on the owner's calendar and todo list.
-- But not every message is a task: "thanks", a question, a passing
-- thought deserve no entries. The transport stops deciding. A send now
-- queues a run with NO event (`event_id` goes nullable): the message
-- row in the Syla conversation, linked through `chat_messages.
-- syla_run_id`, is the instruction, and the claim returns it as
-- `message`. SYLA decides what the message deserves: a real task gets
-- filed through her existing gated path (`propose_todo_edit` kind
-- 'add' — a todo, or a timed event for the calendar — which the owner
-- approves in the Inbox, as everything she writes), and anything else
-- gets only her reply in the thread (`syla_chat_say`, citing the run).
-- The receipt ladder is untouched: it always read the run's own
-- timestamps, never the event.
--
-- Scheduled events keep working exactly as before: a run with an
-- event_id claims and reports identically, and the dispatcher's
-- fail-safes were always status-based.

-- ── The queue: a run may carry a message instead of an event ─────────────

alter table public.syla_job_runs alter column event_id drop not null;

comment on column public.syla_job_runs.event_id is
    'The Syla event this run fires, or NULL for a send-to-Syla message run — the instruction is then the owner''s chat_messages row pointing here through syla_run_id.';

-- The select policy scoped runs through their event''s owner; an
-- event-less run is the owner''s own send, visible to the owner.
drop policy "Runs are viewable by the event's owner" on public.syla_job_runs;
create policy "Runs are viewable by the owner"
    on public.syla_job_runs for select to authenticated
    using (
        (event_id is null and (select public.is_owner()))
        or exists (
            select 1 from public.events e
            where e.id = syla_job_runs.event_id
              and e.profile_id = (select public.current_profile_id())
        )
    );

-- ── send_to_syla: queue the message, fire, nothing on the calendar ───────

create or replace function public.send_to_syla(_about text, _text text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _profile uuid;
    _run_id  uuid;
    _chat_id uuid;
    _url     text;
    _token   text;
    _req     bigint;
    _fired   boolean := false;
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

    insert into public.syla_job_runs (event_id)
    values (null)
    returning id into _run_id;

    -- The message IS the instruction: the owner's row in the Syla
    -- conversation, linked to the run. The chat is seeded by migration;
    -- a database somehow without it gets it here, since a message run
    -- without its message would be an empty waking.
    select id into _chat_id from public.chats where kind = 'syla' limit 1;
    if _chat_id is null then
        insert into public.chats (chat_key, kind, title)
        values ('syla-chat', 'syla', 'Syla')
        returning id into _chat_id;
    end if;
    insert into public.chat_messages (chat_id, body, author, kind, syla_run_id)
    values (_chat_id, btrim(_text), 'me', 'text', _run_id);

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
                'text', 'The owner just messaged you ("' || btrim(_about)
                        || '"). Claim as usual — this run has no event; '
                        || 'the claim entry''s message field carries the '
                        || 'owner''s words. It may or may not be a task: '
                        || 'read it and decide. Only real work deserves '
                        || 'entries — then file them through '
                        || 'scripts/propose-todo-edit --kind add (a todo, '
                        || 'or a timed event for the calendar; the owner '
                        || 'approves in the Inbox). A question, a note or '
                        || 'a passing thought gets no calendar or todo '
                        || 'entry at all. Either way answer in the Syla '
                        || 'conversation with syla_chat_say citing the '
                        || 'run, then finish the run.'),
            timeout_milliseconds := 15000);

        update public.syla_job_runs
        set fired_at = now(), fire_count = fire_count + 1, fire_request_id = _req
        where id = _run_id;
        _fired := true;
    end if;

    return jsonb_build_object('run_id', _run_id, 'fired', _fired);
end;
$$;

comment on function public.send_to_syla(text, text) is
    'The app''s send-to-Syla: the owner''s message lands in the Syla conversation linked to a queued event-less run (chat_messages.syla_run_id — the thread''s receipt ladder), and the routine webhook fires inline with the Vault credential; the client never holds the token. Nothing is written to the calendar or todos: Syla reads the message and decides — a real task becomes a propose_todo_edit ''add'' proposal the owner approves in the Inbox, anything else just gets her reply (syla_chat_say). Owner only. Without a stored credential the run waits for the every-minute dispatcher.';

revoke all on function public.send_to_syla(text, text) from public;
revoke all on function public.send_to_syla(text, text) from anon;
grant execute on function public.send_to_syla(text, text) to authenticated;

-- ── The claim returns the message for event-less runs ────────────────────

create or replace function public.claim_syla_runs()
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
        returning id, event_id
    )
    select coalesce(jsonb_agg(jsonb_build_object(
               'run_id',   c.id,
               'event_id', e.id,
               'event',    e.title,
               'starts',   e.start_time,
               'ends',     e.end_time,
               'message',  (
                   select m.body from public.chat_messages m
                   where m.syla_run_id = c.id and m.author = 'me'
                   order by m.created_at asc
                   limit 1),
               'docs',     coalesce((
                   select jsonb_agg(jsonb_build_object('path', d.path, 'title', d.title))
                   from public.event_docs ed
                   join public.docs d on d.id = ed.doc_id
                   where ed.event_id = e.id), '[]'::jsonb),
               'todos',    coalesce((
                   select jsonb_agg(child.title)
                   from public.todo child
                   where child.event_id = e.id), '[]'::jsonb))), '[]')
    into result
    from claimed c
    left join public.events e on e.id = c.event_id;

    return result;
end;
$$;

comment on function public.claim_syla_runs() is
    'Claims every queued Syla run (queued → running) as the claude role. An event run returns its event title, times, attached docs and child todos — the event is the instructions. A send-to-Syla run has no event: its message field carries the owner''s words (the linked Syla-conversation row), and Syla decides whether they deserve calendar/todo entries (propose_todo_edit) or only a reply. Gated by assert_claude_rq_key().';

-- ── The dispatcher names message runs honestly in the batch fire ─────────
--
-- 20261126000000's body; the only change is the fire-batch aggregation,
-- which inner-joined events and would have dropped event-less runs from
-- re-fires. Left join, with a stand-in name.

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
