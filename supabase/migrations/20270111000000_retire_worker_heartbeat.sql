-- Retire the Mac worker's heartbeat machinery.
--
-- The Mac app era is over: setup and sign-in live on desktop web, the
-- connector routine is the worker (notes/13-claude-connector.md), and
-- the clients no longer draw routing cues. What 20270108000000 and
-- 20270109000000 built for the Mac-default arrangement therefore
-- comes out — new installs should not carry a heartbeat table nobody
-- stamps or a status RPC nobody reads:
--
--   worker_presence       the ~20s heartbeat the Mac app stamped
--   worker_heartbeat()    the stamp-and-peek RPC it called
--   syla_worker_status()  the owner-only classification the apps drew
--                         "on your Mac" / "in the cloud" from
--
-- What stays, deliberately:
--   - syla_job_runs.claimed_by and its check ('mac'|'cloud'|'routine'):
--     the recorded history of where past runs executed, and 'routine' /
--     'cloud' are still stamped today (connector sessions and Daytona).
--   - The syla-fire function and the whole Daytona fallback: it simply
--     provisions on every accepted fire now, with no heartbeat to
--     stand down on (the function change rides this migration).
--   - clear_syla_webhook(): generic webhook plumbing, not Mac-specific.
--
-- Presence was cosmetic by design — watched, never audited — so
-- dropping the table loses narration history only, never a recorded
-- fact of any run.

drop function public.syla_worker_status();
drop function public.worker_heartbeat(text, text);
drop table public.worker_presence;
