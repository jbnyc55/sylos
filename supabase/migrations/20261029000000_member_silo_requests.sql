-- Silo membership requests: an existing member can knock.
--
-- Invites flow outward (the owner mints, the friend claims —
-- 20261027000000), but a member already inside has no way to ask for
-- more: "add me to your location silo so my copy of the app can plot
-- you." Until now that ask traveled out-of-band or got shoehorned into a
-- free-text edit proposal. This queue gives it a first-class shape, the
-- third of its kind after member_prompt_requests and
-- member_edit_requests — and it deliberately stays a queue: approving is
-- the owner inserting the silo_members row from the app (stamping the
-- silo's defaults as always), never anything this table does by itself.
--
-- The silo is named as FREE TEXT, not a foreign key, for two reasons: a
-- member can only see silos they are already in, so an FK could not name
-- the one they want; and free text confirms nothing — a request for a
-- silo that doesn't exist reads the same as one that does, so the queue
-- never leaks the owner's vocabulary. A vibe app's manifest names the
-- silo it expects (skills/vibe-apps), and this is how its members ask to
-- be let in.
--
-- No new permission gates it: anyone holding a live member token may ask
-- (they are already inside the trust boundary), and a small pending cap
-- plus one-open-ask-per-silo keep it from becoming noise.

create table public.member_silo_requests (
    id           uuid primary key default gen_random_uuid(),
    member_id    uuid not null references public.members (id) on delete cascade,
    -- What the member calls the silo they want into — the owner's
    -- vocabulary is theirs to match up.
    silo_name    text not null check (char_length(silo_name) between 1 and 50),
    message      text not null default '' check (char_length(message) <= 1000),
    status       text not null default 'pending'
                     check (status in ('pending', 'approved', 'declined')),
    created_at   timestamptz not null default now(),
    resolved_at  timestamptz,
    check ((status = 'pending') = (resolved_at is null))
);

comment on table public.member_silo_requests is
    'Members asking to be admitted to a silo, by name. The owner resolves each from the app — approving means inserting the silo_members row there; this queue only records the ask and the ruling.';

create unique index member_silo_requests_one_pending
    on public.member_silo_requests (member_id, lower(silo_name))
    where status = 'pending';

-- ── Row level security ───────────────────────────────────────────────────

alter table public.member_silo_requests enable row level security;

-- Owner: sees the queue, rules on it, prunes old rows.
create policy "Silo requests are viewable by the owner"
    on public.member_silo_requests for select to authenticated
    using (public.is_owner());
create policy "Silo requests are resolvable by the owner"
    on public.member_silo_requests for update to authenticated
    using (public.is_owner()) with check (public.is_owner());
create policy "Silo requests are deletable by the owner"
    on public.member_silo_requests for delete to authenticated
    using (public.is_owner());

-- Member: reads their own asks and rulings back — part of the ungated
-- whoami surface, like the other two queues. Writing goes through
-- member_request_silo below, never directly.
create policy "A member reads their own silo requests"
    on public.member_silo_requests for select to member
    using (member_id = public.current_member_id());

create policy "claude reads silo requests"
    on public.member_silo_requests for select to claude
    using (true);

grant select, delete on public.member_silo_requests to authenticated;
grant update (status, resolved_at) on public.member_silo_requests to authenticated;
grant select on public.member_silo_requests to member;
grant select on public.member_silo_requests to claude;

-- ---------------------------------------------------------------------------
-- member_request_silo — token in, queued ask out
-- ---------------------------------------------------------------------------
--
-- Same shape as member_submit_prompt: SECURITY DEFINER because the member
-- role holds no insert grant — this function is the single gate. It
-- authenticates the token, caps the backlog, refuses a duplicate open ask
-- for the same silo, and stamps app.member_id first so row_edits
-- attributes the insert to the member.

create function public.member_request_silo(
    _token text, _silo_name text, _message text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    mid uuid;
    rid uuid;
begin
    mid := public.authenticate_member(_token);

    if _silo_name is null or btrim(_silo_name) = '' then
        raise exception 'name the silo you are asking into';
    end if;
    if char_length(btrim(_silo_name)) > 50 then
        raise exception 'silo name is longer than 50 characters';
    end if;
    if _message is not null and char_length(_message) > 1000 then
        raise exception 'message is longer than 1000 characters';
    end if;

    if (select count(*) from public.member_silo_requests
        where member_id = mid and status = 'pending') >= 5 then
        raise exception 'you already have 5 pending requests — wait for rulings first';
    end if;

    if exists (select 1 from public.member_silo_requests
               where member_id = mid
                 and lower(silo_name) = lower(btrim(_silo_name))
                 and status = 'pending') then
        raise exception 'you already have a pending request for this silo';
    end if;

    perform set_config('app.member_id', mid::text, true);

    insert into public.member_silo_requests (member_id, silo_name, message)
    values (mid, btrim(_silo_name), coalesce(btrim(_message), ''))
    returning id into rid;

    return jsonb_build_object('id', rid, 'status', 'pending');
end;
$$;

comment on function public.member_request_silo(text, text, text) is
    'Queues one silo membership ask for the owner to rule on. Returns the request id; the member polls it back through member_rq.';

revoke all on function public.member_request_silo(text, text, text) from public;
grant execute on function public.member_request_silo(text, text, text) to anon;
