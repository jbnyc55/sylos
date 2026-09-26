-- Goals replace "me" on the network canvas.
--
-- The model, refined again: there is no special focal node. A goal is a
-- triple — a node of one type forming a link of one type to a node of
-- another type — and a strategy can define several, each counted
-- separately by the simulation. Goals are cards in a new 'goals' section,
-- their params naming the three type cards ({"from", "link", "to"}); the
-- sim's me_type / target_link fields are superseded (left in old rows,
-- ignored by the app).

alter table public.network_strategy_cards
    drop constraint network_strategy_cards_section_check;

alter table public.network_strategy_cards
    add constraint network_strategy_cards_section_check check (section in (
        'target', 'entities', 'links', 'collectives',
        'size', 'growth', 'diffusion', 'criteria', 'target_criteria', 'rate',
        'campaign', 'spread', 'handoff', 'messages', 'goals'));

comment on column public.network_strategy_cards.params is
    'Section-specific numbers behind the claim. Messages: {"virality", "threshold_drop"}. Node types: {"share"} or {"count"}. Link types: {"share", "spread_mult"}. Goals: {"from": node-type card id, "link": link-type card id, "to": node-type card id}. Absent keys fall back to app defaults.';

-- ---------------------------------------------------------------------------
-- Migrate the two pre-goals strategies: their me_type becomes the to-side
-- of a proper goal card, with a new goal-link type where none fits.
-- Everything is pinned to the known seeded row ids and guarded on "no
-- goals yet", so edited canvases are left alone and a from-scratch replay
-- is a no-op.
-- ---------------------------------------------------------------------------

do $$
declare
    v_profile uuid;
    v_link uuid;
begin
    -- Finding a girlfriend: goal = Singles —Partner→ Me.
    select profile_id into v_profile
    from public.network_strategies
    where id = '0e90a94d-630d-4a30-b11a-95878687f906' and deleted_at is null;

    if v_profile is not null and not exists (
        select 1 from public.network_strategy_cards
        where strategy_id = '0e90a94d-630d-4a30-b11a-95878687f906'
          and section = 'goals' and deleted_at is null
    ) then
        insert into public.network_strategy_cards
            (profile_id, strategy_id, section, title, status, rank, params)
        values
            (v_profile, '0e90a94d-630d-4a30-b11a-95878687f906', 'links',
             'Partner', 'assumption', 10, '{}')
        returning id into v_link;

        insert into public.network_strategy_cards
            (profile_id, strategy_id, section, title, status, rank, params)
        values
            (v_profile, '0e90a94d-630d-4a30-b11a-95878687f906', 'goals',
             'Singles —Partner→ Me', 'assumption', 0,
             jsonb_build_object(
                 'from', '42dee419-795c-4e30-82c7-aaa14948782b',
                 'link', v_link,
                 'to',   '0f3b7ade-3616-494f-b5de-aaf9255785ae'));
    end if;

    -- Uber vs taxis: goal = Rider —Buyer→ Uber.
    select profile_id into v_profile
    from public.network_strategies
    where id = 'f78d60e1-d462-4df7-8383-283f2f8b872e' and deleted_at is null;

    if v_profile is not null and not exists (
        select 1 from public.network_strategy_cards
        where strategy_id = 'f78d60e1-d462-4df7-8383-283f2f8b872e'
          and section = 'goals' and deleted_at is null
    ) then
        insert into public.network_strategy_cards
            (profile_id, strategy_id, section, title, status, rank, params)
        values
            (v_profile, 'f78d60e1-d462-4df7-8383-283f2f8b872e', 'links',
             'Buyer', 'assumption', 10, '{}')
        returning id into v_link;

        insert into public.network_strategy_cards
            (profile_id, strategy_id, section, title, status, rank, params)
        values
            (v_profile, 'f78d60e1-d462-4df7-8383-283f2f8b872e', 'goals',
             'Rider —Buyer→ Uber', 'testing', 0,
             jsonb_build_object(
                 'from', 'd980c3ea-d32b-4f40-a5de-df967cb7be25',
                 'link', v_link,
                 'to',   'e6f14f39-d012-4137-9c08-239d2c247b23'));
    end if;
end
$$;
