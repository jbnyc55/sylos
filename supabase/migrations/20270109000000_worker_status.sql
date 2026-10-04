-- syla_worker_status(): the one read behind the apps' routing cues.
--
-- The phone draws "on your Mac" / "in the cloud" from two facts it
-- cannot assemble on its own: the Mac's worker_presence heartbeat
-- (20270108000000) is readable, but whether a fire webhook is armed —
-- and at what — lives in Vault, which no client may read. This
-- SECURITY DEFINER function answers only the classification, never a
-- secret: the newest heartbeat, whether it is fresh (the same 90s
-- window syla-fire stands down on), and the webhook's kind ('cloud'
-- when it points at this project's own syla-fire function, 'routine'
-- for an Anthropic fire URL, null when nothing is armed).
--
-- The cues stay honest about the three real states: fresh heartbeat →
-- the Mac has it; stale + armed → the next run executes in the cloud;
-- stale + nothing armed → runs wait for the Mac. No heartbeat ever →
-- the pre-Mac arrangement, and the apps show nothing.

create function public.syla_worker_status()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    _seen timestamptz;
    _name text;
    _url  text;
begin
    if not public.is_owner() then
        raise exception 'only the owner reads worker status';
    end if;

    select wp.last_seen_at, wp.device_name into _seen, _name
    from public.worker_presence wp
    order by wp.last_seen_at desc
    limit 1;

    select decrypted_secret into _url
    from vault.decrypted_secrets where name = 'syla_webhook_url';

    return jsonb_build_object(
        'seen_at',     _seen,
        'device_name', _name,
        -- Keep this window equal to syla-fire's default
        -- WORKER_FRESH_SECONDS, so the cue and the routing agree.
        'fresh',       _seen is not null and _seen > now() - interval '90 seconds',
        'fallback',    case
                           when _url is null then null
                           when _url like '%/functions/v1/syla-fire' then 'cloud'
                           else 'routine'
                       end);
end;
$$;

comment on function public.syla_worker_status() is
    'Owner-only: the routing-cue read — newest worker_presence heartbeat (seen_at, device_name, fresh within syla-fire''s 90s window) and the armed webhook''s kind (''cloud'' = this project''s syla-fire, ''routine'' = Anthropic, null = nothing armed). Returns classification only; no Vault secret ever leaves.';

revoke all on function public.syla_worker_status() from public;
grant execute on function public.syla_worker_status() to authenticated;
