-- Chat first: the conversation becomes the front door.
--
-- The client is rebuilt around three tabs — Chats | Chute | Home — and the
-- chat schema of 20261116000000 grows what that needs:
--
--   * The three chat tables are declared SYSTEM in the siloing registry.
--     They were created after the registry existed and were never declared,
--     so the warden auto-registered them as 'table' — placeable as a whole,
--     which for chats is a sharing hazard: a chat is secret by audience
--     (its chat_followers roster IS the grant), and placing the whole table
--     in a silo would widen every conversation to a shelf of followers.
--     Declaring 'system' drops any placements and the warden's whole-table
--     follower grant; the per-chat follower policies from 20261116 are the
--     intended access, so their explicit grant is re-issued below.
--   * A third chat kind, 'syla': the owner's one conversation with their
--     agent. Seeded per owner (seed_owner_defaults + a backfill); the
--     client pins it by kind, not key.
--   * waiting_on_human on chats — the blue dot. Set by the owner's client
--     (a received ask_human message, "Ask [name] directly") or by Syla
--     through set_chat_waiting() when a reply needs the human.
--   * author and kind on chat_messages. Every cross-person feature is an
--     attributed message on the sender's side — the distributed-chat rule:
--     drafts, rules and conclusions stay local; what travels is a message
--     with a kind. 'auto_reply' is a message my Syla sent on my behalf
--     (always attributed — the receiving client renders "signed as Syla");
--     'ask_human' is the travelling ask-for-the-human flag (the receiving
--     client marks its chat waiting); 'syla_status' is Syla's own status
--     lines inside the Syla chat. No shared mutable chat state anywhere.
--   * syla_run_id on chat_messages links a Syla-chat message to its queued
--     run, which is how the thread shows receipts (20261126000000).
--
-- Claude's write path is structured only: column-scoped INSERT on
-- chat_messages behind a policy requiring author = 'syla', reached through
-- syla_chat_say() and (once reply rules exist, 20261122000000)
-- send_auto_reply(). send_auto_reply is created THERE, not here: it
-- asserts against reply_rules, so it follows the table — the clean
-- dependency order. The rule_id column on chat_messages moves with it.

-- ── Chats are system machinery, never placeable ──────────────────────────

select public.declare_table_siloing(t, 'system')
from unnest(array['chats', 'chat_followers', 'chat_messages']) as t;

