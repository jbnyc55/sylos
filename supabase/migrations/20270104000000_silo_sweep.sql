-- The silo sweep: siloing becomes stock, scheduled, and simpler.
--
-- Three product decisions land together, all from the Silos app redesign:
--
-- 1. SILOING IS STOCK, the chute's way. The retired daily note-siloing
--    cron (20270101000000) left scheduled siloing to chute-filing time;
--    this brings it back as a first-class stock job: a 'Silo sweep'
--    event seeded PRE-LATCHED FOREVER (last_fired_on = 9999-12-31) so
--    the generic due-scan never fires it, a silo_settings row holding
--    the owner's cadence (hourly / thrice / nightly at a time / weekly
--    — the stock setting is nightly at 02:00), and a sweep branch in
--    syla_dispatch() as its only dispatcher. An empty backlog never
--    wakes anyone: the branch fires only when unsiloed notes or docs
--    wait (or a retroactive re-sweep was requested, below). The seeded
--    event mirrors the cadence on the calendar, so Syla Tasks shows the
--    real schedule; 'Silo now' is sweep_silos_now(), owner-only,
--    queue-and-fire-inline — sort_chute_now's pattern.
--
-- 2. A RULEBOOK CHANGE ASKS: FORWARD-ONLY OR RETROACTIVE? Editing a
--    silo's description changes what Syla files there from now on; it
--    says nothing about the records already placed. The app now asks,
--    and "retroactive" stamps silos.resweep_requested_at — the next
--    sweep re-reads that silo's existing placements against the new
--    rulebook (every move trigger-logged in row_edits, so undoable),
--    then clears the stamp through the gated clear_silo_resweep().
--    Forward-only — the default, and "decide later" — stamps nothing.
--
-- 3. BEING IN A SILO IS THE GRANT. The three per-follow toggles
--    (allows_sql / allows_prompts / allows_edits) made membership mean
--    "maybe reads, configurable"; the model simplifies to: a follower
--    in a silo READS it, full stop — add to share, remove to unshare.
--    Columns stay (append-only history; prompts/edits remain per-person
--    levers elsewhere), but allows_sql now defaults true at both levels
--    and every existing follow is backfilled readable. Putting a record
--    in a silo was already the grant; putting a person in one now is
--    too.

-- ── The sweep settings ───────────────────────────────────────────────────

create table public.silo_settings (
    profile_id    uuid primary key default public.current_profile_id()
                  references public.profiles (id) on delete cascade,
    cadence       text not null default 'daily'
                  check (cadence in ('hourly', 'thrice', 'daily', 'weekly')),
    -- Used when cadence = 'daily' (nightly at this time) or 'weekly'
    -- (Sunday at this time); 'thrice' is the fixed trio 09:00 / 13:00 /
    -- 18:00 local, 'hourly' is on the hour-ish.
    daily_time    time not null default '02:00',
    last_swept_at timestamptz,
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

comment on table public.silo_settings is
    'One row per profile: when Syla sweeps unsiloed records into silos (cadence + daily_time; ''thrice'' means 09:00/13:00/18:00 local, ''weekly'' means Sunday at daily_time). The stock setting is nightly at 02:00. last_swept_at is the dispatcher''s latch, stamped when a sweep run is queued.';
comment on column public.silo_settings.last_swept_at is
    'When a sweep run was last queued (stamped by the dispatcher and sweep_silos_now). The cadence latch: hourly = an hour since; thrice/daily/weekly = the latest passed slot not yet covered.';

create trigger silo_settings_set_updated_at
    before update on public.silo_settings
    for each row execute function public.set_updated_at();

alter table public.silo_settings enable row level security;
select public.declare_table_siloing('silo_settings', 'system');

create policy "Silo settings are their profile's"
    on public.silo_settings for all to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));
create policy "claude reads silo settings"
    on public.silo_settings for select to claude using (true);
create policy "claude stamps the sweep time"
    on public.silo_settings for update to claude
    using (true) with check (true);

