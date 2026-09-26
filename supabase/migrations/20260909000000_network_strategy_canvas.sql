-- The network strategy canvas: write out and validate the components of a
-- network-based growth strategy, per the Network section of the
-- how-to-market-a-startup doc.
--
-- A strategy is one canvas — a fixed grid of sections drawn from the
-- methodology (target link, entities, links, collectives, the five network
-- properties, campaign type, spread conditions, funnel handoff). Each
-- section holds cards: one claim each, carrying a validation status the
-- owner advances as evidence comes in (assumption → testing → validated /
-- invalidated) and free-form evidence notes. The campaign-type call —
-- viral growth vs threshold lowering — is a property of the strategy
-- itself, so it lives on the strategy row; its rationale cards live in the
-- 'campaign' section.

create table public.network_strategies (
    id            uuid primary key default gen_random_uuid(),
    profile_id    uuid not null references public.profiles (id) on delete cascade,
    title         text not null check (char_length(title) between 1 and 200),
    -- 'viral': the network itself can create the target link, so growth can
    -- compound. 'threshold': the network only spreads secondary links
    -- (information, reputation, introductions), so a funnel must finish the
    -- job. Null until the owner makes the call on the canvas.
    campaign_type text check (campaign_type in ('viral', 'threshold')),
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),
    -- Soft delete, like the goal map: stamped rather than removed, so a
    -- strategy and its cards stay recoverable in the table.
    deleted_at    timestamptz,

    -- The cards' composite FK points at this pair; it is what keeps a card
    -- from being attached under another profile's strategy.
    unique (id, profile_id)
);

comment on table public.network_strategies is
    'One network strategy canvas each: a growth strategy analyzed through the network lens of the marketing doc. campaign_type is the viral-vs-threshold call; the canvas cards live in network_strategy_cards.';

create table public.network_strategy_cards (
    id          uuid primary key default gen_random_uuid(),
    strategy_id uuid not null,
    profile_id  uuid not null references public.profiles (id) on delete cascade,
    -- Which box of the canvas the card sits in. The section set is the
    -- methodology itself, so it is fixed here rather than user-defined.
    section     text not null check (section in (
        'target', 'entities', 'links', 'collectives',
        'size', 'growth', 'diffusion', 'criteria', 'rate',
        'campaign', 'spread', 'handoff')),
    -- The claim being made — one hypothesis about the network per card.
    title       text not null check (char_length(title) between 1 and 500),
    -- Where the claim stands: written down, being tested, or resolved
    -- either way. Invalidated cards stay on the canvas — a disproven
    -- assumption is a finding, not clutter.
    status      text not null default 'assumption'
        check (status in ('assumption', 'testing', 'validated', 'invalidated')),
    -- Evidence and reasoning, edited in the drawer when the card is selected.
    notes       text,
    -- Position among the cards of the same section; lower ranks first.
    rank        integer not null default 0,
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    deleted_at  timestamptz,

    foreign key (strategy_id, profile_id)
        references public.network_strategies (id, profile_id)
        on delete cascade
);

comment on table public.network_strategy_cards is
    'The cards on a network strategy canvas: one claim per card, placed in a fixed methodology section, carrying a validation status and evidence notes. The composite (strategy_id, profile_id) FK pins every card to its strategy''s profile.';

-- The page loads a profile's cards for one strategy and groups by section;
-- cards render in rank order within their box.
create index network_strategy_cards_profile_strategy_idx
    on public.network_strategy_cards (profile_id, strategy_id, section, rank);

create trigger network_strategies_set_updated_at
    before update on public.network_strategies
    for each row execute function public.set_updated_at();

create trigger network_strategy_cards_set_updated_at
    before update on public.network_strategy_cards
    for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------

alter table public.network_strategies enable row level security;
alter table public.network_strategy_cards enable row level security;

-- Fully owned by the profile that created them; card-to-strategy integrity
-- is the composite FK's job, not the policies'.
create policy "Network strategies are viewable by their owner"
    on public.network_strategies for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Network strategies are insertable by their owner"
    on public.network_strategies for insert
    to authenticated
    with check (profile_id = (select public.current_profile_id()));

create policy "Network strategies are updatable by their owner"
    on public.network_strategies for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Network strategies are deletable by their owner"
    on public.network_strategies for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Network strategy cards are viewable by their owner"
    on public.network_strategy_cards for select
    to authenticated
    using (profile_id = (select public.current_profile_id()));

create policy "Network strategy cards are insertable by their owner"
    on public.network_strategy_cards for insert
    to authenticated
    with check (profile_id = (select public.current_profile_id()));

create policy "Network strategy cards are updatable by their owner"
    on public.network_strategy_cards for update
    to authenticated
    using (profile_id = (select public.current_profile_id()))
    with check (profile_id = (select public.current_profile_id()));

create policy "Network strategy cards are deletable by their owner"
    on public.network_strategy_cards for delete
    to authenticated
    using (profile_id = (select public.current_profile_id()));

-- The claude role reads every application table; its select grant arrives via
-- default privileges (20260816000300).
create policy "claude reads everything"
    on public.network_strategies for select
    to claude
    using (true);

create policy "claude reads everything"
    on public.network_strategy_cards for select
    to claude
    using (true);

-- Privileges mirror the policies exactly (see 20260816000200): both gates
-- must open for a row to be reachable, and anon gets nothing.
grant select, insert, update, delete on public.network_strategies to authenticated;
grant select, insert, update, delete on public.network_strategy_cards to authenticated;
