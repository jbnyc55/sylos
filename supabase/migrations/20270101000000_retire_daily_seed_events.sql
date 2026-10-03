-- The seed slims to what a fresh install actually needs.
--
-- Crowning used to seed five Syla events: four dailies (note siloing,
-- edit feedback, goal synergy, day summary) plus the Chute sort. The
-- chute branch fires the sort only when raw items wait, but the four
-- dailies ride the generic due-scan, which queues them unconditionally
-- — on a fresh install that is four sessions a day that claim, find
-- nothing, and finish. And none of them is load-bearing on day one:
--
--   * Note siloing re-vets placements against a silo vocabulary that
--     doesn't exist yet — and the chute sort already silos things
--     correctly at filing time.
--   * Goal synergy needs multiple populated goal maps.
--   * Day summary has nothing to roll up until there is data, and
--     feeds the older goal-map calendar surface.
--   * Edit feedback IS load-bearing — without it a changes_requested
--     proposal is never revised — but it is reactive work, not daily
--     work, so it becomes an inline fire below instead of a cron.
--
-- So the seed drops to the Chute sort plus an 'Edit feedback' event
-- kept the chute's way: PRE-LATCHED FOREVER (last_fired_on 9999-12-31)
-- so the due-scan never fires it, existing only so a run has an event
-- — its attached doc (syla/edit-feedback) is the procedure, its
-- history shows in Syla Tasks. Its one dispatcher is a trigger on the
-- two proposal tables: the owner flagging a proposal
-- (status -> changes_requested) queues a run and fires the webhook
-- inline, send_to_syla's arrangement — flips coalesce onto a
-- still-queued run, and without a stored credential the run waits for
-- the every-minute tick. After this, the generic due-scan serves only
-- events the owner put on the calendar themself.
--
-- Existing installs catch up below. The three retired events are
-- deleted guarded by their seeded shape (title, assignee, daily/1, no
-- end bound) and by having no child todos — a row the owner reshaped,
-- bounded, or hung todos under is theirs and stays (it keeps firing on
-- its schedule, which is then their choice). Their run history goes
-- with them (syla_job_runs cascades), with row_edits keeping the
-- images, and their docs stay — instruction docs are append-only
-- history the owner can still read, edit or delete in the app. The
-- seeded 'Daily edit feedback' event is not deleted but converted in
-- place — retitled 'Edit feedback', reshaped to a one-off on its own
-- start date (no more daily band on the calendar for an on-demand
-- job), and pinned — so its doc link and run history ride through.

-- ── The seed: Chute sort + Edit feedback, both pre-latched ───────────────
--
-- Body otherwise 20261124000000's, minus the four dailies. The Edit
-- feedback event is one-off-shaped (freq null, dated the crowning day)
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
            ('Edit feedback', time '09:00', time '09:15', null)
         ) as s (title, starts, ends, freq)
    where not exists (select 1 from public.events e
                      where e.title = s.title and e.assignee = 'syla');

    insert into public.event_docs (event_id, doc_id)
    select e.id, d.id
    from (values
            ('Chute sort',    'syla/chute-sort'),
            ('Edit feedback', 'syla/edit-feedback')
         ) as s (title, doc_path)
    join public.events e on e.title = s.title and e.assignee = 'syla'
    join public.docs d on d.path = s.doc_path
    on conflict do nothing;

    -- Both events are dispatched by their own paths alone (the chute
    -- branch; the proposal-feedback trigger): latch the generic
    -- due-scan off forever.
    update public.events
    set last_fired_on = date '9999-12-31'
    where title in ('Chute sort', 'Edit feedback')
      and assignee = 'syla' and profile_id = new.id;

    insert into public.chute_settings (profile_id)
    values (new.id)
    on conflict (profile_id) do nothing;

    insert into public.chats (chat_key, kind, title)
    select 'syla-chat', 'syla', 'Syla'
    where not exists (select 1 from public.chats where kind = 'syla');

    return new;
end
$$;

-- ── The inline fire: a flagged proposal wakes Syla ───────────────────────
--
-- One function, a trigger on each proposal table. Only the owner can
-- put a row in changes_requested (the claude policies check into
-- pending/withdrawn alone), so every fire is the owner's own flag.
-- A deleted (or pre-seed) install heals here: recreate the event,
-- latched like the seed makes it — sort_chute_now's arrangement.