grant select, insert, update, delete on public.silo_settings to authenticated;
grant select on public.silo_settings to claude;
grant update (last_swept_at) on public.silo_settings to claude;

-- ── Retroactive rulebook changes ─────────────────────────────────────────

alter table public.silos add column resweep_requested_at timestamptz;

comment on column public.silos.resweep_requested_at is
    'Stamped by the owner when a rulebook (description) change should apply retroactively: the next sweep re-reads this silo''s existing placements against the new rulebook — every move trigger-logged, so undoable — and clears the stamp through clear_silo_resweep(). Null means the change was forward-only.';

-- The sweep's close-out: only the stamp moves, only when set, as the
-- claude role — logged like every silos write.
grant update (resweep_requested_at) on public.silos to claude;

create policy "claude clears the resweep stamp"
    on public.silos for update to claude
    using (resweep_requested_at is not null)
    with check (resweep_requested_at is null);

create function public.clear_silo_resweep(_silo_id uuid)
returns jsonb
language plpgsql
security invoker
as $$
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    update public.silos
    set resweep_requested_at = null
    where id = _silo_id and resweep_requested_at is not null;

    if not found then
        raise exception 'no silo with id % awaits a re-sweep', _silo_id;
    end if;

    return jsonb_build_object('id', _silo_id, 'resweep', 'done');
end;
$$;

comment on function public.clear_silo_resweep(uuid) is
    'Marks one silo''s requested retroactive re-sweep done, as the claude role — called AFTER the sweep actually re-read that silo''s placements against the new rulebook. Only a stamped silo moves. Gated by assert_claude_rq_key().';

revoke all on function public.clear_silo_resweep(uuid) from public;
grant execute on function public.clear_silo_resweep(uuid) to anon;

-- ── Being in a silo is the grant ─────────────────────────────────────────

alter table public.silos alter column default_allows_sql set default true;
alter table public.silo_followers alter column allows_sql set default true;

update public.silos
set default_allows_sql = true
where not default_allows_sql;

update public.silo_followers
set allows_sql = true
where not allows_sql;

comment on column public.silos.default_allows_sql is
    'Kept at true: being admitted to a silo IS the read grant. Historical per-silo default from the configurable-permissions era; the app no longer surfaces it.';
comment on column public.silo_followers.allows_sql is
    'True for every follow since the membership-is-the-grant change: a follower in a silo reads it, full stop. The column remains the lever follower_rq checks.';

-- ── The job's instructions ───────────────────────────────────────────────

insert into public.docs (path, title, html)
select 'syla/silo-sweep', 'Silo sweep', $doc$<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Silo sweep</title>
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
<h1>Silo sweep</h1>
<p>Unsiloed records wait; this run places them. A silo's rulebook is its <code>description</code> (what belongs, then "But not: …") plus any <code>silo_rules</code> sentences — read both and honor them exactly; a silo with followers is a sharing decision, so place carefully. Load <code>skills/silo-edits</code> if proposing a rulebook change seems warranted; never change a rulebook yourself.</p>
<pre>scripts/rq "select id, name, description, resweep_requested_at from silos order by name"
scripts/rq "select s.name, r.kind, r.body from silo_rules r join silos s on s.id = r.silo_id"</pre>
<ol>
<li><strong>The backlog.</strong> Unvetted jots and unplaced docs:
<pre>scripts/rq "select n.id, n.note_type, n.body from manual_notes n
where n.parent_note_id is null and n.silos_vetted_at is null
  and not exists (select 1 from note_silos s where s.note_id = n.id)
  and not exists (select 1 from silo_asks a where a.note_id = n.id and a.status = 'open')
order by n.created_at"

scripts/rq "select d.id, d.path, d.title from docs d
where d.siloed_at is null
  and not exists (select 1 from doc_silos s where s.doc_id = d.id)
  and not exists (select 1 from doc_followers f where f.doc_id = d.id)
  and not exists (select 1 from silo_asks a where a.doc_id = d.id and a.status = 'open')
