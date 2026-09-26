-- day_summary: one row per (profile, day) of rolled-up stats for the calendar,
-- written once daily by the Claude morning routine (skills: daily-summary).
--
-- The calendar's streak ✕ is gone; past day cells now show summary stats
-- instead. Stats live in ONE jsonb column so the set of metrics can grow
-- without schema changes. The agreed shape, which the skill and the web
-- client both rely on:
--
--   {
--     "insights": "One or two sentences on how to optimize this day.",
--     "calories": { "value": 2150,  "description": "what this measures" },
--     "spend":    { "value": 63.20, "description": "what this measures" }
--   }
--
-- `insights` is the one top-level string; every other key is a metric object
-- carrying a numeric `value` and a `description` of what it measures and how
-- it was computed. New metrics are new keys, nothing else.
--
-- The client only ever READS this table — rollups are never computed or
-- stored by the browser (see notes/08-daily-logs-and-plaid.md). The write
-- path is the claude role, through the structured upsert_day_summary RPC
-- below, following the log_agent_edit pattern from 20260820000000: no dynamic
-- SQL, gate on the Vault key, `set local role claude`, one upsert.

create table public.day_summary (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    day         date not null,
    stats       jsonb not null default '{}'::jsonb check (jsonb_typeof(stats) = 'object'),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),

    -- Re-running the routine for a day must replace, never stack.
    unique (profile_id, day)
);

comment on table public.day_summary is
    'Per-day rollup of the raw logs, written by the daily Claude routine. stats: {"insights": text, "<metric>": {"value": number, "description": text}}.';

create index day_summary_profile_id_day_idx
    on public.day_summary (profile_id, day desc);

create trigger day_summary_set_updated_at
    before update on public.day_summary
    for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.day_summary enable row level security;

-- Owners read their own summaries; there is deliberately no insert/update/
-- delete for authenticated — the client never writes rollups.
create policy "Day summaries are viewable by their owner"
    on public.day_summary for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- The claude role reads everything, per 20260816000300…
create policy "claude reads everything"
    on public.day_summary for select
    to claude
    using (true);

-- …and, unusually, WRITES this table: it is the routine's output. This widens
-- the role's write surface from "append to agent_edits" to "append to
-- agent_edits + own the day_summary rollups". Still no delete, and the only
-- transport is the structured RPC below.
create policy "claude writes day summaries"
    on public.day_summary for insert
    to claude
    with check (true);

create policy "claude updates day summaries"
    on public.day_summary for update
    to claude
    using (true)
    with check (true);

-- Privileges mirror the policies (see 20260816000200). claude's SELECT
-- arrives via default privileges. Its write grants are COLUMN-scoped: it may
-- create a row (naming only the keys and the stats) and edit stats on an
-- existing row — id and the timestamps stay on their defaults and triggers,
-- unreachable even through the RPC below.
grant select on public.day_summary to authenticated;
grant insert (profile_id, day, stats) on public.day_summary to claude;
grant update (stats) on public.day_summary to claude;

-- ---------------------------------------------------------------------------
-- upsert_day_summary — the routine's write path over HTTPS
-- ---------------------------------------------------------------------------
--
-- Same contract as log_agent_edit (20260820000000): gate on the Vault key,
-- switch to claude, one structured write — arguments, never SQL. Upserting on
-- (profile_id, day) makes re-running a day idempotent and backfills cheap.

create or replace function public.upsert_day_summary(
    _profile_id uuid,
    _day        date,
    _stats      jsonb
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    result jsonb;
begin
    perform public.assert_claude_rq_key();

    if _stats is null or jsonb_typeof(_stats) <> 'object' then
        raise exception 'stats must be a JSON object';
    end if;

    set local statement_timeout = '30s';
    set local role claude;

    insert into public.day_summary (profile_id, day, stats)
    values (_profile_id, _day, _stats)
    on conflict (profile_id, day)
    do update set stats = excluded.stats
    returning jsonb_build_object('id', id, 'day', day, 'updated_at', updated_at)
    into result;

    return result;
end;
$$;

comment on function public.upsert_day_summary(uuid, date, jsonb) is
    'Upserts one day_summary row as the claude role. Gated by assert_claude_rq_key().';

revoke all on function public.upsert_day_summary(uuid, date, jsonb) from public;
grant execute on function public.upsert_day_summary(uuid, date, jsonb) to anon;
