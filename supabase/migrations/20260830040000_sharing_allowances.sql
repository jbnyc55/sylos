-- Sharing allowances: each note type declares where its content may be sent.
--
-- Types are becoming audiences ("besties can see my bank data") as well as
-- categories, and audiences differ in what they may do with content — a group
-- may read something it must never forward to a model provider. So the
-- sharing policy hangs on the type: an extensible vocabulary of destinations
-- (sharing_allowances, seeded with local model / personal cloud / public
-- cloud) and a junction naming the destinations each type permits.
--
-- The semantics every consumer must honor:
--
--   * DENY BY DEFAULT. A type with no allowance rows shares nowhere. The
--     seeded types therefore start fully private until the user opts in.
--   * INTERSECTION ACROSS TYPES. A note may go to a destination only when
--     every one of its types allows that destination — the most restrictive
--     tag wins. An untagged note shares nowhere.
--   * Allowances govern sending content ONWARD (to groups, exports, model
--     providers on the reader's side). The owner's own in-house routines
--     (tagging, daily summary) are the owner processing their own data and
--     are not gated here.
--
-- Nothing in the app sends content anywhere yet; this is the policy layer
-- those features must consult when they arrive.

create table public.sharing_allowances (
    id          uuid primary key default gen_random_uuid(),
    name        text not null unique check (char_length(name) between 1 and 50),
    created_at  timestamptz not null default now()
);

comment on table public.sharing_allowances is
    'The vocabulary of sharing destinations a note type can permit (local model, personal cloud, …). App-wide; users add new ones from the tag modal.';

insert into public.sharing_allowances (name)
values ('local model'), ('personal cloud'), ('public cloud');

create table public.note_type_allowances (
    note_type_id  uuid not null references public.note_types (id) on delete cascade,
    allowance_id  uuid not null references public.sharing_allowances (id) on delete cascade,
    primary key (note_type_id, allowance_id)
);

comment on table public.note_type_allowances is
    'Which sharing destinations each note type permits. No rows for a type = that type shares nowhere; a note''s effective set is the intersection across its types.';

-- ---------------------------------------------------------------------------
-- Editable note types
-- ---------------------------------------------------------------------------
--
-- The tag modal now edits existing types (name, description, allowances), so
-- the "rename only by migration" stance from 20260828050000 relaxes to name
-- and description. Deleting a type still stays a by-migration act — dropping
-- one silently untags every note under it.

create policy "Note types are updatable by signed-in users"
    on public.note_types for update
    to authenticated
    using (true)
    with check (true);

grant update (name, description) on public.note_types to authenticated;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.sharing_allowances   enable row level security;
alter table public.note_type_allowances enable row level security;

-- sharing_allowances mirror note_types: shared vocabulary, readable and
-- extendable by any signed-in user, never edited or deleted from the client —
-- an allowance's meaning must not shift under the types already using it.
create policy "Sharing allowances are viewable by signed-in users"
    on public.sharing_allowances for select
    to authenticated
    using (true);

create policy "Sharing allowances are insertable by signed-in users"
    on public.sharing_allowances for insert
    to authenticated
    with check (true);

-- The junction is the per-type policy itself: signed-in users set and unset.
create policy "Type allowances are viewable by signed-in users"
    on public.note_type_allowances for select
    to authenticated
    using (true);

create policy "Type allowances are insertable by signed-in users"
    on public.note_type_allowances for insert
    to authenticated
    with check (true);

create policy "Type allowances are deletable by signed-in users"
    on public.note_type_allowances for delete
    to authenticated
    using (true);

-- The claude role reads both, like every application table — routines that
-- share content onward must consult these before doing so.
create policy "claude reads everything"
    on public.sharing_allowances for select
    to claude
    using (true);

create policy "claude reads everything"
    on public.note_type_allowances for select
    to claude
    using (true);

-- Privileges mirror the policies exactly (see 20260816000200).
grant select, insert on public.sharing_allowances to authenticated;
grant select, insert, delete on public.note_type_allowances to authenticated;