order by d.created_at"</pre></li>
<li><strong>Place each record</strong>: <code>scripts/silo-note --note &lt;id&gt; --silos &lt;silo-ids&gt;</code> (an empty <code>--silos ""</code> is the honest "nothing fits" — it still stamps the vetting) and <code>scripts/doc-silo --path &lt;a/b/c&gt; --silos &lt;silo-ids&gt;</code>. Answered <code>silo_asks</code> are precedent: match the owner's past rulings before judging fresh.</li>
<li><strong>Ambiguity is a question, never a guess</strong>: <code>scripts/silo-ask</code> with the silos you weighed and how sure you were. Leave the record at that; a future sweep picks it up with the answer.</li>
<li><strong>Retroactive rulebook changes.</strong> A silo with <code>resweep_requested_at</code> set had its rulebook changed and the owner chose "retroactive": re-read every record currently placed there against the NEW rulebook, move out (and re-home) what no longer belongs, and pull in clear matches the old rulebook missed where you meet them. Every move is trigger-logged and undoable, so be decisive. Then close it out: the <code>clear_silo_resweep(_silo_id)</code> RPC.</li>
</ol>
<p>Then finish the run as usual (<code>scripts/syla-finish</code>) with a one-line summary — how many placed, how many questions, which silos re-swept. Prefer a reasonable placement over a pile of questions: the owner can undo any move in one tap.</p>
<footer>doc <code>syla/silo-sweep</code></footer>
</body></html>$doc$
where not exists (select 1 from public.docs where path = 'syla/silo-sweep');

-- A system doc's siloing is decided at the seed: stamped, in no silo —
-- it never shows in Unsiloed and never wakes the sweep below.
update public.docs set siloed_at = now()
where path = 'syla/silo-sweep' and siloed_at is null;

-- ── Doc vetting leaves a stamp ───────────────────────────────────────────
--
-- silo-note's set_note_silos always stamped silos_vetted_at, so a jot
-- vetted into zero silos is provably done; set_doc_silos never stamped,
-- so a doc Syla read and placed nowhere stayed "unsiloed" forever — in
-- the Unsiloed count, and (below) in the sweep branch's waiting check,
-- which must converge. Same body as 20260926000000's, plus the stamp.

create or replace function public.set_doc_silos(_path text, _silo_ids uuid[])
returns jsonb
language plpgsql
as $$
declare
    _doc_id uuid;
    removed integer;
    added   integer;
begin
    perform public.assert_claude_rq_key();

    if _silo_ids is null then
        raise exception 'silo_ids must be an array (possibly empty), not null';
    end if;

    set local statement_timeout = '30s';
    set local role claude;

    select id into _doc_id from public.docs where path = _path;
    if _doc_id is null then
        raise exception 'no doc at %', _path;
    end if;

    delete from public.doc_silos
    where doc_id = _doc_id
      and silo_id <> all (_silo_ids);
    get diagnostics removed = row_count;

    insert into public.doc_silos (doc_id, silo_id)
    select _doc_id, unnest(_silo_ids)
    on conflict do nothing;
    get diagnostics added = row_count;

    -- The vetting stamp: this doc's siloing was decided, even into zero
    -- silos — the docs' silos_vetted_at.
    update public.docs
    set siloed_at = now()
    where id = _doc_id and siloed_at is null;

    return jsonb_build_object(
        'doc_id',  _doc_id,
        'path',    _path,
        'silos',   coalesce(array_length(_silo_ids, 1), 0),
        'added',   added,
        'removed', removed
    );
end;
$$;

comment on function public.set_doc_silos(text, uuid[]) is
    'Replaces one doc''s doc_silos rows with exactly the given silo ids (empty = out of every silo) and stamps siloed_at — the doc''s siloing was decided, so Unsiloed and the sweep stop counting it. As the claude role; gated by assert_claude_rq_key().';

