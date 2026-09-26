-- The ranked mind map: goals and their ranked methods of action, recursively.
--
-- One table of cells forming a forest. A cell with no parent is a top-level
-- goal; its children are the methods of action for reaching it, ranked
-- against each other. Every method is itself a goal to its own children, so
-- the structure recurses: goal → ranked methods → each method's ranked
-- methods, drawn left to right in the web app.

create table public.mind_map_cells (
    id          uuid primary key default gen_random_uuid(),
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    parent_id   uuid,
    title       text not null check (char_length(title) between 1 and 200),
    -- Position among siblings; lower ranks first. The client assigns
    -- max(sibling rank) + 1 on insert and swaps values to reorder.
    rank        integer not null default 0,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),

    -- The composite parent FK below needs this pair to point at; it is what
    -- keeps a cell from being attached under another profile's cell.
    unique (id, profile_id),
    foreign key (parent_id, profile_id)
        references public.mind_map_cells (id, profile_id)
        on delete cascade
);

comment on table public.mind_map_cells is
    'Ranked mind map: a forest of cells. parent_id null = a top-level goal; children are its ranked methods of action, each recursively a goal of its own. The composite (parent_id, profile_id) FK pins every child to its parent''s profile.';

-- The page loads a profile's whole map and groups by parent; siblings render
-- in rank order.
create index mind_map_cells_profile_parent_rank_idx
    on public.mind_map_cells (profile_id, parent_id, rank);

create trigger mind_map_cells_set_updated_at
    before update on public.mind_map_cells
    for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.mind_map_cells enable row level security;

-- Fully owned by the profile that created them; parent integrity is the
-- composite FK's job, not the policies'.
create policy "Mind map cells are viewable by their owner"
    on public.mind_map_cells for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Mind map cells are insertable by their owner"
    on public.mind_map_cells for insert
    to authenticated
    with check (profile_id = (select public.current_profile_id()));

create policy "Mind map cells are updatable by their owner"
    on public.mind_map_cells for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Mind map cells are deletable by their owner"
    on public.mind_map_cells for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- The claude role reads every application table; its select grant arrives via
-- default privileges (20260816000300).
create policy "claude reads everything"
    on public.mind_map_cells for select
    to claude
    using (true);

-- Privileges mirror the policies exactly (see 20260816000200): both gates
-- must open for a row to be reachable, and anon gets nothing. Edit logging
-- attaches itself via the event trigger from 20260831010000.
grant select, insert, update, delete on public.mind_map_cells to authenticated;
