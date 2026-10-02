-- The chute: everything lands raw; Syla's scheduled sort files it.
--
-- The middle tab is a capture page: text, a photo, a file, a voice note —
-- one "Drop it", no filing decision at drop time. Each drop is a
-- chute_items row with status 'raw'. On a cadence the owner picks
-- (chute_settings: hourly / three fixed times a day / once a day at a
-- time), the dispatcher queues a run of the seeded 'Chute sort' event
-- whenever raw items are waiting, and Syla files each item into its real
-- home through the gated write paths she already has — then marks it here
-- with file_chute_item(), leaving a human-readable receipt (filed_to) and
-- a machine locator (filed_locator). Ambiguity becomes a question
-- (ask_chute_question → the Inbox), never a guess.
--
-- Undo is row_edits as UI: every status flip carries full before/after
-- images, so "Undo" in the client is the owner setting the row back to
-- 'raw' and clearing the filing — one visible, logged write, no special
-- machinery.
--
-- Dispatch is deliberately NOT the event's own daily latch: the 'Chute
-- sort' event exists so a run has an event (its docs are the
-- instructions, its history shows in Syla Jobs), but it is seeded
-- PRE-LATCHED FOREVER (last_fired_on = 9999-12-31) so the generic due-scan
-- never fires it. The chute branch in syla_dispatch() is its only
-- dispatcher: due is read off chute_settings (cadence vs last_sorted_at,
-- America/New_York like everything else) AND at least one raw item —
-- an empty chute never wakes anyone. 'Sort now' is sort_chute_now(),
-- owner-only, queue-and-fire-inline exactly like send_to_syla. (If the
-- owner retimes the seeded event in the app, the latch trigger resets and
-- the generic scan takes over too — harmless, just a second schedule.)

-- ── The drops ────────────────────────────────────────────────────────────

create table public.chute_items (
    id            uuid primary key default gen_random_uuid(),
    profile_id    uuid not null default public.current_profile_id()
                  references public.profiles (id) on delete cascade,
    kind          text not null default 'text'
                  check (kind in ('text', 'photo', 'file', 'voice')),
    body          text not null default '' check (char_length(body) <= 8000),
    upload_id     uuid references public.uploads (id) on delete set null,
    status        text not null default 'raw'
                  check (status in ('raw', 'filed', 'question', 'dismissed')),
    filed_to      text check (filed_to is null or char_length(filed_to) <= 200),
    filed_locator text check (filed_locator is null or char_length(filed_locator) <= 200),
    question      text check (question is null or char_length(question) <= 500),
    answer        text check (answer is null or char_length(answer) <= 2000),
    created_at    timestamptz not null default now(),
    filed_at      timestamptz,
    answered_at   timestamptz
);

comment on table public.chute_items is
    'The quick-capture chute: everything lands raw (text in body, media as an uploads row), and Syla''s scheduled sort files each item into its real home through her existing gated writes, marking the receipt here. Undo is the owner flipping status back to raw — row_edits as UI. Never shared: captures are presorted private.';
comment on column public.chute_items.status is
    'raw: waiting for the sort. filed: landed somewhere real (see filed_to / filed_locator). question: Syla needs the owner — shows in the Inbox. dismissed: the owner binned it.';
comment on column public.chute_items.filed_to is
    'Human-readable receipt of where it went, e.g. ''Notes · Gift ideas'' — what the chute list shows under a filed item.';
comment on column public.chute_items.filed_locator is
    'Machine locator of the filed record, table:id shaped, e.g. ''manual_notes:6f1c…'' — what Undo and the client''s "open it" use.';
comment on column public.chute_items.question is
    'Syla''s question about an ambiguous drop, surfaced as an Inbox card; the owner''s reply lands in answer, and the next sort reads it.';
comment on column public.chute_items.upload_id is
    'For photo / file / voice drops: the stored file (the content-addressed uploads row the client created at drop time).';

create index chute_items_profile_status_idx
    on public.chute_items (profile_id, status, created_at);
create index chute_items_upload_id_idx on public.chute_items (upload_id);

alter table public.chute_items enable row level security;
select public.declare_table_siloing('chute_items', 'system');

create policy "Chute items are their profile's"
    on public.chute_items for all to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));
create policy "claude reads the chute"
    on public.chute_items for select to claude using (true);
-- The structural gate on the sort: only a raw item moves, and only into
-- filed or question — dismissing and undoing are the owner's verbs.
create policy "claude files raw items"
    on public.chute_items for update to claude
    using (status = 'raw')
    with check (status in ('filed', 'question'));