-- Backfill: the seeded system docs (hers, not the owner's unfiled data)
-- count as decided too — without this every install holds a permanently
-- "unsiloed" pile that would wake the sweep below each slot forever.
update public.docs set siloed_at = now()
where (path like 'syla/%' or path like 'skills/%' or path like 'notes/%')
  and siloed_at is null;

-- ── Seeding: the event, its doc, the settings row ────────────────────────
--
-- seed_owner_defaults is 20270101000000's body plus the sweep pieces. The
-- 'Silo sweep' event is inserted daily-shaped at the stock 02:00 block
-- and then latched forever — the second UPDATE touches no schedule
-- field, so the reset-latch trigger keeps the value.

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
           (now() at time zone 'America/New_York')::date, s.starts, s.ends, s.freq, 1
    from (values
            ('Chute sort',    time '15:00', time '15:30', 'daily'),
            ('Silo sweep',    time '02:00', time '02:30', 'daily'),
            ('Edit feedback', time '09:00', time '09:15', null)
         ) as s (title, starts, ends, freq)
    where not exists (select 1 from public.events e
                      where e.title = s.title and e.assignee = 'syla');

    insert into public.event_docs (event_id, doc_id)
    select e.id, d.id
    from (values
            ('Chute sort',    'syla/chute-sort'),
            ('Silo sweep',    'syla/silo-sweep'),
            ('Edit feedback', 'syla/edit-feedback')
         ) as s (title, doc_path)
    join public.events e on e.title = s.title and e.assignee = 'syla'
    join public.docs d on d.path = s.doc_path
    on conflict do nothing;

    -- All three are dispatched by their own paths alone (the chute
    -- branch; the sweep branch; the proposal-feedback trigger): latch
    -- the generic due-scan off forever.
    update public.events
    set last_fired_on = date '9999-12-31'
    where title in ('Chute sort', 'Silo sweep', 'Edit feedback')
      and assignee = 'syla' and profile_id = new.id;

    insert into public.chute_settings (profile_id)
    values (new.id)
    on conflict (profile_id) do nothing;

    insert into public.silo_settings (profile_id)
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
                   where e.title = 'Silo sweep' and e.assignee = 'syla') then
        insert into public.events (profile_id, title, assignee,
                                   start_date, start_time, end_time, freq, interval_n)
        values (_owner, 'Silo sweep', 'syla',
                (now() at time zone 'America/New_York')::date,
                time '02:00', time '02:30', 'daily', 1)
        returning id into _event;

        update public.events set last_fired_on = date '9999-12-31'
        where id = _event;

        insert into public.event_docs (event_id, doc_id)
        select _event, d.id from public.docs d where d.path = 'syla/silo-sweep'
        on conflict do nothing;
    end if;

    insert into public.silo_settings (profile_id)
    values (_owner)
    on conflict (profile_id) do nothing;
end
$$;

-- ── The seeded event mirrors the cadence ─────────────────────────────────
--
-- chute_settings_mirror_event's arrangement (20261206000000): whenever
-- cadence or daily_time changes, the Silo sweep event's calendar shape
-- follows —
--
--   daily   → the daily_time, a half-hour block (clamped at midnight)
--   thrice  → 09:00–18:00
--   hourly  → 00:00–23:59, daily
--   weekly  → the daily_time block, weekly on Sunday
--
-- — and the forever-latch is re-pinned in a second UPDATE that touches
-- no schedule field, because the reset-latch trigger clears
-- last_fired_on on any schedule change and an un-latched Silo sweep
-- would fire twice (the generic due-scan plus the sweep branch).

create function public.silo_settings_mirror_event()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    _start time;
    _end   time;
    _freq  text;
    _bywd  smallint[];
