-- Per-guest token lifetimes, and an instant block.
--
-- Each guest gets a token_ttl_days the owner sets in the Guests tab: how
-- long a claimed key works before the guest must re-verify their email for
-- a fresh one. Null means the key never expires on its own. And because a
-- ttl only stops them *eventually*, a blocked flag covers the gap between
-- "the key would elapse" and "I want them out now": flipping it on refuses
-- their very next query, and flipping it off restores the same key — no
-- re-claim needed, unlike Revoke, which destroys the key outright.
--
-- Everything is enforced DYNAMICALLY — authenticate_guest re-reads the row
-- on every call and compares claimed_at + ttl against now(), nothing is
-- stored at claim time — so ttl changes, blocks, and revokes all hit the
-- current key immediately: shortening a ttl to 1 day kills a week-old key
-- on their next query, and clearing token_hash (Revoke) cuts off the next
-- call the moment it commits.

alter table public.guests
    add column token_ttl_days integer
        check (token_ttl_days is null or token_ttl_days between 1 and 3650),
    add column blocked boolean not null default false;

comment on column public.guests.token_ttl_days is
    'How many days a claimed key lasts before the guest must re-verify their email. Null = no expiry. Enforced live against claimed_at, so changes hit the current key too.';

comment on column public.guests.blocked is
    'Instant suspension: true refuses every query on the guest''s next call, false restores the same key. Orthogonal to expiry and revocation.';

-- The owner sets both alongside the existing token_hash revoke path.
grant update (token_ttl_days, blocked) on public.guests to authenticated;

-- authenticate_guest grows the block and expiry checks. Same contract
-- otherwise: SECURITY DEFINER only to read guests, 28000 on every failure,
-- and the last_seen_at touch happens only for a token that actually passed.
create or replace function public.authenticate_guest(_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    g record;
begin
    if _token is null or char_length(_token) < 32 then
        raise exception 'missing or malformed guest token' using errcode = '28000';
    end if;

    select id, claimed_at, token_ttl_days, blocked into g
    from public.guests
    where token_hash = encode(extensions.digest(_token, 'sha256'), 'hex');

    if g.id is null then
        raise exception 'invalid guest token' using errcode = '28000';
    end if;

    if g.blocked then
        raise exception 'guest access is blocked' using errcode = '28000';
    end if;

    if g.token_ttl_days is not null
       and g.claimed_at is not null
       and g.claimed_at + make_interval(days => g.token_ttl_days) <= now() then
        raise exception 'guest token expired — verify your email again to claim a fresh key'
            using errcode = '28000';
    end if;

    update public.guests set last_seen_at = now() where id = g.id;

    return g.id;
end;
$$;