grant select, insert, update, delete on public.chute_items to authenticated;
grant select on public.chute_items to claude;
grant update (status, filed_to, filed_locator, filed_at, question)
    on public.chute_items to claude;

-- ── The sort settings ────────────────────────────────────────────────────

create table public.chute_settings (
    profile_id     uuid primary key default public.current_profile_id()
                   references public.profiles (id) on delete cascade,
    cadence        text not null default 'daily'
                   check (cadence in ('hourly', 'thrice', 'daily')),
    -- Used when cadence = 'daily'; 'thrice' is the fixed trio 09:00 /
    -- 13:00 / 18:00 local, 'hourly' is on the hour-ish (the dispatcher's
    -- next tick an hour after the last sort).
    daily_time     time not null default '15:00',
    auto_open      boolean not null default true,
    last_sorted_at timestamptz,
    created_at     timestamptz not null default now(),
    updated_at     timestamptz not null default now()
);

comment on table public.chute_settings is
    'One row per profile: when Syla sorts the chute (cadence + daily_time; ''thrice'' means 09:00/13:00/18:00 local) and whether the capture drawer auto-opens on launch. last_sorted_at is the dispatcher''s latch, stamped when a sort run is queued.';
comment on column public.chute_settings.auto_open is
    'The drawer''s auto-open-on-launch text toggle — a client preference that rides here so every device agrees.';
comment on column public.chute_settings.last_sorted_at is
    'When a sort run was last queued (stamped by the dispatcher and sort_chute_now; Syla may refresh it when a sort finishes). The cadence latch: hourly = an hour since; thrice/daily = the latest passed slot not yet covered.';

create trigger chute_settings_set_updated_at
    before update on public.chute_settings
    for each row execute function public.set_updated_at();

alter table public.chute_settings enable row level security;
select public.declare_table_siloing('chute_settings', 'system');

create policy "Chute settings are their profile's"
    on public.chute_settings for all to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));
create policy "claude reads chute settings"
    on public.chute_settings for select to claude using (true);
create policy "claude stamps the sort time"
    on public.chute_settings for update to claude
    using (true) with check (true);

grant select, insert, update, delete on public.chute_settings to authenticated;
grant select on public.chute_settings to claude;
grant update (last_sorted_at) on public.chute_settings to claude;

-- ── The sort's write path ────────────────────────────────────────────────

create function public.file_chute_item(
    _item_id      uuid,
    _filed_to     text,
    _filed_locator text default null
)
returns jsonb
language plpgsql
security invoker
as $$
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    if _filed_to is null or char_length(btrim(_filed_to)) not between 1 and 200 then
        raise exception 'say where it went, in 1–200 characters (e.g. ''Notes · Gift ideas'')';
    end if;
    if _filed_locator is not null and char_length(_filed_locator) > 200 then
        raise exception 'the locator is longer than 200 characters';
    end if;

    update public.chute_items
    set status = 'filed',
        filed_to = btrim(_filed_to),
        filed_locator = _filed_locator,
        filed_at = now()
    where id = _item_id and status = 'raw';

    if not found then
        raise exception 'no raw chute item with id % (already filed, questioned, or dismissed?)', _item_id;
    end if;

    return jsonb_build_object('id', _item_id, 'status', 'filed', 'filed_to', btrim(_filed_to));
end;
$$;

comment on function public.file_chute_item(uuid, text, text) is
    'Marks one raw chute item filed, as the claude role, with the human-readable receipt (filed_to) and machine locator (filed_locator) — called AFTER the item actually landed somewhere real through a gated write. Only raw items move. Gated by assert_claude_rq_key().';

revoke all on function public.file_chute_item(uuid, text, text) from public;
grant execute on function public.file_chute_item(uuid, text, text) to anon;

create function public.ask_chute_question(_item_id uuid, _question text)
returns jsonb
language plpgsql
security invoker
as $$
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    if _question is null or char_length(btrim(_question)) not between 1 and 500 then
        raise exception 'the question must be 1–500 characters';
    end if;

    update public.chute_items
    set status = 'question',
        question = btrim(_question)
    where id = _item_id and status = 'raw';

    if not found then
        raise exception 'no raw chute item with id % (already filed, questioned, or dismissed?)', _item_id;
    end if;

    return jsonb_build_object('id', _item_id, 'status', 'question');
