-- Live status notes: the receipt ladder narrates while Syla works.
--
-- Today the ladder's top rung is one static line — started_at flips and
-- the thread says "Syla's reading…" until the reply lands, however long
-- the run takes. This migration gives a running run a one-line status
-- the session keeps fresh, so the owner watches the work move:
--
--   Reading up in your docs…  →  Checking the calendar…  →
--   Crunching the numbers on notes…  →  Writing your reply…
--
-- Deliberately NOT realtime: no websockets, no channels, no new client
-- machinery. The note is two columns on syla_job_runs; the app's
-- existing receipt polling simply reads them. And the notes themselves
-- cost nothing to produce: scripts/rq translates each query it ships
-- into a phrase deterministically (table → wording, string matching
-- only — no model call, and the raw SQL itself is never shown), while
-- scripts/syla-status lets the session set a milestone line by hand.
-- Statuses are cosmetic by design — the ladder's FACTS stay the
-- timestamps and the reply row, exactly as 20261126000000 drew them.

alter table public.syla_job_runs
    add column status_note    text
        check (status_note is null or char_length(status_note) <= 120),
    add column status_note_at timestamptz;

comment on column public.syla_job_runs.status_note is
    'One line of what the session is doing right now, set via set_syla_run_status() while the run is ''running'' (scripts/rq derives it from each query; scripts/syla-status sets it by hand). Cosmetic narration for the Syla-thread receipt — never a recorded fact; the timestamps and the reply row stay the ladder''s truth.';
comment on column public.syla_job_runs.status_note_at is
    'When status_note was last refreshed.';

-- The claude role may touch only the two note columns beyond what
-- 20260920000000 granted; the existing "claude advances syla job runs"
-- update policy already covers the rows (status stays ''running'').
grant update (status_note, status_note_at) on public.syla_job_runs to claude;

-- ---------------------------------------------------------------------------
-- set_syla_run_status — the one write path for the note
-- ---------------------------------------------------------------------------
-- Same contract as every claude write (notes/03-agent-access.md): gate on
-- the Vault rq key, `set local role claude`, structured arguments. One
-- deliberate difference: a run that is not (or no longer) 'running' is NOT
-- an error — status is narration, and a note racing the finish must never
-- crash the tooling mid-run. The caller learns via `noted` instead.

create function public.set_syla_run_status(_run_id uuid, _note text)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _clean text;
    _id    uuid;
begin
    perform public.assert_claude_rq_key();

    -- One tidy line whatever arrives: whitespace (newlines included)
    -- collapsed, trimmed, clipped to the column's 120, empty becomes
    -- null — which clears the note rather than storing a blank.
    _clean := nullif(left(btrim(regexp_replace(coalesce(_note, ''), '\s+', ' ', 'g')), 120), '');

    set local statement_timeout = '10s';
    set local role claude;

    update public.syla_job_runs
    set status_note = _clean, status_note_at = now()
    where id = _run_id and status = 'running'
    returning id into _id;

    return jsonb_build_object('run_id', _run_id, 'noted', _id is not null);
end;
$$;

comment on function public.set_syla_run_status(uuid, text) is
    'Sets (or, with an empty note, clears) the live status line on one running syla job run, as the claude role — the Syla thread shows it in place of "Syla''s reading…". Best-effort on purpose: a run that is not running answers noted=false instead of raising. Gated by assert_claude_rq_key().';

revoke all on function public.set_syla_run_status(uuid, text) from public;
grant execute on function public.set_syla_run_status(uuid, text) to anon;
