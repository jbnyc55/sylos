-- The Chute sort event mirrors the cadence.
--
-- The sorting schedule lives in chute_settings — the dispatcher's
-- chute branch reads it, the Chute page edits it — while Syla Jobs
-- renders her CALENDAR: the seeded 'Chute sort' event, whose times
-- were frozen at the seed's 15:00 block however the cadence changed.
-- So "Syla sorts hourly" on one page and "Chute sort, 3pm" on the
-- other. This trigger keeps the placeholder honest: whenever cadence
-- or daily_time changes, the event's time block follows —
--
--   daily   → the daily_time, a half-hour block (clamped at midnight)
--   thrice  → 09:00–18:00 (first slot to last)
--   hourly  → 00:00–23:59 (any hour raw items wait)
--
-- — and the forever-latch is re-pinned in a second UPDATE that touches
-- no schedule field, the seed's own pattern, because the reset-latch
-- trigger clears last_fired_on on any start_time change and an
-- un-latched Chute sort would fire twice (the generic due-scan plus
-- the chute branch). The trigger fires only on cadence/daily_time
-- (and insert), never on the dispatcher's last_sorted_at stamps.

create function public.chute_settings_mirror_event()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    _start time;
    _end   time;
begin
    if new.cadence = 'daily' then
        _start := coalesce(new.daily_time, time '15:00');
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

    update public.events
    set start_time = _start, end_time = _end
    where title = 'Chute sort' and assignee = 'syla'
      and profile_id = new.profile_id
      and (start_time is distinct from _start or end_time is distinct from _end);

    -- Re-pin the forever-latch the retime just reset.
    update public.events
    set last_fired_on = date '9999-12-31'
    where title = 'Chute sort' and assignee = 'syla'
      and profile_id = new.profile_id
      and last_fired_on is distinct from date '9999-12-31';

    return new;
end;
$$;

create trigger chute_settings_mirror_event
    after insert or update of cadence, daily_time on public.chute_settings
    for each row execute function public.chute_settings_mirror_event();

comment on function public.chute_settings_mirror_event() is
    'Keeps the seeded Chute sort event''s time block mirroring chute_settings (daily → the daily_time; thrice → 09:00–18:00; hourly → all day) so Syla Jobs shows the real schedule, and re-pins last_fired_on = 9999-12-31 after the retime — the chute branch stays the event''s only dispatcher.';

-- Backfill: existing installs mirror their current cadence once.
update public.events e
set (start_time, end_time) = (
        case when cs.cadence = 'daily'  then coalesce(cs.daily_time, time '15:00')
             when cs.cadence = 'thrice' then time '09:00'
             else time '00:00' end,
        case when cs.cadence = 'daily'  then
                  case when coalesce(cs.daily_time, time '15:00') >= time '23:30'
                       then time '23:59:59'
                       else coalesce(cs.daily_time, time '15:00') + interval '30 minutes' end
             when cs.cadence = 'thrice' then time '18:00'
             else time '23:59:59' end)
from public.chute_settings cs
where e.title = 'Chute sort' and e.assignee = 'syla'
  and e.profile_id = cs.profile_id;

update public.events
set last_fired_on = date '9999-12-31'
where title = 'Chute sort' and assignee = 'syla'
  and last_fired_on is distinct from date '9999-12-31';
