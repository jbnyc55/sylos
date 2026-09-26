-- Both logs gain an unspoofable actor_id.
--
-- edited_by (row_edits) and agent (agent_edits) name a *role* — 'claude',
-- 'authenticated' — but several actors share a role: every guest arrives as
-- the same role with only app.guest_id telling them apart, and every
-- signed-in app session shares 'authenticated' with auth.uid() naming the
-- person. Once more than one agent can be messing with the same tables, the
-- role name alone cannot answer "who did this". actor_id records the finer
-- identity, and it is stamped by triggers — never accepted from the client —
-- so it cannot be claimed falsely.
--
-- actor_id is null when the role itself is the whole identity: the claude
-- role today authenticates with a single shared key, so there is no finer id
-- to record until per-agent identities exist (at which point the rq gate
-- should set an app.* setting and current_actor_id() grows a branch for it).

-- ---------------------------------------------------------------------------
-- current_actor_id — the finer identity behind current_user
-- ---------------------------------------------------------------------------

create function public.current_actor_id()
returns uuid
language sql
stable
set search_path = ''
as $$
    select coalesce(
        nullif(current_setting('app.guest_id', true), '')::uuid,
        auth.uid()
    )
$$;

comment on function public.current_actor_id() is
    'The specific actor behind current_user: the guest (app.guest_id, set by authenticate_guest) or the signed-in user (auth.uid()). Null when the role itself is the whole identity, e.g. the claude role until per-agent ids exist.';

-- ---------------------------------------------------------------------------
-- row_edits.actor_id
-- ---------------------------------------------------------------------------

alter table public.row_edits add column actor_id uuid;

comment on column public.row_edits.actor_id is
    'current_actor_id() at DML time, stamped inside the log_row_edit trigger like edited_by, so it cannot be masked. Null for rows whose role is the whole identity.';

-- Same function as 20260830080000_wiki.sql, plus the actor_id stamp.
create or replace function public.log_row_edit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    _row_id uuid;
begin
    if tg_op = 'DELETE' then
        _row_id := old.id;
    else
        _row_id := new.id;
    end if;

    insert into public.row_edits (table_name, row_id, op, edited_by, actor_id, old_row, new_row)
    values (
        tg_table_name,
        _row_id,
        tg_op,
        current_user,
        public.current_actor_id(),
        case when tg_op = 'INSERT' then null else to_jsonb(old) end,
        case when tg_op = 'DELETE' then null else to_jsonb(new) end
    );

    return null;
end;
$$;

comment on function public.log_row_edit() is
    'AFTER row trigger: appends the full before/after row images to row_edits as the role doing the DML, so edited_by and actor_id cannot be masked.';

-- ---------------------------------------------------------------------------
-- agent_edits.actor_id
-- ---------------------------------------------------------------------------
--
-- agent_edits stays the voluntary narrative log and its agent column stays
-- client-chosen prose — but who actually inserted each row is now recorded
-- the same unspoofable way as in row_edits: stamped by a trigger, with any
-- client-supplied value overwritten.

alter table public.agent_edits add column actor_id uuid;

comment on column public.agent_edits.actor_id is
    'current_actor_id() at insert time, stamped by the stamp_agent_edit_actor trigger; a client-supplied value is overwritten. Null for rows whose role is the whole identity.';

create function public.stamp_agent_edit_actor()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.actor_id := public.current_actor_id();
    return new;
end;
$$;

comment on function public.stamp_agent_edit_actor() is
    'BEFORE INSERT trigger on agent_edits: forces actor_id to the real actor, ignoring whatever the insert supplied.';

-- Only triggers run this; execute-permission on trigger functions is checked
-- against the table owner at creation time, so no role needs a grant.
revoke all on function public.stamp_agent_edit_actor() from public;

create trigger agent_edits_stamp_actor
    before insert on public.agent_edits
    for each row execute function public.stamp_agent_edit_actor();
