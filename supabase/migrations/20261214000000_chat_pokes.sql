-- Chat pokes: a connection's send wakes this database's Syla.
--
-- Until now nothing woke Syla when a connected person messaged. The
-- distributed-chat rule means the peer's message lands in THEIR
-- database (your client reads it over the relay by chat_key), so no
-- row ever changes here — no trigger could fire, the dispatcher has no
-- chat branch, and the only wake for drafting was the owner tapping
-- "Have Syla draft yours". The reply ladder, the preflight and the
-- draft card all existed; the *detection* of an incoming message did
-- not.
--
-- The sender's side closes the gap. After a send, the sender's client
-- (or their Syla, after an auto-reply — the relay's new 'poke' kind)
-- calls follower_poke_chat() here with its follower token and the
-- shared chat_key: "I just posted in our chat". The poke is a recorded
-- row (chat_pokes — raw logs now, like everything), and it queues a
-- syla_job_runs row and fires the routine webhook inline, exactly
-- send_to_syla's arrangement: Vault credential, run left queued for
-- the every-minute dispatcher when none is stored. The claim returns
-- the poke context (which chat, who) and Syla does what
-- skills/chat-replies always said: read the whole thread, run the
-- preflight, draft / send under a rule / set the chat waiting.
--
-- Boundaries, unchanged:
--   * The roster is the grant. Only a follower a chat_followers row
--     names on that exact chat may poke it — not every follower, and
--     never the Syla conversation. A poke carries NO text: it says "a
--     message exists", and the message itself is read back over the
--     relay like always. Nothing crosses the boundary but the knock.
--   * Pokes coalesce. While a poke-queued run is still waiting to be
--     claimed, further pokes on that chat ride it (the session reads
--     the thread fresh, so one run covers them all); a hostile
--     rapid-fire sender is bounded to one waking per claim cycle, the
--     poke log names them, and blocking the follower ends it.
--   * The owner sees everything: chat_pokes is owner-readable, the
--     run is visible like any event-less run, and every row is in
--     row_edits.

-- ── The poke log ─────────────────────────────────────────────────────────

create table public.chat_pokes (
    id          uuid primary key default gen_random_uuid(),
    chat_id     uuid not null references public.chats (id) on delete cascade,
    follower_id uuid not null references public.followers (id) on delete cascade,
    run_id      uuid references public.syla_job_runs (id) on delete set null,
    created_at  timestamptz not null default now()
);

comment on table public.chat_pokes is
    'One row per "a connection just posted in our chat" knock (follower_poke_chat). Carries no message text — the thread is read over the relay as always; this only wakes Syla. run_id is the syla_job_runs row the poke queued or rode (pokes on a chat coalesce onto its still-queued run).';
comment on column public.chat_pokes.run_id is
    'The run this poke queued, or the already-queued run it coalesced onto. Null only if that run row was deleted.';

create index chat_pokes_chat_idx on public.chat_pokes (chat_id, created_at desc);
create index chat_pokes_run_idx on public.chat_pokes (run_id);

alter table public.chat_pokes enable row level security;
select public.declare_table_siloing('chat_pokes', 'system');

-- The owner reads the knock log and may prune it; Syla reads it (the
-- claim joins it). Followers write only through the RPC below (which
-- runs as definer) and never read back — the RPC's answer is their
-- receipt.
create policy "Pokes are viewable by the owner"
    on public.chat_pokes for select to authenticated
    using (public.is_owner());
create policy "Pokes are deletable by the owner"
    on public.chat_pokes for delete to authenticated
    using (public.is_owner());
create policy "claude reads pokes"
    on public.chat_pokes for select to claude using (true);

grant select, delete on public.chat_pokes to authenticated;
grant select on public.chat_pokes to claude;

-- ── The knock: follower_poke_chat ────────────────────────────────────────

create function public.follower_poke_chat(_token text, _chat_key text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    mid    uuid;
    _chat  record;
    _open  uuid;
    _run   uuid;
    _id    uuid;
    _name  text;
    _url   text;
    _tok   text;
    _req   bigint;
    _fired boolean := false;
begin
    mid := public.authenticate_follower(_token);

    if _chat_key is null
       or btrim(_chat_key) !~ '^[A-Za-z0-9_-]{8,100}$' then
        raise exception 'malformed chat key';
    end if;

    -- The roster is the grant: only a dm or group whose chat_followers
    -- row names this follower. The Syla conversation is kind 'syla'
    -- and so never pokeable.
    select c.id, c.title, c.kind into _chat
    from public.chats c
    join public.chat_followers cf on cf.chat_id = c.id
    where c.chat_key = btrim(_chat_key)
      and cf.follower_id = mid
      and c.kind in ('dm', 'group');
    if _chat.id is null then
        raise exception 'no shared chat with that key names you'
            using errcode = '42501';
    end if;

    perform set_config('app.follower_id', mid::text, true);

    -- Coalesce onto the chat's still-queued poke run, if one waits: the
    -- claiming session reads the whole thread fresh, so one waking
    -- covers every poke that lands before it.
    select p.run_id into _open
    from public.chat_pokes p
    join public.syla_job_runs r on r.id = p.run_id
    where p.chat_id = _chat.id
      and r.status = 'queued'
    order by p.created_at desc
    limit 1;

    if _open is not null then
        insert into public.chat_pokes (chat_id, follower_id, run_id)
        values (_chat.id, mid, _open)
        returning id into _id;
        return jsonb_build_object('id', _id, 'run_id', _open,
                                  'coalesced', true, 'fired', false);
    end if;

    insert into public.syla_job_runs (event_id)
    values (null)
    returning id into _run;

    insert into public.chat_pokes (chat_id, follower_id, run_id)
    values (_chat.id, mid, _run)
    returning id into _id;

    select f.name into _name from public.followers f where f.id = mid;

    -- Fire now, the dispatcher's own way (send_to_syla's arrangement).
    -- Missing credential: leave the run queued for the every-minute
    -- dispatcher.
    select decrypted_secret into _url
    from vault.decrypted_secrets where name = 'syla_webhook_url';
    select decrypted_secret into _tok
    from vault.decrypted_secrets where name = 'syla_webhook_token';

    if _url is not null and _tok is not null then
        _req := net.http_post(
            url := _url,
            headers := jsonb_build_object(
                'Authorization',     'Bearer ' || _tok,
                'anthropic-version', '2023-06-01',
                'anthropic-beta',    'experimental-cc-routine-2026-04-01',
                'Content-Type',      'application/json'),
            body := jsonb_build_object(
                'text', coalesce(_name, 'A connection')
                        || ' just posted in a chat with the owner. Claim '
                        || 'as usual — this run has no event; the claim '
                        || 'entry''s poke field names the chat (id, key, '
                        || 'title, who). Load skills/chat-replies first, '
                        || 'then read the WHOLE thread — your side '
                        || '(chat_messages) plus theirs over the relay '
                        || '(scripts/following-rq, matched by chat_key) — '
                        || 'and act by that connection''s reply ladder: '
                        || 'propose mode means a draft via '
                        || 'propose_chat_reply; auto/syla_syla means '
                        || 'send_auto_reply ONLY where an active REPLY '
                        || 'rule covers the message; anything uncovered '
                        || 'waits for the human (set_chat_waiting, plus a '
                        || 'draft or nothing). A message asking for the '
                        || 'human always stops you. Then finish the run.'),
            timeout_milliseconds := 15000);

        update public.syla_job_runs
        set fired_at = now(), fire_count = fire_count + 1, fire_request_id = _req
        where id = _run;
        _fired := true;
    end if;

    return jsonb_build_object('id', _id, 'run_id', _run,
                              'coalesced', false, 'fired', _fired);
end;
$$;

comment on function public.follower_poke_chat(text, text) is
    'The sender-side poke: a connected person''s client (or their Syla, through the relay''s poke kind) knocks after posting in a shared chat, and this database queues an event-less syla_job_runs row and fires the routine webhook inline — so the owner''s Syla reads the thread and acts by the reply ladder. Gated by the follower token, and by the chat''s own roster: only a dm or group naming the follower. Carries no text; pokes coalesce onto a still-queued run. Without a stored credential the run waits for the every-minute dispatcher.';

revoke all on function public.follower_poke_chat(text, text) from public;
grant execute on function public.follower_poke_chat(text, text) to anon;

-- ── The claim names the poked chat ───────────────────────────────────────
--
-- Body otherwise 20261211000000's; runs gain the poke object — the
-- chat's id, key, title and kind, plus who knocked (every distinct
-- poker coalesced onto the run).

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
               'poke', (
                   select jsonb_build_object(
                              'chat_id',    ch.id,
                              'chat_key',   ch.chat_key,
                              'chat_title', ch.title,
                              'chat_kind',  ch.kind,
                              'from',       (
                                  select jsonb_agg(distinct f.name)
                                  from public.chat_pokes p2
                                  join public.followers f on f.id = p2.follower_id
                                  where p2.run_id = c.id))
                   from public.chat_pokes p
                   join public.chats ch on ch.id = p.chat_id
                   where p.run_id = c.id
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
    'Claims every queued Syla run (queued → running) as the claude role. An event run returns its event title, times, attached docs and child todos — the event is the instructions. A send-to-Syla run has no event: its message field carries the owner''s words and message_upload_id its attached file if any. A poke run has no event and no message: its poke field names the chat a connection just posted in (skills/chat-replies says what to do). Gated by assert_claude_rq_key().';

-- ── The dispatcher names poke runs honestly in the batch fire ────────────
--
-- 20261209000000's body; two changes, both in the final fire: the
-- stand-in name for an event-less run tells a poke from an owner
-- message, and the batch text explains the poke field.

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
    -- (forever-pre-latched) CANONICAL Chute sort event and stamps the
    -- latch. The oldest row is the canonical one; satellites are display.
    for _cs in
        select cs.profile_id, cs.cadence, cs.daily_time, cs.last_sorted_at,
               (select e.id from public.events e
                where e.profile_id = cs.profile_id
                  and e.assignee = 'syla'
                  and e.title = 'Chute sort'
                order by e.created_at asc
                limit 1) as event_id
        from public.chute_settings cs
        where exists (select 1 from public.chute_items ci
                      where ci.profile_id = cs.profile_id
                        and ci.status = 'raw')
    loop
        if _cs.event_id is null then
            continue;
        end if;
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
           string_agg(distinct coalesce(e.title,
               case when exists (select 1 from public.chat_pokes p
                                 where p.run_id = r.id)
                    then 'a new message from a connection'
                    else 'a message from the owner' end), ', ')
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
                    || 'the instructions. A run with no event is either a '
                    || 'message from the owner (the claim''s message '
                    || 'field — decide whether it deserves calendar/todo '
                    || 'entries via propose_todo_edit or only a reply via '
                    || 'syla_chat_say) or a connection''s new chat '
                    || 'message (the claim''s poke field names the chat — '
                    || 'read the thread and act by skills/chat-replies).'),
        timeout_milliseconds := 15000);

    update public.syla_job_runs
    set fired_at = _now, fire_count = fire_count + 1, fire_request_id = _req
    where id = any (_to_fire);
