-- Chat attachments: a message can carry a file.
--
-- The drop drawer already captures photos, files and voice as rows in
-- the content-addressed uploads store; the chat composers now stage the
-- same captures, so a message is text, an attachment, or both. The
-- shape mirrors the chute exactly:
--
--   * upload_id on chat_messages — the client creates the uploads row
--     at send time (hash-first, deduped) and the message references it.
--     One per message, like one per drop.
--   * The body check relaxes: a captionless attachment sends with an
--     empty body (the attachment is the message). Text-only messages
--     still need words.
--   * send_to_syla grows an optional _upload_id, validated as the
--     owner's own upload, so the Syla conversation attaches like any
--     other chat; the claim returns it as message_upload_id and Syla
--     looks at the file the way she already looks at chute media
--     (scripts/file-url → the claude-file edge function).
--
-- What travels to a peer: the message ROW only. A follower's select on
-- chat_messages (table-level since 20261121000000) shows upload_id, so
-- their client can render "sent an attachment" honestly — but the bytes
-- stay in the owner's private bucket, and uploads metadata has no
-- follower policy. Cross-database file delivery is its own feature
-- (signed-URL relay), deliberately not smuggled in here.
--
-- No new claude write: Syla's column-scoped insert on chat_messages
-- keeps not including upload_id — she sends words. Her reads already
-- cover uploads metadata, and claude_file_target covers the bytes.

-- ── The column ───────────────────────────────────────────────────────────

alter table public.chat_messages
    add column upload_id uuid references public.uploads (id) on delete set null;

comment on column public.chat_messages.upload_id is
    'The message''s attachment, if any: the content-addressed uploads row the sender''s client created at send time (the drop drawer''s store). One per message. The bytes stay in the owner''s private bucket — a peer reading this side over follower_rq sees that an attachment exists, never the file.';

create index chat_messages_upload_id_idx on public.chat_messages (upload_id);

-- A captionless attachment is a legal message; words-only still needs
-- words.
alter table public.chat_messages drop constraint chat_messages_body_check;
alter table public.chat_messages add constraint chat_messages_body_check
    check (char_length(body) <= 8000
           and (char_length(body) >= 1 or upload_id is not null));

-- (No new grants: authenticated and follower hold table-level SELECT,
-- and authenticated table-level INSERT, so the new column rides along.
-- claude's column-scoped INSERT stays without it on purpose.)

-- ── send_to_syla: the message may carry a file ───────────────────────────
--
-- Body otherwise 20261202000000's. The old two-argument form is dropped
-- (a default would make two-argument calls ambiguous); PostgREST calls
-- without _upload_id land on the default.

drop function public.send_to_syla(text, text);

create function public.send_to_syla(_about text, _text text, _upload_id uuid default null)
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
    -- Words, a file, or both — like any chat message.
    if _text is null then
        _text := '';
    end if;
    if char_length(btrim(_text)) > 4000 then
        raise exception 'the message must be at most 4000 characters';
    end if;
    if char_length(btrim(_text)) = 0 and _upload_id is null then
        raise exception 'the message needs words or an attachment';
    end if;

    _profile := public.current_profile_id();
    if _profile is null then
        raise exception 'no profile for this session';
    end if;

    -- SECURITY DEFINER: never let a send point at someone else's file.
    if _upload_id is not null and not exists (
        select 1 from public.uploads u
        where u.id = _upload_id and u.profile_id = _profile
    ) then
        raise exception 'no upload with id % for this owner', _upload_id;
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
    insert into public.chat_messages (chat_id, body, author, kind, syla_run_id, upload_id)
    values (_chat_id, btrim(_text), 'me', 'text', _run_id, _upload_id);

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
                        || 'run, then finish the run.'
                        || case when _upload_id is null then '' else
                           ' The message carries an attached file — the '
                           || 'claim entry''s message_upload_id names it; '
                           || 'scripts/file-url answers a signed link so '
                           || 'you can look at it before deciding.' end),
            timeout_milliseconds := 15000);

        update public.syla_job_runs
        set fired_at = now(), fire_count = fire_count + 1, fire_request_id = _req
        where id = _run_id;
        _fired := true;
    end if;

    return jsonb_build_object('run_id', _run_id, 'fired', _fired);
end;
$$;

comment on function public.send_to_syla(text, text, uuid) is
    'The app''s send-to-Syla: the owner''s message (words, an attached upload, or both) lands in the Syla conversation linked to a queued event-less run (chat_messages.syla_run_id — the thread''s receipt ladder), and the routine webhook fires inline with the Vault credential; the client never holds the token. Nothing is written to the calendar or todos: Syla reads the message and decides — a real task becomes a propose_todo_edit ''add'' proposal the owner approves in the Inbox, anything else just gets her reply (syla_chat_say). Owner only. Without a stored credential the run waits for the every-minute dispatcher.';

revoke all on function public.send_to_syla(text, text, uuid) from public;
revoke all on function public.send_to_syla(text, text, uuid) from anon;
grant execute on function public.send_to_syla(text, text, uuid) to authenticated;

-- ── The claim names the message's attachment ─────────────────────────────
--
-- Body otherwise 20261202000000's; message runs gain message_upload_id,
-- the handle scripts/file-url takes.

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
               'message_upload_id', (
                   select m.upload_id from public.chat_messages m
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
    'Claims every queued Syla run (queued → running) as the claude role. An event run returns its event title, times, attached docs and child todos — the event is the instructions. A send-to-Syla run has no event: its message field carries the owner''s words (the linked Syla-conversation row) and message_upload_id its attached file if any (scripts/file-url looks at it), and Syla decides whether they deserve calendar/todo entries (propose_todo_edit) or only a reply. Gated by assert_claude_rq_key().';
