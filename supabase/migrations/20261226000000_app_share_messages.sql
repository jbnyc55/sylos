-- App share: an app travels as a message.
--
-- Sharing a vibe code app with a connection used to be a negotiation in
-- prose plus a trip through the silo screens. It becomes ONE message:
-- kind 'app_share', carrying the app's slug in the sender's database.
-- The receiving client renders it as a card — the app's name, icon and
-- manifest read over the follower key — and ONE accept does the whole
-- receiving side: copy the bundle home (apps are never served between
-- databases; every source of truth is local) and grant back the silo
-- the manifest names, both as the receiver's own owner-session writes.
--
-- Why a message and not the follower_silo_requests queue: the queue is
-- a write into the RECEIVER'S database, which needs a token the sender
-- may not hold yet. A message is a row in the SENDER'S database, which
-- makes the whole flow pre-stageable: the sender invites someone, the
-- client opens the chat immediately, and the share card simply waits —
-- unreadable until the claim mints the key, delivered the moment it
-- does. Nothing crosses any boundary at all; the distributed-chat rule
-- ("every cross-person feature travels as an attributed message on the
-- sender's side") carries one more feature.
--
-- What the sender's client does at share time, all owner-session writes
-- in the sender's own database:
--
--   * names the connection on the app (vibe_code_app_followers) so the
--     card's reads — the row's name and icon, the manifest file, and
--     the bundle the accept copies — pass that follower's RLS;
--   * grants its own side of the data (the silo the app's manifest
--     names gets the connection's follow, and the tables the app reads
--     sit in that silo) — stated plainly on the share sheet, because a
--     two-player app is two one-way grants and this is the sender's;
--   * inserts the app_share message, then pokes (follower_poke_chat)
--     when the connection is already claimed.
--
-- The accept on the receiving side is likewise all local: copy the
-- bundle into vibe_code_apps (owner insert), ensure the named silo
-- holds the app's tables, and put the sender's follower row in it.
-- Approving a share is the receiver's act under the receiver's
-- session — exactly the house pattern, no new write path anywhere.
--
-- No claude write: Syla builds and deploys apps (save_vibe_code_app),
-- but SHARING one is a grant, and grants are the owner's alone. Her
-- column-scoped insert on chat_messages deliberately stays without
-- app_slug; what she drafts (chat_reply_proposals) is words.

-- ── The kind, and the slug it carries ────────────────────────────────────

alter table public.chat_messages drop constraint chat_messages_kind_check;
alter table public.chat_messages
    add constraint chat_messages_kind_check
        check (kind in ('text', 'auto_reply', 'ask_human', 'syla_status',
                        'app_share')),
    add column app_slug text
        check (app_slug is null
               or (app_slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
                   and char_length(app_slug) <= 100)),
    add constraint chat_messages_app_share_check
        check ((kind = 'app_share') = (app_slug is not null));

comment on column public.chat_messages.kind is
    'text: an ordinary message. auto_reply: sent by my Syla on my behalf under an active reply rule — always attributed; peers render it "signed as Syla". ask_human: the travelling ask-for-the-human flag — a receiving client marks its chat waiting_on_human. syla_status: Syla''s own status/receipt lines inside the Syla chat. app_share: this side shared a vibe code app — app_slug names it here; the receiving client renders the card and one accept copies the bundle home and grants back the silo its manifest names.';
comment on column public.chat_messages.app_slug is
    'For kind app_share only: the shared app''s slug in THIS database. The receiver reads the app row, its sylos-manifest.json and (on accept) the bundle over their follower key — the sender''s client named them on the app (vibe_code_app_followers) at share time — then rebuilds it locally; apps are never served between databases.';

-- A share can ride with or without words: the card is the message, like
-- an attachment.
alter table public.chat_messages drop constraint chat_messages_body_check;
alter table public.chat_messages add constraint chat_messages_body_check
    check (char_length(body) <= 8000
           and (char_length(body) >= 1
                or upload_id is not null
                or app_slug is not null));

-- (No new grants: authenticated and follower hold table-level SELECT and
-- authenticated table-level INSERT, so the new column rides along.
-- claude's column-scoped INSERT stays without app_slug on purpose.)

-- ── skills/chat-replies knows a share card is not hers to answer ─────────
--
-- Targeted guarded swap, the house pattern for seeded docs.

update public.docs
set html = replace(html,
    '<p>Your side''s messages are in <code>chat_messages</code>;',
    '<p>A message with <code>kind = ''app_share''</code> (yours or a peer''s) is a shared-app card: the owner acts on it in the thread — accepting is their client''s work, never yours — so it needs no draft unless words ride along that genuinely ask something. Your side''s messages are in <code>chat_messages</code>;')
where path = 'skills/chat-replies'
  and html not like '%shared-app card%';
