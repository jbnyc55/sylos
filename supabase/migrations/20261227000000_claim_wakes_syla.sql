-- The claim wakes Syla: an accepted invite is an event here.
--
-- Accepting an invite happens IN THIS DATABASE (claim_follower_invite
-- burns the code and mints the key right here), yet nothing told the
-- owner's Syla. The moments around a first connection are exactly when
-- she has work: the first-run race waits on "they're in", a pre-staged
-- chat just became readable on the other side, and the owner deserves a
-- line in the Syla conversation rather than discovering a flipped
-- claimed_at themselves.
--
-- Same arrangement as chat pokes (20261214000000), one step simpler
-- because claims are rare and never coalesce:
--
--   * follower_claims is the raw log — one row per redeemed invite,
--     naming the follower and the event-less syla_job_runs row it
--     queued. Raw logs now, like everything.
--   * claim_follower_invite queues the run and fires the routine
--     webhook inline with the Vault credential; without one the run
--     waits for the every-minute dispatcher. The claim itself NEVER
--     fails on the wake: the fire sits after the burn, and pg_net
--     queues the request rather than sending it in-line.
--   * claim_syla_runs returns the context as a claim field — who
--     joined, and whether they attached a connect-back offer — the way
--     poke runs carry their poke field.

-- ── The claim log ────────────────────────────────────────────────────────

create table public.follower_claims (
    id          uuid primary key default gen_random_uuid(),
    follower_id uuid not null references public.followers (id) on delete cascade,
    run_id      uuid references public.syla_job_runs (id) on delete set null,
    created_at  timestamptz not null default now()
);

comment on table public.follower_claims is
    'One row per redeemed follower invite (claim_follower_invite): the moment a person accepted and their key was minted. run_id is the event-less syla_job_runs row the claim queued so the owner''s Syla learns a connection just landed. Raw log; the followers row''s claimed_at stays the live state.';

create index follower_claims_run_idx on public.follower_claims (run_id);
create index follower_claims_follower_idx
    on public.follower_claims (follower_id, created_at desc);

alter table public.follower_claims enable row level security;
select public.declare_table_siloing('follower_claims', 'system');

-- The owner reads and may prune; Syla reads (the claim joins it). Rows
-- are written only by claim_follower_invite, which runs as definer.
create policy "Follower claims are viewable by the owner"
    on public.follower_claims for select to authenticated
    using (public.is_owner());
create policy "Follower claims are deletable by the owner"
    on public.follower_claims for delete to authenticated
    using (public.is_owner());
create policy "claude reads follower claims"
    on public.follower_claims for select to claude using (true);

grant select, delete on public.follower_claims to authenticated;
grant select on public.follower_claims to claude;

-- ── claim_follower_invite queues the run and knocks ──────────────────────
--
-- Body otherwise 20261213000000's (the connect-back offer); the claim
-- additionally queues an event-less run, logs it in follower_claims,
-- and fires the routine webhook inline — send_to_syla's arrangement.

