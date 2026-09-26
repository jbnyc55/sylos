-- Health: HealthKit samples, streamed into rows.
--
-- The richest passive source a phone has — steps, sleep, workouts, heart
-- rate, weight — and locked to the device by design: HealthKit has no
-- server API at all, so the app is the only possible sync engine. With
-- Health read access granted it uploads new samples through
-- record_health_samples (a phone_devices key, scope 'health'); HealthKit
-- background delivery wakes the app when new data lands, and anchored
-- queries make each upload exactly the delta since the last.
--
-- Unlike the contacts and calendar mirrors this table is APPEND-ONLY like
-- user_locations — samples are readings, not documents. Each row keeps
-- HealthKit's own sample UUID as its dedupe key, so retried batches and
-- re-anchored queries land once. Deletions on the Health side are not
-- chased ("raw logs now, aggregation later" — the log is what happened);
-- the owner can delete rows any time, and the row_edits log is the undo.
--
-- `kind` is a short app-chosen name ('steps', 'sleep', 'workout', …), not
-- the HKQuantityTypeIdentifier spelling, so queries read naturally and new
-- kinds need no migration. Quantity samples carry value+unit; category
-- samples (sleep stages) and workouts carry text_value too.

create table public.health_samples (
    id         uuid primary key default gen_random_uuid(),
    profile_id uuid not null references public.profiles (id) on delete cascade,
    device_id  uuid references public.phone_devices (id) on delete set null,
    -- 'steps', 'heart_rate', 'resting_heart_rate', 'weight',
    -- 'active_energy', 'distance', 'sleep', 'workout', … — the app names
    -- kinds; new ones need no migration.
    kind       text not null check (kind ~ '^[a-z0-9_]{1,60}$'),
    starts_at  timestamptz not null,
    ends_at    timestamptz not null,
    -- Quantity kinds: the number and its unit ('count', 'count/min', 'kg',
    -- 'kcal', 'm', 's'). Null for purely categorical samples.
    value      double precision,
    unit       text check (char_length(unit) <= 40),
    -- Categorical payload: the sleep stage ('core', 'rem', 'deep', …) or
    -- the workout activity ('running', 'traditional_strength_training', …).
    text_value text check (char_length(text_value) <= 200),
    -- What recorded it, as HealthKit reports it ("Apple Watch", an app name).
    source     text not null default '' check (char_length(source) <= 300),
    -- HKSample.uuid — HealthKit's own identity for the sample, which is
    -- what makes retried uploads idempotent.
    dedupe     text not null check (char_length(dedupe) between 1 and 100),
    created_at timestamptz not null default now(),

    unique (profile_id, dedupe),
    check (ends_at >= starts_at)
);

comment on table public.health_samples is
    'Append-only mirror of the phone''s HealthKit samples, one row per sample, written by record_health_samples with a scope-health device key. Idempotent per (profile, HealthKit UUID); rollups are Syla''s jobs'' work, never the client''s.';

create index health_samples_kind_idx on public.health_samples (profile_id, kind, starts_at desc);

alter table public.health_samples enable row level security;

create policy "Health samples are viewable by their profile or the owner"
    on public.health_samples for select to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());
create policy "Health samples are deletable by their profile or the owner"
    on public.health_samples for delete to authenticated
    using (profile_id = (select public.current_profile_id()) or public.is_owner());

create policy "claude reads health samples"
    on public.health_samples for select to claude using (true);

grant select, delete on public.health_samples to authenticated;
grant select on public.health_samples to claude;

-- ---------------------------------------------------------------------------
-- record_health_samples — the phone's upload, as anon with the device key
-- ---------------------------------------------------------------------------
--
-- _samples is a JSON array of {kind, starts_at, ends_at, value, unit,
-- text_value, source, dedupe}. Append-only with on conflict do nothing,
-- so anchored-query overlaps and retried batches are harmless; malformed
-- rows are dropped rather than failing the batch.

create function public.record_health_samples(_token text, _samples jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _device   record;
    _given    integer;
    _inserted integer;
begin
    select * into _device from public.phone_device_for(_token, 'health');

    if _samples is null or jsonb_typeof(_samples) <> 'array' then
        raise exception 'samples must be a JSON array';
    end if;
    _given := jsonb_array_length(_samples);
    if _given > 2000 then
        raise exception 'at most 2000 samples per call (got %)', _given;
    end if;

    set local statement_timeout = '60s';

    insert into public.health_samples (
        profile_id, device_id, kind, starts_at, ends_at,
        value, unit, text_value, source, dedupe)
    select _device.profile_id, _device.device_id,
           s.kind, s.starts_at,
           greatest(s.ends_at, s.starts_at),
           s.value,
           left(s.unit, 40),
           left(s.text_value, 200),
           left(coalesce(s.source, ''), 300),
           left(s.dedupe, 100)
    from jsonb_to_recordset(_samples) as s (
        kind text, starts_at timestamptz, ends_at timestamptz,
        value double precision, unit text, text_value text,
        source text, dedupe text)
    where s.kind ~ '^[a-z0-9_]{1,60}$'
      and s.starts_at is not null
      and s.ends_at is not null
      and s.dedupe is not null and s.dedupe <> ''
    on conflict (profile_id, dedupe) do nothing;

    get diagnostics _inserted = row_count;

    return jsonb_build_object('inserted', _inserted, 'received', _given);
end;
$$;

comment on function public.record_health_samples(text, jsonb) is
    'Appends a batch of HealthKit samples for the device key''s profile. Idempotent per (profile, dedupe) — retried and overlapping batches land once. Raises 28000 for an unknown or wrong-scope key.';

revoke all on function public.record_health_samples(text, jsonb) from public;
grant execute on function public.record_health_samples(text, jsonb) to anon, authenticated;