begin
    if new.cadence in ('daily', 'weekly') then
        _start := coalesce(new.daily_time, time '02:00');
        if _start >= time '23:30' then
            _end := time '23:59:59';
        else
            _end := _start + interval '30 minutes';
        end if;
    elsif new.cadence = 'thrice' then
        _start := time '09:00';
        _end   := time '18:00';
    else -- hourly
        _start := time '00:00';
        _end   := time '23:59:59';
    end if;

    if new.cadence = 'weekly' then
        _freq := 'weekly';
        _bywd := array[0]::smallint[];
    else
        _freq := 'daily';
        _bywd := null;
    end if;

    update public.events
    set start_time = _start, end_time = _end, freq = _freq, byweekday = _bywd
    where title = 'Silo sweep' and assignee = 'syla'
      and profile_id = new.profile_id
      and (start_time is distinct from _start or end_time is distinct from _end
           or freq is distinct from _freq or byweekday is distinct from _bywd);

    -- Re-pin the forever-latch the reshape just reset.
    update public.events
    set last_fired_on = date '9999-12-31'
    where title = 'Silo sweep' and assignee = 'syla'
      and profile_id = new.profile_id
      and last_fired_on is distinct from date '9999-12-31';

    return new;
end;
$$;

create trigger silo_settings_mirror_event
    after insert or update of cadence, daily_time on public.silo_settings
    for each row execute function public.silo_settings_mirror_event();

comment on function public.silo_settings_mirror_event() is
    'Keeps the seeded Silo sweep event''s calendar shape mirroring silo_settings (daily → the daily_time block; thrice → 09:00–18:00; hourly → all day; weekly → the block on Sunday) so Syla Tasks shows the real schedule, and re-pins last_fired_on = 9999-12-31 after the reshape — the sweep branch stays the event''s only dispatcher.';

-- Backfill: existing installs mirror their (stock) cadence once.
update public.events e
set (start_time, end_time) = (time '02:00', time '02:30')
from public.silo_settings ss
where e.title = 'Silo sweep' and e.assignee = 'syla'
  and e.profile_id = ss.profile_id
  and ss.cadence = 'daily'
  and (e.start_time is distinct from time '02:00'
       or e.end_time is distinct from time '02:30');

update public.events
set last_fired_on = date '9999-12-31'
where title = 'Silo sweep' and assignee = 'syla'
  and last_fired_on is distinct from date '9999-12-31';

-- ── The dispatcher grows the sweep branch ────────────────────────────────
--
-- Body otherwise 20261227000000's. The sweep branch sits after the chute
-- branch, same latch style: per profile with silo_settings, due = the
-- cadence says so (last_swept_at vs the latest passed slot,
-- America/New_York) AND something waits — an unvetted top-level jot, an
-- unplaced unshared doc (neither carrying an open silo ask), or a silo
-- stamped for a retroactive re-sweep. Queueing stamps last_swept_at in
-- the same tick.

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
    _week_slot  timestamp;
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

    -- The sweep branch: a due cadence with unsiloed records waiting (or
    -- a retroactive re-sweep requested) queues a run of the
    -- (forever-pre-latched) Silo sweep event and stamps the latch.
    for _cs in
        select ss.profile_id, ss.cadence, ss.daily_time, ss.last_swept_at,
               (select e.id from public.events e
                where e.profile_id = ss.profile_id
                  and e.assignee = 'syla'
                  and e.title = 'Silo sweep'
                order by e.created_at asc
                limit 1) as event_id
        from public.silo_settings ss
        where exists (
                  select 1 from public.manual_notes n
                  where n.profile_id = ss.profile_id
                    and n.parent_note_id is null
                    and n.silos_vetted_at is null
                    and not exists (select 1 from public.note_silos j
                                    where j.note_id = n.id)
                    and not exists (select 1 from public.silo_asks a
                                    where a.note_id = n.id and a.status = 'open'))
              or exists (
                  select 1 from public.docs d
                  where d.siloed_at is null
                    and not exists (select 1 from public.doc_silos j
                                    where j.doc_id = d.id)
                    and not exists (select 1 from public.doc_followers f
                                    where f.doc_id = d.id)
                    and not exists (select 1 from public.silo_asks a
                                    where a.doc_id = d.id and a.status = 'open'))
              or exists (select 1 from public.silos s
                         where s.resweep_requested_at is not null)
    loop
        if _cs.event_id is null then
            continue;
        end if;
        if _cs.cadence = 'hourly' then
            _due := _cs.last_swept_at is null
                    or _cs.last_swept_at <= _now - interval '1 hour';
        elsif _cs.cadence = 'thrice' then
            select max(t) into _slot
            from unnest(array[time '09:00', time '13:00', time '18:00']) as t
            where t <= _local_time;
            _due := _slot is not null
                    and (_cs.last_swept_at is null
                         or (_cs.last_swept_at at time zone 'America/New_York')
                            < _local_date + _slot);
        elsif _cs.cadence = 'weekly' then
            -- The most recent Sunday slot at daily_time.
            _week_slot := (_local_date
                           - extract(dow from _local_date)::int)
                          + _cs.daily_time;
            _due := (_local_date + _local_time) >= _week_slot
                    and (_cs.last_swept_at is null
                         or (_cs.last_swept_at at time zone 'America/New_York')
                            < _week_slot);
        else
            _due := _local_time >= _cs.daily_time
                    and (_cs.last_swept_at is null
                         or (_cs.last_swept_at at time zone 'America/New_York')
                            < _local_date + _cs.daily_time);
        end if;

        if _due then
            insert into public.syla_job_runs (event_id)
            values (_cs.event_id);
            update public.silo_settings
            set last_swept_at = _now
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