create or replace function public.claim_follower_invite(_code text, _peer jsonb default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    m     record;
    tok   text;
    _url  text;
    _key  text;
    _back text;
    _run  uuid;
    _name text;
    _whurl text;
    _whtok text;
    _req  bigint;
begin
    if _code is null or char_length(_code) < 32 then
        raise exception 'missing or malformed invite code' using errcode = '28000';
    end if;

    -- The offer is validated before the code is even looked up, so a
    -- malformed one never burns the invite. The column checks are the
    -- same bounds; failing here answers a clear error while the claim
    -- is still retryable without the offer.
    if _peer is not null then
        _url  := nullif(trim(_peer->>'project_url'), '');
        _key  := nullif(trim(_peer->>'anon_key'), '');
        _back := nullif(trim(_peer->>'invite_code'), '');
        if _url is null or _url not like 'https://%' or char_length(_url) > 200
           or _key is null or char_length(_key) not between 20 and 500
           or _back is null or char_length(_back) not between 32 and 200 then
            raise exception 'malformed connect-back offer' using errcode = '22023';
        end if;
    end if;

    select id, blocked, invite_expires_at into m
    from public.followers
    where invite_code_hash = encode(extensions.digest(_code, 'sha256'), 'hex');

    if m.id is null
       or m.blocked
       or m.invite_expires_at is null
       or m.invite_expires_at <= now() then
        raise exception 'invalid or expired invite' using errcode = '28000';
    end if;

    tok := encode(extensions.gen_random_bytes(32), 'hex');

    -- The claim is the authoritative moment for the offer: whatever
    -- this claim carried replaces whatever an earlier claim left, and
    -- a claim with no offer clears a stale one.
    update public.followers
    set token_hash        = encode(extensions.digest(tok, 'sha256'), 'hex'),
        claimed_at        = now(),
        invite_code_hash  = null,
        invite_expires_at = null,
        peer_project_url  = _url,
        peer_anon_key     = _key,
        peer_invite_code  = _back,
        peer_offered_at   = case when _back is null then null else now() end
    where id = m.id;

    -- The wake: queue an event-less run, log the claim on it, and fire
    -- the routine webhook the dispatcher's own way. Missing credential:
    -- the run stays queued for the every-minute dispatcher.
    insert into public.syla_job_runs (event_id)
    values (null)
    returning id into _run;

    insert into public.follower_claims (follower_id, run_id)
    values (m.id, _run);

    select f.name into _name from public.followers f where f.id = m.id;

    select decrypted_secret into _whurl
    from vault.decrypted_secrets where name = 'syla_webhook_url';
    select decrypted_secret into _whtok
    from vault.decrypted_secrets where name = 'syla_webhook_token';

    if _whurl is not null and _whtok is not null then
        _req := net.http_post(
            url := _whurl,
            headers := jsonb_build_object(
                'Authorization',     'Bearer ' || _whtok,
                'anthropic-version', '2023-06-01',
                'anthropic-beta',    'experimental-cc-routine-2026-04-01',
                'Content-Type',      'application/json'),
            body := jsonb_build_object(
                'text', coalesce(_name, 'Someone')
                        || ' just accepted the owner''s invite and is now '
                        || 'a connection. Claim as usual — this run has no '
                        || 'event; the claim entry''s claim field names who '
                        || 'joined and whether they connected back. If the '
                        || 'first-run walkthrough''s race stage is underway '
                        || '(skills/first-run), follow it; otherwise one '
                        || 'short line in the Syla conversation '
                        || '(syla_chat_say) telling the owner is enough. '
                        || 'Then finish the run.'),
            timeout_milliseconds := 15000);

        update public.syla_job_runs
        set fired_at = now(), fire_count = fire_count + 1, fire_request_id = _req
        where id = _run;
    end if;

    return jsonb_build_object('token', tok, 'follower_id', m.id);
end;
$$;

comment on function public.claim_follower_invite(text, jsonb) is
    'Burns a single-use invite code and issues (or rotates) that follower''s personal key; raises 28000 on any miss. _peer, optional, is the claimer''s connect-back offer ({project_url, anon_key, invite_code}) — stored on the row for the owner''s client to redeem, so one invite and one accept connect both ways. The claim also queues an event-less syla_job_runs row (logged in follower_claims) and fires the routine webhook inline, so the owner''s Syla learns a connection just landed.';

-- ── The claim run carries its context ────────────────────────────────────
--
-- Body otherwise 20261214000000's; runs gain the claim object — who
-- accepted, and whether their claim carried a connect-back offer.

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
               'claim', (
                   select jsonb_build_object(
                              'follower_id', f.id,
                              'name',        f.name,
                              'connected_back',
                                  f.peer_following_id is not null
                                  or f.peer_invite_code is not null)
                   from public.follower_claims fc
                   join public.followers f on f.id = fc.follower_id
                   where fc.run_id = c.id
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
    'Claims every queued Syla run (queued → running) as the claude role. An event run returns its event title, times, attached docs and child todos — the event is the instructions. A send-to-Syla run has no event: its message field carries the owner''s words and message_upload_id its attached file if any. A poke run''s poke field names the chat a connection just posted in (skills/chat-replies says what to do). A claim run''s claim field names the connection who just accepted the owner''s invite (connected_back says whether their claim carried a connect-back offer) — skills/first-run''s race stage, or a short note to the owner. Gated by assert_claude_rq_key().';

-- ── The dispatcher names claim runs honestly in the batch fire ───────────
--
-- 20261214000000's body; the stand-in name for an event-less run learns
-- the claim case, and the batch text explains the claim field.

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
                    when exists (select 1 from public.follower_claims fc
                                 where fc.run_id = r.id)
                    then 'an accepted connection invite'
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
                    || 'the instructions. A run with no event is a message '
                    || 'from the owner (the claim''s message field — '
                    || 'decide whether it deserves calendar/todo entries '
                    || 'via propose_todo_edit or only a reply via '
                    || 'syla_chat_say), a connection''s new chat message '
                    || '(the claim''s poke field names the chat — read the '
                    || 'thread and act by skills/chat-replies), or an '
                    || 'accepted invite (the claim''s claim field names '
                    || 'who joined — skills/first-run''s race stage, or a '
                    || 'short note to the owner).'),
        timeout_milliseconds := 15000);

    update public.syla_job_runs
    set fired_at = _now, fire_count = fire_count + 1, fire_request_id = _req
    where id = any (_to_fire);
end;
$$;
