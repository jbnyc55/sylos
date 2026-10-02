-- Reply rules: the per-person preflight, in plain English.
--
-- A reply rule is one sentence the owner can read, edit and reorder — the
-- whole list for a connection is checked top-to-bottom (rank order) before
-- any auto-reply sends, and anything the sentences do not cover waits for
-- the human. Exactly two verdicts: REPLY and DON'T REPLY. Rules are
-- decoupled from silos entirely — silos stay pure data slices
-- (20261128000000); rules are reply semantics and live here alone.
--
-- Provenance is a label, never a lock: built_in marks the one rule every
-- connection starts with ("Never agree to money, travel, or plans with
-- other people"), and Syla's suggestions arrive as status 'suggested' —
-- but every rule, whoever wrote it, is editable text the owner owns.
-- Two platform guarantees are deliberately NOT rules, because rules are
-- editable and these must not be: a message asking for the human always
-- stops Syla (stated in the app's footnote, bound in her skills doc), and
-- the preflight itself — uncovered means wait. The database's gate here is
-- structural, not semantic: send_auto_reply (below) proves the mode, the
-- rule's existence, status and verdict; reading the thread against the
-- sentences is the agent's procedure (skills/chat-replies), and a wrong
-- call is attributable — the message carries rule_id, and everything is in
-- row_edits.
--
-- Statuses: 'active' counts in the preflight; 'draft' is parked (an
-- integration declined, a rule the owner shelved); 'suggested' is Syla's
-- proposal card — capped at ONE pending suggestion per connection, and the
-- skills doc has her offer the next one only after a yes.

create table public.reply_rules (
    id                uuid primary key default gen_random_uuid(),
    follower_id       uuid not null references public.followers (id) on delete cascade,
    -- Checked top-to-bottom in rank order; fractional ranks make reordering
    -- one update.
    rank              double precision not null default 0,
    verdict           text not null check (verdict in ('reply', 'dont_reply')),
    body              text not null check (char_length(body) between 1 and 500),
    built_in          boolean not null default false,
    status            text not null default 'active'
                      check (status in ('active', 'draft', 'suggested')),
    rationale         text check (rationale is null or char_length(rationale) <= 500),
    needs_integration text check (needs_integration is null
                                  or char_length(needs_integration) <= 80),
    created_at        timestamptz not null default now(),
    updated_at        timestamptz not null default now()
);

comment on table public.reply_rules is
    'The per-connection preflight: plain-English sentences checked top-to-bottom (rank order) before any auto-reply sends; anything uncovered waits for the human. Two verdicts (reply / dont_reply); every rule is editable text, built_in and suggested included. The owner''s table; Syla only ever inserts status ''suggested'' through suggest_reply_rule().';
comment on column public.reply_rules.rank is
    'Position in the preflight, ascending. The built-in seed sits at 1000 so owner rules naturally check first.';
comment on column public.reply_rules.built_in is
    'Seeded with the connection rather than written by anyone — a provenance label only; the text stays editable like every rule.';
comment on column public.reply_rules.status is
    'active: counts in the preflight. draft: parked — e.g. the integration it needs was declined. suggested: Syla''s pending proposal, shown as a card; accepting flips it active.';
comment on column public.reply_rules.rationale is
    'Syla''s why, shown on the suggestion card. Null on owner-written rules.';
comment on column public.reply_rules.needs_integration is
    'Slug of a missing integration that would power this rule (e.g. ''location''), disclosed on the card; the connect sheet follows an accepted rule that names one.';

create index reply_rules_follower_rank_idx
    on public.reply_rules (follower_id, rank);

create trigger reply_rules_set_updated_at
    before update on public.reply_rules
    for each row execute function public.set_updated_at();

alter table public.reply_rules enable row level security;
select public.declare_table_siloing('reply_rules', 'system');

-- The owner runs the list entirely; followers never see anyone's rules —
-- one-sided visibility is the point.
create policy "Reply rules are the owner's"
    on public.reply_rules for all to authenticated
    using (public.is_owner()) with check (public.is_owner());
create policy "claude reads reply rules"
    on public.reply_rules for select to claude using (true);
create policy "claude only ever suggests rules"
    on public.reply_rules for insert to claude
    with check (status = 'suggested');

grant select, insert, update, delete on public.reply_rules to authenticated;
grant select on public.reply_rules to claude;
-- status is in the column list so the RPC can say 'suggested' explicitly
-- (the column default is 'active', which the policy would refuse);
-- built_in, id and the timestamps stay on their defaults.
grant insert (follower_id, rank, verdict, body, status, rationale, needs_integration)
    on public.reply_rules to claude;

-- ── Every connection starts with the built-in guardrail ──────────────────

create function public.followers_seed_builtin_rule()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.reply_rules (follower_id, rank, verdict, body, built_in)
    values (new.id, 1000, 'dont_reply',
            'Never agree to money, travel, or plans with other people', true);
    return new;
end;
$$;

comment on function public.followers_seed_builtin_rule() is
    'AFTER INSERT on followers: seeds the one shipped DON''T REPLY rule every connection starts with. A label-bearing row like any other — the owner may rewrite or even delete it; the undeletable guarantee (asking for the human stops Syla) is platform behavior, not a rule.';

revoke execute on function public.followers_seed_builtin_rule()
    from public, anon, authenticated;

create trigger followers_seed_builtin_rule
    after insert on public.followers
    for each row execute function public.followers_seed_builtin_rule();

insert into public.reply_rules (follower_id, rank, verdict, body, built_in)
select f.id, 1000, 'dont_reply',
       'Never agree to money, travel, or plans with other people', true
from public.followers f
where not exists (select 1 from public.reply_rules r
                  where r.follower_id = f.id and r.built_in);

-- ── Syla's one suggestion at a time ──────────────────────────────────────

create function public.suggest_reply_rule(
    _follower_id       uuid,
    _verdict           text,
    _body              text,
    _rationale         text default null,
    _needs_integration text default null
)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _rank double precision;
    _id   uuid;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    if _verdict not in ('reply', 'dont_reply') then
        raise exception 'verdict must be reply or dont_reply';
    end if;
    if _body is null or char_length(btrim(_body)) not between 1 and 500 then
        raise exception 'the rule must be 1–500 characters of plain English';
    end if;
    if _rationale is not null and char_length(_rationale) > 500 then
        raise exception 'the rationale is longer than 500 characters';
    end if;
    if _needs_integration is not null and char_length(_needs_integration) > 80 then
        raise exception 'the integration slug is longer than 80 characters';
    end if;
    if not exists (select 1 from public.followers f where f.id = _follower_id) then
        raise exception 'no connection with id %', _follower_id;
    end if;

    -- One pending suggestion per connection; the next only after a yes.
    if exists (select 1 from public.reply_rules
               where follower_id = _follower_id and status = 'suggested') then
        raise exception 'this connection already has a pending rule suggestion — offer the next one only after the owner resolves it';
    end if;

    -- Slot below the owner's rules but above the built-in guardrail.
    select coalesce(max(rank), 0) + 10 into _rank
    from public.reply_rules
    where follower_id = _follower_id and not built_in;

    insert into public.reply_rules
        (follower_id, rank, verdict, body, status, rationale, needs_integration)
    values
        (_follower_id, _rank, _verdict, btrim(_body), 'suggested',
         _rationale, _needs_integration)
    returning id into _id;

    return jsonb_build_object('id', _id, 'status', 'suggested', 'rank', _rank);
end;
$$;

comment on function public.suggest_reply_rule(uuid, text, text, text, text) is
    'Files one pending reply-rule suggestion for a connection as the claude role — a card the owner accepts (status → active, text editable first), parks (draft) or deletes. Capped at one pending suggestion per connection. Gated by assert_claude_rq_key().';

revoke all on function public.suggest_reply_rule(uuid, text, text, text, text) from public;
grant execute on function public.suggest_reply_rule(uuid, text, text, text, text) to anon;

-- ── The message remembers its rule ───────────────────────────────────────
--
-- 20261121000000 left this column to this file on purpose: it references
-- reply_rules, so it is created after the table it points at.

alter table public.chat_messages
    add column rule_id uuid references public.reply_rules (id) on delete set null;

comment on column public.chat_messages.rule_id is
    'For kind = auto_reply: the active reply rule that authorized the send. The attribution trail — every auto-reply names its rule, and the rule''s text at send time is recoverable from row_edits.';

grant insert (rule_id) on public.chat_messages to claude;

-- ── Sending under a rule ─────────────────────────────────────────────────
--
-- The structural gate for auto mode: a dm, a single counterparty whose
-- mode allows it, and an ACTIVE, REPLY-verdict rule of theirs to cite.
-- Whether the rule's sentence truly covers the message is the preflight —
-- agent procedure (skills/chat-replies), attributable via rule_id — not
-- something SQL can judge.

create function public.send_auto_reply(_chat_id uuid, _body text, _rule_id uuid)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _kind     text;
    _n        integer;
    _follower uuid;
    _mode     text;
    _id       uuid;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    if _body is null or char_length(btrim(_body)) not between 1 and 8000 then
        raise exception 'the message must be 1–8000 characters';
    end if;

    select kind into _kind from public.chats where id = _chat_id;
    if _kind is null then
        raise exception 'no chat with id %', _chat_id;
    end if;
    if _kind <> 'dm' then
        raise exception 'auto-replies are for dms only (this chat is %)', _kind;
    end if;

    select count(*) into _n from public.chat_followers where chat_id = _chat_id;
    if _n <> 1 then
        raise exception 'auto-replies need exactly one counterparty (this chat names %)', _n;
    end if;
    select follower_id into _follower
    from public.chat_followers where chat_id = _chat_id;

    select syla_reply_mode into _mode
    from public.followers where id = _follower;
    if _mode not in ('auto', 'syla_syla') then
        raise exception 'this connection does not allow auto-replies (mode %)', _mode;
    end if;

    if not exists (
        select 1 from public.reply_rules r
        where r.id = _rule_id
          and r.follower_id = _follower
          and r.status = 'active'
          and r.verdict = 'reply'
    ) then
        raise exception 'the cited rule must be an active REPLY rule of this connection';
    end if;

    insert into public.chat_messages (chat_id, body, author, kind, rule_id)
    values (_chat_id, btrim(_body), 'syla', 'auto_reply', _rule_id)
    returning id into _id;

    return jsonb_build_object('id', _id, 'chat_id', _chat_id, 'rule_id', _rule_id);
end;
$$;

comment on function public.send_auto_reply(uuid, text, uuid) is
    'Sends one attributed auto-reply (author ''syla'', kind ''auto_reply'') into a dm as the claude role, citing the active REPLY rule that authorized it — refused unless the chat is a dm whose single counterparty''s syla_reply_mode is auto or syla_syla and the rule is theirs, active, verdict reply. The semantic preflight is skills/chat-replies; this gate is structural. Gated by assert_claude_rq_key().';

revoke all on function public.send_auto_reply(uuid, text, uuid) from public;
grant execute on function public.send_auto_reply(uuid, text, uuid) to anon;
