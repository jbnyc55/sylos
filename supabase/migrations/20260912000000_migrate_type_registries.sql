-- Migrate the pre-registry canvases to named node types and link types.
--
-- The two strategies seeded before 20260911's registries carry prose
-- claims in the 'entities' and 'links' sections ("Single women ~26–34 who
-- want something serious", "Close friends — high trust, but only two of
-- them know I'm actually looking"). The registries want single names with
-- params (mix share, spread multiplier, the focal type's dot count), so
-- each old card becomes a named type: the single name moves into title,
-- the numbers into params, and the original prose is preserved in the
-- card's evidence notes rather than lost. The card rows keep their ids and
-- statuses — this is a rename, not a replacement.
--
-- Every update is pinned to the specific row id it was written for, so on
-- a database that never held these seeded rows (a from-scratch replay)
-- this migration is a no-op.

create or replace function pg_temp.migrate_type_card(
    card_id uuid,
    new_title text,
    new_params jsonb
) returns void language plpgsql as $$
begin
    update public.network_strategy_cards
    set title = new_title,
        params = new_params,
        notes = case
            when notes is null or notes = '' then 'Original claim: ' || title
            else notes || E'\n\nOriginal claim: ' || title
        end
    where id = card_id
      -- Only ever migrate a card still wearing its pre-registry shape; a
      -- card the owner has since renamed or parameterized is theirs.
      and params is null;
end
$$;

-- ---------------------------------------------------------------------------
-- Finding a girlfriend
-- ---------------------------------------------------------------------------

-- Node types. "Me — the node trying to form the link" becomes the focal
-- type; the sim blob below points me_type at it.
select pg_temp.migrate_type_card(
    '0f3b7ade-3616-494f-b5de-aaf9255785ae', 'Me', '{"count": 1}');
select pg_temp.migrate_type_card(
    '42dee419-795c-4e30-82c7-aaa14948782b', 'Singles', '{"share": 3}');
select pg_temp.migrate_type_card(
    '76bbce20-ac00-4207-9cf1-1c8552a03651', 'Connectors', '{"share": 1}');
select pg_temp.migrate_type_card(
    '6a8dff88-c1a6-40a1-b5e0-4d67d1eeb777', 'Hosts', '{"share": 2}');

-- Link types: friendship carries information fast, acquaintance slowly,
-- and the coworker claim itself says office norms suppress it.
select pg_temp.migrate_type_card(
    'db2c2527-99f6-4dd3-b667-c0908bdac992', 'Friendship',
    '{"share": 2, "spread_mult": 1.5}');
select pg_temp.migrate_type_card(
    '28ef13eb-107f-4920-8d78-e6bf60ea9be3', 'Acquaintance',
    '{"share": 6, "spread_mult": 0.6}');
select pg_temp.migrate_type_card(
    '94c3c0df-395b-44a2-a0f5-9df1b39cbd3c', 'Coworker',
    '{"share": 3, "spread_mult": 0.3}');

-- This strategy predates the sim blob entirely, so it gets the worked
-- example's parameters plus the focal type — only if it still has none.
update public.network_strategies
set sim = jsonb_build_object(
        'network_size', 80, 'avg_links', 4, 'my_links', 7,
        'join_pct', 4, 'leave_pct', 3, 'churn_pct', 6,
        'relink_pct', 8, 'commit_pct', 30, 'unlink_pct', 25,
        'node_scale', 1, 'seed', 7,
        'me_type', '0f3b7ade-3616-494f-b5de-aaf9255785ae')
where id = '0e90a94d-630d-4a30-b11a-95878687f906'
  and sim is null;

-- ---------------------------------------------------------------------------
-- Uber vs taxis
-- ---------------------------------------------------------------------------

select pg_temp.migrate_type_card(
    'e6f14f39-d012-4137-9c08-239d2c247b23', 'Uber', '{"count": 1}');
select pg_temp.migrate_type_card(
    'd980c3ea-d32b-4f40-a5de-df967cb7be25', 'Rider', '{"share": 10}');
select pg_temp.migrate_type_card(
    '7664b876-66af-4f93-9d0a-d0ac1f357611', 'Adopter', '{"share": 2}');

select pg_temp.migrate_type_card(
    'abfd6a22-0a6d-4b30-b5be-be737173ba2b', 'Recommender',
    '{"share": 3, "spread_mult": 1.2}');
select pg_temp.migrate_type_card(
    'd104ad4f-f725-4578-90d5-e8785326523e', 'Sharer',
    '{"share": 2, "spread_mult": 1.6}');

-- This strategy already has a sim blob from the simulation era; it only
-- lacks the focal type. Merge, never overwrite tuned knobs — and only
-- while no focal type has been chosen.
update public.network_strategies
set sim = sim || jsonb_build_object(
        'me_type', 'e6f14f39-d012-4137-9c08-239d2c247b23')
where id = 'f78d60e1-d462-4df7-8383-283f2f8b872e'
  and sim is not null
  and sim->>'me_type' is null;

drop function pg_temp.migrate_type_card(uuid, text, jsonb);