-- ── Silo now ─────────────────────────────────────────────────────────────

create function public.sweep_silos_now()
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
        raise exception 'only the owner sweeps the silos';
    end if;
    _profile := public.current_profile_id();
    if _profile is null then
        raise exception 'no profile for this session';
    end if;

    select e.id into _event
    from public.events e
    where e.profile_id = _profile and e.assignee = 'syla' and e.title = 'Silo sweep'
    order by e.created_at asc
    limit 1;

    -- A deleted (or pre-sweep) install heals here: recreate the seeded
    -- event, latched like the seed makes it.
    if _event is null then
        insert into public.events (profile_id, title, assignee,
                                   start_date, start_time, end_time, freq, interval_n)
        values (_profile, 'Silo sweep', 'syla',
                (now() at time zone 'America/New_York')::date,
                time '02:00', time '02:30', 'daily', 1)
        returning id into _event;

        update public.events set last_fired_on = date '9999-12-31'
        where id = _event;

        insert into public.event_docs (event_id, doc_id)
        select _event, d.id from public.docs d where d.path = 'syla/silo-sweep'
        on conflict do nothing;
    end if;

    insert into public.silo_settings (profile_id)
    values (_profile)
    on conflict (profile_id) do nothing;

    insert into public.syla_job_runs (event_id)
    values (_event)
    returning id into _run;

    update public.silo_settings
    set last_swept_at = now()
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
                'text', 'The owner tapped Silo now. Claim as usual — the '
                        || 'run''s event is the Silo sweep; its attached '
                        || 'doc (syla/silo-sweep) is the procedure.'),
            timeout_milliseconds := 15000);

        update public.syla_job_runs
        set fired_at = now(), fire_count = fire_count + 1, fire_request_id = _req
        where id = _run;
        _fired := true;
    end if;

    return jsonb_build_object('run_id', _run, 'fired', _fired);
end;
$$;

comment on function public.sweep_silos_now() is
    'The Silos app''s Silo now: queues a run of the owner''s Silo sweep event (recreating the seeded event if it went missing), stamps the cadence latch, and fires the routine webhook inline from the Vault credential — sort_chute_now''s pattern. Owner only. Returns {run_id, fired}.';

revoke all on function public.sweep_silos_now() from public;
grant execute on function public.sweep_silos_now() to authenticated;
