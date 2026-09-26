-- Events carry the siloed mark like every other record type: null means
-- unsiloed unless event_silos says otherwise; a timestamp means marked
-- handled by hand even without placements.

alter table public.events add column siloed_at timestamptz;

comment on column public.events.siloed_at is
    'Marked siloed by hand: out of the To-silo backlog even without event_silos placements.';