end;
$$;

-- ── The skill learns the poke ────────────────────────────────────────────
--
-- Targeted text swaps on the seeded doc (20261205000000's pattern), so
-- an owner's own edits elsewhere in the page survive; an already-edited
-- sentence just no-ops.

update public.docs
set html = replace(html,
    '<footer>doc <code>skills/chat-replies</code></footer>',
    '<h2>Poke runs — a connection just messaged</h2>
<p>When a connected person posts in a shared chat, their side knocks here (<code>follower_poke_chat</code>) and the knock queues a run for you: the claim entry''s <code>poke</code> field names the chat (<code>chat_id</code>, <code>chat_key</code>, the title, who). Read the whole thread — your side plus theirs over the relay — then act by that connection''s ladder exactly as above: a draft in propose mode, a rule-covered <code>send_auto_reply</code> in auto, and <code>set_chat_waiting</code> when nothing covers it. Rapid messages coalesce into one waking; reading the thread fresh covers every poke. The poke carries no text — the thread is the only material.</p>
<p>After YOU send an auto-reply into a chat whose person you also follow back, knock back: <code>scripts/following-poke &lt;name&gt; &lt;chat_key&gt;</code>. Their side decides what their Syla does with it — in syla_syla this is what keeps the two agents'' turn-taking going.</p>
<footer>doc <code>skills/chat-replies</code></footer>')
where path = 'skills/chat-replies';
