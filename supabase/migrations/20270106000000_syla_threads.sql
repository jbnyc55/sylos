-- Named Syla threads.
--
-- The Mac app's sidebar holds several conversations with Syla, not
-- one: any owner client may now create additional chats rows with
-- kind = 'syla' (the owner policy already allows the insert; the
-- kind check has allowed 'syla' since chat_first). What was missing
-- was routing: send_to_syla always wrote into the first syla chat,
-- and syla_chat_say always answered there. Now the send takes an
-- optional thread and the reply follows the run's own message home.
-- Clients that never pass a thread (the iPhone) behave exactly as
-- before: the oldest syla chat is the default, seeded on demand.

-- ── send_to_syla: an optional thread ─────────────────────────────────────
-- Dropped, not replaced in place: keeping both arities would make
-- the PostgREST call ambiguous. The two-argument call shape still
-- works against this one through the default.

drop function public.send_to_syla(text, text);

create function public.send_to_syla(_about text, _text text, _chat_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _profile uuid;
    _run_id  uuid;
    _chat    uuid;
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

    -- The thread: the one the caller names (it must be a Syla
    -- conversation), else the oldest syla chat, seeded on demand.
    if _chat_id is not null then
        select id into _chat from public.chats
        where id = _chat_id and kind = 'syla';
        if _chat is null then
            raise exception 'that chat is not a Syla conversation';
        end if;
    else
        select id into _chat from public.chats
        where kind = 'syla' order by created_at asc limit 1;
        if _chat is null then
            insert into public.chats (chat_key, kind, title)
            values ('syla-chat', 'syla', 'Syla')
            returning id into _chat;
        end if;
    end if;

    insert into public.syla_job_runs (event_id)
    values (null)
    returning id into _run_id;

    insert into public.chat_messages (chat_id, body, author, kind, syla_run_id)
    values (_chat, btrim(_text), 'me', 'text', _run_id);

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

    return jsonb_build_object('run_id', _run_id, 'fired', _fired, 'chat_id', _chat);
end;
$$;

comment on function public.send_to_syla(text, text, uuid) is
    'The app''s send-to-Syla, thread-aware: the owner''s message lands in the named Syla thread (or the oldest one — the default conversation) linked to a queued event-less run, and the webhook fires inline with the Vault credential. Owner only; _chat_id must be a kind=syla chat. Without a stored credential the run waits for the every-minute dispatcher.';

revoke all on function public.send_to_syla(text, text, uuid) from public;
revoke all on function public.send_to_syla(text, text, uuid) from anon;
grant execute on function public.send_to_syla(text, text, uuid) to authenticated;

-- ── syla_chat_say: the reply follows the run home ────────────────────────

create or replace function public.syla_chat_say(_body text, _run_id uuid default null)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _chat uuid;
    _id   uuid;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    if _body is null or char_length(btrim(_body)) not between 1 and 8000 then
        raise exception 'the message must be 1–8000 characters';
    end if;

    -- The thread the run's own message lives in; a run without one
    -- (or no run cited) answers in the default Syla conversation.
    if _run_id is not null then
        select chat_id into _chat from public.chat_messages
        where syla_run_id = _run_id and author = 'me'
        order by created_at asc limit 1;
    end if;
    if _chat is null then
        select id into _chat from public.chats
        where kind = 'syla' order by created_at asc limit 1;
    end if;
    if _chat is null then
        raise exception 'this database has no Syla conversation yet (chats kind = syla)';
    end if;

    insert into public.chat_messages (chat_id, body, author, kind, syla_run_id)
    values (_chat, btrim(_body), 'syla', 'text', _run_id)
    returning id into _id;

    return jsonb_build_object('id', _id, 'chat_id', _chat);
end;
$$;

comment on function public.syla_chat_say(text, uuid) is
    'Syla''s message to the owner, thread-aware: it lands in the thread whose message queued the cited run, else in the default Syla conversation. Author ''syla'', kind ''text''. Gated by assert_claude_rq_key().';

revoke all on function public.syla_chat_say(text, uuid) from public;
grant execute on function public.syla_chat_say(text, uuid) to anon;
