-- Mac-only side threads: kind 'syla_thread'.
--
-- The owner's ONE Syla conversation (kind 'syla', the oldest row)
-- stays what it always was — the thread the iPhone pins and shows.
-- The Mac's additional threads get their own kind so every other
-- client can tell them apart: same owner-only RLS, never mirrored
-- to a peer, and the phone's chat list filters them out. Routing
-- is unchanged — send_to_syla simply accepts them as targets, and
-- syla_chat_say already follows the run's own message home.

alter table public.chats drop constraint chats_kind_check;
alter table public.chats
    add constraint chats_kind_check
    check (kind in ('dm', 'group', 'syla', 'syla_thread'));

comment on column public.chats.kind is
    'dm: one other person (one chat_followers row). group: several. syla: the owner''s one conversation with their agent — local only, never mirrored to a peer; the phone pins it by this kind. syla_thread: an additional owner–agent thread (the Mac''s sidebar) — local only, and left out of the phone''s lists.';

-- Same signature as 20270106 — replaced in place; only the target
-- check widens to accept a Mac thread.
create or replace function public.send_to_syla(
    _about text, _text text,
    _upload_id uuid default null,
    _chat_id uuid default null
)
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

    -- The thread: the one the caller names (the Syla conversation or
    -- a Mac thread), else the oldest syla chat, seeded on demand.
    if _chat_id is not null then
        select id into _chat from public.chats
        where id = _chat_id and kind in ('syla', 'syla_thread');
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

    insert into public.chat_messages (chat_id, body, author, kind, syla_run_id, upload_id)
    values (_chat, btrim(_text), 'me', 'text', _run_id, _upload_id);

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

    return jsonb_build_object('run_id', _run_id, 'fired', _fired, 'chat_id', _chat);
end;
$$;

comment on function public.send_to_syla(text, text, uuid, uuid) is
    'The app''s send-to-Syla, thread-aware: the owner''s message (words, an attached upload, or both) lands in the named thread — the Syla conversation or a Mac-only syla_thread — or in the oldest syla chat by default, linked to a queued event-less run; the webhook fires inline with the Vault credential. Owner only. Without a stored credential the run waits for the every-minute dispatcher.';
