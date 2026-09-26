-- The daily summary becomes goal-aware: alongside the metric objects, the
-- routine now writes a `goals` array — one traffic-light entry per live
-- top-level goal-map cell, judged against everything the day logged, with
-- optional advisory map/todo suggestions. Documentation-only change: the
-- stats column stays one jsonb object, and the agreed shape the skill and
-- the web client rely on (see 20260828080000) simply grows a second
-- non-metric key next to `insights`:
--
--   "goals": [
--     {
--       "id": "<mind_map_cells uuid>",
--       "title": "Get lean",
--       "status": "green" | "yellow" | "red",
--       "why": "evidence from the day's data",
--       "map_suggestions": ["optional advisory goal-map edits"],
--       "todo_suggestions": ["optional advisory todos"]
--     }
--   ]
--
-- Suggestions are advisory text only — the routine never writes to
-- mind_map_cells or todo. The client renders the entries as dots on the
-- calendar cells and as cards in the past-day view, and drops malformed
-- entries rather than trusting them.

comment on table public.day_summary is
    'Per-day rollup of the raw logs, written by the daily Claude routine. stats: {"insights": text, "goals": [{"id": uuid, "title": text, "status": "green"|"yellow"|"red", "why": text, "map_suggestions"?: [text], "todo_suggestions"?: [text]}], "<metric>": {"value": number, "description": text}}.';
