-- Let the daily Claude routine log weight lifts it finds in the day's notes.
--
-- The Weights page's table (20260901100000) so far had one writer: the owner,
-- through the app. But lifts also get logged as free-text notes ("benched
-- 185x5 today"), and the morning daily-summary routine already reads every
-- note of the finished day — so it now also extracts lifts and writes them
-- into public.weight_lifts, through a structured RPC in the established
-- upsert_day_summary / tag_note pattern: arguments never SQL, gate on the
-- Vault key, `set local role claude`, one insert.
--
-- Unlike day_summary there is no natural conflict key to upsert on — three
-- identical sets on one day are three legitimate rows. Idempotency across
-- re-runs (and dedup against sets the owner already logged in the app) is
-- therefore the skill's job: it reads the day's existing rows first and only
-- inserts what is missing (skills/../daily-summary).

-- claude may append lifts; still no update or delete — corrections belong to
-- the owner in the app, and every insert lands in row_edits for undo.
create policy "claude logs weight lifts"
    on public.weight_lifts for insert
    to claude
    with check (true);

-- Column-scoped like day_summary's grants: the role names the lift fields
-- and nothing else — id and the timestamps stay on their defaults, and
-- lifted_on must be given explicitly (the routine runs the morning after,
-- so `default current_date` would stamp the wrong day).
grant insert (profile_id, lift, weight_lb, reps, lifted_on)
    on public.weight_lifts to claude;

-- ---------------------------------------------------------------------------
-- log_weight_lift — the routine's write path over HTTPS
-- ---------------------------------------------------------------------------

create or replace function public.log_weight_lift(
    _profile_id uuid,
    _lift       text,
    _weight_lb  numeric,
    _lifted_on  date,
    _reps       integer default null
)
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

    insert into public.weight_lifts (profile_id, lift, weight_lb, reps, lifted_on)
    values (_profile_id, _lift, _weight_lb, _reps, _lifted_on)
    returning jsonb_build_object(
        'id', id, 'lift', lift, 'weight_lb', weight_lb,
        'reps', reps, 'lifted_on', lifted_on)
    into result;

    return result;
end;
$$;

comment on function public.log_weight_lift(uuid, text, numeric, date, integer) is
    'Inserts one weight_lifts row as the claude role — the daily routine''s write path for lifts logged in notes. Gated by assert_claude_rq_key(). Not idempotent: the caller dedupes against the day''s existing rows.';

revoke all on function public.log_weight_lift(uuid, text, numeric, date, integer) from public;
grant execute on function public.log_weight_lift(uuid, text, numeric, date, integer) to anon;
