-- Channels: the market's actual links, as chosen node—link→node combos.
--
-- Every node—link→node combination is a potential relationship; a canvas
-- picks the few that exist and sets each one's properties — links per
-- node and spread multiplier — after selecting the triple, the same way
-- goals are defined. Channel cards live in a new 'channels' section with
-- params {"from": node-type card id or absent for any, "link": link-type
-- card id, "to": node-type card id or absent for any, "avg", "spread_mult"}.
-- Link types become pure vocabulary (name + color); their per-type
-- avg/spread properties move onto channels.

alter table public.network_strategy_cards
    drop constraint network_strategy_cards_section_check;

alter table public.network_strategy_cards
    add constraint network_strategy_cards_section_check check (section in (
        'target', 'entities', 'links', 'collectives',
        'size', 'growth', 'diffusion', 'criteria', 'target_criteria', 'rate',
        'campaign', 'spread', 'handoff', 'messages', 'goals', 'channels'));

-- Existing canvases: each info-carrying link type (one with an avg or a
-- legacy share — the goal/default types carry neither) becomes one
-- wildcard channel over any node types, keeping its numbers. Only for
-- strategies that have no channels yet, so a replay or an edited canvas
-- is left alone.
insert into public.network_strategy_cards
    (profile_id, strategy_id, section, title, rank, params)
select
    c.profile_id,
    c.strategy_id,
    'channels',
    c.title || ' (any ↔ any)',
    c.rank,
    jsonb_build_object(
        'link', c.id,
        'avg', coalesce((c.params->>'avg')::numeric, (c.params->>'share')::numeric, 1),
        'spread_mult', coalesce((c.params->>'spread_mult')::numeric, 1))
from public.network_strategy_cards c
where c.section = 'links'
  and c.deleted_at is null
  and (c.params ? 'avg' or c.params ? 'share')
  and not exists (
      select 1 from public.network_strategy_cards ch
      where ch.strategy_id = c.strategy_id
        and ch.section = 'channels'
        and ch.deleted_at is null);
