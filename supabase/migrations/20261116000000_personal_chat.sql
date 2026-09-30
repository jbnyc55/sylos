-- Personal chat: your words in your own database.
--
-- Chat stops being the one centralized record. A conversation has no
-- host anywhere: EACH MEMBER'S OWN PROJECT holds their side of it —
-- the messages they sent — and reading a chat means merging the sides
-- by timestamp, each fetched from its author's database over the
-- follower machinery that already exists (a DM is a MUTUAL FOLLOW).
-- The company project keeps no chat index, no bodies, no social graph;
-- its one remaining chat duty is a stateless push hop (the relay that
-- wakes a phone stores nothing). notes/10-apps-and-chat.md carries the
-- full story and the costs, chosen deliberately: no cold-start DMs
-- before a project exists, no contact discovery, a paused peer is a
-- silent peer.
--
-- The shape, three tables in the owner's schema:
--
--   * chats — one row per conversation the owner is in. chat_key is
--     the SHARED handle: the creator mints it, and every member's own
--     copy of the conversation carries the same key, which is how two
--     databases' halves know they are the same chat.
--   * chat_members — who else is in it, as references to the owner's
--     own members rows (the followers). Naming a member on a chat IS
--     the grant: DMs never touch silos. A silo placement can widen a
--     record to a whole shelf of followers; a chat is secret by
--     audience, so its visibility rule is membership, full stop.
--   * chat_messages — the owner's own messages, append-only in use,
--     and deletable: deleting your side is REAL deletion (the peers'
--     copies of their own words are theirs, in their databases).
--
-- A member's client discovers a new conversation by reading the
-- creator's database: the select policies below show a follower
-- exactly the chats that name them, and their client mirrors the row
-- (same chat_key, roster pointing back) into its own project. Nobody
-- ever writes into anyone else's database — each side only reads.
--
-- The row_edits event trigger (20260831010000) attaches logging to
-- these tables the moment they are created, so every send and delete
-- carries the usual undo images.

create table public.chats (
    id          uuid primary key default gen_random_uuid(),
    -- The shared conversation handle, minted by whoever starts the
    -- chat and copied verbatim into every member's own chats row.
    chat_key    text not null unique
                check (chat_key ~ '^[A-Za-z0-9_-]+$'
                       and char_length(chat_key) between 8 and 100),
    kind        text not null default 'dm' check (kind in ('dm', 'group')),
    -- The owner's own name for it; '' shows the members' names.
    title       text not null default '' check (char_length(title) <= 200),
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

create table public.chat_members (
    chat_id     uuid not null references public.chats (id) on delete cascade,
    member_id   uuid not null references public.members (id) on delete cascade,
    created_at  timestamptz not null default now(),
    primary key (chat_id, member_id)
);

create table public.chat_messages (
    id          uuid primary key default gen_random_uuid(),
    chat_id     uuid not null references public.chats (id) on delete cascade,
    body        text not null check (char_length(body) between 1 and 8000),
    created_at  timestamptz not null default now()
);

comment on table public.chats is
    'One row per conversation this owner is in — their own copy. chat_key is the shared handle every member''s copy carries; the sides of a chat live in their authors'' databases and clients merge them by timestamp.';
comment on table public.chat_members is
    'Who else is in the chat, as this owner''s members rows. Naming a member IS the read grant — chats are secret by audience and never siloed.';
comment on table public.chat_messages is
    'The owner''s own messages only; the other sides live in their authors'' databases. Deleting a row is real deletion of your side (row_edits still holds the undo image).';

create index chat_members_member_id_idx on public.chat_members (member_id);
create index chat_messages_chat_id_created_at_idx
    on public.chat_messages (chat_id, created_at);

create trigger chats_set_updated_at
    before update on public.chats
    for each row execute function public.set_updated_at();

-- ── Row level security ───────────────────────────────────────────────────

alter table public.chats enable row level security;
alter table public.chat_members enable row level security;
alter table public.chat_messages enable row level security;

-- The owner runs their side entirely: create chats, name members,
-- send, and delete for real.
create policy "Chats are the owner's"
    on public.chats for all to authenticated
    using (public.is_owner()) with check (public.is_owner());
create policy "Chat members follow the owner"
    on public.chat_members for all to authenticated
    using (public.is_owner()) with check (public.is_owner());
create policy "Chat messages are the owner's"
    on public.chat_messages for all to authenticated
    using (public.is_owner()) with check (public.is_owner());

-- A follower reads exactly the chats that name them: the row (to
-- discover and mirror the conversation), their own naming (the
-- proof), and the messages of those chats. Never a write: their side
-- of the conversation lives in their own database.
create policy "A member reads chats naming them"
    on public.chats for select
    to member
    using (exists (
        select 1 from public.chat_members cm
        where cm.chat_id = chats.id
          and cm.member_id = public.current_member_id()
    ));
create policy "A member reads their own chat namings"
    on public.chat_members for select
    to member
    using (member_id = public.current_member_id());
create policy "A member reads messages of chats naming them"
    on public.chat_messages for select
    to member
    using (exists (
        select 1 from public.chat_members cm
        where cm.chat_id = chat_messages.chat_id
          and cm.member_id = public.current_member_id()
    ));

grant select, insert, update, delete on public.chats to authenticated;
grant select, insert, delete on public.chat_members to authenticated;
grant select, insert, delete on public.chat_messages to authenticated;
grant select on public.chats to member;
grant select on public.chat_members to member;
grant select on public.chat_messages to member;

-- The agent reads the owner's own sent messages like any of the
-- owner's records (her sweeps, the archive of your own words); the
-- other sides sit in other people's databases, where only their own
-- agents and grants apply. No claude write path: chats have no
-- proposals to make.
create policy "claude reads chats"
    on public.chats for select to claude using (true);
create policy "claude reads chat members"
    on public.chat_members for select to claude using (true);
create policy "claude reads chat messages"
    on public.chat_messages for select to claude using (true);
grant select on public.chats, public.chat_members, public.chat_messages to claude;

-- Peers listen live while the app is open: one realtime channel per
-- followed project, RLS deciding per-row as always. Guarded so a
-- database without the publication (or with the table already in it)
-- applies cleanly.
do $$
begin
    alter publication supabase_realtime add table public.chat_messages;
exception
    when undefined_object then null;
    when duplicate_object then null;
end
$$;