end;
$$;

comment on function public.ask_chute_question(uuid, text) is
    'Turns one raw chute item into a question for the owner (an Inbox card), as the claude role — the ambiguity path: never guess a filing. The owner''s reply lands in answer; the next sort reads it. Gated by assert_claude_rq_key().';

revoke all on function public.ask_chute_question(uuid, text) from public;
grant execute on function public.ask_chute_question(uuid, text) to anon;

-- ── The job's instructions ───────────────────────────────────────────────

insert into public.docs (path, title, html)
select 'syla/chute-sort', 'Chute sort', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Chute sort</title>
<style>
  body { margin: 0 auto; max-width: 42rem; padding: 2rem 1.25rem 4rem;
         font: 16px/1.6 system-ui, sans-serif; color: #1a1a1a; background: #fdfdfc; }
  h1 { font-size: 1.6rem; } h2 { font-size: 1.2rem; margin-top: 2rem; }
  code, pre { font-family: ui-monospace, monospace; background: #f0efec; border-radius: 4px; }
  code { padding: 0.1em 0.3em; } pre { padding: 0.75rem; overflow-x: auto; }
  @media (prefers-color-scheme: dark) {
    body { color: #e8e6e3; background: #16181a; }
    code, pre { background: #24272b; }
  }
</style></head>
<body>
<h1>Chute sort</h1>
<p>The owner drops things into the chute all day without filing them; this run files them. Read <code>skills/chute</code> first if it isn't fresh. Work the raw items oldest-first:</p>
<pre>scripts/rq "select id, kind, body, upload_id, answer, created_at
from chute_items where status = 'raw' order by created_at"</pre>
<ol>
<li><strong>File each item into its real home</strong> through the write paths you already have — a lasting page or reference → <code>scripts/doc-save</code> (then <code>doc-silo</code> if it clearly fits a silo); a task or a dated thing → <code>scripts/propose-todo-edit</code> (a calendar add may go as a <code>propose_approval</code> card instead); a photo/file/voice drop already lives in <code>uploads</code> — filing can mean just naming where it belongs. An item with an <code>answer</code> is a question the owner came back on: honor the answer.</li>
<li><strong>Mark the receipt</strong>: <code>file_chute_item(_item_id, _filed_to, _filed_locator)</code> — <code>_filed_to</code> human-readable (<code>Notes · Gift ideas</code>), <code>_filed_locator</code> machine-shaped (<code>docs:&lt;uuid&gt;</code>). File the chute row only after the real write succeeded.</li>
<li><strong>Ambiguity is a question, never a guess</strong>: <code>ask_chute_question(_item_id, _question)</code> — one short question the owner can answer from the Inbox. Leave the item at that; the next run picks it up with the answer.</li>
<li>Items the owner dismissed are not yours; never touch <code>dismissed</code> rows.</li>
</ol>
<p>Then finish the run as usual (<code>scripts/syla-finish</code>) with a one-line summary — how many filed, how many questions. Every filing is undoable by the owner (your update is in <code>row_edits</code>), so prefer a reasonable filing plus a clear <code>filed_to</code> over a pile of questions.</p>
<footer>doc <code>syla/chute-sort</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'syla/chute-sort');

insert into public.doc_silos (doc_id, silo_id)
select d.id, s.id
from public.docs d
join public.silos s on s.name = 'syla'
where d.path = 'syla/chute-sort'
  and not exists (select 1 from public.doc_silos j
                  where j.doc_id = d.id and j.silo_id = s.id);

-- The capability doc beside it, under skills/.
insert into public.docs (path, title, html)
select 'skills/chute', 'The chute: capture now, sort on schedule', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>The chute: capture now, sort on schedule</title>
<style>
  body { margin: 0 auto; max-width: 42rem; padding: 2rem 1.25rem 4rem;
         font: 16px/1.6 system-ui, sans-serif; color: #1a1a1a; background: #fdfdfc; }
  h1 { font-size: 1.6rem; } h2 { font-size: 1.2rem; margin-top: 2rem; }
  code, pre { font-family: ui-monospace, monospace; background: #f0efec; border-radius: 4px; }
  code { padding: 0.1em 0.3em; } pre { padding: 0.75rem; overflow-x: auto; }
  @media (prefers-color-scheme: dark) {
    body { color: #e8e6e3; background: #16181a; }
    code, pre { background: #24272b; }
  }
</style></head>
<body>
<h1>The chute: capture now, sort on schedule</h1>
<p>The chute (<code>chute_items</code>) is the owner's zero-friction capture surface: text, photos, files and voice notes land with <code>status = 'raw'</code> and no filing decision. Filing is YOUR job, on the schedule in <code>chute_settings</code> (hourly / 09:00-13:00-18:00 / once daily) — the dispatcher queues the seeded <em>Chute sort</em> event whenever raw items wait, and <code>syla/chute-sort</code> is that run's exact procedure. The owner can also fire it immediately ("Sort now").</p>
<h2>Your two verbs here</h2>
<ul>
<li><code>file_chute_item(_item_id, _filed_to, _filed_locator)</code> — after the item really landed somewhere through a gated write. <code>_filed_to</code> is for the owner's eyes ("Notes · Gift ideas"); <code>_filed_locator</code> is <code>table:id</code> for the client.</li>
<li><code>ask_chute_question(_item_id, _question)</code> — the ambiguity path; the card shows in the Inbox and the owner's reply arrives in the row's <code>answer</code>.</li>
</ul>
<p>Both move only <code>raw</code> items — dismissing and undoing are the owner's verbs, and an undo (back to raw) simply hands the item to your next run. Every move you make is in <code>row_edits</code>; that log is the undo UI, so file decisively and legibly rather than hedging.</p>
<p>Done looks like: zero raw items, each filed one wearing an honest <code>filed_to</code>, questions only where a human genuinely has to choose.</p>
<footer>doc <code>skills/chute</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'skills/chute');

insert into public.doc_silos (doc_id, silo_id)
select d.id, s.id
from public.docs d
join public.silos s on s.name = 'skills'
where d.path = 'skills/chute'
  and not exists (select 1 from public.doc_silos j
                  where j.doc_id = d.id and j.silo_id = s.id);

-- ── Seeding: the event, its doc, the settings row ────────────────────────
--
-- seed_owner_defaults is 20261121000000's body plus the chute pieces. The
-- 'Chute sort' event is inserted daily-shaped (so the app's calendar shows
-- it honestly) and then latched forever — the second UPDATE touches no
-- schedule field, so the reset-latch trigger keeps the value.

create or replace function public.seed_owner_defaults()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.events (profile_id, title, assignee,
                               start_date, start_time, end_time, freq, interval_n)
    select new.id, s.title, 'syla',
           (now() at time zone 'America/New_York')::date, s.starts, s.ends, 'daily', 1
    from (values
            ('Daily note siloing',   time '06:15', time '06:30', 'syla/note-siloing'),
            ('Daily edit feedback',  time '06:30', time '06:45', 'syla/edit-feedback'),
            ('Goal synergy linking', time '06:45', time '07:00', 'syla/goal-synergy'),
            ('Morning day summary',  time '07:00', time '07:30', 'syla/daily-summary'),
            ('Chute sort',           time '15:00', time '15:30', 'syla/chute-sort')
         ) as s (title, starts, ends, doc_path)
    where not exists (select 1 from public.events e
                      where e.title = s.title and e.assignee = 'syla');

    insert into public.event_docs (event_id, doc_id)
    select e.id, d.id
    from (values
            ('Daily note siloing',   'syla/note-siloing'),
            ('Daily edit feedback',  'syla/edit-feedback'),
            ('Goal synergy linking', 'syla/goal-synergy'),
            ('Morning day summary',  'syla/daily-summary'),
            ('Chute sort',           'syla/chute-sort')
         ) as s (title, doc_path)
    join public.events e on e.title = s.title and e.assignee = 'syla'
    join public.docs d on d.path = s.doc_path
    on conflict do nothing;

    -- The chute event is dispatched by the chute branch alone: latch the
    -- generic due-scan off forever.
    update public.events
    set last_fired_on = date '9999-12-31'
    where title = 'Chute sort' and assignee = 'syla' and profile_id = new.id;

    insert into public.chute_settings (profile_id)
    values (new.id)
    on conflict (profile_id) do nothing;

    insert into public.chats (chat_key, kind, title)
    select 'syla-chat', 'syla', 'Syla'
    where not exists (select 1 from public.chats where kind = 'syla');

    return new;
end
$$;

-- Backfill for databases whose owner is already crowned: the same pieces,
-- same guards.
do $$
declare
    _owner uuid;
    _event uuid;
begin
    select id into _owner from public.profiles where is_owner;
    if _owner is null then
        return;
    end if;

    if not exists (select 1 from public.events e
                   where e.title = 'Chute sort' and e.assignee = 'syla') then
        insert into public.events (profile_id, title, assignee,
                                   start_date, start_time, end_time, freq, interval_n)
        values (_owner, 'Chute sort', 'syla',
                (now() at time zone 'America/New_York')::date,
                time '15:00', time '15:30', 'daily', 1)
        returning id into _event;

        update public.events set last_fired_on = date '9999-12-31'
        where id = _event;

        insert into public.event_docs (event_id, doc_id)
        select _event, d.id from public.docs d where d.path = 'syla/chute-sort'
        on conflict do nothing;
    end if;

    insert into public.chute_settings (profile_id)
    values (_owner)
    on conflict (profile_id) do nothing;
end
$$;

-- ── The dispatcher grows the chute branch ────────────────────────────────
--
-- Body otherwise 20261006000000's. The branch runs each tick, before the
-- fire step, so a due sort rides the same webhook batch: per profile with
-- a chute, due = the cadence says so (last_sorted_at vs the latest passed
-- slot, America/New_York — the same latch style as events) AND at least
-- one raw item. Queueing stamps last_sorted_at in the same tick.

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
    select array_agg(r.id), string_agg(distinct e.title, ', ')
    into _to_fire, _names
    from public.syla_job_runs r
    join public.events e on e.id = r.event_id
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
            'text', 'Queued Syla events: ' || _names
                    || '. The syla_job_runs queue is the source of truth. '
                    || 'Each run points at an events row assigned to you: do '
                    || 'what the event says — the row, its child todos '
                    || '(todo.event_id) and its attached docs (event_docs -> '
                    || 'docs) together are the instructions.'),
        timeout_milliseconds := 15000);

    update public.syla_job_runs
    set fired_at = _now, fire_count = fire_count + 1, fire_request_id = _req
    where id = any (_to_fire);
end;
$$;

-- ── Sort now ─────────────────────────────────────────────────────────────

create function public.sort_chute_now()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _profile uuid;
    _event   uuid;
    _run     uuid;
    _url     text;
    _token   text;
    _req     bigint;
    _fired   boolean := false;
begin
    if not public.is_owner() then
        raise exception 'only the owner sorts the chute';
    end if;
    _profile := public.current_profile_id();
    if _profile is null then
        raise exception 'no profile for this session';
    end if;

    select e.id into _event
    from public.events e
    where e.profile_id = _profile and e.assignee = 'syla' and e.title = 'Chute sort'
    limit 1;

    -- A deleted (or pre-chute) install heals here: recreate the seeded
    -- event, latched like the seed makes it.
    if _event is null then
        insert into public.events (profile_id, title, assignee,
                                   start_date, start_time, end_time, freq, interval_n)
        values (_profile, 'Chute sort', 'syla',
                (now() at time zone 'America/New_York')::date,
                time '15:00', time '15:30', 'daily', 1)
        returning id into _event;

        update public.events set last_fired_on = date '9999-12-31'
        where id = _event;

        insert into public.event_docs (event_id, doc_id)
        select _event, d.id from public.docs d where d.path = 'syla/chute-sort'
        on conflict do nothing;
    end if;

    insert into public.chute_settings (profile_id)
    values (_profile)
    on conflict (profile_id) do nothing;

    insert into public.syla_job_runs (event_id)
    values (_event)
    returning id into _run;

    update public.chute_settings
    set last_sorted_at = now()
    where profile_id = _profile;

    -- Fire now, the dispatcher's own way; without a credential the run
    -- waits for the every-minute tick.
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
                'text', 'The owner tapped Sort now. Claim as usual — the '
                        || 'run''s event is the Chute sort; its attached doc '
                        || '(syla/chute-sort) is the procedure.'),
            timeout_milliseconds := 15000);

        update public.syla_job_runs
        set fired_at = now(), fire_count = fire_count + 1, fire_request_id = _req
        where id = _run;
        _fired := true;
    end if;

    return jsonb_build_object('run_id', _run, 'fired', _fired);
end;
$$;

comment on function public.sort_chute_now() is
    'The chute header''s Sort now: queues a run of the owner''s Chute sort event (recreating the seeded event if it went missing), stamps the cadence latch, and fires the routine webhook inline from the Vault credential — send_to_syla''s pattern. Owner only. Returns {run_id, fired}.';

revoke all on function public.sort_chute_now() from public;
grant execute on function public.sort_chute_now() to authenticated;
