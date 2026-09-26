-- The network canvas becomes a simulated multi-layer network.
--
-- The model, refined: nodes usually need to KNOW something before they will
-- form the target link, so information linking and target linking are
-- separate layers with separate criteria — the 'criteria' section now means
-- information linking criteria, and a new 'target_criteria' section holds
-- the target side. Different actions spread information at different
-- speeds, so messages become first-class: a new 'messages' section, one
-- card per thing you could do, each carrying its own spread rate (how fast
-- awareness travels an information link) and threshold drop (how much
-- knowing it lowers the bar to the target link) in a params blob.
--
-- The diagram itself is generated, not drawn: a seeded simulation of blue
-- unaware nodes joining, leaving and re-linking around the red "me" node,
-- awareness (yellow) spreading along information links at the active
-- message's rate, and aware nodes eventually re-linking their target link
-- (green) at relink_rate × threshold_drop. Its knobs live in a sim blob on
-- the strategy row.

alter table public.network_strategy_cards
    drop constraint network_strategy_cards_section_check;

alter table public.network_strategy_cards
    add constraint network_strategy_cards_section_check check (section in (
        'target', 'entities', 'links', 'collectives',
        'size', 'growth', 'diffusion', 'criteria', 'target_criteria', 'rate',
        'campaign', 'spread', 'handoff', 'messages'));

alter table public.network_strategy_cards
    add column params jsonb;

comment on column public.network_strategy_cards.params is
    'Section-specific numbers behind the claim. For messages: {"virality": pct chance per information link per month that awareness passes, "threshold_drop": pct of the target-link threshold this message removes once known}. Absent keys fall back to app defaults.';

alter table public.network_strategies
    add column sim jsonb;

comment on column public.network_strategies.sim is
    'Simulation parameters for the generated network diagram: {"network_size", "avg_links", "my_links", "join_pct", "leave_pct", "churn_pct", "relink_pct", "seed", "active_message": card id}. Absent keys fall back to app defaults; the whole projection is recomputed client-side from these, so revising them after validating a claim regenerates every future state.';
