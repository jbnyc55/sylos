-- Draw the network canvas as an actual network.
--
-- The canvas becomes a node-and-edge diagram: entity cards are draggable
-- nodes with a position, link and target cards are edges wired between two
-- entities, and collective cards are hulls drawn around their member
-- entities. Three additions carry that:
--
--   1. x/y on cards — an entity node's position on the graph plane (null =
--      auto-layout until first dragged).
--   2. source_id/target_id on cards — the two entities an edge connects
--      (link and target sections; null = not yet drawn on the graph).
--   3. network_collective_members — which entities each collective card
--      encloses, a junction because one entity can sit in several
--      collectives at once.
--   4. qty / qty_growth / growth_kind — the quantified assumption behind a
--      node or edge (how many now, how fast it grows, linearly or
--      compounding), which is what lets the canvas project the network
--      forward on a time slider: node bubbles swell, edges thicken and new
--      relationships fade in as the months advance. Revising the numbers as
--      claims get validated regenerates the whole projection, since every
--      future state is computed from them.
--
-- The annotation sections (the five properties, campaign, spread, handoff)
-- ignore all of this and keep rendering as cards beside the graph.

alter table public.network_strategy_cards
    add column x double precision,
    add column y double precision,
    add column source_id uuid,
    add column target_id uuid,
    add column qty double precision,
    add column qty_growth double precision,
    add column growth_kind text not null default 'linear'
        check (growth_kind in ('linear', 'compound')),
    -- The composite FKs below (and the junction's) point at this pair; it
    -- is what keeps an edge or a membership from reaching across profiles.
    add constraint network_strategy_cards_id_profile_key unique (id, profile_id);

-- Self-referencing composite FKs pin both endpoints to the row's own
-- profile. On endpoint deletion only the endpoint column resets — the
-- column list keeps profile_id out of the set-null — leaving the edge card
-- un-drawn rather than gone. (Cards are normally soft-deleted anyway; the
-- app treats an edge whose endpoint is soft-deleted as un-drawn too.)
alter table public.network_strategy_cards
    add constraint network_strategy_cards_source_fkey
        foreign key (source_id, profile_id)
        references public.network_strategy_cards (id, profile_id)
        on delete set null (source_id),
    add constraint network_strategy_cards_target_fkey
        foreign key (target_id, profile_id)
        references public.network_strategy_cards (id, profile_id)
        on delete set null (target_id);

comment on column public.network_strategy_cards.x is
    'Entity sections only: the node''s center x on the graph plane; null = auto-layout until first dragged.';
comment on column public.network_strategy_cards.y is
    'Entity sections only: the node''s center y on the graph plane; null = auto-layout until first dragged.';
comment on column public.network_strategy_cards.source_id is
    'Link/target sections only: the entity card this edge leaves from; null = not yet drawn on the graph.';
comment on column public.network_strategy_cards.target_id is
    'Link/target sections only: the entity card this edge points at; null = not yet drawn on the graph.';
comment on column public.network_strategy_cards.qty is
    'Entity/link/target sections: how many such entities or relationships exist now (the t=0 of the projection); null = not quantified, drawn unscaled.';
comment on column public.network_strategy_cards.qty_growth is
    'How qty changes per month: linear = net adds per month, compound = percent per month. Null = flat.';
comment on column public.network_strategy_cards.growth_kind is
    'Shape of the growth projection: ''linear'' (qty + growth×t) or ''compound'' (qty × (1 + growth/100)^t) — the doc''s threshold-vs-viral distinction, made computable.';

create table public.network_collective_members (
    collective_id uuid not null,
    entity_id     uuid not null,
    profile_id    uuid not null references public.profiles (id) on delete cascade,
    created_at    timestamptz not null default now(),

    primary key (collective_id, entity_id),
    foreign key (collective_id, profile_id)
        references public.network_strategy_cards (id, profile_id)
        on delete cascade,
    foreign key (entity_id, profile_id)
        references public.network_strategy_cards (id, profile_id)
        on delete cascade
);

comment on table public.network_collective_members is
    'Which entity cards each collective card encloses on the network canvas — the hull drawn around a collective is the hull of these members. A junction because one entity can belong to several collectives.';

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.network_collective_members enable row level security;

create policy "Collective members are viewable by their owner"
    on public.network_collective_members for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Collective members are insertable by their owner"
    on public.network_collective_members for insert
    to authenticated
    with check (profile_id = (select public.current_profile_id()));

create policy "Collective members are deletable by their owner"
    on public.network_collective_members for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- The claude role reads every application table; its select grant arrives via
-- default privileges (20260816000300).
create policy "claude reads everything"
    on public.network_collective_members for select
    to claude
    using (true);

-- Membership rows are only ever added and removed whole — there is nothing
-- on them to update, so no update grant or policy.
grant select, insert, delete on public.network_collective_members to authenticated;