create function public.proposal_feedback_wakes_syla()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    _event uuid;
    _run   uuid;
    _url   text;
    _token text;
    _req   bigint;
begin
    select e.id into _event
    from public.events e
    where e.assignee = 'syla' and e.title = 'Edit feedback'
    order by e.created_at asc
    limit 1;

    if _event is null then
        insert into public.events (profile_id, title, assignee,
                                   start_date, start_time, end_time, freq, interval_n)
        values (new.profile_id, 'Edit feedback', 'syla',
                (now() at time zone 'America/New_York')::date,
                time '09:00', time '09:15', null, 1)
        returning id into _event;

        update public.events set last_fired_on = date '9999-12-31'
        where id = _event;

        insert into public.event_docs (event_id, doc_id)
        select _event, d.id from public.docs d where d.path = 'syla/edit-feedback'
        on conflict do nothing;
    end if;

    -- Flips coalesce: while a feedback run is still waiting to be
    -- claimed, further flags ride it — the claiming session reads every
    -- flagged row fresh, so one waking covers them all.
    if exists (select 1 from public.syla_job_runs r
               where r.event_id = _event and r.status = 'queued') then
        return new;
    end if;

    insert into public.syla_job_runs (event_id)
    values (_event)
    returning id into _run;

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
                'text', 'The owner requested changes on an edit proposal. '
                        || 'Claim as usual — the run''s event is Edit '
                        || 'feedback; its attached doc (syla/edit-feedback) '
                        || 'is the procedure: read every changes_requested '
                        || 'row in agent_map_proposals and '
                        || 'agent_todo_proposals and revise or withdraw '
                        || 'each one.'),
            timeout_milliseconds := 15000);

        update public.syla_job_runs
        set fired_at = now(), fire_count = fire_count + 1, fire_request_id = _req
        where id = _run;
    end if;

    return new;
end;
$$;

comment on function public.proposal_feedback_wakes_syla() is
    'The edit-feedback loop''s dispatcher: the owner flagging a proposal (status -> changes_requested) queues a run of the pre-latched Edit feedback event and fires the routine webhook inline, so the revision happens now instead of on a daily cron. Flips coalesce onto a still-queued run; a missing event heals latched; without a stored credential the run waits for the every-minute dispatcher.';

create trigger agent_map_proposals_feedback_wakes_syla
    after update on public.agent_map_proposals
    for each row
    when (new.status = 'changes_requested'
          and old.status is distinct from new.status)
    execute function public.proposal_feedback_wakes_syla();

create trigger agent_todo_proposals_feedback_wakes_syla
    after update on public.agent_todo_proposals
    for each row
    when (new.status = 'changes_requested'
          and old.status is distinct from new.status)
    execute function public.proposal_feedback_wakes_syla();

-- ── Backfill: existing installs shed the dailies ─────────────────────────

-- The seeded edit-feedback event converts in place, keeping its doc
-- link and run history. No time match in the guard: pre-20261006
-- installs carried the syla_jobs-era times through the events move, so
-- the seeded row's times vary by generation; the title, the daily/1
-- shape and the absent end bound are the seeded signature (the end
-- bound also keeps the freq flip inside events_end_needs_freq). The
-- retitle+reshape trips the reset-latch trigger; the pin after it
-- touches no schedule field, so it sticks.
update public.events
set title = 'Edit feedback', freq = null
where title = 'Daily edit feedback' and assignee = 'syla'
  and freq = 'daily' and interval_n = 1
  and until_date is null and count_n is null;

update public.events
set last_fired_on = date '9999-12-31'
where title = 'Edit feedback' and assignee = 'syla'
  and last_fired_on is distinct from date '9999-12-31';

-- The three retired dailies go, same seeded signature, plus: nothing
-- the owner hung under them (child todos cascade with an event, and
-- those are theirs). syla_job_runs and event_docs cascade; row_edits
-- keeps the images.
delete from public.events e
where e.assignee = 'syla'
  and e.title in ('Daily note siloing', 'Goal synergy linking',
                  'Morning day summary')
  and e.freq = 'daily' and e.interval_n = 1
  and e.until_date is null and e.count_n is null
  and not exists (select 1 from public.todo t where t.event_id = e.id);