-- The flip revoked the table-level follower SELECT the warden had made at
-- CREATE TABLE. The per-chat policies ("A follower reads chats naming
-- them", …) are the real access rule and still stand; give them their
-- grant back explicitly.
grant select on public.chats, public.chat_followers, public.chat_messages
    to follower;

-- ── The Syla conversation, and the waiting flag ──────────────────────────

alter table public.chats drop constraint chats_kind_check;
alter table public.chats
    add constraint chats_kind_check check (kind in ('dm', 'group', 'syla')),
    add column waiting_on_human boolean not null default false,
    add column waiting_since timestamptz;

comment on column public.chats.kind is
    'dm: one other person (one chat_followers row). group: several. syla: the owner''s one conversation with their agent — local only, never mirrored to a peer; the client pins it by this kind.';
comment on column public.chats.waiting_on_human is
    'The blue dot: this chat waits on a human, not on Syla. Set by the owner''s client (a received ask_human message, or tapping "Ask [name] directly") or by Syla through set_chat_waiting(); cleared when the human answers.';
comment on column public.chats.waiting_since is
    'When waiting_on_human was last raised; null while the flag is down.';

-- (authenticated already holds table-level UPDATE on chats from 20261116,
-- which covers the two new columns — no extra grant needed.)

-- ── Message authors and kinds ────────────────────────────────────────────

alter table public.chat_messages
    add column author text not null default 'me'
        check (author in ('me', 'syla')),
    add column kind text not null default 'text'
        check (kind in ('text', 'auto_reply', 'ask_human', 'syla_status')),
    add column syla_run_id uuid
        references public.syla_job_runs (id) on delete set null;

comment on column public.chat_messages.author is
    'Who wrote this side''s message: the owner (''me'' — including approved drafts, which send as the human) or their Syla (''syla'' — only ever through the gated RPCs, and only as auto_reply/text/status kinds).';
comment on column public.chat_messages.kind is
    'text: an ordinary message. auto_reply: sent by my Syla on my behalf under an active reply rule — always attributed; peers render it "signed as Syla". ask_human: the travelling ask-for-the-human flag — a receiving client marks its chat waiting_on_human. syla_status: Syla''s own status/receipt lines inside the Syla chat.';
comment on column public.chat_messages.syla_run_id is
    'For Syla-chat messages: the syla_job_runs row this message belongs to. The owner''s send points at the run send_to_syla queued; Syla''s reply points back at the run it answers — the thread''s receipt ladder reads off the run''s timestamps.';

create index chat_messages_syla_run_id_idx
    on public.chat_messages (syla_run_id);

-- ── Seed the Syla conversation ───────────────────────────────────────────
--
-- One per owner, pinned by kind. The chat_key check demands 8+ characters
-- (shared handles are minted long); this chat never crosses databases, so
-- its key is just a stable local constant that satisfies the check.
-- seed_owner_defaults gains the insert (body otherwise 20261006000000's);
-- the backfill covers databases whose owner is already crowned.

create or replace function public.seed_owner_defaults()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    insert into public.events (profile_id, title, assignee,
                               start_date, start_time, end_time, freq, interval_n)
    select new.id, s.title, 'syla',
           (now() at time zone 'America/New_York')::date, s.starts, s.ends, 'daily', 1
    from (values
            ('Daily note siloing',   time '06:15', time '06:30', 'syla/note-siloing'),
            ('Daily edit feedback',  time '06:30', time '06:45', 'syla/edit-feedback'),
            ('Goal synergy linking', time '06:45', time '07:00', 'syla/goal-synergy'),
            ('Morning day summary',  time '07:00', time '07:30', 'syla/daily-summary')
         ) as s (title, starts, ends, doc_path)
    where not exists (select 1 from public.events e
                      where e.title = s.title and e.assignee = 'syla');

    insert into public.event_docs (event_id, doc_id)
    select e.id, d.id
    from (values
            ('Daily note siloing',   'syla/note-siloing'),
            ('Daily edit feedback',  'syla/edit-feedback'),
            ('Goal synergy linking', 'syla/goal-synergy'),
            ('Morning day summary',  'syla/daily-summary')
         ) as s (title, doc_path)
    join public.events e on e.title = s.title and e.assignee = 'syla'
    join public.docs d on d.path = s.doc_path
    on conflict do nothing;

    insert into public.chats (chat_key, kind, title)
    select 'syla-chat', 'syla', 'Syla'
    where not exists (select 1 from public.chats where kind = 'syla');

    return new;
end
$$;

insert into public.chats (chat_key, kind, title)
select 'syla-chat', 'syla', 'Syla'
where exists (select 1 from public.profiles where is_owner)
  and not exists (select 1 from public.chats where kind = 'syla');

-- ── Claude's structured write path ───────────────────────────────────────
--
-- 20261116 gave chats no claude write path because chats had no proposals
-- to make. They still have none: what Syla writes is her OWN attributed
-- messages — into the Syla chat, and (under a rule, 20261122000000) into a
-- dm — plus the waiting flag. Column-scoped, policy-bound, RPC-reached;
-- she still cannot create, retitle or delete a chat, touch the roster, or
-- write a message as 'me'.

grant insert (chat_id, body, author, kind, syla_run_id)
    on public.chat_messages to claude;
create policy "claude sends only as Syla"
    on public.chat_messages for insert
    to claude
    with check (author = 'syla');

grant update (waiting_on_human, waiting_since) on public.chats to claude;
create policy "claude flags chats waiting on a human"
    on public.chats for update
    to claude
    using (true) with check (true);

-- Her reply in the Syla thread (and any line she wants on the record
-- there): one message, author 'syla', kind 'text', optionally pointing at
-- the run it answers.
create function public.syla_chat_say(_body text, _run_id uuid default null)
returns jsonb
language plpgsql
security invoker
as $$
declare
    _chat uuid;
    _id   uuid;
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    if _body is null or char_length(btrim(_body)) not between 1 and 8000 then
        raise exception 'the message must be 1–8000 characters';
    end if;

    select id into _chat from public.chats where kind = 'syla' limit 1;
    if _chat is null then
        raise exception 'this database has no Syla conversation yet (chats kind = syla)';
    end if;

    insert into public.chat_messages (chat_id, body, author, kind, syla_run_id)
    values (_chat, btrim(_body), 'syla', 'text', _run_id)
    returning id into _id;

    return jsonb_build_object('id', _id, 'chat_id', _chat);
end;
$$;

comment on function public.syla_chat_say(text, uuid) is
    'Syla''s message into the owner''s Syla conversation (the chats row with kind = syla), author ''syla'', kind ''text'', optionally linked to the syla_job_runs row it answers — the thread''s "reply" receipt. Gated by assert_claude_rq_key().';

revoke all on function public.syla_chat_say(text, uuid) from public;
grant execute on function public.syla_chat_say(text, uuid) to anon;

-- Raising (or lowering) the blue dot: a reply needs the human, so the chat
-- says so. The flag also travels to the peer as an ask_human MESSAGE —
-- that part is the client's and Syla's procedure, not this function's.
create function public.set_chat_waiting(_chat_id uuid, _waiting boolean)
returns jsonb
language plpgsql
security invoker
as $$
begin
    perform public.assert_claude_rq_key();

    set local statement_timeout = '30s';
    set local role claude;

    if _waiting is null then
        raise exception 'say whether the chat is waiting (true) or not (false)';
    end if;

    update public.chats
    set waiting_on_human = _waiting,
        waiting_since    = case when _waiting then now() end
    where id = _chat_id;

    if not found then
        raise exception 'no chat with id %', _chat_id;
    end if;

    return jsonb_build_object('chat_id', _chat_id, 'waiting', _waiting);
end;
$$;

comment on function public.set_chat_waiting(uuid, boolean) is
    'Flips a chat''s waiting_on_human flag (stamping waiting_since on raise) as the claude role — Syla saying "this one needs you, not me". Gated by assert_claude_rq_key().';

revoke all on function public.set_chat_waiting(uuid, boolean) from public;
grant execute on function public.set_chat_waiting(uuid, boolean) to anon;
